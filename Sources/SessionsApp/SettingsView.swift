import SwiftUI
import ServiceManagement

struct SettingsView: View, SettingsSection {
    /// Включить обратно вкладку «Инвентарь» (28.09.2026 скрыта как пока ненужная).
    static let showInventory = false

    @EnvironmentObject var store: SessionStore
    @EnvironmentObject var updates: UpdateChecker
    @State private var tab = "general"

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider().overlay(Theme.hairline)
            Group {
                switch tab {
                case "notify":  notifications
                case "term":    terminal
                case "hooks":   hooks
                case "projects": projects
                case "inventory": InventoryView()
                case "telegram": TelegramSettingsView()
                default:        general
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(20)
        }
        .frame(width: 660, height: 430)
        .background(Theme.panel)
        .toggleStyle(.switch)
        .tint(Theme.orange)
    }

    // MARK: - Боковое меню

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 1) {
            item("general", "›", "Основное")
            item("notify",  "!", "Уведомления")
            item("term",    "⌘", "Терминал")
            item("hooks",   "∑", "Подключение")
            item("projects", "/", "Проекты")
            // Инвентарь MCP/плагинов пока заглушен: код и тесты остаются, вкладка скрыта.
            if Self.showInventory { item("inventory", "#", "Инвентарь") }
            item("telegram", "✈", "Telegram")
            Spacer()
        }
        .padding(8)
        .frame(width: 172)
        .background(Color.black.opacity(0.16))
    }

    private func item(_ id: String, _ glyph: String, _ title: String) -> some View {
        HStack(spacing: 8) {
            Text(glyph).font(Theme.monoSmall).foregroundStyle(Theme.orange).frame(width: 14)
            Text(title).font(Theme.ui)
            Spacer()
        }
        .padding(.horizontal, 9).padding(.vertical, 6)
        .background(tab == id ? Theme.orange.opacity(0.14) : .clear,
                    in: RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .onTapGesture { tab = id }
    }

    // MARK: - Разделы

    private var general: some View {
        VStack(alignment: .leading, spacing: 0) {
            title("Основное", "Как приложение ведёт себя в системе.")

            row("Запускать при входе в систему",
                "Иначе придётся открывать вручную после перезагрузки") {
                Toggle("", isOn: Binding(
                    get: { SMAppService.mainApp.status == .enabled },
                    set: { on in
                        try? on ? SMAppService.mainApp.register()
                                : SMAppService.mainApp.unregister()
                    })).labelsHidden()
            }

            row("Показывать стоимость",
                "Сумма за сессию и итог за день в подвале списка") {
                Toggle("", isOn: $store.showCost).labelsHidden()
            }

            row("Скрывать завершённые",
                "Убирать из списка через 30 минут после завершения") {
                Toggle("", isOn: $store.hideFinished).labelsHidden()
            }

            if let r = updates.available {
                row("Доступна версия \(r.version)", "Новая версия на GitHub") {
                    Button("Скачать") { NSWorkspace.shared.open(r.url) }
                }
            }

            if let url = Feedback.url {
                row("Отзыв разработчику", "Issue на GitHub") {
                    Button("Открыть") { NSWorkspace.shared.open(url) }
                }
            }

            note("События приходят от хуков локально, через сокет на 127.0.0.1. Наружу приложение ходит только в Telegram (если вы подключили бота) и раз в сутки на GitHub — проверить новую версию.")
            Spacer()
        }
    }

    private var notifications: some View {
        VStack(alignment: .leading, spacing: 0) {
            title("Уведомления", "Два события стоят того, чтобы отвлекать. Остальное — шум.")

            row("Агент ждёт разрешения",
                "Главное уведомление. Кнопки «Разрешить» и «Отклонить» прямо в баннере") {
                Toggle("", isOn: $store.notifyWaiting).labelsHidden()
            }
            row("Работа завершена", "Одно уведомление в конце сессии") {
                Toggle("", isOn: $store.notifyDone).labelsHidden()
            }
            row("Сессия зависла", "Нет событий дольше выбранного времени") {
                HStack(spacing: 10) {
                    Picker("", selection: $store.stallMinutes) {
                        Text("3 мин").tag(3); Text("5 мин").tag(5); Text("10 мин").tag(10)
                    }.labelsHidden().frame(width: 92)
                    Toggle("", isOn: $store.notifyStalled).labelsHidden()
                }
            }

            note("Хоткеи: ⌥Space — открыть панель, ⌥⇧A — разрешить верхнюю ждущую сессию. "
               + "В панели: ↑ ↓ — выбор, ⏎ — разрешить, ⌫ — отклонить.")
            Spacer()
        }
    }

    private var terminal: some View {
        VStack(alignment: .leading, spacing: 0) {
            title("Терминал", "Куда переключаться по клику на сессию.")

            row("Приложение", "По умолчанию определяется по каждой сессии") {
                Picker("", selection: $store.terminalChoice) {
                    Text("Авто").tag("auto")
                    Text("iTerm2").tag("iterm")
                    Text("Terminal").tag("terminal")
                    Text("Warp").tag("warp")
                    Text("VS Code").tag("vscode")
                    Text("Cursor").tag("cursor")
                }.labelsHidden().frame(width: 140)
            }

            note("Точный переход в нужную вкладку работает в iTerm2, Terminal.app и Warp "
               + "(с версии 2026.05.27). VS Code и Cursor просто выводятся вперёд. "
               + "В tmux и по ssh перехода нет вовсе.")
            Spacer()
        }
    }

    private var hooks: some View {
        VStack(alignment: .leading, spacing: 0) {
            title("Подключение", "Чтобы видеть сессии, нужны хуки в настройках Claude Code.")

            let ok = store.hooksInstalled && !store.hooksMoved
            HStack(spacing: 8) {
                Text(ok ? "✓" : "!")
                    .font(Theme.mono)
                    .foregroundStyle(ok ? Theme.green : Theme.orange)
                Text(store.hooksMoved ? "Хуки нужно обновить"
                     : store.hooksInstalled ? "Хуки установлены" : "Хуки не установлены")
                    .font(Theme.ui)
                Spacer()
                if ok {
                    Button("Удалить") {
                        HookInstaller.uninstall()
                        store.refreshHooksState()
                    }
                } else {
                    Button(store.hooksMoved ? "Починить" : "Установить") {
                        HookInstaller.install()
                        store.refreshHooksState()
                    }.buttonStyle(.borderedProminent).tint(Theme.orange)
                }
            }
            .padding(10)
            .background((ok ? Theme.green : Theme.orange).opacity(0.12),
                        in: RoundedRectangle(cornerRadius: 8))
            .padding(.bottom, 12)

            Text("~/.claude/settings.json").font(Theme.monoSmall).foregroundStyle(Theme.textFaint)
                .padding(.bottom, 5)

            ScrollView {
                Text(HookInstaller.previewJSON())
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(Theme.textDim)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(11)
            }
            .frame(height: 152)
            .background(Color.black.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.hairline))

            note("Ваши остальные настройки не трогаются. Перед каждой записью рядом кладётся "
               + "settings.json.sessions-backup — копия последнего состояния до правки "
               + "(хуков или инвентаря). Если приложение выключено, хуки "
               + "молча ничего не делают и Claude Code спрашивает как обычно.")
            Spacer()
        }
    }

    private var projects: some View {
        VStack(alignment: .leading, spacing: 0) {
            title("Проекты", "Деньги по проектам за день и неделю. Считается из транскриптов в ~/.claude.")

            let items = store.costs.byProject.sorted { $0.value.week > $1.value.week }
            if items.isEmpty {
                Text("Пока нет данных за последнюю неделю.")
                    .font(Theme.ui).foregroundStyle(Theme.textDim)
            } else {
                HStack {
                    Text("Проект").frame(maxWidth: .infinity, alignment: .leading)
                    Text("Сегодня").frame(width: 90, alignment: .trailing)
                    Text("Неделя").frame(width: 90, alignment: .trailing)
                }
                .font(Theme.uiSmall).foregroundStyle(Theme.textFaint)
                .padding(.bottom, 4)

                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(items, id: \.key) { name, cost in
                            Divider().overlay(Theme.hairline)
                            HStack {
                                Text(name).font(Theme.mono).foregroundStyle(Theme.text)
                                    .lineLimit(1).truncationMode(.middle)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                Text(cost.today >= 0.01 ? String(format: "$%.2f", cost.today) : "—")
                                    .frame(width: 90, alignment: .trailing)
                                    .foregroundStyle(Theme.textDim)
                                Text(String(format: "$%.2f", cost.week))
                                    .frame(width: 90, alignment: .trailing)
                                    .foregroundStyle(Theme.text)
                            }
                            .font(Theme.monoSmall)
                            .padding(.vertical, 7)
                        }
                    }
                }
            }
            Spacer()
        }
    }
}

// MARK: - Мелочи

/// Общие куски разделов настроек: заголовок, строка с контролом, примечание.
protocol SettingsSection {}

extension SettingsSection {

    func title(_ t: String, _ lede: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(t).font(.system(size: 13, weight: .semibold))
            Text(lede).font(Theme.uiSmall).foregroundStyle(Theme.textFaint)
        }.padding(.bottom, 14)
    }

    func row<C: View>(_ name: String, _ hint: String,
                              @ViewBuilder control: () -> C) -> some View {
        VStack(spacing: 0) {
            Divider().overlay(Theme.hairline)
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(name).font(Theme.ui)
                    Text(hint).font(Theme.uiSmall).foregroundStyle(Theme.textFaint)
                }
                Spacer()
                control()
            }.padding(.vertical, 10)
        }
    }

    func note(_ text: String) -> some View {
        VStack(spacing: 0) {
            Divider().overlay(Theme.hairline).padding(.top, 4)
            Text(text)
                .font(Theme.uiSmall).foregroundStyle(Theme.textFaint)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 12)
        }
    }
}
