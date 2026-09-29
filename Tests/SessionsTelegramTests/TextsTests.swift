import XCTest
@testable import SessionsTelegram

final class TextsTests: XCTestCase {
    func testDoneClipsLastMessageAndNamesProject() {
        let t = Texts.done(project: "web", branch: "dev", lastMessage: String(repeating: "я", count: 5000))
        XCTAssertTrue(t.contains("web · dev"))
        XCTAssertLessThan(t.count, 4096)
    }
    func testCommandsAreValidTelegramNames() {
        for c in Texts.commands {
            XCTAssertTrue(c.command.allSatisfy { $0.isLowercase || $0.isNumber || $0 == "_" }, c.command)
        }
        XCTAssertEqual(Texts.commands.map(\.command), ["afk_start", "afk_back", "afk_status"])
    }
    func testStatusListsSessions() {
        let s = Texts.status(afkOn: true, sessions: [SessionLine(project: "web", branch: "dev", state: "ждёт")])
        XCTAssertTrue(s.contains("web · dev"))
        XCTAssertTrue(s.contains("ждёт"))
    }

    func testDoneRichFitsAndIsBalanced() {
        // Худший случай для экранирования: каждый символ «<» превращается в «&lt;».
        for body in [String(repeating: "<", count: 5000), String(repeating: "**a** `<b>` ", count: 600)] {
            let r = Texts.doneRich(project: "w&b", branch: "dev", lastMessage: body)
            let html = r.html ?? ""
            XCTAssertLessThanOrEqual(html.count, 4096)
            XCTAssertTrue(TelegramHTMLTests.balanced(html), String(html.suffix(200)))
            XCTAssertTrue(html.contains("w&amp;b · dev"))
            XCTAssertLessThanOrEqual(r.appending("Решено: вы вернулись").html!.count, 4096)
        }
    }
    func testDoneRichConvertsMarkdownAndKeepsPlainFallback() {
        let r = Texts.doneRich(project: "web", branch: "dev", lastMessage: "Готово: **тесты** зелёные")
        XCTAssertTrue(r.html?.contains("<b>тесты</b>") ?? false)
        XCTAssertEqual(r.plain, Texts.done(project: "web", branch: "dev", lastMessage: "Готово: **тесты** зелёные"))
    }
    func testNobodyWaitingListsSessions() {
        let s = Texts.nobodyWaiting(afkOn: true, sessions: [SessionLine(project: "web", branch: "dev", state: "работает")])
        XCTAssertTrue(s.hasPrefix("Сейчас ни одна сессия не ждёт ответа."))
        XCTAssertTrue(s.contains("web · dev — работает"))
    }
    func testAfkOnListsSessions() {
        let s = Texts.afkOn(sessions: [SessionLine(project: "web", branch: "dev", state: "работает")])
        XCTAssertTrue(s.hasPrefix("Режим «Я отошёл» включён."))
        XCTAssertTrue(s.contains("web · dev — работает"))
    }

    func testWriteButtonsOnePerSession() {
        let rows = Texts.writeButtons([SessionLine(project: "web", branch: "dev", state: "работает", id: "s1"),
                                       SessionLine(project: "api", branch: "main", state: "готово", id: "s2"),
                                       SessionLine(project: "x", branch: "y", state: "?")])   // без id — без кнопки
        XCTAssertEqual(rows, [[Button(text: "✍ web · dev", data: "w:s1")], [Button(text: "✍ api · main", data: "w:s2")]])
    }

    func testComposeNamesSession() {
        XCTAssertTrue(Texts.compose(project: "web", branch: "dev").contains("web · dev"))
        XCTAssertLessThanOrEqual(Texts.composePlaceholder.count, 64)
    }

    func testAfkOffMentionsDropped() {
        XCTAssertEqual(Texts.afkOffText(dropped: 0), Texts.afkOff)
        XCTAssertTrue(Texts.afkOffText(dropped: 2).contains("Не доставлено из очереди: 2"))
    }

    func testDoneQueuedHasQueueFooterNotReplyFooter() {
        let r = Texts.doneQueued(project: "web", branch: "dev", lastMessage: "**Готово**")
        XCTAssertTrue(r.plain.contains("из очереди"))
        XCTAssertFalse(r.plain.contains("сессия продолжит с вашим текстом"))
        XCTAssertTrue(r.html?.contains("из очереди") ?? false)
    }
}
