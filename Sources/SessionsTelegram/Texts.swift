import Foundation

public struct SessionLine: Sendable {
    public let project: String
    public let branch: String
    public let state: String
    public let id: String
    public init(project: String, branch: String, state: String, id: String = "") {
        self.project = project; self.branch = branch; self.state = state; self.id = id
    }
}

/// Текст сообщения: HTML (parse_mode "HTML") и plain — на случай, если Telegram не разберёт разметку.
public struct RichText: Sendable, Equatable {
    public let plain: String
    public let html: String?
    public init(plain: String, html: String? = nil) { self.plain = plain; self.html = html }

    /// Приписка («Решено: …») к обоим вариантам; в HTML — экранированная.
    public func appending(_ note: String) -> RichText {
        RichText(plain: plain + "\n\n" + note, html: html.map { $0 + "\n\n" + TelegramHTML.escape(note) })
    }
}

/// Тексты бота — plain text; только «готово» дополнительно в HTML (ответ Claude в Markdown).
public enum Texts {

    public static let commands = [
        BotCommand(command: "afk_start", description: "Я отошёл — вести сессии через бота"),
        BotCommand(command: "afk_back", description: "Я вернулся — отпустить сессии"),
        BotCommand(command: "afk_status", description: "Что сейчас с сессиями"),
    ]

    static func head(_ project: String, _ branch: String) -> String { "\(project) · \(branch)" }

    public static func gate(project: String, branch: String, summary: String) -> String {
        "🔐 \(head(project, branch))\nПросит разрешение:\n\(BotAPI.clip(summary, limit: 1500))"
    }

    public static let doneFooter = "Ответьте на это сообщение — сессия продолжит с вашим текстом."
    public static let queuedFooter = "↪ Отдал ваш текст из очереди — сессия продолжает. Ответьте на это сообщение — текст встанет в очередь."

    public static func done(project: String, branch: String, lastMessage: String?,
                            footer: String = doneFooter) -> String {
        var t = "✅ \(head(project, branch)) — готово"
        if let m = body(lastMessage) {
            t += "\n\n" + BotAPI.clip(m, limit: 3500)
        }
        return t + "\n\n" + footer
    }

    /// «Готово» с Markdown ответа, переведённым в HTML. Режем исходный текст (не HTML — иначе
    /// разрезали бы тег), пока HTML не уложится с запасом под приписку «Решено: …».
    public static func doneRich(project: String, branch: String, lastMessage: String?,
                                footer: String = doneFooter) -> RichText {
        let plain = done(project: project, branch: branch, lastMessage: lastMessage, footer: footer)
        let top = "✅ " + TelegramHTML.escape(head(project, branch)) + " — готово"
        var limit = 3500
        while true {
            var t = top
            if let m = body(lastMessage) {
                t += "\n\n" + TelegramHTML.fromMarkdown(BotAPI.clip(m, limit: limit))
            }
            t += "\n\n" + TelegramHTML.escape(footer)
            if t.count <= htmlLimit { return RichText(plain: plain, html: t) }
            // Не влезает даже короткий ответ (огромное имя проекта) — только plain.
            if limit < 100 { return RichText(plain: plain) }
            limit = limit * 3 / 4
        }
    }

    /// «Готово», после которого ход сразу продолжился текстом из очереди.
    public static func doneQueued(project: String, branch: String, lastMessage: String?) -> RichText {
        doneRich(project: project, branch: branch, lastMessage: lastMessage, footer: queuedFooter)
    }

    /// Предел HTML «готово»: 4096 минус запас под приписку при редактировании.
    static let htmlLimit = 3900

    private static func body(_ m: String?) -> String? {
        guard let m = m?.trimmingCharacters(in: .whitespacesAndNewlines), !m.isEmpty else { return nil }
        return m
    }

    public static func waiting(project: String, branch: String, text: String) -> String {
        "⏳ \(head(project, branch)) ждёт ответа в терминале:\n\(BotAPI.clip(text, limit: 1500))"
    }

    public static func stalled(project: String, branch: String, minutes: Int) -> String {
        "🟥 \(head(project, branch)) молчит \(minutes) мин"
    }

    public static func status(afkOn: Bool, sessions: [SessionLine]) -> String {
        let mode = afkOn ? "Режим «Я отошёл» включён." : "Режим «Я отошёл» выключен."
        guard !sessions.isEmpty else { return mode + "\nСессий нет." }
        return mode + "\n\n" + sessions.map { "• \(head($0.project, $0.branch)) — \($0.state)" }.joined(separator: "\n")
    }

    /// Кнопки «Написать» под /afk_status: по одной в строке.
    public static func writeButtons(_ sessions: [SessionLine]) -> [[Button]] {
        sessions.filter { !$0.id.isEmpty }.map { [Button(text: "✍ " + head($0.project, $0.branch), data: CallbackData.write($0.id))] }
    }

    public static func compose(project: String, branch: String) -> String { "✍ Текст для \(head(project, branch)):" }
    public static let composePlaceholder = "Текст для сессии"
    public static let queued = "В очереди — отдам после текущего хода."
    public static let idle = "Сессия сейчас не ждёт ответа и не работает — напишите ей в терминале."
    public static let sessionGone = "Сессия уже закрыта"

    public static let paired = "Бот привязан. /afk_start — включить режим «Я отошёл», /afk_back — выключить."
    public static let needReplyTarget = "Ответьте reply'ем на сообщение нужной сессии."
    public static let notWaiting = "Эта сессия уже не ждёт ответа."
    public static let afkOff = "Режим «Я отошёл» выключен — сессии отпущены."
    public static func afkOffText(dropped: Int) -> String {
        dropped > 0 ? afkOff + "\nНе доставлено из очереди: \(dropped)." : afkOff
    }
    public static let back = "Вы вернулись — сессия отпущена."
    public static func afkOn(sessions: [SessionLine]) -> String { status(afkOn: true, sessions: sessions) }
    /// Ответ без адресата, когда ждущих сессий нет: объяснить и показать, что с сессиями.
    public static func nobodyWaiting(afkOn: Bool, sessions: [SessionLine]) -> String {
        "Сейчас ни одна сессия не ждёт ответа. Сессии пишут сюда сами, когда заканчивают ход.\n\n"
            + status(afkOn: afkOn, sessions: sessions)
    }
    public static func sleeping(held: Int) -> String { "💤 Мак засыпает — сессии встанут (ждут ответа: \(held))." }
    public static func resolved(_ what: String) -> String { "Решено: \(what)" }
}
