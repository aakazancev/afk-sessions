import Foundation

public enum AfkMode: String, Sendable {
    case off      // вы за компьютером
    case manual   // включён вручную — держится до /afk_back или переключателя
    case lock     // включён блокировкой экрана — выключится при разблокировке
}

public enum AfkEvent: Sendable { case manualOn, manualOff, screenLocked, screenUnlocked }

public enum AfkState {
    /// linked — бот привязан (есть токен и чат). Без привязки режим не действует:
    /// не включается ничем, а включённый выключается любым событием.
    public static func next(_ m: AfkMode, _ e: AfkEvent, onLock: Bool, linked: Bool) -> AfkMode {
        guard linked else { return .off }
        switch e {
        case .manualOn:       return .manual
        case .manualOff:      return .off
        case .screenLocked:   return m == .off ? (onLock ? .lock : .off) : m
        case .screenUnlocked: return m == .lock ? .off : m
        }
    }
}
