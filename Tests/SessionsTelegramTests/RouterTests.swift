import XCTest
@testable import SessionsTelegram

final class RouterTests: XCTestCase {

    private func update(_ json: String) -> Update {
        let dec = JSONDecoder(); dec.keyDecodingStrategy = .convertFromSnakeCase
        return try! dec.decode(Update.self, from: Data(json.utf8))
    }
    private func msg(chat: Int64, _ text: String, replyTo: Int? = nil, type: String = "private") -> Update {
        let r = replyTo.map { #","reply_to_message":{"message_id":\#($0)}"# } ?? ""
        return update(#"{"update_id":1,"message":{"message_id":9,"chat":{"id":\#(chat),"type":"\#(type)"},"text":"\#(text)"\#(r)}}"#)
    }
    private func cb(chat: Int64, _ data: String) -> Update {
        update(#"{"update_id":1,"callback_query":{"id":"q","data":"\#(data)","message":{"message_id":9,"chat":{"id":\#(chat)}}}}"#)
    }

    func testPairing() {
        XCTAssertEqual(Router.route(msg(chat: 5, "/start 123456"), pairedChat: nil, pairingCode: "123456",
                                    map: MessageMap(), waiting: []), .pair(chatId: 5))
        XCTAssertEqual(Router.route(msg(chat: 5, "/start 000000"), pairedChat: nil, pairingCode: "123456",
                                    map: MessageMap(), waiting: []), .ignore)
        XCTAssertEqual(Router.route(msg(chat: 6, "/start 123456"), pairedChat: 5, pairingCode: "123456",
                                    map: MessageMap(), waiting: []), .ignore)
    }

    func testPairingOnlyFromPrivateChat() {
        // Код, увиденный в группе, не должен привязать группу: все её участники получили бы кнопки.
        for type in ["group", "supergroup", "channel"] {
            XCTAssertEqual(Router.route(msg(chat: -100, "/start 123456", type: type), pairedChat: nil,
                                        pairingCode: "123456", map: MessageMap(), waiting: []), .ignore)
        }
        // Без поля type (старый формат) — тоже не привязываем.
        let noType = update(#"{"update_id":1,"message":{"message_id":9,"chat":{"id":5},"text":"/start 123456"}}"#)
        XCTAssertEqual(Router.route(noType, pairedChat: nil, pairingCode: "123456",
                                    map: MessageMap(), waiting: []), .ignore)
    }

    func testForeignChatIgnored() {
        XCTAssertEqual(Router.route(msg(chat: 6, "/afk_start"), pairedChat: 5, pairingCode: nil,
                                    map: MessageMap(), waiting: []), .ignore)
        XCTAssertEqual(Router.route(cb(chat: 6, "a:s1"), pairedChat: 5, pairingCode: nil,
                                    map: MessageMap(), waiting: []), .ignore)
    }

    func testCommands() {
        func r(_ t: String) -> BotAction {
            Router.route(msg(chat: 5, t), pairedChat: 5, pairingCode: nil, map: MessageMap(), waiting: [])
        }
        XCTAssertEqual(r("/afk_start"), .afkStart)
        XCTAssertEqual(r("/afk_back@my_bot"), .afkBack)
        XCTAssertEqual(r("/afk_status"), .afkStatus)
        XCTAssertEqual(r("/start"), .afkStatus)
        // неизвестная «команда» — обычный текст; ждущих нет → просим выбрать сессию
        XCTAssertEqual(r("/unknown"), .needReplyTarget)
        XCTAssertEqual(r("/AFK_START"), .afkStart)
        XCTAssertEqual(r("/afk_back сейчас"), .afkBack)
        XCTAssertEqual(r("/start 123456"), .afkStatus)
        XCTAssertEqual(r(""), .ignore)
    }

    func testReplyRouting() {
        var map = MessageMap(); map.remember(40, session: "s1"); map.remember(41, session: "s2")
        XCTAssertEqual(Router.route(msg(chat: 5, "дальше", replyTo: 40), pairedChat: 5, pairingCode: nil,
                                    map: map, waiting: ["s1", "s2"]), .reply(sessionId: "s1", text: "дальше"))
        XCTAssertEqual(Router.route(msg(chat: 5, "дальше", replyTo: 41), pairedChat: 5, pairingCode: nil,
                                    map: map, waiting: ["s1"]), .notWaiting)
        XCTAssertEqual(Router.route(msg(chat: 5, "дальше"), pairedChat: 5, pairingCode: nil,
                                    map: map, waiting: ["s2"]), .reply(sessionId: "s2", text: "дальше"))
        XCTAssertEqual(Router.route(msg(chat: 5, "дальше"), pairedChat: 5, pairingCode: nil,
                                    map: map, waiting: ["s1", "s2"]), .needReplyTarget)
        XCTAssertEqual(Router.route(msg(chat: 5, "дальше"), pairedChat: 5, pairingCode: nil,
                                    map: map, waiting: []), .needReplyTarget)
    }

    func testSlashTextAndUnmappedReply() {
        var map = MessageMap(); map.remember(40, session: "s1")
        XCTAssertEqual(Router.route(msg(chat: 5, "/Users/me/x.swift посмотри", replyTo: 40), pairedChat: 5,
                                    pairingCode: nil, map: map, waiting: ["s1"]),
                       .reply(sessionId: "s1", text: "/Users/me/x.swift посмотри"))
        XCTAssertEqual(Router.route(msg(chat: 5, "/compact"), pairedChat: 5, pairingCode: nil,
                                    map: map, waiting: ["s1"]), .reply(sessionId: "s1", text: "/compact"))
        // reply на сообщение не из карты — не угадываем, даже если ждёт одна сессия
        XCTAssertEqual(Router.route(msg(chat: 5, "дальше", replyTo: 99), pairedChat: 5, pairingCode: nil,
                                    map: map, waiting: ["s1"]), .needReplyTarget)
    }

    func testUnpairedEdgeCases() {
        XCTAssertEqual(Router.route(cb(chat: 5, "a:s1"), pairedChat: nil, pairingCode: "123456",
                                    map: MessageMap(), waiting: []), .ignore)
        XCTAssertEqual(Router.route(msg(chat: 5, "/start 123456"), pairedChat: nil, pairingCode: nil,
                                    map: MessageMap(), waiting: []), .ignore)
    }

    func testCallbacks() {
        func r(_ d: String) -> BotAction {
            Router.route(cb(chat: 5, d), pairedChat: 5, pairingCode: nil, map: MessageMap(), waiting: [])
        }
        XCTAssertEqual(r(CallbackData.approve("r1")), .decide(requestId: "r1", allow: true, callbackId: "q"))
        XCTAssertEqual(r(CallbackData.deny("r1")), .decide(requestId: "r1", allow: false, callbackId: "q"))
        // «Завершить» адресует конкретный удерживаемый stop — по его requestId
        let rid = "0F8C2A57-3E4B-4D2B-9C71-5A6E7D8F9A0B"
        XCTAssertEqual(r(CallbackData.finish(rid)), .finish(requestId: rid, callbackId: "q"))
        XCTAssertLessThanOrEqual(CallbackData.finish(rid).utf8.count, 64)
        XCTAssertEqual(r("zzz"), .ignore)
    }

    func testPairingCodeIsSixDigits() {
        let c = Router.newPairingCode()
        XCTAssertEqual(c.count, 6)
        XCTAssertTrue(c.allSatisfy(\.isNumber))
    }

    func testReplyToWorkingSessionEnqueues() {
        var map = MessageMap(); map.remember(40, session: "s1")
        XCTAssertEqual(Router.route(msg(chat: 5, "и ещё тесты", replyTo: 40), pairedChat: 5, pairingCode: nil,
                                    map: map, waiting: [], working: ["s1"]),
                       .enqueue(sessionId: "s1", text: "и ещё тесты"))
    }

    func testReplyPrefersWaitingOverWorking() {
        var map = MessageMap(); map.remember(40, session: "s1")
        XCTAssertEqual(Router.route(msg(chat: 5, "да", replyTo: 40), pairedChat: 5, pairingCode: nil,
                                    map: map, waiting: ["s1"], working: ["s1"]),
                       .reply(sessionId: "s1", text: "да"))
    }

    func testReplyToIdleSessionNotWaiting() {
        var map = MessageMap(); map.remember(40, session: "s1")
        XCTAssertEqual(Router.route(msg(chat: 5, "да", replyTo: 40), pairedChat: 5, pairingCode: nil,
                                    map: map, waiting: [], working: ["s2"]), .notWaiting)
    }

    func testWriteButtonComposes() {
        XCTAssertEqual(Router.route(cb(chat: 5, CallbackData.write("s1")), pairedChat: 5, pairingCode: nil,
                                    map: MessageMap(), waiting: []), .compose(sessionId: "s1", callbackId: "q"))
        XCTAssertEqual(Router.route(cb(chat: 6, CallbackData.write("s1")), pairedChat: 5, pairingCode: nil,
                                    map: MessageMap(), waiting: []), .ignore)
    }

    func testWriteCallbackFitsTelegramLimit() {
        XCTAssertLessThanOrEqual(CallbackData.write(UUID().uuidString.lowercased()).utf8.count, 64)
    }
}
