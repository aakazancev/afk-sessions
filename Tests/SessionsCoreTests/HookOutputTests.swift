import XCTest
@testable import SessionsCore

final class HookOutputTests: XCTestCase {

    private func json(_ s: String?) -> [String: Any] {
        guard let s, let d = s.data(using: .utf8) else { return [:] }
        return (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] ?? [:]
    }

    func testPermissionAllowAndDeny() {
        let allow = json(HookOutput.permission(GateDecision(decision: "allow")))
        let hso = allow["hookSpecificOutput"] as? [String: Any]
        XCTAssertEqual(hso?["hookEventName"] as? String, "PermissionRequest")
        XCTAssertEqual((hso?["decision"] as? [String: Any])?["behavior"] as? String, "allow")
        XCTAssertNil((hso?["decision"] as? [String: Any])?["message"])

        let deny = json(HookOutput.permission(GateDecision(decision: "deny", reason: "нет")))
        let d = (deny["hookSpecificOutput"] as? [String: Any])?["decision"] as? [String: Any]
        XCTAssertEqual(d?["behavior"] as? String, "deny")
        XCTAssertEqual(d?["message"] as? String, "нет")
    }

    func testPermissionAskOrNilPrintsNothing() {
        XCTAssertNil(HookOutput.permission(nil))
        XCTAssertNil(HookOutput.permission(GateDecision(decision: "ask")))
    }

    func testStopContinueAndStop() {
        let c = json(HookOutput.stop(GateDecision(decision: "continue", reason: "сделай тесты")))
        let hso = c["hookSpecificOutput"] as? [String: Any]
        XCTAssertEqual(hso?["hookEventName"] as? String, "Stop")
        XCTAssertEqual(hso?["additionalContext"] as? String, "сделай тесты")
        XCTAssertNil(HookOutput.stop(GateDecision(decision: "stop")))
        XCTAssertNil(HookOutput.stop(nil))
        XCTAssertNil(HookOutput.stop(GateDecision(decision: "continue", reason: "  ")))
    }
}
