import XCTest
@testable import SessionsInventory

final class UsageScannerTests: XCTestCase {

    private func line(_ cwd: String, _ ts: String, _ name: String, _ input: String) -> String {
        #"{"type":"assistant","cwd":"\#(cwd)","timestamp":"\#(ts)","message":{"content":[{"type":"tool_use","name":"\#(name)","input":\#(input)}]}}"#
    }

    func testRefs() {
        XCTAssertEqual(UsageScanner.refs(toolName: "mcp__plugin_figma_figma__get_screenshot", input: [:]),
                       ["mcp:plugin_figma_figma"])
        XCTAssertEqual(UsageScanner.refs(toolName: "Skill", input: ["skill": "figma:figma-use"]),
                       ["skill:figma:figma-use"])
        XCTAssertEqual(UsageScanner.refs(toolName: "Agent", input: ["subagent_type": "Explore"]),
                       ["agent:Explore"])
        XCTAssertEqual(UsageScanner.refs(toolName: "Task", input: ["subagent_type": "Plan"]),
                       ["agent:Plan"])
        XCTAssertEqual(UsageScanner.refs(toolName: "Bash", input: [:]), [])
    }

    func testCountsByProjectWindowAndSessions() {
        let h = TempHome()
        let now = ISO8601DateFormatter().date(from: "2026-09-28T12:00:00Z")!
        h.write(".claude/projects/-a/s1.jsonl", [
            line("/p/a", "2026-09-27T10:00:00.000Z", "Skill", #"{"skill":"figma:figma-use"}"#),
            line("/p/a", "2026-09-27T11:00:00.000Z", "mcp__ctx__query", "{}"),
            line("/p/a", "2026-07-01T11:00:00.000Z", "mcp__ctx__query", "{}"),   // вне окна
            "not json",
        ].joined(separator: "\n"))
        h.write(".claude/projects/-b/s2.jsonl",
                line("/p/b", "2026-09-26T10:00:00Z", "mcp__claude_ai_Gmail__search", "{}"))

        let idx = UsageScanner(paths: h.paths).scan(days: 30, now: now)
        XCTAssertEqual(idx.inProject(["skill:figma:figma-use"], "/p/a").count, 1)
        XCTAssertEqual(idx.total(["mcp:ctx"]).count, 1)
        XCTAssertEqual(idx.total(["skill:figma:figma-use", "mcp:ctx"]).count, 2)
        XCTAssertEqual(idx.sessionsByProject["/p/a"], 1)
        XCTAssertEqual(Set(idx.projects), ["/p/a", "/p/b"])
        XCTAssertEqual(idx.connectors, ["claude_ai_Gmail"])
    }

    func testPluginSkillCallNotCountedForBareOwnSkill() {
        let h = TempHome()
        h.write(".claude/projects/-a/s.jsonl",
                line("/p/a", "2026-09-27T10:00:00Z", "Skill", #"{"skill":"figma:figma-use"}"#))
        let now = ISO8601DateFormatter().date(from: "2026-09-28T12:00:00Z")!
        let idx = UsageScanner(paths: h.paths).scan(days: 30, now: now)
        // свой скилл с тем же именем имеет refs ["skill:figma-use"] — вызова нет
        XCTAssertEqual(idx.total(["skill:figma-use"]).count, 0)
    }

    private let now = ISO8601DateFormatter().date(from: "2026-09-28T12:00:00Z")!

    func testSubagentCallsCountedButNotAsSessions() {
        let h = TempHome()
        h.write(".claude/projects/-a/s1.jsonl",
                line("/p/a", "2026-09-27T10:00:00Z", "Bash", "{}"))
        h.write(".claude/projects/-a/s1/subagents/agent-1.jsonl",
                line("/p/sub", "2026-09-27T10:00:00Z", "mcp__ctx__query", "{}"))
        // без cwd — проект родительской сессии
        h.write(".claude/projects/-a/s1/subagents/agent-2.jsonl",
                #"{"type":"assistant","timestamp":"2026-09-27T10:00:00Z","message":{"content":[{"type":"tool_use","name":"mcp__ctx__query","input":{}}]}}"#)

        let idx = UsageScanner(paths: h.paths).scan(days: 30, now: now)
        XCTAssertEqual(idx.inProject(["mcp:ctx"], "/p/sub").count, 1)
        XCTAssertEqual(idx.inProject(["mcp:ctx"], "/p/a").count, 1)
        XCTAssertEqual(idx.sessionsByProject, ["/p/a": 1])
    }

    func testFileOlderThanWindowIgnored() throws {
        let h = TempHome()
        let u = h.write(".claude/projects/-a/s.jsonl",
                        line("/p/a", "2026-09-27T10:00:00Z", "mcp__ctx__query", "{}"))
        try FileManager.default.setAttributes(
            [.modificationDate: now.addingTimeInterval(-40 * 86400)], ofItemAtPath: u.path)
        let idx = UsageScanner(paths: h.paths).scan(days: 30, now: now)
        XCTAssertEqual(idx.total(["mcp:ctx"]).count, 0)
        XCTAssertTrue(idx.sessionsByProject.isEmpty)
    }

    func testCacheInvalidatedOnAppend() throws {
        let h = TempHome()
        let first = line("/p/a", "2026-09-27T10:00:00Z", "mcp__ctx__query", "{}")
        let u = h.write(".claude/projects/-a/s.jsonl", first)
        let scanner = UsageScanner(paths: h.paths)
        XCTAssertEqual(scanner.scan(days: 30, now: now).total(["mcp:ctx"]).count, 1)
        h.write(u.path, first + "\n" + line("/p/a", "2026-09-27T11:00:00Z", "mcp__ctx__query", "{}"))
        XCTAssertEqual(scanner.scan(days: 30, now: now).total(["mcp:ctx"]).count, 2)
    }

    func testProjectsOrderDeterministic() {
        var idx = UsageIndex()
        idx.sessionsByProject = ["/b": 1, "/a": 1, "/c": 2]
        XCTAssertEqual(idx.projects, ["/c", "/a", "/b"])
    }
}
