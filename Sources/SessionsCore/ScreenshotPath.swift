import Foundation

/// Путь к файлу скриншота Playwright из tool_response PostToolUse.
/// browser_take_screenshot всегда сохраняет файл и пишет в тексте
/// «- [Screenshot of …](<путь>)»; путь — относительно корня проекта или абсолютный.
/// base64-блок image приходит не всегда — его не используем.
public enum ScreenshotPath {

    public static func isScreenshotTool(_ name: String?) -> Bool {
        name?.hasSuffix("__browser_take_screenshot") ?? false
    }

    public static func extract(toolResponse: Any?, cwd: String,
                               fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> String? {
        let text = texts(toolResponse).joined(separator: "\n")
        guard let r = text.range(of: #"\]\([^)\n]+\.(png|jpe?g)\)"#,
                                 options: [.regularExpression, .caseInsensitive]) else { return nil }
        let raw = String(text[r].dropFirst(2).dropLast())   // без «](» и «)»
        let full = raw.hasPrefix("/") ? raw : (cwd as NSString).appendingPathComponent(raw)
        let path = (full as NSString).standardizingPath
        return fileExists(path) ? path : nil
    }

    /// Текст всех блоков: массив блоков, строка или объект с content.
    static func texts(_ v: Any?) -> [String] {
        switch v {
        case let s as String: return [s]
        case let a as [Any]: return a.flatMap { texts($0) }
        case let d as [String: Any]:
            if let t = d["text"] as? String { return [t] }
            return texts(d["content"])
        default: return []
        }
    }
}
