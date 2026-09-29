import XCTest
@testable import SessionsTelegram

/// Транспорт-заглушка: запоминает вызовы, отдаёт заготовленные ответы.
final class FakeTransport: BotTransport, @unchecked Sendable {
    var calls: [(method: String, body: [String: Any])] = []
    var responses: [String: String] = [:]
    /// Ответы по очереди (раньше responses): первый вызов — первый ответ.
    var queued: [String: [String]] = [:]
    func post(_ method: String, _ body: Data) async throws -> Data {
        calls.append((method, (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]))
        if var q = queued[method], !q.isEmpty {
            let r = q.removeFirst()
            queued[method] = q
            return Data(r.utf8)
        }
        return Data((responses[method] ?? #"{"ok":true,"result":true}"#).utf8)
    }
    var uploads: [(method: String, fields: [String: String], files: [UploadFile])] = []
    func postMultipart(_ method: String, fields: [String: String], files: [UploadFile]) async throws -> Data {
        uploads.append((method, fields, files))
        return Data((responses[method] ?? #"{"ok":true,"result":true}"#).utf8)
    }
}

final class BotAPITests: XCTestCase {

    func testGetUpdatesDecodesMessageAndCallback() async throws {
        let t = FakeTransport()
        t.responses["getUpdates"] = #"""
        {"ok":true,"result":[
          {"update_id":10,"message":{"message_id":5,"chat":{"id":42},"text":"привет",
            "reply_to_message":{"message_id":3,"chat":{"id":42}}}},
          {"update_id":11,"callback_query":{"id":"cb1","data":"a:s1",
            "message":{"message_id":7,"chat":{"id":42}}}}
        ]}
        """#
        let ups = try await BotAPI(transport: t).getUpdates(offset: 9, timeout: 50)
        XCTAssertEqual(ups.count, 2)
        XCTAssertEqual(ups[0].message?.replyToMessage?.messageId, 3)
        XCTAssertEqual(ups[0].message?.chat.id, 42)
        XCTAssertEqual(ups[1].callbackQuery?.data, "a:s1")
        XCTAssertEqual(ups[1].callbackQuery?.message?.messageId, 7)
        XCTAssertEqual(t.calls[0].body["offset"] as? Int, 9)
        XCTAssertEqual(t.calls[0].body["timeout"] as? Int, 50)
        XCTAssertEqual(t.calls[0].body["allowed_updates"] as? [String], ["message", "callback_query"])
    }

    func testSendMessageWithButtonsReturnsId() async throws {
        let t = FakeTransport()
        t.responses["sendMessage"] = #"{"ok":true,"result":{"message_id":77,"chat":{"id":42}}}"#
        let id = try await BotAPI(transport: t).sendMessage(
            chatId: 42, text: "x", buttons: [[Button(text: "Да", data: "a:s")]])
        XCTAssertEqual(id, 77)
        let kb = (t.calls[0].body["reply_markup"] as? [String: Any])?["inline_keyboard"] as? [[[String: Any]]]
        XCTAssertEqual(kb?[0][0]["callback_data"] as? String, "a:s")
        XCTAssertEqual(t.calls[0].body["chat_id"] as? Int64, 42)
    }

    func testParseModeIsSentAndHTMLNotClipped() async throws {
        let t = FakeTransport()
        t.responses["sendMessage"] = #"{"ok":true,"result":{"message_id":1,"chat":{"id":42}}}"#
        let api = BotAPI(transport: t)
        let long = String(repeating: "я", count: 4100)
        _ = try await api.sendMessage(chatId: 42, text: "<b>x</b>" + long, parseMode: "HTML")
        XCTAssertEqual(t.calls[0].body["parse_mode"] as? String, "HTML")
        XCTAssertEqual((t.calls[0].body["text"] as? String)?.hasPrefix("<b>x</b>"), true)
        XCTAssertEqual((t.calls[0].body["text"] as? String)?.count, 4108)
        _ = try await api.sendMessage(chatId: 42, text: long)
        XCTAssertNil(t.calls[1].body["parse_mode"])
        XCTAssertEqual((t.calls[1].body["text"] as? String)?.count, 4096)
        try await api.editMessageText(chatId: 42, messageId: 1, text: "<i>y</i>", parseMode: "HTML")
        XCTAssertEqual(t.calls[2].body["parse_mode"] as? String, "HTML")
    }

    func testRichFallsBackToPlainOnParseError() async throws {
        let t = FakeTransport()
        let parseError = #"{"ok":false,"error_code":400,"description":"Bad Request: can't parse entities: Unsupported start tag"}"#
        t.queued["sendMessage"] = [parseError, #"{"ok":true,"result":{"message_id":9,"chat":{"id":42}}}"#]
        t.queued["editMessageText"] = [parseError, #"{"ok":true,"result":true}"#]
        let api = BotAPI(transport: t)
        let rich = RichText(plain: "**x**", html: "<b>x</b>")
        let id = try await api.send(chatId: 42, rich, buttons: [[Button(text: "Да", data: "f:r")]])
        XCTAssertEqual(id, 9)
        XCTAssertEqual(t.calls.count, 2)
        XCTAssertEqual(t.calls[1].body["text"] as? String, "**x**")
        XCTAssertNil(t.calls[1].body["parse_mode"])
        XCTAssertNotNil(t.calls[1].body["reply_markup"])
        try await api.edit(chatId: 42, messageId: 9, rich.appending("Решено: <да>"))
        XCTAssertEqual(t.calls[2].body["text"] as? String, "<b>x</b>\n\nРешено: &lt;да&gt;")
        XCTAssertEqual(t.calls[3].body["text"] as? String, "**x**\n\nРешено: <да>")
        XCTAssertNil(t.calls[3].body["parse_mode"])
    }

    func testRichDoesNotRetryOtherErrors() async {
        let t = FakeTransport()
        t.responses["editMessageText"] = #"{"ok":false,"error_code":400,"description":"Bad Request: message is not modified"}"#
        do {
            try await BotAPI(transport: t).edit(chatId: 42, messageId: 1, RichText(plain: "a", html: "a"))
            XCTFail("должно бросить")
        } catch {
            XCTAssertEqual(t.calls.count, 1)
        }
    }

    func testErrorEnvelopeThrows() async {
        let t = FakeTransport()
        t.responses["getUpdates"] = #"{"ok":false,"error_code":401,"description":"Unauthorized"}"#
        do {
            _ = try await BotAPI(transport: t).getUpdates(offset: nil, timeout: 0)
            XCTFail("должно бросить")
        } catch let e as BotError {
            XCTAssertEqual(e.code, 401)
        } catch { XCTFail("\(error)") }
    }

    func testClip() {
        XCTAssertEqual(BotAPI.clip("abc", limit: 10), "abc")
        XCTAssertEqual(BotAPI.clip(String(repeating: "я", count: 20), limit: 10).count, 10)
        XCTAssertTrue(BotAPI.clip(String(repeating: "я", count: 20), limit: 10).hasSuffix("…"))
    }

    func testNonJSONBodyThrowsBotError() async {
        let t = FakeTransport()
        t.responses["getUpdates"] = "<html>502 Bad Gateway</html>"
        do {
            _ = try await BotAPI(transport: t).getUpdates(offset: nil, timeout: 0)
            XCTFail("должно бросить")
        } catch let e as BotError {
            XCTAssertNil(e.code)
        } catch { XCTFail("\(error)") }
    }

    func testNetworkErrorDoesNotLeakToken() async {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FailingURLProtocol.self]
        let transport = HTTPTransport(token: "SECRET_TOKEN", session: URLSession(configuration: config))
        do {
            _ = try await transport.post("getUpdates", Data("{}".utf8))
            XCTFail("должно бросить")
        } catch {
            XCTAssertTrue(error is BotError, "\(type(of: error))")
            XCTAssertFalse("\(error)".contains("SECRET_TOKEN"))
            XCTAssertFalse(String(reflecting: error).contains("SECRET_TOKEN"))
            XCTAssertFalse(error.localizedDescription.contains("SECRET_TOKEN"))
        }
    }

    func testSendMediaGroupOfPhotos() async throws {
        let t = FakeTransport()
        let files = (0..<3).map { MediaFile(filename: "s\($0).png", data: Data([UInt8($0)])) }
        try await BotAPI(transport: t).sendMedia(chatId: 42, kind: .photo, files: files, replyTo: 77)
        XCTAssertEqual(t.uploads.count, 1)
        let u = t.uploads[0]
        XCTAssertEqual(u.method, "sendMediaGroup")
        XCTAssertEqual(u.fields["chat_id"], "42")
        let media = try JSONSerialization.jsonObject(with: Data(u.fields["media"]!.utf8)) as! [[String: String]]
        XCTAssertEqual(media.map { $0["type"] }, ["photo", "photo", "photo"])
        XCTAssertEqual(media.map { $0["media"] }, ["attach://file0", "attach://file1", "attach://file2"])
        XCTAssertEqual(u.files.map(\.field), ["file0", "file1", "file2"])
        XCTAssertEqual(u.files[0].mime, "image/png")
        let rp = try JSONSerialization.jsonObject(with: Data(u.fields["reply_parameters"]!.utf8)) as! [String: Any]
        XCTAssertEqual(rp["message_id"] as? Int, 77)
        XCTAssertEqual(rp["allow_sending_without_reply"] as? Bool, true)
    }

    func testSingleFileUsesSendPhotoOrDocument() async throws {
        let t = FakeTransport()
        let f = [MediaFile(filename: "a.jpg", data: Data([1]))]
        try await BotAPI(transport: t).sendMedia(chatId: 1, kind: .photo, files: f, replyTo: nil)
        try await BotAPI(transport: t).sendMedia(chatId: 1, kind: .document, files: f, replyTo: nil)
        XCTAssertEqual(t.uploads.map(\.method), ["sendPhoto", "sendDocument"])
        XCTAssertEqual(t.uploads.map { $0.files[0].field }, ["photo", "document"])
        XCTAssertEqual(t.uploads[0].files[0].mime, "image/jpeg")
        XCTAssertNil(t.uploads[0].fields["reply_parameters"])
        XCTAssertNil(t.uploads[0].fields["media"])
    }

    func testSendMediaEmptyAndOverTen() async throws {
        let t = FakeTransport()
        try await BotAPI(transport: t).sendMedia(chatId: 1, kind: .photo, files: [], replyTo: nil)
        XCTAssertTrue(t.uploads.isEmpty)
        let many = (0..<12).map { MediaFile(filename: "\($0).png", data: Data()) }
        try await BotAPI(transport: t).sendMedia(chatId: 1, kind: .photo, files: many, replyTo: nil)
        XCTAssertEqual(t.uploads[0].method, "sendMediaGroup")
        XCTAssertEqual(t.uploads[0].files.count, 10)
        let media = try JSONSerialization.jsonObject(with: Data(t.uploads[0].fields["media"]!.utf8)) as! [[String: String]]
        XCTAssertEqual(media.count, 10)
    }

    func testSendMediaErrorThrows() async {
        let t = FakeTransport()
        t.responses["sendPhoto"] = #"{"ok":false,"error_code":400,"description":"Bad Request: PHOTO_INVALID_DIMENSIONS"}"#
        do {
            try await BotAPI(transport: t).sendMedia(chatId: 1, kind: .photo,
                                                     files: [MediaFile(filename: "a.png", data: Data())], replyTo: nil)
            XCTFail("должна быть ошибка")
        } catch let e as BotError {
            XCTAssertEqual(e.code, 400)
        } catch { XCTFail("\(error)") }
    }

    func testForceReplyMarkup() async throws {
        let t = FakeTransport()
        t.responses["sendMessage"] = #"{"ok":true,"result":{"message_id":5,"chat":{"id":1}}}"#
        _ = try await BotAPI(transport: t).send(chatId: 1, RichText(plain: "Текст для web · dev:"), forceReply: "Текст для сессии")
        let rm = t.calls[0].body["reply_markup"] as? [String: Any]
        XCTAssertEqual(rm?["force_reply"] as? Bool, true)
        XCTAssertEqual(rm?["input_field_placeholder"] as? String, "Текст для сессии")
    }

    func testMultipartBody() {
        let body = Multipart.body(boundary: "B", fields: ["b": "2", "a": "1"],
                                  files: [UploadFile(field: "file0", filename: "x\"y.png", mime: "image/png", data: Data("PNG".utf8))])
        let s = String(decoding: body, as: UTF8.self)
        XCTAssertEqual(s, "--B\r\nContent-Disposition: form-data; name=\"a\"\r\n\r\n1\r\n"
            + "--B\r\nContent-Disposition: form-data; name=\"b\"\r\n\r\n2\r\n"
            + "--B\r\nContent-Disposition: form-data; name=\"file0\"; filename=\"x_y.png\"\r\nContent-Type: image/png\r\n\r\nPNG\r\n"
            + "--B--\r\n")
    }
}

/// Любой запрос падает с URLError, в userInfo которого — полный URL (как у настоящего URLSession).
final class FailingURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var info: [String: Any] = [:]
        if let url = request.url {
            info[NSURLErrorFailingURLErrorKey] = url
            info[NSURLErrorFailingURLStringErrorKey] = url.absoluteString
        }
        client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet, userInfo: info))
    }
    override func stopLoading() {}
}
