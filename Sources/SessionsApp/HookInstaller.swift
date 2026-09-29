import Foundation
import SessionsCore
import SessionsInventory

/// Правит ~/.claude/settings.json: добавляет свои хуки, чужие не трогает.
/// Перед записью кладёт рядом settings.json.sessions-backup (его перезаписывают и действия инвентаря).
enum HookInstaller {

    static let marker = "sessions-cli"

    static var settingsURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/settings.json")
    }

    /// Путь к CLI внутри бандла приложения.
    static var cliPath: String {
        if let p = Bundle.main.path(forResource: "sessions-cli", ofType: nil) { return p }
        return Bundle.main.bundleURL
            .appendingPathComponent("Contents/Resources/sessions-cli").path
    }

    // MARK: - Состояние

    static func isInstalled() -> Bool {
        guard let raw = try? String(contentsOf: settingsURL, encoding: .utf8) else { return false }
        return raw.contains(marker)
    }

    /// Путь sessions-cli, записанный в хуках. nil — хуков нет.
    static func installedCliPath() -> String? {
        guard let root = try? JSONFile.read(settingsURL),
              let hooks = root["hooks"] as? [String: Any] else { return nil }
        for value in hooks.values {
            guard let groups = value as? [[String: Any]] else { continue }
            for group in groups {
                for handler in (group["hooks"] as? [[String: Any]] ?? []) {
                    guard let cmd = handler["command"] as? String, cmd.contains(marker) else { continue }
                    // Формат: "\"/путь/sessions-cli\" gate"
                    let parts = cmd.components(separatedBy: "\"")
                    if parts.count >= 2 { return parts[1] }
                }
            }
        }
        return nil
    }

    /// Хуки стоят, но указывают на другой бандл — приложение переехало
    /// (или старую копию удалили). События при этом молча теряются.
    static func isMoved() -> Bool {
        guard let installed = installedCliPath() else { return false }
        return installed != cliPath
    }

    /// Хуки стоят, но набор старый: не хватает какого-то события, нет нужного
    /// таймаута или ключа лимита продолжений (его значение — решение пользователя), или остался наш PreToolUse
    /// (он блокировал сессию до allow-правил).
    static func isOutdated() -> Bool {
        guard let root = try? JSONFile.read(settingsURL),
              let hooks = root["hooks"] as? [String: Any],
              installedCliPath() != nil else { return false }
        func ours(_ event: String) -> [[String: Any]] {
            (hooks[event] as? [[String: Any]] ?? [])
                .flatMap { $0["hooks"] as? [[String: Any]] ?? [] }
                .filter { ($0["command"] as? String)?.contains(marker) == true }
        }
        if !ours("PreToolUse").isEmpty { return true }
        if HookEnv.isOutdated(root["env"] as? [String: Any]) { return true }
        return required.contains { req in
            !ours(req.event).contains { handler in
                guard (handler["command"] as? String)?.hasSuffix(" \(req.arg)") == true else { return false }
                guard let t = req.timeout else { return true }
                return handler["timeout"] as? Int == t
            }
        }
    }

    // MARK: - Установка

    /// Событие Claude Code → matcher → аргумент sessions-cli → таймаут хука, с.
    /// gate и stop ждут ответа из Telegram в режиме «Я отошёл» — до 4 ч.
    static let required: [(event: String, matcher: String?, arg: String, timeout: Int?)] = [
        // PermissionRequest срабатывает, только когда Claude реально спросил бы «можно?».
        ("PermissionRequest", "*", "gate",           14400),
        ("PostToolUse",       "*", "tool",           nil),
        ("SessionStart",      nil, "start",          nil),
        ("UserPromptSubmit",  nil, "prompt",         nil),
        ("Notification",      nil, "notify",         nil),
        ("SubagentStart",     nil, "subagent-start", nil),
        ("SubagentStop",      nil, "subagent-stop",  nil),
        ("Stop",              nil, "stop",           14400),
        ("SessionEnd",        nil, "end",            nil),
    ]

    @discardableResult
    static func install() -> Result<Void, Error> {
        do {
            try JSONFile.update(settingsURL) { root in
                // Сначала убираем все свои записи (в т.ч. старый PreToolUse), потом ставим набор заново.
                var hooks = stripped(root["hooks"] as? [String: Any] ?? [:])

                let cli = shellQuote(cliPath)
                for req in required {
                    var handler: [String: Any] = ["type": "command", "command": "\(cli) \(req.arg)"]
                    if let t = req.timeout { handler["timeout"] = t }
                    var group: [String: Any] = ["hooks": [handler]]
                    if let m = req.matcher { group["matcher"] = m }
                    hooks[req.event] = (hooks[req.event] as? [[String: Any]] ?? []) + [group]
                }

                root["hooks"] = hooks

                // Лимит продолжений: дописываем, только если пользователь не задал свой.
                root["env"] = HookEnv.install(root["env"] as? [String: Any])
            }
            return .success(())
        } catch {
            return .failure(error)
        }
    }

    @discardableResult
    static func uninstall() -> Result<Void, Error> {
        do {
            let current = try JSONFile.read(settingsURL)
            guard current["hooks"] != nil || current["env"] != nil else { return .success(()) }
            try JSONFile.update(settingsURL) { root in
                if let hooks = root["hooks"] as? [String: Any] {
                    let rest = stripped(hooks)
                    root["hooks"] = rest.isEmpty ? nil : rest
                }
                // Лимит продолжений убираем, только если он наш (чужое значение не трогаем).
                root["env"] = HookEnv.uninstall(root["env"] as? [String: Any])
            }
            return .success(())
        } catch {
            return .failure(error)
        }
    }

    // MARK: - Внутреннее

    /// Убирает наши обработчики из всех событий; опустевшие группы и события — тоже.
    private static func stripped(_ hooks: [String: Any]) -> [String: Any] {
        var hooks = hooks
        for (event, value) in hooks {
            guard var groups = value as? [[String: Any]] else { continue }
            for gi in groups.indices {
                guard var handlers = groups[gi]["hooks"] as? [[String: Any]] else { continue }
                handlers.removeAll { ($0["command"] as? String)?.contains(marker) == true }
                groups[gi]["hooks"] = handlers
            }
            groups.removeAll { (($0["hooks"] as? [[String: Any]]) ?? []).isEmpty }
            hooks[event] = groups.isEmpty ? nil : groups
        }
        return hooks
    }

    private static func shellQuote(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// Показать в настройках, что именно допишется в файл.
    static func previewJSON() -> String {
        let cli = (cliPath as NSString).abbreviatingWithTildeInPath
        return """
        {
          "hooks": {
            "PermissionRequest": [{ "matcher": "*", "hooks": [{ "type": "command", "command": "\(cli) gate", "timeout": 14400 }] }],
            "PostToolUse":       [{ "matcher": "*", "hooks": [{ "type": "command", "command": "\(cli) tool" }] }],
            "SessionStart":      [{ "hooks": [{ "type": "command", "command": "\(cli) start" }] }],
            "UserPromptSubmit":  [{ "hooks": [{ "type": "command", "command": "\(cli) prompt" }] }],
            "Notification":      [{ "hooks": [{ "type": "command", "command": "\(cli) notify" }] }],
            "SubagentStart":     [{ "hooks": [{ "type": "command", "command": "\(cli) subagent-start" }] }],
            "SubagentStop":      [{ "hooks": [{ "type": "command", "command": "\(cli) subagent-stop" }] }],
            "Stop":              [{ "hooks": [{ "type": "command", "command": "\(cli) stop", "timeout": 14400 }] }],
            "SessionEnd":        [{ "hooks": [{ "type": "command", "command": "\(cli) end" }] }]
          },
          "env": { "\(HookEnv.key)": "\(HookEnv.value)" }
        }
        """
    }
}
