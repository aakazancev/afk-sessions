import Foundation

public struct UsageStat: Sendable, Equatable {
    public var count = 0
    public var last: Date?
    public init(count: Int = 0, last: Date? = nil) { self.count = count; self.last = last }

    mutating func add(_ other: UsageStat) {
        count += other.count
        if let l = other.last, l > (last ?? .distantPast) { last = l }
    }
}

public struct UsageIndex: Sendable {
    public var byRef: [String: [String: UsageStat]] = [:]
    public var sessionsByProject: [String: Int] = [:]
    public init() {}

    public var projects: [String] {
        sessionsByProject.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.map(\.key)
    }

    public func total(_ refs: [String]) -> UsageStat {
        var s = UsageStat()
        for r in Set(refs) { for (_, v) in byRef[r] ?? [:] { s.add(v) } }
        return s
    }

    public func inProject(_ refs: [String], _ project: String) -> UsageStat {
        var s = UsageStat()
        for r in Set(refs) { if let v = byRef[r]?[project] { s.add(v) } }
        return s
    }

    /// Коннекторы claude.ai видны только по вызовам.
    public var connectors: [String] {
        byRef.keys.filter { $0.hasPrefix("mcp:claude_ai_") }
            .map { String($0.dropFirst("mcp:".count)) }.sorted()
    }
}

/// Вызовы MCP / скиллов / агентов из транскриптов ~/.claude/projects/*/*.jsonl.
/// Работает на одной очереди вызывающего (кэш без блокировок).
public final class UsageScanner: @unchecked Sendable {

    private struct Call { let ref: String; let date: Date }
    private struct FileUsage { let mtime: Date; let size: Int; let project: String?; let calls: [Call] }

    private let paths: ClaudePaths
    private var cache: [String: FileUsage] = [:]
    private let iso = ISO8601DateFormatter()
    private let isoFrac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    public init(paths: ClaudePaths) { self.paths = paths }

    public static func refs(toolName: String, input: [String: Any]) -> [String] {
        if toolName.hasPrefix("mcp__") {
            let parts = toolName.components(separatedBy: "__")
            return parts.count >= 3 ? ["mcp:\(parts[1])"] : []
        }
        switch toolName {
        case "Skill":
            return (input["skill"] as? String).map { ["skill:\($0)"] } ?? []
        case "Agent", "Task":
            return (input["subagent_type"] as? String).map { ["agent:\($0)"] } ?? []
        default:
            return []
        }
    }

    public func scan(days: Int, now: Date = .now) -> UsageIndex {
        let fm = FileManager.default
        let cutoff = now.addingTimeInterval(-Double(days) * 86400)
        var index = UsageIndex()
        let dirs = (try? fm.contentsOfDirectory(at: paths.transcripts, includingPropertiesForKeys: nil)) ?? []

        func add(_ usage: FileUsage, project: String) {
            for call in usage.calls where call.date > cutoff {
                var stat = index.byRef[call.ref]?[project] ?? UsageStat()
                stat.add(UsageStat(count: 1, last: call.date))
                index.byRef[call.ref, default: [:]][project] = stat
            }
        }

        for dir in dirs {
            let items = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
            // Сессии: <dir>/<session>.jsonl
            for file in items where file.pathExtension == "jsonl" {
                guard let usage = usage(file, cutoff: cutoff), let project = usage.project else { continue }
                index.sessionsByProject[project, default: 0] += 1
                add(usage, project: project)
            }
            // Сабагенты: <dir>/<session>/subagents/*.jsonl — вызовы в проект, но не сессии
            for sessionDir in items where sessionDir.pathExtension != "jsonl" {
                let subDir = sessionDir.appendingPathComponent("subagents")
                let subs = (try? fm.contentsOfDirectory(at: subDir, includingPropertiesForKeys: nil)) ?? []
                for file in subs where file.pathExtension == "jsonl" {
                    guard let usage = usage(file, cutoff: cutoff), !usage.calls.isEmpty else { continue }
                    let parent = dir.appendingPathComponent(sessionDir.lastPathComponent + ".jsonl")
                    guard let project = usage.project ?? self.usage(parent, cutoff: nil)?.project else { continue }
                    add(usage, project: project)
                }
            }
        }
        return index
    }

    /// Разобранный файл из кэша по (mtime, size); nil — нет файла или mtime старше cutoff.
    private func usage(_ file: URL, cutoff: Date?) -> FileUsage? {
        guard let v = try? file.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
              let mtime = v.contentModificationDate else { return nil }
        if let cutoff, mtime <= cutoff { return nil }
        let size = v.fileSize ?? 0
        if let c = cache[file.path], c.mtime == mtime, c.size == size { return c }
        let u = parse(file, mtime: mtime, size: size)
        cache[file.path] = u
        return u
    }

    private static let toolUseMarker = Data(#""tool_use""#.utf8)
    private static let cwdMarker = Data(#""cwd""#.utf8)

    private func parse(_ file: URL, mtime: Date, size: Int) -> FileUsage {
        var project: String?
        var calls: [Call] = []
        guard let data = try? Data(contentsOf: file, options: .alwaysMapped) else {
            return FileUsage(mtime: mtime, size: size, project: nil, calls: [])
        }
        for line in data.split(separator: 0x0A) {
            // Дешёвый фильтр по байтам: JSON разбираем только строки с вызовами
            // (и строки с cwd, пока проект не найден).
            let hasToolUse = line.range(of: Self.toolUseMarker) != nil
            guard hasToolUse || (project == nil && line.range(of: Self.cwdMarker) != nil),
                  let obj = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { continue }
            if project == nil, let cwd = obj["cwd"] as? String, !cwd.isEmpty { project = cwd }
            guard hasToolUse, obj["type"] as? String == "assistant",
                  let content = (obj["message"] as? [String: Any])?["content"] as? [[String: Any]],
                  let ts = obj["timestamp"] as? String,
                  let date = isoFrac.date(from: ts) ?? iso.date(from: ts) else { continue }
            for block in content where block["type"] as? String == "tool_use" {
                guard let name = block["name"] as? String else { continue }
                for ref in Self.refs(toolName: name, input: block["input"] as? [String: Any] ?? [:]) {
                    calls.append(Call(ref: ref, date: date))
                }
            }
        }
        return FileUsage(mtime: mtime, size: size, project: project, calls: calls)
    }
}
