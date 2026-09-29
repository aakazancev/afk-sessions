import XCTest
@testable import SessionsTelegram

final class StopPolicyTests: XCTestCase {

    func testHoldsOnlyInteractiveSessionInAfk() {
        XCTAssertTrue(StopPolicy.shouldHold(afkActive: true, agentsRunning: false, hasTTY: true, hasReplier: true))
    }

    func testReleasesOtherwise() {
        // Вне режима
        XCTAssertFalse(StopPolicy.shouldHold(afkActive: false, agentsRunning: false, hasTTY: true, hasReplier: true))
        // Ждёт сабагентов — ход не закончен
        XCTAssertFalse(StopPolicy.shouldHold(afkActive: true, agentsRunning: true, hasTTY: true, hasReplier: true))
        // Без терминала: claude -p, Agent SDK, cron — отвечать там некому
        XCTAssertFalse(StopPolicy.shouldHold(afkActive: true, agentsRunning: false, hasTTY: false, hasReplier: true))
        // CLI не ждёт ответа
        XCTAssertFalse(StopPolicy.shouldHold(afkActive: true, agentsRunning: false, hasTTY: true, hasReplier: false))
    }
}
