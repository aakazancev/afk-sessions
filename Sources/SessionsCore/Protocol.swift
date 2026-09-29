import Foundation
#if canImport(Darwin)
import Darwin
#endif

// MARK: - Модель события

public enum EventKind: String, Codable, Sendable {
    case start      // SessionStart — сессия началась
    case tool       // PostToolUse — агент что-то сделал
    case prompt     // UserPromptSubmit — человек написал в терминале
    case notify     // Notification — см. notificationType
    case gate       // PermissionRequest — агент просит разрешение, ждём ответа
    case subagentStart  // SubagentStart — запущен сабагент (agentId)
    case subagentStop   // SubagentStop — сабагент закончил (agentId)
    case stop       // Stop — основной агент закончил ход
    case end        // SessionEnd — сессия закрыта
}

public struct HookEvent: Codable, Sendable {
    public var token: String
    public var kind: EventKind
    public var sessionId: String
    public var cwd: String
    public var transcriptPath: String?
    public var toolName: String?
    public var summary: String?      // человекочитаемое «что происходит»
    public var tty: String?          // /dev/ttys004 — для перехода в терминал
    public var termProgram: String?  // iTerm.app / Apple_Terminal / WarpTerminal / vscode
    public var requestId: String?    // для gate и stop
    public var notificationType: String?  // только для notify: permission_prompt / idle_prompt / …
    public var agentId: String?      // только для subagentStart / subagentStop
    public var focusURL: String?     // WARP_FOCUS_URL — deep-link на панель Warp
    public var lastMessage: String?   // только для stop: финальный ответ сессии
    public var screenshotPath: String?   // только для tool: файл скриншота Playwright

    public init(token: String, kind: EventKind, sessionId: String, cwd: String,
                transcriptPath: String? = nil, toolName: String? = nil,
                summary: String? = nil, tty: String? = nil,
                termProgram: String? = nil, requestId: String? = nil,
                notificationType: String? = nil, agentId: String? = nil,
                focusURL: String? = nil, lastMessage: String? = nil,
                screenshotPath: String? = nil) {
        self.token = token; self.kind = kind; self.sessionId = sessionId; self.cwd = cwd
        self.transcriptPath = transcriptPath; self.toolName = toolName; self.summary = summary
        self.tty = tty; self.termProgram = termProgram; self.requestId = requestId
        self.notificationType = notificationType; self.agentId = agentId
        self.focusURL = focusURL; self.lastMessage = lastMessage
        self.screenshotPath = screenshotPath
    }
}

/// Ответ приложения на gate-запрос.
public struct GateDecision: Codable, Sendable {
    public var decision: String   // allow | deny | ask (gate); continue | stop (stop)
    public var reason: String?
    public init(decision: String, reason: String? = nil) {
        self.decision = decision; self.reason = reason
    }
}

// MARK: - Где лежит точка входа

public enum Bridge {

    public static var supportDir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Sessions", isDirectory: true)
    }

    /// Файл вида "PORT TOKEN". Права 0600 — чтобы токен не читал кто попало.
    public static var endpointFile: URL { supportDir.appendingPathComponent("endpoint") }

    public static func writeEndpoint(port: UInt16, token: String) {
        try? FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true)
        let line = "\(port) \(token)\n"
        try? line.write(to: endpointFile, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                               ofItemAtPath: endpointFile.path)
    }

    public static func readEndpoint() -> (port: UInt16, token: String)? {
        guard let raw = try? String(contentsOf: endpointFile, encoding: .utf8) else { return nil }
        let parts = raw.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ")
        guard parts.count == 2, let p = UInt16(parts[0]) else { return nil }
        return (p, String(parts[1]))
    }

    public static func clearEndpoint() {
        try? FileManager.default.removeItem(at: endpointFile)
    }
}

// MARK: - Клиент (используется только CLI)

public enum BridgeClient {

    /// Отправляет событие. Если ждём ответа — блокируется до decision или таймаута.
    /// Возвращает nil, если приложение не запущено — тогда Claude Code ведёт себя как обычно.
    public static func send(_ event: HookEvent, awaitReply: Bool, timeout: TimeInterval) -> GateDecision? {
        guard let ep = Bridge.readEndpoint() else { return nil }
        guard let fd = connect(port: ep.port, timeout: 2) else { return nil }
        defer { close(fd) }

        guard var payload = try? JSONEncoder().encode(event) else { return nil }
        payload.append(0x0A) // \n — разделитель сообщений

        let written = payload.withUnsafeBytes { buf -> Int in
            guard let base = buf.baseAddress else { return -1 }
            return write(fd, base, buf.count)
        }
        guard written == payload.count else { return nil }

        guard awaitReply else { return nil }
        setReadTimeout(fd, seconds: timeout)
        guard let line = readLine(fd) else { return nil }
        return try? JSONDecoder().decode(GateDecision.self, from: line)
    }

    // MARK: сокеты

    private static func connect(port: UInt16, timeout: TimeInterval) -> Int32? {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")

        setReadTimeout(fd, seconds: timeout)

        let ok = withUnsafePointer(to: &addr) { raw -> Int32 in
            raw.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.connect(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if ok != 0 { close(fd); return nil }
        return fd
    }

    private static func setReadTimeout(_ fd: Int32, seconds: TimeInterval) {
        var tv = timeval(tv_sec: Int(seconds), tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    }

    private static func readLine(_ fd: Int32) -> Data? {
        var out = Data()
        var byte: UInt8 = 0
        while true {
            let n = read(fd, &byte, 1)
            if n <= 0 { return out.isEmpty ? nil : out }
            if byte == 0x0A { return out }
            out.append(byte)
            if out.count > 1_000_000 { return nil }
        }
    }
}
