import XCTest
@testable import SessionsInventory

final class TogglerTests: XCTestCase {

    private func toggler(_ h: TempHome) -> Toggler {
        Toggler(paths: h.paths, stash: h.url.appendingPathComponent("stash.json"))
    }

    func testPluginProjectRoundTrip() throws {
        let h = TempHome()
        let p = h.project("app")
        h.write("\(p)/.claude/settings.local.json", #"{"permissions": {"allow": ["Bash"]}}"#)
        let item = InventoryItem(kind: .plugin, name: "figma@official", scope: .global, source: "")
        try toggler(h).setDisabled(item, true, .project(p))
        XCTAssertEqual((h.json("\(p)/.claude/settings.local.json")["enabledPlugins"] as? [String: Bool])?["figma@official"], false)
        try toggler(h).setDisabled(item, false, .project(p))
        let back = h.json("\(p)/.claude/settings.local.json")
        XCTAssertNil(back["enabledPlugins"])
        XCTAssertNotNil(back["permissions"])
    }

    func testUserMcpEverywhereStashesAndRestores() throws {
        let h = TempHome()
        h.write(".claude.json", #"{"mcpServers": {"ctx": {"command": "npx", "args": ["ctx"]}}, "numStartups": 5}"#)
        let item = InventoryItem(kind: .mcp, name: "ctx", scope: .global,
                                 source: h.paths.claudeJSON.path, mcpOrigin: .userConfig)
        try toggler(h).setDisabled(item, true, .everywhere)
        XCTAssertNil((h.json(".claude.json")["mcpServers"] as? [String: Any])?["ctx"])
        XCTAssertEqual(h.json(".claude.json")["numStartups"] as? Int, 5)
        try toggler(h).setDisabled(item, false, .everywhere)
        let ctx = (h.json(".claude.json")["mcpServers"] as? [String: Any])?["ctx"] as? [String: Any]
        XCTAssertEqual(ctx?["args"] as? [String], ["ctx"])
        XCTAssertNil((h.json("stash.json")["mcpServers"] as? [String: Any])?["ctx"])
    }

    func testUserMcpProjectKeepsOtherProjectKeys() throws {
        let h = TempHome()
        let p = h.project("app")
        h.write(".claude.json", #"{"projects": {"\#(p)": {"hasTrustDialogAccepted": true}}}"#)
        let item = InventoryItem(kind: .mcp, name: "ctx", scope: .global,
                                 source: h.paths.claudeJSON.path, mcpOrigin: .userConfig)
        try toggler(h).setDisabled(item, true, .project(p))
        var conf = (h.json(".claude.json")["projects"] as? [String: Any])?[p] as? [String: Any]
        XCTAssertEqual(conf?["disabledMcpServers"] as? [String], ["ctx"])
        XCTAssertEqual(conf?["hasTrustDialogAccepted"] as? Bool, true)
        try toggler(h).setDisabled(item, false, .project(p))
        conf = (h.json(".claude.json")["projects"] as? [String: Any])?[p] as? [String: Any]
        XCTAssertNil(conf?["disabledMcpServers"])
    }

    func testMcpJSONProject() throws {
        let h = TempHome()
        let p = h.project("app")
        let item = InventoryItem(kind: .mcp, name: "nuxt", scope: .project(p),
                                 source: "\(p)/.mcp.json", mcpOrigin: .mcpJSON)
        try toggler(h).setDisabled(item, true, .project(p))
        XCTAssertEqual(h.json("\(p)/.claude/settings.local.json")["disabledMcpjsonServers"] as? [String], ["nuxt"])
    }

    func testUnsupportedAndMissingProject() {
        let h = TempHome()
        let agent = InventoryItem(kind: .agent, name: "x", scope: .global, source: "")
        XCTAssertThrowsError(try toggler(h).setDisabled(agent, true, .everywhere)) {
            XCTAssertEqual($0 as? ToggleError, .unsupported)
        }
        let skill = InventoryItem(kind: .skill, name: "s", owner: "p", scope: .global, source: "")
        XCTAssertThrowsError(try toggler(h).setDisabled(skill, true, .everywhere)) {
            XCTAssertEqual($0 as? ToggleError, .unsupported)
        }
        let plugin = InventoryItem(kind: .plugin, name: "a@b", scope: .global, source: "")
        XCTAssertThrowsError(try toggler(h).setDisabled(plugin, true, .project("/gone/nowhere"))) {
            XCTAssertEqual($0 as? ToggleError, .projectMissing("/gone/nowhere"))
        }
        // путь есть, но это файл, а не каталог
        let file = h.write("notdir", "x").path
        XCTAssertThrowsError(try toggler(h).setDisabled(plugin, true, .project(file))) {
            XCTAssertEqual($0 as? ToggleError, .projectMissing(file))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: "/gone/nowhere"))
    }

    func testCorruptTargetIsNotOverwritten() {
        let h = TempHome()
        let u = h.write(".claude/settings.json", "{ broken")
        let plugin = InventoryItem(kind: .plugin, name: "a@b", scope: .global, source: "")
        XCTAssertThrowsError(try toggler(h).setDisabled(plugin, true, .everywhere))
        XCTAssertEqual(try String(contentsOf: u, encoding: .utf8), "{ broken")
    }

    private let userCtx = #"{"mcpServers": {"ctx": {"command": "npx", "args": ["ctx"]}}}"#

    private func ctxItem(_ h: TempHome) -> InventoryItem {
        InventoryItem(kind: .mcp, name: "ctx", scope: .global,
                      source: h.paths.claudeJSON.path, mcpOrigin: .userConfig)
    }

    func testRestoreConflictLeavesBothFilesUntouched() throws {
        let h = TempHome()
        h.write(".claude.json", userCtx)
        try toggler(h).setDisabled(ctxItem(h), true, .everywhere)
        // пользователь заново добавил другой ctx
        let claude = h.write(".claude.json", #"{"mcpServers": {"ctx": {"command": "other"}}}"#)
        let stash = h.url.appendingPathComponent("stash.json")
        let before = (try String(contentsOf: claude, encoding: .utf8), try String(contentsOf: stash, encoding: .utf8))
        XCTAssertThrowsError(try toggler(h).setDisabled(ctxItem(h), false, .everywhere)) {
            XCTAssertEqual($0 as? ToggleError, .conflict("ctx"))
        }
        XCTAssertEqual(try String(contentsOf: claude, encoding: .utf8), before.0)
        XCTAssertEqual(try String(contentsOf: stash, encoding: .utf8), before.1)
    }

    func testDisableConflictWithOlderStashEntry() throws {
        let h = TempHome()
        h.write(".claude.json", userCtx)
        h.write("stash.json", #"{"mcpServers": {"ctx": {"command": "older"}}}"#)
        XCTAssertThrowsError(try toggler(h).setDisabled(ctxItem(h), true, .everywhere)) {
            XCTAssertEqual($0 as? ToggleError, .conflict("ctx"))
        }
        XCTAssertNotNil((h.json(".claude.json")["mcpServers"] as? [String: Any])?["ctx"])
    }

    func testMoveIsIdempotentWhenDestinationEqual() throws {
        let h = TempHome()
        h.write(".claude.json", userCtx)
        h.write("stash.json", #"{"mcpServers": {"ctx": {"args": ["ctx"], "command": "npx"}}}"#)
        try toggler(h).setDisabled(ctxItem(h), true, .everywhere)
        XCTAssertNil((h.json(".claude.json")["mcpServers"] as? [String: Any])?["ctx"])
        XCTAssertNotNil((h.json("stash.json")["mcpServers"] as? [String: Any])?["ctx"])
    }

    func testMoveMissingServerThrowsNotFound() {
        let h = TempHome()
        XCTAssertThrowsError(try toggler(h).setDisabled(ctxItem(h), true, .everywhere)) {
            XCTAssertEqual($0 as? ToggleError, .notFound("ctx"))
        }
        XCTAssertThrowsError(try toggler(h).setDisabled(ctxItem(h), false, .everywhere)) {
            XCTAssertEqual($0 as? ToggleError, .notFound("ctx"))
        }
    }

    func testStashRoundTripThroughScanner() throws {
        let h = TempHome()
        h.write(".claude.json", userCtx)
        let stash = h.url.appendingPathComponent("stash.json")
        let scanner = ConfigScanner(paths: h.paths, stash: stash)
        func ctx() -> [InventoryItem] { scanner.scan(projects: []).filter { $0.kind == .mcp && $0.name == "ctx" } }

        try toggler(h).setDisabled(ctxItem(h), true, .everywhere)
        XCTAssertEqual(ctx().count, 1)
        XCTAssertEqual(ctx().first?.disabledGlobally, true)
        // восстанавливаем тем элементом, что показал сканер
        try toggler(h).setDisabled(ctx()[0], false, .everywhere)
        XCTAssertEqual(ctx().count, 1)
        XCTAssertEqual(ctx().first?.disabledGlobally, false)
        XCTAssertEqual(ctx().first?.source, h.paths.claudeJSON.path)
    }

    // MARK: - Финальные правки

    func testRestorePluginInProjectOverridesSharedFalse() throws {
        let h = TempHome()
        let p = h.project("app")
        h.write("\(p)/.claude/settings.json", #"{"enabledPlugins": {"figma@official": false}}"#)
        let item = InventoryItem(kind: .plugin, name: "figma@official", scope: .global, source: "")
        try toggler(h).setDisabled(item, false, .project(p))
        XCTAssertEqual((h.json("\(p)/.claude/settings.local.json")["enabledPlugins"] as? [String: Bool])?["figma@official"], true)
        // общий settings.json проекта не трогаем
        XCTAssertEqual((h.json("\(p)/.claude/settings.json")["enabledPlugins"] as? [String: Bool])?["figma@official"], false)
        // и сканер больше не считает плагин выключенным в проекте
        h.write(".claude/settings.json", #"{"enabledPlugins": {"figma@official": true}}"#)
        let scanned = ConfigScanner(paths: h.paths).scan(projects: [p]).first { $0.name == "figma@official" }
        XCTAssertEqual(scanned?.disabledIn.contains(p), false)
    }

    func testUnexpectedTypeIsNotOverwritten() throws {
        let h = TempHome()
        let p = h.project("app")
        let local = h.write("\(p)/.claude/settings.local.json",
                            #"{"enabledPlugins": "odd", "disabledMcpjsonServers": {"x": 1}}"#)
        let before = try String(contentsOf: local, encoding: .utf8)
        let plugin = InventoryItem(kind: .plugin, name: "a@b", scope: .global, source: "")
        XCTAssertThrowsError(try toggler(h).setDisabled(plugin, true, .project(p))) {
            XCTAssertEqual($0 as? ToggleError, .unexpectedType("enabledPlugins"))
        }
        let nuxt = InventoryItem(kind: .mcp, name: "nuxt", scope: .project(p), source: "", mcpOrigin: .mcpJSON)
        XCTAssertThrowsError(try toggler(h).setDisabled(nuxt, true, .project(p))) {
            XCTAssertEqual($0 as? ToggleError, .unexpectedType("disabledMcpjsonServers"))
        }
        XCTAssertEqual(try String(contentsOf: local, encoding: .utf8), before)
        // массив не из строк — тоже неожиданный тип
        h.write(".claude.json", #"{"projects": {"\#(p)": {"disabledMcpServers": [1, 2]}}}"#)
        XCTAssertThrowsError(try toggler(h).setDisabled(ctxItem(h), true, .project(p))) {
            XCTAssertEqual($0 as? ToggleError, .unexpectedType("disabledMcpServers"))
        }
        XCTAssertNotNil(ToggleError.unexpectedType("k").errorDescription)
    }

    func testMcpJSONProjectRoundTrip() throws {
        let h = TempHome()
        let p = h.project("app")
        h.write("\(p)/.claude/settings.local.json", #"{"disabledMcpjsonServers": ["other"]}"#)
        let item = InventoryItem(kind: .mcp, name: "nuxt", scope: .project(p),
                                 source: "\(p)/.mcp.json", mcpOrigin: .mcpJSON)
        try toggler(h).setDisabled(item, true, .project(p))
        XCTAssertEqual(h.json("\(p)/.claude/settings.local.json")["disabledMcpjsonServers"] as? [String], ["other", "nuxt"])
        try toggler(h).setDisabled(item, false, .project(p))
        XCTAssertEqual(h.json("\(p)/.claude/settings.local.json")["disabledMcpjsonServers"] as? [String], ["other"])
    }

    func testProjectConfigMcpRoundTrip() throws {
        let h = TempHome()
        let p = h.project("app")
        h.write(".claude.json", #"{"projects": {"\#(p)": {"mcpServers": {"atl": {}}, "allowedTools": []}}}"#)
        let item = InventoryItem(kind: .mcp, name: "atl", scope: .project(p),
                                 source: h.paths.claudeJSON.path, mcpOrigin: .projectConfig)
        try toggler(h).setDisabled(item, true, .project(p))
        var conf = (h.json(".claude.json")["projects"] as? [String: Any])?[p] as? [String: Any]
        XCTAssertEqual(conf?["disabledMcpServers"] as? [String], ["atl"])
        try toggler(h).setDisabled(item, false, .project(p))
        conf = (h.json(".claude.json")["projects"] as? [String: Any])?[p] as? [String: Any]
        XCTAssertNil(conf?["disabledMcpServers"])
        XCTAssertNotNil((conf?["mcpServers"] as? [String: Any])?["atl"])
        XCTAssertNotNil(conf?["allowedTools"])
    }

    /// Оптимистичное обновление в панели совпадает с тем, что потом покажет сканер.
    func testToggledMatchesRescan() throws {
        let h = TempHome()
        let p = h.project("app")
        h.write("app/.mcp.json", #"{"mcpServers": {"nuxt-remote": {"url": "http://x"}}}"#)
        let find = { ConfigScanner(paths: h.paths).scan(projects: [p]).first { $0.name == "nuxt-remote" }! }
        let item = find()
        XCTAssertFalse(item.disabledIn.contains(p))
        try toggler(h).setDisabled(item, true, .project(p))
        XCTAssertEqual(item.toggled(true, .project(p)), find())
        try toggler(h).setDisabled(item, false, .project(p))
        XCTAssertEqual(item.toggled(true, .project(p)).toggled(false, .project(p)), find())
    }

    func testToggledEverywhere() {
        let item = InventoryItem(kind: .plugin, name: "figma@official", scope: .global, source: "")
        XCTAssertTrue(item.toggled(true, .everywhere).disabledGlobally)
        XCTAssertFalse(item.toggled(true, .everywhere).toggled(false, .everywhere).disabledGlobally)
        XCTAssertTrue(item.toggled(true, .everywhere).disabledIn.isEmpty)
    }
}
