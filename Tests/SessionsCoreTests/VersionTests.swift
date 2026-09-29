import XCTest
@testable import SessionsCore

final class VersionTests: XCTestCase {
    func testNewer() {
        XCTAssertTrue(Version.isNewer("v0.7", than: "0.6"))
        XCTAssertTrue(Version.isNewer("0.10", than: "0.9"))
        XCTAssertTrue(Version.isNewer("0.7.1", than: "0.7"))
        XCTAssertTrue(Version.isNewer("v1.0", than: "0.9.9"))
    }
    func testNotNewer() {
        XCTAssertFalse(Version.isNewer("0.7", than: "0.7"))
        XCTAssertFalse(Version.isNewer("v0.7.0", than: "0.7"))
        XCTAssertFalse(Version.isNewer("0.6", than: "0.7"))
    }
    func testGarbage() {
        XCTAssertFalse(Version.isNewer("latest", than: "0.7"))
        XCTAssertFalse(Version.isNewer("", than: "0.7"))
        XCTAssertFalse(Version.isNewer("0.8-beta", than: "0.7"))
        XCTAssertFalse(Version.isNewer("0.8", than: "dev"))
    }
}
