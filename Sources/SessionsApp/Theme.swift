import SwiftUI

enum Theme {
    static let orange     = Color(red: 0.851, green: 0.467, blue: 0.341) // D97757
    static let orangeHi   = Color(red: 0.902, green: 0.545, blue: 0.420)
    static let green      = Color(red: 0.561, green: 0.659, blue: 0.420)
    static let red        = Color(red: 0.788, green: 0.376, blue: 0.353)

    static let text       = Color(red: 0.949, green: 0.925, blue: 0.894) // F2ECE4
    static let textDim    = Color(red: 0.655, green: 0.612, blue: 0.565) // A79C90
    static let textFaint  = Color(red: 0.435, green: 0.404, blue: 0.373) // 6F675F

    static let panel      = Color(red: 0.118, green: 0.102, blue: 0.086) // 1E1A16
    static let hairline   = Color.white.opacity(0.09)
    static let raise      = Color.white.opacity(0.045)

    static let mono       = Font.system(size: 12.5, weight: .semibold, design: .monospaced)
    static let monoSmall  = Font.system(size: 10.5, design: .monospaced)
    static let ui         = Font.system(size: 12.5)
    static let uiSmall    = Font.system(size: 11)

    static func dot(_ state: SessionState) -> Color {
        switch state {
        case .waiting: return orange
        case .stalled: return red
        case .working: return textFaint
        case .done:    return green
        }
    }
}

extension TimeInterval {
    /// «4 мин», «2 ч 10 мин», «12 с»
    var short: String {
        let s = Int(self)
        if s < 60 { return "\(s) с" }
        let m = s / 60
        if m < 60 { return "\(m) мин" }
        return "\(m / 60) ч \(m % 60) мин"
    }
}
