import Foundation
import SessionsCore

// sessions-cli <start|tool|prompt|notify|gate|subagent-start|subagent-stop|stop|end>
//
// Читает JSON хука со stdin, отправляет приложению, для gate и stop ждёт
// решения и печатает ответ для Claude Code (см. HookOutput).
//
// Железное правило: что бы ни случилось — выходим с кодом 0 и пустым stdout.
// Тогда при выключенном приложении Claude Code просто спрашивает как обычно.

let args = CommandLine.arguments
// Аргументы совпадают с rawValue, кроме сабагентов (в хуках — через дефис).
let aliases: [String: EventKind] = ["subagent-start": .subagentStart, "subagent-stop": .subagentStop]
guard args.count > 1, let kind = aliases[args[1]] ?? EventKind(rawValue: args[1]) else { exit(0) }

let stdinData = FileHandle.standardInput.readDataToEndOfFile()
let hook = (try? JSONSerialization.jsonObject(with: stdinData)) as? [String: Any] ?? [:]

func str(_ key: String) -> String? { hook[key] as? String }

let sessionId = str("session_id") ?? "unknown"
let cwd = str("cwd") ?? FileManager.default.currentDirectoryPath
let toolName = str("tool_name")
let toolInput = hook["tool_input"] as? [String: Any]
let permissionMode = str("permission_mode") ?? "default"

// MARK: - Человекочитаемое описание действия

func summarize() -> String? {
    switch kind {
    case .notify:
        return str("message")
    case .gate, .tool:
        guard let tool = toolName else { return nil }
        switch tool {
        case "Bash":
            return toolInput?["command"] as? String
        case "Read", "Edit", "Write", "NotebookEdit":
            if let p = toolInput?["file_path"] as? String {
                return (p as NSString).abbreviatingWithTildeInPath
            }
            return tool
        case "WebFetch":
            return toolInput?["url"] as? String
        default:
            return tool
        }
    default:
        return nil
    }
}

// MARK: - Откуда запущена сессия

/// TTY процесса claude (наш родитель), чтобы потом сфокусировать нужную вкладку.
func parentTTY() -> String? {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/ps")
    p.arguments = ["-o", "tty=", "-p", String(getppid())]
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = FileHandle.nullDevice
    try? p.run()
    p.waitUntilExit()
    let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    guard !out.isEmpty, out != "??" else { return nil }
    return out.hasPrefix("/dev/") ? out : "/dev/\(out)"
}

let env = ProcessInfo.processInfo.environment
let requestId = UUID().uuidString

// В авто-режимах решает сам Claude Code (в auto — классификатор): молча выходим,
// активность всё равно придёт с PostToolUse.
let autoModes: Set<String> = ["bypassPermissions", "auto", "dontAsk", "plan"]
let editTools: Set<String> = ["Edit", "Write", "NotebookEdit", "MultiEdit"]
if kind == .gate && (
    autoModes.contains(permissionMode) ||
    (permissionMode == "acceptEdits" && editTools.contains(toolName ?? ""))
) { exit(0) }

let event = HookEvent(
    token: Bridge.readEndpoint()?.token ?? "",
    kind: kind,
    sessionId: sessionId,
    cwd: cwd,
    transcriptPath: str("transcript_path"),
    toolName: toolName,
    summary: summarize(),
    tty: parentTTY(),
    termProgram: env["TERM_PROGRAM"],
    requestId: (kind == .gate || kind == .stop) ? requestId : nil,
    notificationType: kind == .notify ? str("notification_type") : nil,
    agentId: kind == .subagentStart || kind == .subagentStop ? str("agent_id") : nil,
    focusURL: env["WARP_FOCUS_URL"],
    lastMessage: kind == .stop ? str("last_assistant_message") : nil,
    screenshotPath: kind == .tool && ScreenshotPath.isScreenshotTool(toolName)
        ? ScreenshotPath.extract(toolResponse: hook["tool_response"], cwd: cwd) : nil
)

// MARK: - Отправка

guard kind == .gate || kind == .stop else {
    _ = BridgeClient.send(event, awaitReply: false, timeout: 2)
    exit(0)
}

// Ждём приложение. Таймаут хука в settings.json — 14400 с; берём меньше,
// чтобы вернуть управление первыми. Вне режима «Я отошёл» приложение
// отвечает на stop сразу, а на gate — через 300 с ответом ask.
let decision = BridgeClient.send(event, awaitReply: true, timeout: 14_000)
let output = kind == .gate ? HookOutput.permission(decision) : HookOutput.stop(decision)
if let output { print(output) }
exit(0)
