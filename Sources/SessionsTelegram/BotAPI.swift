import Foundation

public protocol BotTransport: Sendable {
    func post(_ method: String, _ body: Data) async throws -> Data
    func postMultipart(_ method: String, fields: [String: String], files: [UploadFile]) async throws -> Data
}

/// Настоящий транспорт: POST https://api.telegram.org/bot<token>/<method>.
public struct HTTPTransport: BotTransport {
    let token: String
    let session: URLSession

    public init(token: String, session: URLSession = .shared) { self.token = token; self.session = session }

    public func post(_ method: String, _ body: Data) async throws -> Data {
        var req = try request(method)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = body
        req.timeoutInterval = 70   // long polling держит до 50 с
        return try await perform(req)
    }

    public func postMultipart(_ method: String, fields: [String: String], files: [UploadFile]) async throws -> Data {
        let boundary = "afk-" + UUID().uuidString
        var req = try request(method)
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.httpBody = Multipart.body(boundary: boundary, fields: fields, files: files)
        req.timeoutInterval = 120   // до 10 снимков по нескольку МБ
        return try await perform(req)
    }

    private func request(_ method: String) throws -> URLRequest {
        guard let url = URL(string: "https://api.telegram.org/bot\(token)/\(method)") else {
            throw BotError(code: nil, message: "Неверный токен")
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        return req
    }

    private func perform(_ req: URLRequest) async throws -> Data {
        // Ошибки URLSession несут полный URL (с токеном) в userInfo — наружу их не выпускаем.
        do {
            let (data, _) = try await session.data(for: req)
            return data
        } catch let e as URLError {
            throw BotError(code: nil, message: e.localizedDescription)
        } catch {
            throw BotError(code: nil, message: "Нет связи с Telegram")
        }
    }
}

public struct BotError: Error, LocalizedError, Equatable {
    public let code: Int?
    public let message: String
    public init(code: Int?, message: String) { self.code = code; self.message = message }
    public var errorDescription: String? { message }
    /// 400 «can't parse entities»: Telegram не принял HTML-разметку.
    public var isParseError: Bool { code == 400 && message.lowercased().contains("can't parse entities") }
}

public struct BotAPI: Sendable {
    let transport: BotTransport

    public init(transport: BotTransport) { self.transport = transport }

    public func getUpdates(offset: Int?, timeout: Int) async throws -> [Update] {
        var p: [String: Any] = ["timeout": timeout, "allowed_updates": ["message", "callback_query"]]
        if let offset { p["offset"] = offset }
        return try await call("getUpdates", p)
    }

    /// Возвращает message_id отправленного сообщения.
    /// С parseMode текст не обрезается: обрезка посреди тега сломала бы разметку — длину держит вызывающий.
    public func sendMessage(chatId: Int64, text: String, parseMode: String? = nil,
                            buttons: [[Button]] = [], forceReply: String? = nil) async throws -> Int {
        var p: [String: Any] = ["chat_id": chatId, "text": parseMode == nil ? Self.clip(text) : text]
        if let parseMode { p["parse_mode"] = parseMode }
        if !buttons.isEmpty { p["reply_markup"] = Self.keyboard(buttons) }
        if let forceReply { p["reply_markup"] = ["force_reply": true, "input_field_placeholder": forceReply] as [String: Any] }
        let m: Message = try await call("sendMessage", p)
        return m.messageId
    }

    public func editMessageText(chatId: Int64, messageId: Int, text: String, parseMode: String? = nil,
                                buttons: [[Button]] = []) async throws {
        var p: [String: Any] = ["chat_id": chatId, "message_id": messageId,
                                "text": parseMode == nil ? Self.clip(text) : text]
        if let parseMode { p["parse_mode"] = parseMode }
        p["reply_markup"] = Self.keyboard(buttons)   // пустая клавиатура убирает кнопки
        let _: Ignored = try await call("editMessageText", p)
    }

    /// HTML-вариант, а если Telegram не разобрал разметку — тот же текст plain.
    public func send(chatId: Int64, _ t: RichText, buttons: [[Button]] = [], forceReply: String? = nil) async throws -> Int {
        guard let html = t.html else {
            return try await sendMessage(chatId: chatId, text: t.plain, buttons: buttons, forceReply: forceReply)
        }
        do {
            return try await sendMessage(chatId: chatId, text: html, parseMode: "HTML", buttons: buttons, forceReply: forceReply)
        } catch let e as BotError where e.isParseError {
            return try await sendMessage(chatId: chatId, text: t.plain, buttons: buttons, forceReply: forceReply)
        }
    }

    public func edit(chatId: Int64, messageId: Int, _ t: RichText, buttons: [[Button]] = []) async throws {
        guard let html = t.html else {
            return try await editMessageText(chatId: chatId, messageId: messageId, text: t.plain, buttons: buttons)
        }
        do {
            try await editMessageText(chatId: chatId, messageId: messageId, text: html, parseMode: "HTML", buttons: buttons)
        } catch let e as BotError where e.isParseError {
            try await editMessageText(chatId: chatId, messageId: messageId, text: t.plain, buttons: buttons)
        }
    }

    public func answerCallbackQuery(id: String, text: String?) async throws {
        var p: [String: Any] = ["callback_query_id": id]
        if let text { p["text"] = text }
        let _: Ignored = try await call("answerCallbackQuery", p)
    }

    public func setMyCommands(_ commands: [BotCommand]) async throws {
        let list = commands.map { ["command": $0.command, "description": $0.description] }
        let _: Ignored = try await call("setMyCommands", ["commands": list])
    }

    /// 1 файл — sendPhoto/sendDocument, 2–10 — альбом sendMediaGroup (лишние отбрасываются).
    /// replyTo — ответом на сообщение «готово»; удалено — всё равно отправить.
    public func sendMedia(chatId: Int64, kind: MediaKind, files: [MediaFile], replyTo: Int?) async throws {
        let files = Array(files.prefix(10))
        guard !files.isEmpty else { return }
        let type = kind == .photo ? "photo" : "document"
        var fields = ["chat_id": String(chatId)]
        if let replyTo {
            fields["reply_parameters"] = Self.json(["message_id": replyTo, "allow_sending_without_reply": true])
        }
        if files.count == 1 {
            let _: Ignored = try await upload(kind == .photo ? "sendPhoto" : "sendDocument",
                                              fields, [files[0].upload(field: type)])
            return
        }
        let uploads = files.enumerated().map { $1.upload(field: "file\($0)") }
        fields["media"] = Self.json(uploads.map { ["type": type, "media": "attach://\($0.field)"] })
        let _: Ignored = try await upload("sendMediaGroup", fields, uploads)
    }

    /// Telegram не принимает текст длиннее 4096 символов.
    public static func clip(_ text: String, limit: Int = 4096) -> String {
        text.count <= limit ? text : String(text.prefix(limit - 1)) + "…"
    }

    // MARK: - Внутреннее

    private struct Envelope<R: Decodable>: Decodable {
        let ok: Bool
        let result: R?
        let description: String?
        let errorCode: Int?
    }

    /// Результат, содержимое которого не нужно (true или объект).
    private struct Ignored: Decodable { init(from decoder: Decoder) throws {} }

    private static func keyboard(_ rows: [[Button]]) -> [String: Any] {
        ["inline_keyboard": rows.map { $0.map { ["text": $0.text, "callback_data": $0.data] } }]
    }

    private func call<R: Decodable>(_ method: String, _ params: [String: Any]) async throws -> R {
        try Self.decode(try await transport.post(method, JSONSerialization.data(withJSONObject: params)))
    }

    private static func json(_ object: Any) -> String {
        (try? JSONSerialization.data(withJSONObject: object)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }

    private func upload<R: Decodable>(_ method: String, _ fields: [String: String], _ files: [UploadFile]) async throws -> R {
        try Self.decode(try await transport.postMultipart(method, fields: fields, files: files))
    }

    private static func decode<R: Decodable>(_ data: Data) throws -> R {
        let dec = JSONDecoder()
        dec.keyDecodingStrategy = .convertFromSnakeCase
        // Не конверт Bot API (например, HTML 502 от прокси) — понятная ошибка вместо DecodingError.
        guard let env = try? dec.decode(Envelope<R>.self, from: data) else {
            throw BotError(code: nil, message: "Неожиданный ответ Telegram")
        }
        guard env.ok, let result = env.result else {
            throw BotError(code: env.errorCode, message: env.description ?? "Ошибка Telegram")
        }
        return result
    }
}
