import XCTest
@testable import SessionsTelegram

final class AfkStateTests: XCTestCase {
    func testTable() {
        XCTAssertEqual(AfkState.next(.off, .screenLocked, onLock: true, linked: true), .lock)
        XCTAssertEqual(AfkState.next(.off, .screenLocked, onLock: false, linked: true), .off)
        XCTAssertEqual(AfkState.next(.lock, .screenUnlocked, onLock: true, linked: true), .off)
        XCTAssertEqual(AfkState.next(.manual, .screenUnlocked, onLock: true, linked: true), .manual)
        XCTAssertEqual(AfkState.next(.manual, .screenLocked, onLock: true, linked: true), .manual)
        XCTAssertEqual(AfkState.next(.lock, .manualOn, onLock: true, linked: true), .manual)
        XCTAssertEqual(AfkState.next(.lock, .manualOff, onLock: true, linked: true), .off)
        XCTAssertEqual(AfkState.next(.off, .manualOn, onLock: false, linked: true), .manual)
        XCTAssertEqual(AfkState.next(.lock, .screenLocked, onLock: true, linked: true), .lock)
        XCTAssertEqual(AfkState.next(.off, .manualOff, onLock: true, linked: true), .off)
        XCTAssertEqual(AfkState.next(.off, .screenUnlocked, onLock: true, linked: true), .off)
        XCTAssertEqual(AfkState.next(.manual, .manualOn, onLock: true, linked: true), .manual)
        XCTAssertEqual(AfkState.next(.manual, .manualOff, onLock: true, linked: true), .off)
    }

    /// Бот не привязан — режим не включается ничем и выключается любым событием.
    func testNotLinked() {
        XCTAssertEqual(AfkState.next(.off, .manualOn, onLock: true, linked: false), .off)
        XCTAssertEqual(AfkState.next(.off, .screenLocked, onLock: true, linked: false), .off)
        XCTAssertEqual(AfkState.next(.manual, .screenUnlocked, onLock: true, linked: false), .off)
        XCTAssertEqual(AfkState.next(.lock, .screenLocked, onLock: true, linked: false), .off)
    }
}
