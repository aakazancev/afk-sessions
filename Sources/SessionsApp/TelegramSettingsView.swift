import SwiftUI

/// Вкладка «Telegram»: токен бота, привязка чата, переключатели режима «Я отошёл».
struct TelegramSettingsView: View, SettingsSection {
    @EnvironmentObject var telegram: TelegramBridge
    @EnvironmentObject var afk: AfkController
    /// Введённый токен живёт только до «Сохранить».
    @State private var token = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                title("Telegram", "Один бот на все сессии. Работает, пока включён режим «Я отошёл».")
                statusBox
                tokenRow
                toggles
                note("Закрытая крышка MacBook всё равно усыпит мак — сессии встанут, бот предупредит.")
            }
        }
        .scrollIndicators(.never)
    }

    // MARK: - Статус и привязка

    private var statusBox: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(glyph).font(Theme.mono).foregroundStyle(color)
                Text(statusText).font(Theme.ui)
                Spacer()
                if telegram.status == .connected {
                    Button("Отвязать") { telegram.unpair() }
                } else if case .error = telegram.status {
                    // Отклонённый токен лежит в файле — дать его убрать.
                    Button("Удалить токен") { telegram.setToken(nil) }
                }
            }
            if case .pairing(let code) = telegram.status {
                pairing(code)
            }
            if let err = telegram.lastError {
                Text(err).font(Theme.uiSmall).foregroundStyle(Theme.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
        .padding(.bottom, 12)
    }

    private func pairing(_ code: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(code)
                .font(.system(size: 22, weight: .semibold, design: .monospaced))
                .foregroundStyle(Theme.text)
                .textSelection(.enabled)
            Text("Напишите боту: /start \(code)")
                .font(Theme.uiSmall).foregroundStyle(Theme.textDim)
                .textSelection(.enabled)
        }
    }

    private var glyph: String {
        switch telegram.status {
        case .noToken:   return "–"
        case .pairing:   return "…"
        case .connected: return "✓"
        case .error:     return "!"
        }
    }

    private var color: Color {
        switch telegram.status {
        case .noToken:   return Theme.textFaint
        case .pairing:   return Theme.orange
        case .connected: return Theme.green
        case .error:     return Theme.red
        }
    }

    private var statusText: String {
        switch telegram.status {
        case .noToken:        return "Бот не настроен"
        case .pairing:        return "Ждёт привязки"
        case .connected:      return "Подключён"
        case .error(let msg): return msg
        }
    }

    // MARK: - Токен

    /// Токен сохранён и принят: поле не нужно. При ошибке — просим ввести заново.
    private var tokenSaved: Bool {
        switch telegram.status {
        case .pairing, .connected: return true
        case .noToken, .error:     return false
        }
    }

    @ViewBuilder private var tokenRow: some View {
        if tokenSaved {
            row("Токен бота", "Токен хранится в файле, доступном только вашему пользователю") {
                Button("Удалить токен") { telegram.setToken(nil) }
            }
        } else {
            row("Токен бота", "Выдаёт @BotFather командой /newbot") {
                HStack(spacing: 8) {
                    // Поле тянется до 260, кнопка свой размер не отдаёт — иначе её сжимает в полоску.
                    SecureField("Токен от @BotFather", text: $token)
                        .textFieldStyle(.roundedBorder).frame(minWidth: 160, maxWidth: 260)
                        .onSubmit(save)
                    Button("Сохранить", action: save)
                        .fixedSize()
                        .disabled(token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    /// Пустое поле — ничего не делать: Enter не должен удалять токен.
    private func save() {
        let t = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        token = ""
        telegram.setToken(t)
    }

    // MARK: - Переключатели

    private var toggles: some View {
        VStack(spacing: 0) {
            row("Разрешения кнопками в Telegram",
                "«Разрешить» и «Отклонить» прямо в сообщении бота") {
                Toggle("", isOn: $telegram.approvals).labelsHidden()
            }
            row("Включать режим при блокировке экрана",
                "При разблокировке режим выключится сам") {
                Toggle("", isOn: $afk.onLock).labelsHidden()
            }
            row("Не давать маку засыпать в режиме",
                "Пока режим включён, сессии продолжают работать") {
                Toggle("", isOn: $afk.preventSleep).labelsHidden()
            }
        }
    }
}
