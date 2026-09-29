import XCTest
@testable import SessionsInventory

final class SuggesterTests: XCTestCase {

    private func plugin(_ name: String, refs: [String], weight: Int?) -> InventoryItem {
        var i = InventoryItem(kind: .plugin, name: name, scope: .global, source: "", weightTokens: weight)
        i.usageRefs = refs
        return i
    }

    func testUnusedEverywhereAndUnusedInProject() {
        // проекты без каталога не предлагаются — нужны настоящие каталоги
        let h = TempHome()
        let (web, swift, rare) = (h.project("p/web"), h.project("p/swift"), h.project("p/rare"))
        var usage = UsageIndex()
        usage.sessionsByProject = [web: 5, swift: 4, rare: 1]
        usage.byRef = ["skill:nuxt:seo": [web: UsageStat(count: 3, last: nil)]]
        let unused = plugin("figma@official", refs: ["skill:figma:use"], weight: 3000)
        let nuxt = plugin("nuxt@x", refs: ["skill:nuxt:seo"], weight: 500)
        var child = unused; child.owner = "figma"; child.kind = .skill   // дети не предлагаются

        let s = Suggester.suggest(items: [nuxt, unused, child], usage: usage, days: 30)
        XCTAssertEqual(s.first?.item.name, "figma@official")
        XCTAssertEqual(s.first?.target, .everywhere)
        XCTAssertTrue(s.first!.text.contains("figma"))
        XCTAssertTrue(s.contains { $0.item.name == "nuxt@x" && $0.target == .project(swift) })
        XCTAssertFalse(s.contains { $0.target == .project(rare) })   // мало сессий
        XCTAssertFalse(s.contains { $0.target == .project(web) })    // там используется
        XCTAssertEqual(s.filter { $0.item.owner != nil }.count, 0)
    }

    func testDisabledAndUntoggleableSkipped() {
        var off = plugin("a@b", refs: ["skill:a:x"], weight: 10); off.disabledGlobally = true
        var agent = InventoryItem(kind: .agent, name: "x", scope: .global, source: "")
        agent.usageRefs = ["agent:x"]
        XCTAssertTrue(Suggester.suggest(items: [off, agent], usage: UsageIndex(), days: 30).isEmpty)
    }

    func testUnreadableSkipped() {
        // маркеры битых файлов и плагины без установки не предлагаем выключать
        var broken = plugin("broken@x", refs: ["skill:broken:x"], weight: 100); broken.unreadable = true
        var mcp = InventoryItem(kind: .mcp, name: "srv", scope: .global, source: "", mcpOrigin: .userConfig)
        mcp.unreadable = true
        var usage = UsageIndex()
        usage.sessionsByProject = ["/p/web": 5]
        usage.byRef = ["mcp:srv": ["/p/other": UsageStat(count: 1, last: nil)]]
        mcp.usageRefs = ["mcp:srv"]
        XCTAssertTrue(mcp.toggleable && broken.toggleable)
        XCTAssertTrue(Suggester.suggest(items: [broken, mcp], usage: usage, days: 30).isEmpty)
    }

    func testMcpWithoutOriginNotToggleable() {
        // маркер нечитаемого ~/.claude.json / stash: kind .mcp без mcpOrigin
        var marker = InventoryItem(kind: .mcp, name: "~/.claude.json", scope: .global, source: "")
        marker.unreadable = true
        XCTAssertFalse(marker.toggleable)
        let user = InventoryItem(kind: .mcp, name: "s", scope: .global, source: "", mcpOrigin: .userConfig)
        XCTAssertTrue(user.toggleable)
    }

    func testItemsWithoutUsageRefsSkipped() {
        // плагин только с хуками/LSP/командами — вызовы не отслеживаются, не предлагаем
        let lsp = plugin("swift-lsp@x", refs: [], weight: nil)
        var usage = UsageIndex()
        usage.sessionsByProject = ["/p/web": 5]
        XCTAssertTrue(Suggester.suggest(items: [lsp], usage: usage, days: 30).isEmpty)
    }

    func testMarkersSkipped() {
        var marker = plugin("settings.json", refs: ["skill:x"], weight: 10)
        marker.marker = true
        XCTAssertFalse(marker.toggleable)
        XCTAssertTrue(Suggester.suggest(items: [marker], usage: UsageIndex(), days: 30).isEmpty)
    }

    func testMissingProjectDirsSkipped() {
        let h = TempHome()
        let real = h.project("real")
        var usage = UsageIndex()
        usage.sessionsByProject = [real: 5, "/gone/nowhere": 9]
        usage.byRef = ["skill:a:x": ["/elsewhere": UsageStat(count: 1, last: nil)]]
        let s = Suggester.suggest(items: [plugin("a@b", refs: ["skill:a:x"], weight: 1)], usage: usage, days: 30)
        XCTAssertEqual(s.map(\.target), [.project(real)])
    }

    func testOrderStableForEqualWeights() {
        let items = (0..<12).map { plugin("p\($0)@x", refs: ["skill:p\($0):s"], weight: 100) }
        let a = Suggester.suggest(items: items, usage: UsageIndex(), days: 30)
        let b = Suggester.suggest(items: items.reversed(), usage: UsageIndex(), days: 30)
        XCTAssertEqual(a.map(\.id), b.map(\.id))
        XCTAssertEqual(a.map(\.id), a.map(\.id).sorted())
    }
}
