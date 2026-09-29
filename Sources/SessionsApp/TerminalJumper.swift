import Foundation
import AppKit

/// Точный переход: iTerm2 и Terminal.app — AppleScript по tty,
/// Warp — deep-link из WARP_FOCUS_URL (Warp ≥ 2026.05.27), иначе только активация.
enum TerminalJumper {

    static func focus(tty: String?, termProgram: String?, focusURL: String?,
                      cwd: String, override: String) {
        let target = (override == "auto") ? (termProgram ?? "") : override

        switch target {
        case "iTerm.app", "iterm":
            if let tty, runAppleScript(iTermScript(tty: tty)) { return }
            activate(bundleId: "com.googlecode.iterm2")

        case "Apple_Terminal", "terminal":
            if let tty, runAppleScript(terminalScript(tty: tty)) { return }
            activate(bundleId: "com.apple.Terminal")

        case "WarpTerminal", "warp":
            // Warp сам кладёт в окружение сессии ссылку на её панель.
            // Схему не собираем: у preview/oss-сборок она другая.
            if let focusURL, let url = URL(string: focusURL),
               NSWorkspace.shared.open(url) { return }
            activate(bundleId: "dev.warp.Warp-Stable")

        case "vscode", "code":
            activate(bundleId: "com.microsoft.VSCode")

        case "cursor":
            activate(bundleId: "com.todesktop.230313mzl4w4u92")

        default:
            // Неизвестный терминал: пробуем оба скрипта, дальше — ничего.
            if let tty, runAppleScript(iTermScript(tty: tty)) { return }
            if let tty, runAppleScript(terminalScript(tty: tty)) { return }
        }
    }

    // MARK: - Скрипты

    private static func iTermScript(tty: String) -> String {
        """
        tell application "iTerm2"
          activate
          repeat with w in windows
            tell w
              repeat with t in tabs
                repeat with s in sessions of t
                  if tty of s is "\(tty)" then
                    select w
                    tell t to select
                    tell s to select
                    return "ok"
                  end if
                end repeat
              end repeat
            end tell
          end repeat
        end tell
        return "miss"
        """
    }

    private static func terminalScript(tty: String) -> String {
        """
        tell application "Terminal"
          activate
          repeat with w in windows
            repeat with t in tabs of w
              if tty of t is "\(tty)" then
                set frontmost of w to true
                set selected of t to true
                return "ok"
              end if
            end repeat
          end repeat
        end tell
        return "miss"
        """
    }

    @discardableResult
    private static func runAppleScript(_ source: String) -> Bool {
        var error: NSDictionary?
        guard let script = NSAppleScript(source: source) else { return false }
        let result = script.executeAndReturnError(&error)
        if error != nil { return false }
        return result.stringValue == "ok"
    }

    private static func activate(bundleId: String) {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) else { return }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: config)
    }
}
