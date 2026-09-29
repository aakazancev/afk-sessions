import Foundation

public struct Suggestion: Identifiable, Hashable, Sendable {
    public var item: InventoryItem
    public var target: ToggleTarget
    public var text: String
    public var id: String {
        switch target {
        case .everywhere: return item.id + "|*"
        case .project(let p): return item.id + "|" + p
        }
    }
}

/// «Не вызывался — выключить?» по фактам из транскриптов.
public enum Suggester {

    public static func suggest(items: [InventoryItem], usage: UsageIndex, days: Int) -> [Suggestion] {
        var out: [Suggestion] = []
        // нечитаемые (битые файлы, плагины без установки) не предлагаем;
        // маркеры битых файлов отсекает toggleable;
        // без usageRefs (плагин только с хуками/LSP/командами) вызовы не видны — тоже
        for item in items where item.owner == nil && item.scope == .global
                             && item.toggleable && !item.disabledGlobally && !item.unreadable
                             && !item.usageRefs.isEmpty {
            let name = item.kind == .plugin ? String(item.name.split(separator: "@").first ?? "") : item.name
            let total = usage.total(item.usageRefs).count

            if total == 0 {
                let w = item.weightTokens.map { ", ~\($0) ток." } ?? ""
                out.append(Suggestion(item: item, target: .everywhere,
                                      text: "\(name): 0 вызовов за \(days) дн.\(w) — выключить везде?"))
                continue
            }
            guard item.kind == .plugin || item.kind == .mcp else { continue }
            for p in usage.projects where (usage.sessionsByProject[p] ?? 0) >= 3
                                       && isDirectory(p)
                                       && usage.inProject(item.usageRefs, p).count == 0
                                       && !item.disabledIn.contains(p) {
                let proj = (p as NSString).lastPathComponent
                out.append(Suggestion(item: item, target: .project(p),
                                      text: "\(name) не вызывался в \(proj) — выключить там?"))
            }
        }
        // при равном весе — по id, чтобы восьмёрка не менялась от порядка элементов
        return Array(out.sorted {
            let (a, b) = ($0.item.weightTokens ?? 0, $1.item.weightTokens ?? 0)
            return a != b ? a > b : $0.id < $1.id
        }.prefix(8))
    }

    /// Проекты, каталога которых больше нет, не предлагаем.
    private static func isDirectory(_ p: String) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: p, isDirectory: &isDir) && isDir.boolValue
    }
}
