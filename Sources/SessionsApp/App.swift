import SwiftUI
import AppKit
import UserNotifications
import ServiceManagement

@main
struct SessionsApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate

    var body: some Scene {
        MenuBarExtra {
            MenuBarView().environmentObject(delegate.store)
                .environmentObject(delegate.afk)
                .environmentObject(delegate.telegram)
                .environmentObject(delegate.updates)
        } label: {
            MenuBarLabel(store: delegate.store)
        }
        .menuBarExtraStyle(.window)

        Window("Настройки", id: "settings") {
            SettingsView().environmentObject(delegate.store)
                .environmentObject(delegate.inventory)
                .environmentObject(delegate.afk)
                .environmentObject(delegate.telegram)
                .environmentObject(delegate.updates)
        }
        .windowResizability(.contentSize)
    }

}

/// Лейбл в строке меню. Отдельный view с @ObservedObject — иначе SwiftUI
/// не перерисовывает иконку при изменениях в store.
struct MenuBarLabel: View {
    @ObservedObject var store: SessionStore

    var body: some View {
        Image(nsImage: Self.render(
            attention: store.waitingCount + store.stalledCount,
            working: store.sessions.filter { $0.state == .working }.count,
            stalled: store.stalledCount > 0
        ))
    }

    // Как в макете (.status-item): глиф ›_ + число в пилюле.
    // Ждут/молчат — цветная пилюля со счётчиком внимания; всё работает —
    // монохромный template со счётчиком активных; пусто — просто ›_.
    // Рисуем одной картинкой: фон-пилюлю в лейбле MenuBarExtra иначе не задать.
    private static var cache: [String: NSImage] = [:]

    private static func render(attention: Int, working: Int, stalled: Bool) -> NSImage {
        let key = "\(attention)-\(working)-\(stalled)"
        if let cached = cache[key] { return cached }

        let pill = attention > 0
        let color: NSColor = !pill ? .black
            : stalled ? NSColor(red: 0.788, green: 0.376, blue: 0.353, alpha: 1)   // C9605A
                      : NSColor(red: 0.851, green: 0.467, blue: 0.341, alpha: 1)   // D97757
        let count = pill ? attention : working

        let font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let text = count > 0 ? NSAttributedString(string: "\(count)", attributes: attrs) : nil
        let textWidth = text.map { ceil($0.size().width) } ?? 0

        let glyphWidth: CGFloat = 12
        let pad: CGFloat = pill ? 6 : 2
        let gap: CGFloat = text == nil ? 0 : 4
        let width = pad + glyphWidth + gap + textWidth + pad
        let height: CGFloat = 16

        let image = NSImage(size: NSSize(width: width, height: height), flipped: false) { _ in
            if pill {
                color.withAlphaComponent(0.2).setFill()
                NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: width, height: height),
                             xRadius: 5, yRadius: 5).fill()
            }
            // ›
            let caret = NSBezierPath()
            caret.lineWidth = 1.9
            caret.lineCapStyle = .round
            caret.lineJoinStyle = .round
            caret.move(to: NSPoint(x: pad + 0.5, y: 4.5))
            caret.line(to: NSPoint(x: pad + 4, y: 8))
            caret.line(to: NSPoint(x: pad + 0.5, y: 11.5))
            color.setStroke()
            caret.stroke()
            // _
            let underscore = NSBezierPath()
            underscore.lineWidth = 1.9
            underscore.lineCapStyle = .round
            underscore.move(to: NSPoint(x: pad + 7, y: 4))
            underscore.line(to: NSPoint(x: pad + glyphWidth, y: 4))
            underscore.stroke()

            text?.draw(at: NSPoint(x: pad + glyphWidth + gap,
                                   y: (height - ceil(font.ascender - font.descender)) / 2))
            return true
        }
        image.isTemplate = !pill
        cache[key] = image
        return image
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {

    let store = SessionStore()
    let inventory = InventoryStore()
    let afk = AfkController()
    let updates = UpdateChecker()
    lazy var telegram = TelegramBridge(store: store, afk: afk)
    private var server: EventServer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Приложение живёт только в строке меню, в Dock его нет.
        NSApp.setActivationPolicy(.accessory)

        // Режим «Я отошёл» и мост — до сервера, чтобы первые события уже видели режим.
        store.afkActive = { [weak afk] in afk?.isOn ?? false }
        store.observer = telegram
        telegram.start()

        server = EventServer(store: store)
        server?.start()
        updates.start()

        Notifier.bootstrap(handler: self)

        Hotkeys.shared.install(
            openPanel: { Self.openMenuBarPanel() },
            approveTop: { [weak self] in self?.store.approveTop() }
        )

        promptAutostartOnce()
    }

    /// Один раз предложить автозапуск: без него после перезагрузки панели
    /// нет, а хуки молчат — выглядит как «сломалось».
    private func promptAutostartOnce() {
        let key = "askedAutostart"
        guard !UserDefaults.standard.bool(forKey: key),
              SMAppService.mainApp.status != .enabled else { return }
        UserDefaults.standard.set(true, forKey: key)

        let alert = NSAlert()
        alert.messageText = "Запускать при входе в систему?"
        alert.informativeText = "Иначе после перезагрузки панель придётся открывать вручную. Можно поменять в настройках."
        alert.addButton(withTitle: "Запускать")
        alert.addButton(withTitle: "Не сейчас")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            try? SMAppService.mainApp.register()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        Hotkeys.shared.removeAll()
        // До остановки сервера: ждущим CLI — ответ, а не обрыв.
        store.releaseAllStops()
        store.askAllGates()
        server?.stop()
    }

    /// ⌥Space: раскрыть панель в строке меню.
    private static func openMenuBarPanel() {
        NSApp.activate(ignoringOtherApps: true)
        for window in NSApp.windows where window.className.contains("MenuBarExtra") {
            window.makeKeyAndOrderFront(nil)
            return
        }
        // Запасной путь: клик по элементу строки меню.
        NSApp.sendAction(Selector(("toggleMenuBarExtra:")), to: nil, from: nil)
    }

    // MARK: - Кнопки в уведомлениях

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        guard let sessionId = info["sessionId"] as? String else { return }

        switch response.actionIdentifier {
        case Notifier.approve:
            store.decide(sessionId: sessionId, allow: true)
        case Notifier.deny:
            store.decide(sessionId: sessionId, allow: false)
        default:
            if let s = store.sessions.first(where: { $0.id == sessionId }) {
                store.jump(to: s)
            }
        }
    }

    /// Показывать баннер, даже когда приложение активно.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification) async
        -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}
