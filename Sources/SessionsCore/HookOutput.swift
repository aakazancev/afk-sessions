import Foundation

/// Что CLI печатает в stdout в ответ Claude Code. nil — ничего не печатать
/// (Claude Code ведёт себя как без приложения).
public enum HookOutput {

    public static func permission(_ d: GateDecision?) -> String? {
        guard let d, d.decision == "allow" || d.decision == "deny" else { return nil }
        // message у PermissionRequest учитывается только для deny.
        var verdict: [String: Any] = ["behavior": d.decision]
        if d.decision == "deny" { verdict["message"] = d.reason ?? "Отклонено в AFK Sessions" }
        return encode(["hookSpecificOutput": ["hookEventName": "PermissionRequest", "decision": verdict]])
    }

    /// continue + непустой текст → сессия продолжает с этим текстом как указанием.
    public static func stop(_ d: GateDecision?) -> String? {
        guard let d, d.decision == "continue",
              let text = d.reason?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty
        else { return nil }
        return encode(["hookSpecificOutput": ["hookEventName": "Stop", "additionalContext": text]])
    }

    private static func encode(_ obj: [String: Any]) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: obj) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
