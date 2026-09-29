import XCTest
@testable import SessionsCore

final class HookEnvTests: XCTestCase {

    func testInstallAddsWhenAbsent() {
        XCTAssertEqual(HookEnv.install(nil)[HookEnv.key] as? String, "100")
        let env = HookEnv.install(["OTHER": "1"])
        XCTAssertEqual(env[HookEnv.key] as? String, "100")
        XCTAssertEqual(env["OTHER"] as? String, "1")
    }

    func testInstallKeepsUserValue() {
        XCTAssertEqual(HookEnv.install([HookEnv.key: "20"])[HookEnv.key] as? String, "20")
        XCTAssertEqual(HookEnv.install([HookEnv.key: "0"])[HookEnv.key] as? String, "0")
    }

    func testOutdatedOnlyWhenAbsent() {
        XCTAssertTrue(HookEnv.isOutdated(nil))
        XCTAssertTrue(HookEnv.isOutdated(["OTHER": "1"]))
        XCTAssertFalse(HookEnv.isOutdated([HookEnv.key: "100"]))
        // Пользователь сам поставил другое значение — это его решение.
        XCTAssertFalse(HookEnv.isOutdated([HookEnv.key: "20"]))
    }

    func testUninstallRemovesOnlyOurs() {
        XCTAssertNil(HookEnv.uninstall(nil))
        XCTAssertNil(HookEnv.uninstall([HookEnv.key: "100"]))
        let rest = HookEnv.uninstall([HookEnv.key: "100", "OTHER": "1"])
        XCTAssertNil(rest?[HookEnv.key])
        XCTAssertEqual(rest?["OTHER"] as? String, "1")
        XCTAssertEqual(HookEnv.uninstall([HookEnv.key: "20"])?[HookEnv.key] as? String, "20")
        // Пустой env пользователя не трогаем — его ключа не было.
        XCTAssertNotNil(HookEnv.uninstall([:]))
    }
}
