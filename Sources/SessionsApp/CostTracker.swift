import Foundation

struct ProjectCost {
    var today: Double = 0
    var week: Double = 0
}

struct CostSnapshot {
    var bySession: [String: Double] = [:]    // sessionId → $ за всю сессию
    var byProject: [String: ProjectCost] = [:]
    var totalToday: Double = 0
}

/// Деньги по транскриптам Claude Code (~/.claude/projects/*/*.jsonl).
/// Разбор кэшируется по (mtime, size) — пересчитываются только изменённые файлы.
/// Цены за MTok: Fable/Mythos 10/50, Opus 5/25, Sonnet 3/15, Haiku 1/5.
/// Кэш: чтение ×0.1, запись 5м ×1.25, запись 1ч ×2.
final class CostTracker {

    static let shared = CostTracker()

    private struct FileStats {
        var mtime: Date
        var size: Int
        var project: String
        var total: Double
        var daily: [String: Double]   // "yyyy-MM-dd" локального дня → $
    }

    private var cache: [String: FileStats] = [:]
    private let queue = DispatchQueue(label: "sessions.cost", qos: .utility)

    private let dayKey: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
    private let isoFrac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private let iso = ISO8601DateFormatter()

    func refresh(completion: @escaping @Sendable (CostSnapshot) -> Void) {
        queue.async { [self] in
            let snapshot = scan()
            DispatchQueue.main.async { completion(snapshot) }
        }
    }

    // MARK: - Сканирование

    private func scan() -> CostSnapshot {
        let fm = FileManager.default
        let root = fm.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects")
        let cutoff = Date().addingTimeInterval(-8 * 86400)

        var snapshot = CostSnapshot()
        let projects = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        for dir in projects {
            let files = (try? fm.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey]
            )) ?? []
            for file in files where file.pathExtension == "jsonl" {
                guard let attrs = try? file.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
                      let mtime = attrs.contentModificationDate,
                      mtime > cutoff else { continue }
                let size = attrs.fileSize ?? 0

                let stats: FileStats
                if let cached = cache[file.path], cached.mtime == mtime, cached.size == size {
                    stats = cached
                } else {
                    stats = parse(file: file, mtime: mtime, size: size)
                    cache[file.path] = stats
                }
                merge(stats, sessionId: file.deletingPathExtension().lastPathComponent, into: &snapshot)
            }
        }
        return snapshot
    }

    private func merge(_ stats: FileStats, sessionId: String, into snapshot: inout CostSnapshot) {
        guard stats.total > 0 else { return }
        snapshot.bySession[sessionId] = stats.total

        let today = dayKey.string(from: .now)
        let weekDays = Set((0..<7).map {
            dayKey.string(from: Date().addingTimeInterval(-Double($0) * 86400))
        })

        var p = snapshot.byProject[stats.project] ?? ProjectCost()
        for (day, cost) in stats.daily {
            if day == today { p.today += cost; snapshot.totalToday += cost }
            if weekDays.contains(day) { p.week += cost }
        }
        snapshot.byProject[stats.project] = p
    }

    // MARK: - Разбор одного файла

    private func parse(file: URL, mtime: Date, size: Int) -> FileStats {
        var project = "—"
        var total = 0.0
        var daily: [String: Double] = [:]

        guard let data = fm_read(file) else {
            return FileStats(mtime: mtime, size: size, project: project, total: 0, daily: [:])
        }

        for line in data.split(separator: 0x0A) {
            guard let obj = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any] else { continue }
            if project == "—", let cwd = obj["cwd"] as? String, !cwd.isEmpty {
                project = (cwd as NSString).lastPathComponent
            }
            guard obj["type"] as? String == "assistant",
                  let msg = obj["message"] as? [String: Any],
                  let usage = msg["usage"] as? [String: Any] else { continue }

            let cost = Self.cost(usage: usage, model: msg["model"] as? String ?? "")
            guard cost > 0 else { continue }
            total += cost

            if let ts = obj["timestamp"] as? String,
               let date = isoFrac.date(from: ts) ?? iso.date(from: ts) {
                daily[dayKey.string(from: date), default: 0] += cost
            }
        }
        return FileStats(mtime: mtime, size: size, project: project, total: total, daily: daily)
    }

    private func fm_read(_ url: URL) -> Data? { try? Data(contentsOf: url) }

    // MARK: - Цена

    private static func rates(for model: String) -> (input: Double, output: Double) {
        let m = model.lowercased()
        if m.contains("fable") || m.contains("mythos") { return (10, 50) }
        if m.contains("opus")   { return (5, 25) }
        if m.contains("sonnet") { return (3, 15) }
        if m.contains("haiku")  { return (1, 5) }
        return (5, 25)
    }

    private static func cost(usage: [String: Any], model: String) -> Double {
        let r = rates(for: model)
        let inRate = r.input / 1_000_000
        let outRate = r.output / 1_000_000

        func n(_ key: String, _ dict: [String: Any]) -> Double {
            (dict[key] as? NSNumber)?.doubleValue ?? 0
        }

        var cost = n("input_tokens", usage) * inRate
            + n("output_tokens", usage) * outRate
            + n("cache_read_input_tokens", usage) * inRate * 0.1

        if let creation = usage["cache_creation"] as? [String: Any] {
            cost += n("ephemeral_5m_input_tokens", creation) * inRate * 1.25
            cost += n("ephemeral_1h_input_tokens", creation) * inRate * 2.0
        } else {
            cost += n("cache_creation_input_tokens", usage) * inRate * 1.25
        }
        return cost
    }
}
