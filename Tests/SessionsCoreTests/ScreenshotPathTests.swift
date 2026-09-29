import XCTest
@testable import SessionsCore

final class ScreenshotPathTests: XCTestCase {
    private let yes: (String) -> Bool = { _ in true }

    private func blocks(_ text: String) -> [[String: Any]] {
        [["type": "text", "text": text], ["type": "image", "source": ["type": "base64", "data": "xx"]]]
    }

    func testToolName() {
        XCTAssertTrue(ScreenshotPath.isScreenshotTool("mcp__plugin_playwright_playwright__browser_take_screenshot"))
        XCTAssertTrue(ScreenshotPath.isScreenshotTool("mcp__playwright__browser_take_screenshot"))
        XCTAssertFalse(ScreenshotPath.isScreenshotTool("mcp__plugin_figma_figma__get_screenshot"))
        XCTAssertFalse(ScreenshotPath.isScreenshotTool(nil))
    }

    func testRelativeDotPath() {
        let r = blocks("### Result\n- [Screenshot of full page](./footer-check.png)\n### Ran Playwright code\n```js\nawait page.screenshot({ path: './footer-check.png' });\n```")
        XCTAssertEqual(ScreenshotPath.extract(toolResponse: r, cwd: "/p/web", fileExists: yes), "/p/web/footer-check.png")
    }

    func testRelativeDirPathAndJpeg() {
        let r = blocks("- [Screenshot of viewport](.playwright-mcp/page-2026-09-23T08-28-30-923Z.jpeg)")
        XCTAssertEqual(ScreenshotPath.extract(toolResponse: r, cwd: "/p/web", fileExists: yes),
                       "/p/web/.playwright-mcp/page-2026-09-23T08-28-30-923Z.jpeg")
    }

    func testAbsolutePath() {
        let r = blocks("- [Screenshot of viewport](/tmp/shots/a.png)")
        XCTAssertEqual(ScreenshotPath.extract(toolResponse: r, cwd: "/p/web", fileExists: yes), "/tmp/shots/a.png")
    }

    func testSpacesAndCyrillicInName() {
        let r = blocks("- [Screenshot of viewport](shots/главная страница.png)")
        XCTAssertEqual(ScreenshotPath.extract(toolResponse: r, cwd: "/p/web", fileExists: yes),
                       "/p/web/shots/главная страница.png")
    }

    func testPlainStringResponse() {
        XCTAssertEqual(ScreenshotPath.extract(toolResponse: "- [Screenshot of viewport](a.png)", cwd: "/p", fileExists: yes), "/p/a.png")
    }

    func testWrappedContentObject() {
        let r: [String: Any] = ["content": blocks("- [Screenshot of viewport](a.png)")]
        XCTAssertEqual(ScreenshotPath.extract(toolResponse: r, cwd: "/p", fileExists: yes), "/p/a.png")
    }

    func testNoLinkOrErrorOrMissingFile() {
        XCTAssertNil(ScreenshotPath.extract(toolResponse: blocks("### Error\nError: File access denied"), cwd: "/p", fileExists: yes))
        XCTAssertNil(ScreenshotPath.extract(toolResponse: nil, cwd: "/p", fileExists: yes))
        XCTAssertNil(ScreenshotPath.extract(toolResponse: blocks("- [x](a.png)"), cwd: "/p", fileExists: { _ in false }))
    }
}
