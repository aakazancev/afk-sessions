import SwiftUI
import SessionsTelegram

struct MenuBarView: View {
    @EnvironmentObject var store: SessionStore
    @EnvironmentObject var afk: AfkController
    @EnvironmentObject var updates: UpdateChecker
    @Environment(\.openWindow) private var openWindow
    @State private var selection: String?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Theme.hairline)

            if store.hooksMoved {
                movedBanner
                Divider().overlay(Theme.hairline)
            }

            if store.visible.isEmpty {
                empty
            } else {
                ScrollView {
                    LazyVStack(spacing: 1) {
                        ForEach(store.visible) { s in
                            SessionRow(session: s, selected: selection == s.id)
                                .contentShape(Rectangle())
                                .onTapGesture { selection = s.id; store.jump(to: s) }
                        }
                    }
                    .padding(.vertical, 4)
                }
                .frame(height: listHeight)
            }

            Divider().overlay(Theme.hairline)
            updateRow
            footer
        }
        .frame(width: 400)
        .background(Theme.panel)
        .onAppear {
            selection = store.topWaiting?.id ?? store.visible.first?.id
            store.refreshHooksState()
        }
        .onKeyPress(.upArrow)   { move(-1); return .handled }
        .onKeyPress(.downArrow) { move(1);  return .handled }
        .onKeyPress(.return)    { decide(allow: true);  return .handled }
        .onKeyPress(.delete)    { decide(allow: false); return .handled }
    }

    // MARK: - Части

    /// Окно MenuBarExtra не умеет обнимать ScrollView по контенту,
    /// поэтому высота списка считается из числа строк: строка 54 + зазор 1,
    /// плюс вертикальные отступы списка. Потолок — 420, дальше скролл.
    private var listHeight: CGFloat {
        let rows = CGFloat(store.visible.count)
        return min(rows * SessionRow.height + max(rows - 1, 0) + 8, 420)
    }

    /// Версия из Info.plist бандла; без бандла (swift run) — прочерк.
    private static let version: String = {
        guard let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        else { return "—" }
        return "v" + v
    }()

    private var header: some View {
        HStack(spacing: 8) {
            Text("›_").font(Theme.monoSmall).foregroundStyle(Theme.orange)
            Text("AFK Sessions").font(.system(size: 12.5, weight: .semibold))
            Spacer()
            if store.waitingCount > 0 {
                Text("\(store.waitingCount) ждёт вас")
                    .font(Theme.uiSmall).foregroundStyle(Theme.orange)
            }
            afkPill
            Text(Self.version).font(Theme.monoSmall).foregroundStyle(Theme.textFaint)
        }
        .padding(.horizontal, 13).padding(.vertical, 9)
    }

    /// Переключатель режима «Я отошёл»: оранжевый, пока режим включён.
    private var afkPill: some View {
        Button {
            afk.send(afk.isOn ? .manualOff : .manualOn)
        } label: {
            HStack(spacing: 4) {
                Text("Я отошёл")
                if afk.mode == .lock {
                    Text("· по блокировке").opacity(0.75)
                }
                // Сессии, чей Stop держит режим, — иначе не понять, что их держит мак.
                if !store.heldStops.isEmpty {
                    Text("· ждут \(store.heldStops.count)")
                }
            }
            .font(Theme.uiSmall)
            .foregroundStyle(afk.isOn ? Theme.panel : Theme.textDim)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(afk.isOn ? Theme.orange : Theme.raise, in: Capsule())
            .overlay(Capsule().strokeBorder(afk.isOn ? .clear : Theme.hairline))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        // Без привязанного бота режим не действует — переключать нечего.
        .disabled(!afk.linked)
        .opacity(afk.linked ? 1 : 0.5)
        .help(afk.linked
            ? "Режим «Я отошёл»: Stop сессий придерживается, а разрешения и ответы "
                + "идут через Telegram-бота. Включается и блокировкой экрана — см. настройки."
            : "Сначала подключите Telegram в настройках")
    }

    /// Хуки указывают на старый путь бандла — после переезда приложения
    /// события молча теряются, надо переустановить.
    private var movedBanner: some View {
        HStack(spacing: 8) {
            Text("!").font(Theme.mono).foregroundStyle(Theme.orange)
            Text("Хуки устарели или смотрят на старый путь")
                .font(Theme.uiSmall).foregroundStyle(Theme.text)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button("Починить") {
                HookInstaller.install()
                store.refreshHooksState()
            }.buttonStyle(AccentButton())
        }
        .padding(.horizontal, 13).padding(.vertical, 8)
        .background(Theme.orange.opacity(0.12))
    }

    private var empty: some View {
        VStack(spacing: 6) {
            Text(store.hooksInstalled ? "Активных сессий нет" : "Хуки не установлены")
                .font(Theme.ui).foregroundStyle(Theme.textDim)
            if store.hooksInstalled {
                Text("⌥Space — панель · ⌥⇧A — разрешить верхнюю")
                    .font(Theme.uiSmall).foregroundStyle(Theme.textFaint)
            } else {
                Button("Открыть настройки") { openSettings() }
                    .buttonStyle(.link).font(Theme.uiSmall)
            }
        }
        .frame(maxWidth: .infinity).padding(.vertical, 28)
    }

    @ViewBuilder private var updateRow: some View {
        if let r = updates.available {
            Button("Доступна версия \(r.version) — скачать") { NSWorkspace.shared.open(r.url) }
                .buttonStyle(.link).font(Theme.uiSmall)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 13).padding(.top, 6)
        }
    }

    private var footer: some View {
        HStack(spacing: 6) {
            Text("\(store.sessions.count) \(plural(store.sessions.count, "сессия", "сессии", "сессий"))")
            if store.showCost, store.costs.totalToday >= 0.01 {
                Text("· $\(store.costs.totalToday, specifier: "%.2f") сегодня")
            }
            if store.stalledCount > 0 {
                Text("· \(store.stalledCount) молчит").foregroundStyle(Theme.red)
            }
            Spacer()
            if let url = Feedback.url {
                Button("Отзыв") { NSWorkspace.shared.open(url) }
                    .buttonStyle(.plain).foregroundStyle(Theme.textFaint)
            }
            Button("Настройки…") { openSettings() }
                .buttonStyle(.plain).foregroundStyle(Theme.textDim)
            Button("Выход") { NSApplication.shared.terminate(nil) }
                .buttonStyle(.plain).foregroundStyle(Theme.textFaint)
        }
        .font(Theme.monoSmall)
        .foregroundStyle(Theme.textFaint)
        .padding(.horizontal, 13).padding(.vertical, 8)
    }

    // MARK: - Клавиатура

    private func move(_ delta: Int) {
        let list = store.visible
        guard !list.isEmpty else { return }
        let current = list.firstIndex { $0.id == selection } ?? 0
        let next = min(max(current + delta, 0), list.count - 1)
        selection = list[next].id
    }

    private func decide(allow: Bool) {
        guard let id = selection,
              let s = store.visible.first(where: { $0.id == id }),
              s.state == .waiting, store.canDecide(s) else { return }
        store.decide(sessionId: id, allow: allow)
    }

    private func openSettings() {
        NSApp.activate(ignoringOtherApps: true)
        openWindow(id: "settings")
    }

    private func plural(_ n: Int, _ a: String, _ b: String, _ c: String) -> String {
        let n10 = n % 10, n100 = n % 100
        if n10 == 1 && n100 != 11 { return a }
        if (2...4).contains(n10) && !(12...14).contains(n100) { return b }
        return c
    }
}

// MARK: - Строка сессии

struct SessionRow: View {
    @EnvironmentObject var store: SessionStore
    let session: Session
    let selected: Bool

    /// Фиксированная высота строки — от неё считается высота панели.
    static let height: CGFloat = 54

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 7) {
                Circle()
                    .fill(session.state == .working ? .clear : Theme.dot(session.state))
                    .overlay(
                        Circle().strokeBorder(Theme.dot(session.state),
                                              lineWidth: session.state == .working ? 1.5 : 0)
                    )
                    .frame(width: 7, height: 7)

                Text(store.displayProject(session)).font(Theme.mono).foregroundStyle(Theme.text)

                Text(session.branch)
                    .font(Theme.monoSmall).foregroundStyle(Theme.textDim)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Theme.raise, in: RoundedRectangle(cornerRadius: 4))

                Spacer()

                Text(label)
                    .font(Theme.uiSmall)
                    .foregroundStyle(session.state == .waiting ? Theme.orange : Theme.textFaint)
                    .monospacedDigit()
            }

            HStack(spacing: 8) {
                Text(session.pending?.summary ?? session.activity)
                    .font(Theme.uiSmall)
                    .foregroundStyle(session.pending != nil ? Theme.orangeHi : Theme.textDim)
                    .lineLimit(1).truncationMode(.middle)
                    .padding(.horizontal, session.pending != nil ? 5 : 0)
                    .padding(.vertical, session.pending != nil ? 2 : 0)
                    .background(
                        session.pending != nil ? Theme.orange.opacity(0.14) : .clear,
                        in: RoundedRectangle(cornerRadius: 4)
                    )

                Spacer()

                if session.state == .waiting && store.canDecide(session) {
                    Button("Разрешить") { store.decide(sessionId: session.id, allow: true) }
                        .buttonStyle(AccentButton())
                    Button("Нет") { store.decide(sessionId: session.id, allow: false) }
                        .buttonStyle(PlainBorderButton())
                } else if store.heldStops.contains(session.id) {
                    // Stop держит режим «Я отошёл»: отпустить — сессия закончит ход.
                    Button("Отпустить") { store.releaseStop(sessionId: session.id, continueWith: nil) }
                        .buttonStyle(PlainBorderButton())
                } else if session.state == .waiting {
                    // Ответить можно только в терминале.
                    Button("Открыть терминал") { store.jump(to: session) }
                        .buttonStyle(AccentButton())
                } else if store.showCost, let cost = store.costs.bySession[session.id], cost >= 0.01 {
                    Text("$\(cost, specifier: "%.2f")")
                        .font(Theme.monoSmall).foregroundStyle(Theme.textFaint)
                }
            }
            .padding(.leading, 14)
        }
        .padding(.horizontal, 13)
        .frame(height: Self.height)
        .background(selected ? Theme.raise : .clear, in: RoundedRectangle(cornerRadius: 7))
        .padding(.horizontal, 5)
        .contextMenu {
            Button("Перейти в терминал") { store.jump(to: session) }
            Button("Убрать из списка") { store.forget(session) }
        }
    }

    private var label: String {
        switch session.state {
        case .waiting: return "ждёт \(session.age.short)"
        case .working: return "работает \(session.age.short)"
        case .stalled: return "молчит \(session.age.short)"
        case .done:    return "готово \(session.age.short) назад"
        }
    }
}

// MARK: - Кнопки

struct AccentButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11.5, weight: .semibold))
            .foregroundStyle(Color(red: 0.137, green: 0.09, blue: 0.063))
            .padding(.horizontal, 10).padding(.vertical, 3)
            .background(configuration.isPressed ? Theme.orangeHi : Theme.orange,
                        in: RoundedRectangle(cornerRadius: 5))
    }
}

struct PlainBorderButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11.5, weight: .medium))
            .foregroundStyle(Theme.text)
            .padding(.horizontal, 10).padding(.vertical, 3)
            .background(Color.white.opacity(configuration.isPressed ? 0.16 : 0.08),
                        in: RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Theme.hairline))
    }
}
