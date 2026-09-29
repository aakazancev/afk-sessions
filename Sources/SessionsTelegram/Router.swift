import Foundation

public enum BotAction: Equatable {
    case pair(chatId: Int64)
    case afkStart, afkBack, afkStatus
    case reply(sessionId: String, text: String)
    case notWaiting
    case needReplyTarget
    case decide(requestId: String, allow: Bool, callbackId: String)
    /// requestId удерживаемого stop: старая кнопка не завершит следующий ход.
    case finish(requestId: String, callbackId: String)
    /// Сессия работает — текст в очередь до её stop.
    case enqueue(sessionId: String, text: String)
    /// Кнопка «Написать» из /afk_status.
    case compose(sessionId: String, callbackId: String)
    case ignore
}

/// message_id сообщения бота → сессия, о которой оно.
public struct MessageMap: Sendable {
    private var map: [Int: String] = [:]
    public init() {}
    public mutating func remember(_ messageId: Int, session: String) { map[messageId] = session }
    public func session(for messageId: Int) -> String? { map[messageId] }
}

public enum CallbackData {
    // Аргумент — requestId (gate или удерживаемого stop), не сессия.
    public static func approve(_ r: String) -> String { "a:" + r }
    public static func deny(_ r: String) -> String { "d:" + r }
    public static func finish(_ r: String) -> String { "f:" + r }
    // Аргумент — сессия, не requestId.
    public static func write(_ sessionId: String) -> String { "w:" + sessionId }
}

public enum Router {

    public static func newPairingCode() -> String {
        String(format: "%06d", Int.random(in: 0...999_999))
    }

    public static func route(_ u: Update, pairedChat: Int64?, pairingCode: String?,
                             map: MessageMap, waiting: [String], working: [String] = []) -> BotAction {
        if let q = u.callbackQuery {
            guard let chat = q.message?.chat.id, chat == pairedChat, let data = q.data,
                  data.count > 2 else { return .ignore }
            let rid = String(data.dropFirst(2))
            switch data.prefix(2) {
            case "a:": return .decide(requestId: rid, allow: true, callbackId: q.id)
            case "d:": return .decide(requestId: rid, allow: false, callbackId: q.id)
            case "f:": return .finish(requestId: rid, callbackId: q.id)
            case "w:": return .compose(sessionId: rid, callbackId: q.id)
            default:   return .ignore
            }
        }

        guard let m = u.message else { return .ignore }
        let text = (m.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

        guard m.chat.id == pairedChat else {
            // Только личный чат: код, показанный в группе, привязал бы всю группу.
            if pairedChat == nil, m.chat.type == "private", let code = pairingCode, text == "/start \(code)" {
                return .pair(chatId: m.chat.id)
            }
            return .ignore
        }
        guard !text.isEmpty else { return .ignore }

        // Командой считаем только известные; прочий текст со «/» (пути, /compact) — обычный ответ.
        let word = text.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? text
        let cmd = (word.split(separator: "@").first.map(String.init) ?? word).lowercased()
        switch cmd {
        case "/afk_start": return .afkStart
        case "/afk_back":  return .afkBack
        case "/afk_status", "/start": return .afkStatus
        default: break
        }

        if let rid = m.replyToMessage?.messageId {
            // reply на сообщение не о сессии (или после перезапуска) — просим выбрать сессию явно
            guard let sid = map.session(for: rid) else { return .needReplyTarget }
            if waiting.contains(sid) { return .reply(sessionId: sid, text: text) }
            if working.contains(sid) { return .enqueue(sessionId: sid, text: text) }
            return .notWaiting
        }
        return waiting.count == 1 ? .reply(sessionId: waiting[0], text: text) : .needReplyTarget
    }
}
