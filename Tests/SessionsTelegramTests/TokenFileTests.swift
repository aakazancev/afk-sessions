import XCTest
@testable import SessionsTelegram

final class TokenFileTests: XCTestCase {

    private var dir: URL!
    private var file: TokenFile!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tokenfile-\(UUID().uuidString)")
        // Каталога ещё нет — save должен создать его сам.
        file = TokenFile(url: dir.appendingPathComponent("sub/telegram-token"))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func mode() throws -> Int {
        let attrs = try FileManager.default.attributesOfItem(atPath: file.url.path)
        return (attrs[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }

    func testMissingIsNil() {
        XCTAssertNil(file.token())
    }

    func testSaveReadOverwrite() throws {
        XCTAssertTrue(file.save("123:abc"))
        XCTAssertEqual(file.token(), "123:abc")
        XCTAssertEqual(try mode(), 0o600)

        XCTAssertTrue(file.save("456:def"))
        XCTAssertEqual(file.token(), "456:def")
        XCTAssertEqual(try mode(), 0o600)
        // Временных файлов рядом не остаётся.
        let rest = try FileManager.default.contentsOfDirectory(atPath: file.url.deletingLastPathComponent().path)
        XCTAssertEqual(rest, ["telegram-token"])
    }

    func testTightensExistingPermissions() throws {
        try FileManager.default.createDirectory(at: file.url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try "old".write(to: file.url, atomically: false, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.url.path)
        XCTAssertTrue(file.save("new"))
        XCTAssertEqual(try mode(), 0o600)
    }

    func testDelete() {
        XCTAssertTrue(file.save("123:abc"))
        XCTAssertTrue(file.save(nil))
        XCTAssertNil(file.token())
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.url.path))
        // Удалить отсутствующий — не ошибка.
        XCTAssertTrue(file.save(nil))
        // Пустой токен — как удаление.
        XCTAssertTrue(file.save("x"))
        XCTAssertTrue(file.save("  "))
        XCTAssertNil(file.token())
    }

    func testTrimsWhitespace() throws {
        try FileManager.default.createDirectory(at: file.url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try "123:abc\n".write(to: file.url, atomically: false, encoding: .utf8)
        XCTAssertEqual(file.token(), "123:abc")
    }
}
