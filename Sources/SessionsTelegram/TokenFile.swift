import Foundation

/// Токен бота в файле с правами 0600 (как у Telegram-плагина Claude Code).
/// Связка ключей не подходит: ad-hoc подпись меняется с каждой сборкой,
/// и после каждого обновления система спрашивала бы доступ заново.
public struct TokenFile: Sendable {
    public let url: URL
    public init(url: URL) { self.url = url }

    public func token() -> String? {
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    /// nil или пустая строка — удалить. Запись атомарная: временный файл,
    /// сразу созданный с 0600, затем rename поверх старого. false — не вышло.
    @discardableResult
    public func save(_ token: String?) -> Bool {
        let t = token?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !t.isEmpty else {
            return unlink(url.path) == 0 || errno == ENOENT
        }
        let dir = url.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch { return false }

        let tmp = dir.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString)")
        let fd = open(tmp.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard fd >= 0 else { return false }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        do {
            try handle.write(contentsOf: Data(t.utf8))
            try handle.close()
        } catch {
            unlink(tmp.path)
            return false
        }
        guard rename(tmp.path, url.path) == 0 else {
            unlink(tmp.path)
            return false
        }
        return true
    }
}
