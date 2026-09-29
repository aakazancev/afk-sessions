import XCTest
@testable import SessionsInventory

final class ConfigScannerTests: XCTestCase {

    private func fixture() -> (TempHome, String) {
        let h = TempHome()
        let proj = h.project("work/app")
        let plug = h.url.appendingPathComponent("cache/figma/1.0").path
        h.write(".claude/settings.json", #"""
        {"enabledPlugins": {"figma@official": true, "old@official": false}}
        """#)
        h.write(".claude/plugins/installed_plugins.json", """
        {"plugins": {"figma@official": [{"scope": "user", "installPath": "\(plug)"}],
                     "old@official":   [{"scope": "user", "installPath": "/nowhere"}]}}
        """)
        h.write("\(plug)/skills/figma-use/SKILL.md", """
        ---
        name: figma-use
        description: Use before every use_figma call
        ---
        body
        """)
        h.write("\(plug)/agents/spec.md", "---\nname: figma-spec\ndescription: pulls numbers\n---\n")
        h.write("\(plug)/.mcp.json", #"{"mcpServers": {"figma": {"type": "http"}}}"#)
        h.write(".claude.json", """
        {"mcpServers": {"ctx": {"command": "x"}},
         "projects": {"\(proj)": {"mcpServers": {"atlassian": {}}, "disabledMcpServers": ["ctx"]},
                      "/gone/project": {"mcpServers": {"z": {}}}}}
        """)
        h.write("\(proj)/.mcp.json", #"{"mcpServers": {"nuxt": {}}}"#)
        h.write("\(proj)/.claude/settings.local.json",
                #"{"enabledPlugins": {"figma@official": false}, "disabledMcpjsonServers": ["nuxt"]}"#)
        return (h, proj)
    }

    private func find(_ items: [InventoryItem], _ kind: ItemKind, _ name: String,
                      _ scope: Scope = .global) -> InventoryItem? {
        items.first { $0.kind == kind && $0.name == name && $0.scope == scope }
    }

    func testPluginWithChildren() {
        let (h, _) = fixture()
        let items = ConfigScanner(paths: h.paths).scan(projects: [])
        let plugin = find(items, .plugin, "figma@official")!
        XCTAssertFalse(plugin.disabledGlobally)
        XCTAssertTrue(plugin.usageRefs.contains("skill:figma:figma-use"))
        XCTAssertTrue(plugin.usageRefs.contains("mcp:plugin_figma_figma"))
        XCTAssertNotNil(plugin.weightTokens)
        let skill = find(items, .skill, "figma-use")!
        XCTAssertEqual(skill.owner, "figma")
        XCTAssertEqual(skill.usageRefs, ["skill:figma:figma-use", "skill:figma-use"])
        XCTAssertEqual(find(items, .agent, "figma-spec")?.owner, "figma")
        XCTAssertEqual(find(items, .mcp, "figma")?.mcpOrigin, .plugin)
    }

    func testDisabledPluginWithoutInstallIsUnreadable() {
        let (h, _) = fixture()
        let old = find(ConfigScanner(paths: h.paths).scan(projects: []), .plugin, "old@official")!
        XCTAssertTrue(old.disabledGlobally)
        XCTAssertTrue(old.unreadable)
    }

    func testProjectItemsAndDisables() {
        let (h, proj) = fixture()
        let items = ConfigScanner(paths: h.paths).scan(projects: [proj, "/gone/project"])
        XCTAssertTrue(find(items, .mcp, "ctx")!.disabledIn.contains(proj))
        XCTAssertEqual(find(items, .mcp, "atlassian", .project(proj))?.mcpOrigin, .projectConfig)
        let nuxt = find(items, .mcp, "nuxt", .project(proj))!
        XCTAssertEqual(nuxt.mcpOrigin, .mcpJSON)
        XCTAssertTrue(nuxt.disabledIn.contains(proj))
        XCTAssertTrue(find(items, .plugin, "figma@official")!.disabledIn.contains(proj))
        XCTAssertNil(find(items, .mcp, "z", .project("/gone/project")))
    }

    func testCorruptClaudeJSONDoesNotBreakScan() {
        let (h, proj) = fixture()
        h.write(".claude.json", "{ broken")
        let items = ConfigScanner(paths: h.paths).scan(projects: [proj])
        XCTAssertNotNil(find(items, .plugin, "figma@official"))
        XCTAssertTrue(items.contains { $0.unreadable && $0.name == "~/.claude.json" })
    }

    func testFrontmatter() {
        let fm = Frontmatter.parse("---\nname: a\ndescription: >-\n  one\n  two\n---\nbody")
        XCTAssertEqual(fm["name"], "a")
        XCTAssertEqual(fm["description"], "one two")
        XCTAssertEqual(Frontmatter.tokens(name: "abcd", description: "abcdefgh"), 3)
        XCTAssertTrue(Frontmatter.parse("no frontmatter").isEmpty)
    }

    func testProjectSettingsMergedPerKey() {
        let (h, proj) = fixture()
        h.write(".claude/settings.json", #"""
        {"enabledPlugins": {"figma@official": true, "a@x": true, "b@x": true}}
        """#)
        h.write("\(proj)/.mcp.json", #"{"mcpServers": {"nuxt": {}, "team": {}}}"#)
        h.write("\(proj)/.claude/settings.json",
                #"{"enabledPlugins": {"a@x": false}, "disabledMcpjsonServers": ["team"]}"#)
        h.write("\(proj)/.claude/settings.local.json",
                #"{"enabledPlugins": {"b@x": false}, "disabledMcpjsonServers": ["nuxt"]}"#)
        let items = ConfigScanner(paths: h.paths).scan(projects: [proj])
        XCTAssertTrue(find(items, .plugin, "a@x")!.disabledIn.contains(proj))
        XCTAssertTrue(find(items, .plugin, "b@x")!.disabledIn.contains(proj))
        XCTAssertTrue(find(items, .mcp, "team", .project(proj))!.disabledIn.contains(proj))
        XCTAssertTrue(find(items, .mcp, "nuxt", .project(proj))!.disabledIn.contains(proj))
    }

    func testNonBoolPluginEntryIsSkipped() {
        let (h, _) = fixture()
        h.write(".claude/settings.json", #"""
        {"enabledPlugins": {"figma@official": true, "weird@x": "yes"}}
        """#)
        let items = ConfigScanner(paths: h.paths).scan(projects: [])
        XCTAssertNotNil(find(items, .plugin, "figma@official"))
        XCTAssertNil(find(items, .plugin, "weird@x"))
    }

    func testIdsAreUnique() {
        let (h, proj) = fixture()
        h.write(".claude.json", """
        {"mcpServers": {"ctx": {}},
         "projects": {"\(proj)": {"mcpServers": {"nuxt": {}}}}}
        """)
        let items = ConfigScanner(paths: h.paths).scan(projects: [proj])
        XCTAssertEqual(items.filter { $0.name == "nuxt" }.count, 2)
        XCTAssertEqual(Set(items.map(\.id)).count, items.count)
    }

    func testStashedServersAreDisabledGlobally() {
        let (h, _) = fixture()
        let stash = h.write("stash.json", #"{"mcpServers": {"old": {"command": "y"}, "ctx": {"command": "z"}}}"#)
        let items = ConfigScanner(paths: h.paths, stash: stash).scan(projects: [])
        let old = find(items, .mcp, "old")
        XCTAssertEqual(old?.disabledGlobally, true)
        XCTAssertEqual(old?.mcpOrigin, .userConfig)
        XCTAssertEqual(old?.source, stash.path)
        XCTAssertEqual(old?.usageRefs, ["mcp:old"])
        // ctx есть и в ~/.claude.json — из stash не дублируется
        XCTAssertEqual(items.filter { $0.kind == .mcp && $0.name == "ctx" }.count, 1)
        XCTAssertEqual(find(items, .mcp, "ctx")?.disabledGlobally, false)
        XCTAssertEqual(Set(items.map(\.id)).count, items.count)
    }

    func testCorruptStashIsUnreadable() {
        let (h, _) = fixture()
        let stash = h.write("stash.json", "{ broken")
        let items = ConfigScanner(paths: h.paths, stash: stash).scan(projects: [])
        XCTAssertTrue(items.contains { $0.unreadable && $0.source == stash.path })
        XCTAssertNotNil(find(items, .mcp, "ctx"))
    }

    func testPluginChildrenIdsDifferByPluginKey() {
        var a = InventoryItem(kind: .skill, name: "s", owner: "figma", scope: .global, source: "")
        var b = a
        a.pluginKey = "figma@a"; b.pluginKey = "figma@b"
        XCTAssertNotEqual(a.id, b.id)
    }

    // MARK: - Финальные правки

    func testMarkersAreNotToggleable() {
        let (h, _) = fixture()
        h.write(".claude/settings.json", "{ broken")
        h.write(".claude.json", "{ broken")
        let stash = h.write("stash.json", "{ broken")
        let items = ConfigScanner(paths: h.paths, stash: stash).scan(projects: [])
        let markers = items.filter(\.marker)
        XCTAssertEqual(Set(markers.map(\.source)),
                       [h.paths.userSettings.path, h.paths.claudeJSON.path, stash.path])
        XCTAssertTrue(markers.allSatisfy { !$0.toggleable })
        // маркер kind .plugin «settings.json» раньше считался выключаемым
        XCTAssertFalse(find(items, .plugin, "settings.json")!.toggleable)
    }

    func testPluginFlatAndWrappedMcpJSON() {
        let (h, _) = fixture()
        let pw = h.url.appendingPathComponent("cache/playwright/1.0").path
        h.write(".claude/settings.json", #"""
        {"enabledPlugins": {"figma@official": true, "playwright@official": true}}
        """#)
        h.write(".claude/plugins/installed_plugins.json", """
        {"plugins": {"figma@official": [{"scope": "user", "installPath": "\(h.url.path)/cache/figma/1.0"}],
                     "playwright@official": [{"scope": "user", "installPath": "\(pw)"}]}}
        """)
        // плоский формат, как у playwright: без обёртки mcpServers
        h.write("\(pw)/.mcp.json", #"{"playwright": {"command": "npx"}, "note": "x"}"#)
        let items = ConfigScanner(paths: h.paths).scan(projects: [])
        let m = items.first { $0.kind == .mcp && $0.name == "playwright" }
        XCTAssertEqual(m?.mcpOrigin, .plugin)
        XCTAssertEqual(m?.usageRefs, ["mcp:plugin_playwright_playwright"])
        XCTAssertNil(items.first { $0.kind == .mcp && $0.name == "note" })
        XCTAssertTrue(find(items, .plugin, "playwright@official")!.usageRefs.contains("mcp:plugin_playwright_playwright"))
        // формат с обёрткой (figma) по-прежнему читается
        XCTAssertEqual(find(items, .mcp, "figma")?.usageRefs, ["mcp:plugin_figma_figma"])
    }

    func testMcpNamesNormalizedInRefs() {
        XCTAssertEqual(McpName.normalize("my.server x"), "my_server_x")
        XCTAssertEqual(McpName.normalize("Claude Docs"), "Claude_Docs")
        XCTAssertEqual(McpName.normalize("a-b_C9"), "a-b_C9")
        let (h, proj) = fixture()
        h.write(".claude.json", """
        {"mcpServers": {"my.server x": {}},
         "projects": {"\(proj)": {"mcpServers": {"team.srv": {}}}}}
        """)
        h.write("\(proj)/.mcp.json", #"{"mcpServers": {"nuxt ui": {}}}"#)
        h.write("\(h.url.path)/cache/figma/1.0/.mcp.json", #"{"mcpServers": {"fig.ma": {}}}"#)
        let items = ConfigScanner(paths: h.paths).scan(projects: [proj])
        XCTAssertEqual(find(items, .mcp, "my.server x")?.usageRefs, ["mcp:my_server_x"])
        XCTAssertEqual(find(items, .mcp, "team.srv", .project(proj))?.usageRefs, ["mcp:team_srv"])
        XCTAssertEqual(find(items, .mcp, "nuxt ui", .project(proj))?.usageRefs, ["mcp:nuxt_ui"])
        XCTAssertEqual(find(items, .mcp, "fig.ma")?.usageRefs, ["mcp:plugin_figma_fig_ma"])
    }
}
