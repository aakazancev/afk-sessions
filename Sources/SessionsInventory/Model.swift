import Foundation

public enum ItemKind: String, Sendable { case plugin, skill, agent, mcp, connector }

public enum Scope: Hashable, Sendable {
    case global
    case project(String)   // абсолютный путь проекта
}

/// Куда применить выключение.
public enum ToggleTarget: Hashable, Sendable {
    case everywhere
    case project(String)
}

/// Откуда взялся MCP-сервер — от этого зависит, каким ключом его выключать.
public enum McpOrigin: String, Sendable {
    case userConfig      // ~/.claude.json → mcpServers (глобальный)
    case projectConfig   // ~/.claude.json → projects[путь].mcpServers
    case mcpJSON         // <проект>/.mcp.json
    case plugin          // .mcp.json внутри плагина
}

public struct InventoryItem: Identifiable, Hashable, Sendable {
    public var kind: ItemKind
    /// Скилл/агент/сервер — своё имя; плагин — ключ из enabledPlugins ("figma@claude-plugins-official").
    public var name: String
    /// Короткое имя плагина-владельца ("figma") для скиллов/агентов/MCP из плагина.
    public var owner: String?
    /// Полный ключ плагина-владельца ("figma@claude-plugins-official") — для уникального id.
    public var pluginKey: String?
    public var scope: Scope
    public var source: String            // файл, из которого взят
    public var mcpOrigin: McpOrigin?
    public var weightTokens: Int?        // оценка «сколько ест контекста»
    public var disabledGlobally = false
    public var disabledIn: Set<String> = []   // проекты, где выключен
    /// Ключи в UsageIndex: "skill:…", "mcp:…", "agent:…".
    public var usageRefs: [String] = []
    public var unreadable = false
    /// Маркер битого файла (settings.json, ~/.claude.json, stash) — не настоящий элемент.
    public var marker = false

    public var id: String {
        let s: String
        switch scope { case .global: s = ""; case .project(let p): s = p }
        return "\(kind.rawValue)|\(s)|\(pluginKey ?? owner ?? "")|\(mcpOrigin?.rawValue ?? "")|\(name)"
    }

    public init(kind: ItemKind, name: String, owner: String? = nil, scope: Scope,
                source: String, mcpOrigin: McpOrigin? = nil, weightTokens: Int? = nil) {
        self.kind = kind; self.name = name; self.owner = owner; self.scope = scope
        self.source = source; self.mcpOrigin = mcpOrigin; self.weightTokens = weightTokens
    }

    /// Можно ли выключить из приложения. Маркеры, скиллы, агенты, коннекторы и MCP плагина — нет:
    /// у Claude Code нет ключа для них по отдельности (скиллы — через /skill-doctor).
    public var toggleable: Bool {
        if marker { return false }
        switch kind {
        case .plugin: return true
        case .skill: return false
        case .mcp: return mcpOrigin != nil && mcpOrigin != .plugin
        case .agent, .connector: return false
        }
    }

    /// Состояние после успешного `Toggler.setDisabled` — таким его покажет следующий скан.
    /// Нужно, чтобы строка обновилась сразу, не дожидаясь пересканирования транскриптов.
    public func toggled(_ disabled: Bool, _ target: ToggleTarget) -> InventoryItem {
        var it = self
        switch target {
        case .everywhere: it.disabledGlobally = disabled
        case .project(let p):
            if disabled { it.disabledIn.insert(p) } else { it.disabledIn.remove(p) }
        }
        return it
    }
}

/// Имена MCP-серверов так, как Claude Code пишет их в `mcp__<server>__<tool>`:
/// символы вне [A-Za-z0-9_-] заменяются на «_» («Claude Docs» → «Claude_Docs»).
public enum McpName {
    public static func normalize(_ name: String) -> String {
        String(name.unicodeScalars.map { c -> Character in
            switch c {
            case "a"..."z", "A"..."Z", "0"..."9", "_", "-": return Character(c)
            default: return "_"
            }
        })
    }
}
