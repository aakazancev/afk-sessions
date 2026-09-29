import XCTest
@testable import SessionsTelegram

final class TelegramHTMLTests: XCTestCase {
    private func h(_ s: String) -> String { TelegramHTML.fromMarkdown(s) }

    func testEscapesSpecialChars() {
        XCTAssertEqual(h("a < b && c > d"), "a &lt; b &amp;&amp; c &gt; d")
    }

    func testBold() {
        XCTAssertEqual(h("это **важно** и __тоже__"), "это <b>важно</b> и <b>тоже</b>")
    }

    func testItalic() {
        XCTAssertEqual(h("это *курсив* и _тоже_"), "это <i>курсив</i> и <i>тоже</i>")
    }

    func testUnderscoreInsideWordsIsNotItalic() {
        XCTAssertEqual(h("snake_case_name и 2*3*4"), "snake_case_name и 2*3*4")
    }

    func testInlineCodeKeepsMarkupAndEscapes() {
        XCTAssertEqual(h("запусти `a **b** <c>`"), "запусти <code>a **b** &lt;c&gt;</code>")
    }

    func testFencedBlock() {
        let md = "до\n```swift\nlet x = **1** < 2\n```\nпосле"
        XCTAssertEqual(h(md), "до\n<pre>let x = **1** &lt; 2</pre>\nпосле")
    }

    func testHeading() {
        XCTAssertEqual(h("## Итог работы"), "<b>Итог работы</b>")
    }

    func testBoldHeadingIsNotDoubled() {
        XCTAssertEqual(h("# **Итог**"), "<b>Итог</b>")
        XCTAssertEqual(h("## __Итог__"), "<b>Итог</b>")
    }

    func testLinkTextHasNoOtherEntities() {
        // Telegram: text_link не может содержать code — внутри ссылки только экранирование.
        XCTAssertEqual(h("[`run` **x** <y>](https://e.com)"), "<a href=\"https://e.com\">run **x** &lt;y&gt;</a>")
    }

    func testListMarkers() {
        XCTAssertEqual(h("- раз\n* два\n  - вложенный"), "• раз\n• два\n  • вложенный")
    }

    func testLink() {
        XCTAssertEqual(h("см. [доку](https://example.com/a?b=1&c=\"2\")"),
                       "см. <a href=\"https://example.com/a?b=1&amp;c=&quot;2&quot;\">доку</a>")
    }

    func testRelativeLinkStaysAsText() {
        // Telegram не принимает ссылки без схемы — такую разметку оставляем как есть.
        XCTAssertEqual(h("[Foo.swift](Sources/Foo.swift)"), "[Foo.swift](Sources/Foo.swift)")
    }

    func testNesting() {
        XCTAssertEqual(h("**жирный с *курсивом* и `кодом`**"),
                       "<b>жирный с <i>курсивом</i> и <code>кодом</code></b>")
    }

    func testUnclosedMarkersStayAsIs() {
        XCTAssertEqual(h("**не закрыт и `тоже и _ещё"), "**не закрыт и `тоже и _ещё")
        XCTAssertEqual(h("```\nкод без конца"), "```\nкод без конца")
        XCTAssertTrue(Self.balanced(h("**a *b** c*")))
    }

    /// Теги b/i/code/pre/a закрываются в обратном порядке.
    static func balanced(_ html: String) -> Bool {
        var stack: [String] = []
        let re = try! NSRegularExpression(pattern: "<(/?)(b|i|code|pre|a)(?: [^>]*)?>")
        let ns = html as NSString
        for m in re.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
            let closing = ns.substring(with: m.range(at: 1)) == "/"
            let tag = ns.substring(with: m.range(at: 2))
            if closing { if stack.popLast() != tag { return false } } else { stack.append(tag) }
        }
        // Вне тегов не должно остаться голых < и >.
        let stripped = re.stringByReplacingMatches(in: html, range: NSRange(location: 0, length: ns.length), withTemplate: "")
        return stack.isEmpty && !stripped.contains("<") && !stripped.contains(">")
    }
}
