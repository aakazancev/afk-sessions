import XCTest
@testable import SessionsInventory

final class JSONFileTests: XCTestCase {

    func testReadMissingIsEmpty() throws {
        let h = TempHome()
        XCTAssertTrue(try JSONFile.read(h.url.appendingPathComponent("nope.json")).isEmpty)
    }

    func testReadCorruptThrows() {
        let h = TempHome()
        let u = h.write("bad.json", "{ not json")
        XCTAssertThrowsError(try JSONFile.read(u))
    }

    func testUpdateKeepsOtherKeysAndBacksUp() throws {
        let h = TempHome()
        let u = h.write("s.json", #"{"keep": {"a": 1}, "flag": true}"#)
        try JSONFile.update(u) { $0["new"] = "x" }
        let r = h.json("s.json")
        XCTAssertEqual((r["keep"] as? [String: Any])?["a"] as? Int, 1)
        XCTAssertEqual(r["flag"] as? Bool, true)
        XCTAssertEqual(r["new"] as? String, "x")
        let backup = h.json("s.json.sessions-backup")
        XCTAssertNil(backup["new"])
        XCTAssertEqual(backup["flag"] as? Bool, true)
    }

    func testUpdateCreatesMissingFileAndDirs() throws {
        let h = TempHome()
        let u = h.url.appendingPathComponent("deep/dir/s.json")
        try JSONFile.update(u) { $0["a"] = 1 }
        XCTAssertEqual(h.json("deep/dir/s.json")["a"] as? Int, 1)
    }

    func testUpdateRefusesCorruptFile() {
        let h = TempHome()
        let u = h.write("bad.json", "{ not json")
        XCTAssertThrowsError(try JSONFile.update(u) { $0["a"] = 1 })
        XCTAssertEqual(try String(contentsOf: u, encoding: .utf8), "{ not json")
    }

    func testUpdateKeepsPermissions() throws {
        let h = TempHome()
        let u = h.write("secret.json", #"{"token": "x"}"#)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: u.path)
        try JSONFile.update(u) { $0["a"] = 1 }
        let perms = try FileManager.default.attributesOfItem(atPath: u.path)[.posixPermissions] as? Int
        XCTAssertEqual(perms, 0o600)
        XCTAssertEqual(h.json("secret.json")["a"] as? Int, 1)
    }

    func testUpdateKeepsSymlink() throws {
        let h = TempHome()
        let target = h.write("real/target.json", #"{"keep": true}"#)
        let link = h.url.appendingPathComponent("link.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        try JSONFile.update(link) { $0["a"] = 1 }
        let type = try FileManager.default.attributesOfItem(atPath: link.path)[.type] as? FileAttributeType
        XCTAssertEqual(type, .typeSymbolicLink)
        XCTAssertEqual(h.json("real/target.json")["a"] as? Int, 1)
        XCTAssertEqual(h.json("real/target.json")["keep"] as? Bool, true)
    }
}
