import Foundation
@testable import SessionsInventory

/// Временный home с нужными файлами. Удаляется в deinit.
final class TempHome {
    let url: URL
    var paths: ClaudePaths { ClaudePaths(home: url) }

    init() {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("inv-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
    deinit { try? FileManager.default.removeItem(at: url) }

    /// Путь относительно home (или абсолютный) → записать текст.
    @discardableResult
    func write(_ path: String, _ text: String) -> URL {
        let u = path.hasPrefix("/") ? URL(fileURLWithPath: path) : url.appendingPathComponent(path)
        try! FileManager.default.createDirectory(at: u.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try! text.write(to: u, atomically: true, encoding: .utf8)
        return u
    }

    func json(_ path: String) -> [String: Any] {
        let u = path.hasPrefix("/") ? URL(fileURLWithPath: path) : url.appendingPathComponent(path)
        return (try? JSONFile.read(u)) ?? [:]
    }

    /// Каталог проекта внутри home.
    func project(_ name: String) -> String {
        let p = url.appendingPathComponent(name).path
        try! FileManager.default.createDirectory(atPath: p, withIntermediateDirectories: true)
        return p
    }
}
