import Foundation

// Минимум полей Bot API, которые нужны боту. Ключи — snake_case (decoder конвертирует).

public struct Update: Decodable, Sendable {
    public let updateId: Int
    public let message: Message?
    public let callbackQuery: CallbackQuery?
}

public struct Message: Decodable, Sendable {
    public let messageId: Int
    public let chat: Chat
    public let text: String?
    public let replyToMessage: MessageRef?
}

/// reply_to_message — полноценный Message, но нам нужен только id (и без рекурсии типов).
public struct MessageRef: Decodable, Sendable {
    public let messageId: Int
}

public struct Chat: Decodable, Sendable {
    public let id: Int64
    /// private / group / supergroup / channel. Привязка — только из private.
    public let type: String?
}

public struct CallbackQuery: Decodable, Sendable {
    public let id: String
    public let message: CallbackMessage?
    public let data: String?
}

public struct CallbackMessage: Decodable, Sendable {
    public let messageId: Int
    public let chat: Chat
}

public struct Button: Sendable, Equatable {
    public let text: String
    public let data: String   // callback_data, ≤ 64 байт
    public init(text: String, data: String) { self.text = text; self.data = data }
}

public struct BotCommand: Sendable {
    public let command: String
    public let description: String
    public init(command: String, description: String) { self.command = command; self.description = description }
}
