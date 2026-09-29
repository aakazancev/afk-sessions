import Foundation

/// Чтение и правка JSON-конфигов Claude Code: бэкап рядом, атомарная запись,
/// битый файл не перезаписываем никогда.
public enum JSONFile {

    public struct Corrupt: Error, LocalizedError {
        public let path: String
        public var errorDescription: String? { "Не удалось разобрать \(path)" }
    }

    /// Нет файла или пустой — пустой словарь. Битый — ошибка.
    public static func read(_ url: URL) throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        let data = try Data(contentsOf: url)
        guard !data.isEmpty else { return [:] }
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw Corrupt(path: url.path)
        }
        return obj
    }

    /// Свежее чтение → change → бэкап <файл>.sessions-backup → атомарная запись.
    /// Симлинк не заменяется файлом — пишем в его цель; права существующего файла
    /// (~/.claude.json с токенами — 0600) сохраняются.
    public static func update(_ url: URL, _ change: (inout [String: Any]) throws -> Void) throws {
        let url = url.resolvingSymlinksInPath()
        var root = try read(url)
        try change(&root)
        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: url.path) {
            let backup = URL(fileURLWithPath: url.path + ".sessions-backup")
            try? fm.removeItem(at: backup)
            try fm.copyItem(at: url, to: backup)
        }
        let data = try JSONSerialization.data(
            withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        let perms = (try? fm.attributesOfItem(atPath: url.path))?[.posixPermissions]
        try data.write(to: url, options: .atomic)
        if let perms {
            try fm.setAttributes([.posixPermissions: perms], ofItemAtPath: url.path)
        }
    }
}
