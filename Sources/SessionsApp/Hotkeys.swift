import Foundation
import AppKit
import Carbon.HIToolbox
import UserNotifications

// MARK: - Глобальные хоткеи
//
// RegisterEventHotKey не требует разрешения на Универсальный доступ,
// в отличие от CGEventTap. Для двух наших сочетаний этого достаточно.

final class Hotkeys {

    static let shared = Hotkeys()

    private var refs: [EventHotKeyRef?] = []
    private var actions: [UInt32: () -> Void] = [:]
    private var handler: EventHandlerRef?

    /// ⌥Space — открыть панель, ⌥⇧A — разрешить верхнюю ждущую.
    func install(openPanel: @escaping () -> Void, approveTop: @escaping () -> Void) {
        actions[1] = openPanel
        actions[2] = approveTop

        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))

        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var hkID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject),
                              EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &hkID)
            DispatchQueue.main.async {
                Hotkeys.shared.actions[hkID.id]?()
            }
            return noErr
        }, 1, &spec, nil, &handler)

        register(id: 1, keyCode: UInt32(kVK_Space), modifiers: UInt32(optionKey))
        register(id: 2, keyCode: UInt32(kVK_ANSI_A), modifiers: UInt32(optionKey | shiftKey))
    }

    private func register(id: UInt32, keyCode: UInt32, modifiers: UInt32) {
        var ref: EventHotKeyRef?
        let hkID = EventHotKeyID(signature: OSType(0x53455353), id: id) // 'SESS'
        let status = RegisterEventHotKey(keyCode, modifiers, hkID,
                                         GetApplicationEventTarget(), 0, &ref)
        if status == noErr { refs.append(ref) }
        else { NSLog("Sessions: хоткей \(id) занят другим приложением") }
    }

    func removeAll() {
        refs.forEach { if let r = $0 { UnregisterEventHotKey(r) } }
        refs.removeAll()
    }
}

// MARK: - Уведомления

enum Notifier {

    static let category = "SESSION_WAITING"
    static let approve = "APPROVE"
    static let deny = "DENY"

    static func bootstrap(handler: UNUserNotificationCenterDelegate) {
        let center = UNUserNotificationCenter.current()
        center.delegate = handler
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }

        let cat = UNNotificationCategory(
            identifier: category,
            actions: [
                UNNotificationAction(identifier: approve, title: "Разрешить", options: []),
                UNNotificationAction(identifier: deny, title: "Отклонить", options: [])
            ],
            intentIdentifiers: []
        )
        center.setNotificationCategories([cat])
    }

    /// actionable — есть живой gate-запрос: тогда кнопки «Разрешить/Отклонить».
    /// Иначе уведомление без кнопок, клик ведёт в терминал.
    static func waiting(project: String, text: String, sessionId: String, actionable: Bool) {
        post(id: "wait-\(sessionId)",
             title: actionable ? "\(project) ждёт разрешения" : "\(project) ждёт вас",
             body: text,
             category: actionable ? category : nil,
             userInfo: ["sessionId": sessionId])
    }

    static func done(project: String, sessionId: String) {
        post(id: "done-\(sessionId)", title: "\(project) — готово", body: "Сессия завершена",
             userInfo: ["sessionId": sessionId])
    }

    static func stalled(project: String, minutes: Int, sessionId: String) {
        post(id: "stall-\(sessionId)", title: "\(project) молчит",
             body: "Нет событий \(minutes) мин",
             userInfo: ["sessionId": sessionId])
    }

    static func hud(_ text: String) {
        post(id: "hud-\(UUID().uuidString)", title: text, body: "")
    }

    static func dismiss(sessionId: String) {
        UNUserNotificationCenter.current()
            .removeDeliveredNotifications(withIdentifiers: ["wait-\(sessionId)"])
    }

    private static func post(id: String, title: String, body: String,
                             category: String? = nil, userInfo: [String: Any] = [:]) {
        let content = UNMutableNotificationContent()
        content.title = title
        if !body.isEmpty { content.body = body }
        if let category { content.categoryIdentifier = category }
        content.userInfo = userInfo
        let req = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req)
    }
}
