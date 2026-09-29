import Foundation

/// Наш ключ в "env" файла ~/.claude/settings.json: лимит продолжений Stop-хука.
/// Иначе Claude Code примет не больше 8 продолжений подряд из Telegram.
/// Чужое (пользовательское) значение не трогаем ни при установке, ни при удалении.
public enum HookEnv {
    public static let key = "CLAUDE_CODE_STOP_HOOK_BLOCK_CAP"
    public static let value = "100"

    /// env после установки: ключ дописываем, только если его нет.
    public static func install(_ env: [String: Any]?) -> [String: Any] {
        var env = env ?? [:]
        if env[key] == nil { env[key] = value }
        return env
    }

    /// Хуки надо переустановить: ключа нет. Любое заданное значение — решение пользователя.
    public static func isOutdated(_ env: [String: Any]?) -> Bool {
        env?[key] == nil
    }

    /// env после удаления: убираем ключ, только если значение наше.
    /// nil — env опустел и его стоит убрать из файла.
    public static func uninstall(_ env: [String: Any]?) -> [String: Any]? {
        guard var env, env[key] as? String == value else { return env }
        env[key] = nil
        return env.isEmpty ? nil : env
    }
}
