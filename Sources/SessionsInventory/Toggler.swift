import Foundation

public enum ToggleError: Error, LocalizedError, Equatable {
    case unsupported
    case projectMissing(String)
    case conflict(String)
    case notFound(String)
    case unexpectedType(String)

    public var errorDescription: String? {
        switch self {
        case .unsupported: return "Этот элемент нельзя выключить отдельно"
        case .projectMissing(let p): return "Проекта больше нет: \(p)"
        case .conflict(let n): return "Сервер «\(n)» уже есть — сначала разберитесь с ним вручную"
        case .notFound(let n): return "Сервер «\(n)» не найден"
        case .unexpectedType(let k): return "Ключ «\(k)» в конфиге неожиданного вида — поправьте вручную"
        }
    }
}

/// Выключает и возвращает элементы инвентаря. Каждая запись — JSONFile.update:
/// свежее чтение, только свой ключ, бэкап, атомарно.
public struct Toggler {
    let paths: ClaudePaths
    let stash: URL   // куда уезжают глобальные MCP при «выключить везде»

    public init(paths: ClaudePaths, stash: URL) { self.paths = paths; self.stash = stash }

    public func setDisabled(_ item: InventoryItem, _ disabled: Bool, _ target: ToggleTarget) throws {
        if case .project(let p) = target {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: p, isDirectory: &isDir), isDir.boolValue else {
                throw ToggleError.projectMissing(p)
            }
        }
        switch (item.kind, target) {
        case (.plugin, .everywhere):
            try JSONFile.update(paths.userSettings) { root in
                try Self.setKey(&root, "enabledPlugins", item.name, disabled ? false : true)
            }
        case (.plugin, .project(let p)):
            // Выключен в общем settings.json проекта — удаления из local мало, нужно явное true.
            let shared = (try? JSONFile.read(paths.projectSettings(p))) ?? [:]
            let sharedOff = (shared["enabledPlugins"] as? [String: Any])?[item.name] as? Bool == false
            try JSONFile.update(paths.projectSettingsLocal(p)) { root in
                try Self.setKey(&root, "enabledPlugins", item.name, disabled ? false : (sharedOff ? true : nil))
            }
        case (.mcp, .everywhere) where item.mcpOrigin == .userConfig:
            try moveServer(item.name, toStash: disabled)
        case (.mcp, .project(let p)) where item.mcpOrigin == .userConfig || item.mcpOrigin == .projectConfig:
            try JSONFile.update(paths.claudeJSON) { root in
                var projects = root["projects"] as? [String: Any] ?? [:]
                var conf = projects[p] as? [String: Any] ?? [:]
                try Self.setMember(&conf, "disabledMcpServers", item.name, disabled)
                projects[p] = conf
                root["projects"] = projects
            }
        case (.mcp, .project(let p)) where item.mcpOrigin == .mcpJSON:
            try JSONFile.update(paths.projectSettingsLocal(p)) { root in
                try Self.setMember(&root, "disabledMcpjsonServers", item.name, disabled)
            }
        default:
            throw ToggleError.unsupported
        }
    }

    // MARK: - Глобальный MCP ↔ stash

    /// Сначала запись в пункт назначения, потом удаление из источника:
    /// сбой посередине оставит дубль, но не потерю.
    private func moveServer(_ name: String, toStash: Bool) throws {
        let (from, to) = toStash ? (paths.claudeJSON, stash) : (stash, paths.claudeJSON)
        guard let config = ((try JSONFile.read(from))["mcpServers"] as? [String: Any])?[name] else {
            throw ToggleError.notFound(name)
        }
        try JSONFile.update(to) { root in
            // Такой же сервер уже там — ничего не затираем; другой — конфликт, источник не трогаем.
            if let existing = (root["mcpServers"] as? [String: Any])?[name],
               !NSDictionary(dictionary: ["v": existing]).isEqual(to: ["v": config]) {
                throw ToggleError.conflict(name)
            }
            try Self.setKey(&root, "mcpServers", name, config)
        }
        try JSONFile.update(from) { try Self.setKey(&$0, "mcpServers", name, nil) }
    }

    // MARK: - Помощники

    /// root[dict][key] = value; nil удаляет ключ, пустой dict удаляется целиком.
    /// root[dict] не словарь — ошибка, чужое не затираем.
    static func setKey(_ root: inout [String: Any], _ dict: String, _ key: String, _ value: Any?) throws {
        if root[dict] != nil && !(root[dict] is [String: Any]) { throw ToggleError.unexpectedType(dict) }
        var d = root[dict] as? [String: Any] ?? [:]
        d[key] = value
        root[dict] = d.isEmpty ? nil : d
    }

    /// Добавить/убрать имя в массиве; пустой массив удаляется.
    /// root[list] не массив строк — ошибка, чужое не затираем.
    static func setMember(_ root: inout [String: Any], _ list: String, _ name: String, _ present: Bool) throws {
        if root[list] != nil && !(root[list] is [String]) { throw ToggleError.unexpectedType(list) }
        var arr = root[list] as? [String] ?? []
        arr.removeAll { $0 == name }
        if present { arr.append(name) }
        root[list] = arr.isEmpty ? nil : arr
    }
}
