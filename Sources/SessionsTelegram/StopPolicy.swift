import Foundation

/// Держать ли Stop сессии до ответа из Telegram.
public enum StopPolicy {
    /// Только в режиме «Я отошёл», когда ход действительно закончен (сабагентов нет),
    /// у сессии есть терминал (фоновые claude -p, Agent SDK, cron отпускаем сразу)
    /// и CLI ждёт ответа.
    public static func shouldHold(afkActive: Bool, agentsRunning: Bool,
                                  hasTTY: Bool, hasReplier: Bool) -> Bool {
        afkActive && !agentsRunning && hasTTY && hasReplier
    }
}
