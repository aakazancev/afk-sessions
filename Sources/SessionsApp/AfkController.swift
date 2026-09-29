import SwiftUI
import AppKit
import IOKit.pwr_mgt
import SessionsTelegram

/// Режим «Я отошёл»: включение вручную или блокировкой экрана,
/// запрет сна на время режима, предупреждение перед сном.
@MainActor
final class AfkController: ObservableObject {

    @Published private(set) var mode: AfkMode = .off
    // @AppStorage внутри ObservableObject не публикует изменения — храним сами.
    @Published var onLock = UserDefaults.standard.object(forKey: "afkOnLock") as? Bool ?? true {
        didSet { UserDefaults.standard.set(onLock, forKey: "afkOnLock") }
    }
    @Published var preventSleep = UserDefaults.standard.object(forKey: "afkPreventSleep") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(preventSleep, forKey: "afkPreventSleep")
            updateAssertion()
        }
    }

    /// Бот привязан (есть токен и чат) — выставляет мост. Без привязки режим
    /// не действует: не включается, а включённый выключается (с отпусканием stop).
    @Published var linked = false {
        didSet {
            guard linked != oldValue else { return }
            if !linked { send(.manualOff) }
            updateAssertion()
        }
    }

    /// Эффективный режим: включён и бот привязан.
    var isOn: Bool { mode != .off && linked }

    /// (было, стало) — вызывается только при смене режима.
    var onChange: ((AfkMode, AfkMode) -> Void)?
    /// Мак засыпает при включённом режиме — у системы мало времени, best effort.
    var onWillSleep: (() -> Void)?

    private var assertion: IOPMAssertionID?
    /// Контроллер живёт всё время работы приложения — наблюдателей не снимаем.
    private var tokens: [NSObjectProtocol] = []
    private var lockObserver: LockObserver?

    init() {
        lockObserver = LockObserver { [weak self] locked in
            self?.send(locked ? .screenLocked : .screenUnlocked)
        }
        observe(NSWorkspace.shared.notificationCenter, NSWorkspace.willSleepNotification.rawValue) {
            if $0.isOn { $0.onWillSleep?() }
        }
    }

    func send(_ e: AfkEvent) {
        let old = mode
        let new = AfkState.next(old, e, onLock: onLock, linked: linked)
        guard new != old else { return }
        mode = new
        updateAssertion()
        onChange?(old, new)
    }

    // MARK: - Внутреннее

    private func observe(_ center: NotificationCenter, _ name: String,
                         _ action: @escaping @MainActor (AfkController) -> Void) {
        let t = center.addObserver(forName: Notification.Name(name), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                action(self)
            }
        }
        tokens.append(t)
    }

    /// Режим включён и настройка вкл. — держим assertion, иначе снимаем.
    private func updateAssertion() {
        let want = isOn && preventSleep
        if want, assertion == nil {
            var id: IOPMAssertionID = 0
            let r = IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                                                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                                "AFK Sessions: режим «Я отошёл»" as CFString, &id)
            if r == kIOReturnSuccess { assertion = id }
        } else if !want, let id = assertion {
            IOPMAssertionRelease(id)
            assertion = nil
        }
    }
}

/// Блокировка/разблокировка экрана. NSApplication приостанавливает доставку распределённых
/// уведомлений, пока приложение не активно (а приложение из строки меню почти всегда не активно),
/// и по умолчанию (coalesce) они копятся до активации. Поэтому — .deliverImmediately,
/// а он есть только у API с селектором.
@MainActor
private final class LockObserver: NSObject {
    private let handler: (Bool) -> Void

    init(_ handler: @escaping (Bool) -> Void) {
        self.handler = handler
        super.init()
        let dnc = DistributedNotificationCenter.default()
        dnc.addObserver(self, selector: #selector(locked),
                        name: Notification.Name("com.apple.screenIsLocked"),
                        object: nil, suspensionBehavior: .deliverImmediately)
        dnc.addObserver(self, selector: #selector(unlocked),
                        name: Notification.Name("com.apple.screenIsUnlocked"),
                        object: nil, suspensionBehavior: .deliverImmediately)
    }

    deinit { DistributedNotificationCenter.default().removeObserver(self) }

    // Доставка — в главном потоке (run loop, где зарегистрировались).
    @objc private func locked(_ n: Notification) { MainActor.assumeIsolated { handler(true) } }
    @objc private func unlocked(_ n: Notification) { MainActor.assumeIsolated { handler(false) } }
}
