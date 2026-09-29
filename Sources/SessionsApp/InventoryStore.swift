import Foundation
import SwiftUI
import SessionsCore
import SessionsInventory

/// Состояние вкладки «Инвентарь». Сканирование — на фоне, результат — на main.
@MainActor
final class InventoryStore: ObservableObject {

    @Published private(set) var items: [InventoryItem] = []
    @Published private(set) var usage = UsageIndex()
    @Published private(set) var suggestions: [Suggestion] = []
    @Published private(set) var loading = false
    @Published var error: String?

    @AppStorage("inventoryDays") var days = 30

    private let paths = ClaudePaths()
    /// Куда уносятся глобальные MCP при «выключить везде» — общий для сканера и Toggler.
    private let stash = Bridge.supportDir.appendingPathComponent("inventory-stash.json")
    private let scanner: UsageScanner
    private let queue = DispatchQueue(label: "sessions.inventory", qos: .utility)
    /// Запрос обновления, пришедший во время сканирования, — повторить после него.
    private var again = false

    init() { scanner = UsageScanner(paths: paths) }

    func refresh() {
        guard !loading else { again = true; return }
        loading = true
        let days = days, paths = paths, stash = stash, scanner = scanner
        queue.async {
            let usage = scanner.scan(days: days)
            var items = ConfigScanner(paths: paths, stash: stash).scan(projects: usage.projects)
            for name in usage.connectors {
                var c = InventoryItem(kind: .connector, name: name, scope: .global, source: "claude.ai")
                c.usageRefs = ["mcp:\(name)"]
                items.append(c)
            }
            let suggestions = Suggester.suggest(items: items, usage: usage, days: days)
            Task { @MainActor in
                self.loading = false
                // Скан начат до записи — его данные устарели и затёрли бы
                // уже применённое выключение; публикуем результат повтора.
                if self.again { self.again = false; self.refresh(); return }
                self.items = items; self.usage = usage
                self.suggestions = suggestions
            }
        }
    }

    func setDisabled(_ item: InventoryItem, _ disabled: Bool, _ target: ToggleTarget) {
        do {
            try Toggler(paths: paths, stash: stash).setDisabled(item, disabled, target)
            error = nil
            // Сразу, не дожидаясь скана: он перечитывает все свежие транскрипты
            if let i = items.firstIndex(where: { $0.id == item.id }) {
                items[i] = items[i].toggled(disabled, target)
            }
            if disabled { suggestions.removeAll { $0.item.id == item.id && $0.target == target } }
        } catch {
            self.error = error.localizedDescription
        }
        refresh()
    }

    /// Проекты для списка: с сессиями за окно, по убыванию активности.
    var projects: [String] { usage.projects.filter { FileManager.default.fileExists(atPath: $0) } }

    func children(of plugin: InventoryItem) -> [InventoryItem] {
        items.filter { $0.pluginKey == plugin.name && $0.kind != .plugin }
    }

    var globalTop: [InventoryItem] {
        items.filter { $0.scope == .global && $0.owner == nil }
    }

    func projectItems(_ p: String) -> [InventoryItem] {
        items.filter { $0.scope == .project(p) }
    }

    func disabledHere(_ p: String) -> [InventoryItem] {
        items.filter { $0.scope == .global && $0.disabledIn.contains(p) }
    }
}
