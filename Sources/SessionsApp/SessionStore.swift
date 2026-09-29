import Foundation
import SwiftUI
import SessionsCore
import SessionsTelegram

enum SessionState: Int, Comparable {
    case waiting = 0   // ждёт разрешения — наверх
    case stalled = 1   // нет событий дольше порога
    case working = 2
    case done   = 3

    static func < (a: SessionState, b: SessionState) -> Bool { a.rawValue < b.rawValue }
}

struct PendingRequest: Identifiable, Equatable {
    let id: String          // requestId
    let toolName: String
    let summary: String
    let since: Date
}

struct Session: Identifiable, Equatable {
    let id: String          // session_id из хука
    var cwd: String
    var project: String
    var branch: String
    var tty: String?
    var termProgram: String?
    var focusURL: String?

    var state: SessionState = .working
    var activity: String = "Запускается"
    var pending: PendingRequest?
    var lastEvent: Date = .now
    var startedAt: Date = .now
    var finishedAt: Date?
    /// Живые сабагенты (agentId). Не персистится: после рестарта пусто.
    var agents: Set<String> = []

    /// Сколько секунд показывать в строке.
    var age: TimeInterval {
        switch state {
        case .waiting: return Date.now.timeIntervalSince(pending?.since ?? lastEvent)
        case .done:    return Date.now.timeIntervalSince(finishedAt ?? lastEvent)
        default:       return Date.now.timeIntervalSince(startedAt)
        }
    }
}

/// Кому рассказывать о событиях сессий в режиме «Я отошёл» (мост в Telegram).
@MainActor
protocol SessionObserver: AnyObject {
    /// Открыт gate-запрос. decidable — есть живой ответчик (можно дать кнопки);
    /// requestId — в callback_data, чтобы старая кнопка не решила следующий запрос.
    func gateOpened(_ s: Session, requestId: String, summary: String, decidable: Bool)
    /// requestId удерживаемого stop — в callback_data кнопки «Завершить».
    func stopHeld(_ s: Session, requestId: String, lastMessage: String?, shots: [String])
    /// Ход закончился и сразу продолжился текстом из очереди.
    func queueDelivered(_ s: Session, lastMessage: String?, shots: [String])
    func waitingInTerminal(_ s: Session, text: String)
    func stalled(_ s: Session, minutes: Int)
    /// Gate решён или закрыт иначе, stop отпущен — отредактировать сообщение (снять кнопки).
    /// text — готовая строка-итог; «Решено: …» только для настоящих решений.
    func resolved(sessionId: String, text: String)
}

@MainActor
final class SessionStore: ObservableObject {

    @Published private(set) var sessions: [Session] = []
    @Published var hooksInstalled: Bool = HookInstaller.isInstalled()
    @Published var hooksMoved: Bool = HookInstaller.isMoved() || HookInstaller.isOutdated()

    func refreshHooksState() {
        hooksInstalled = HookInstaller.isInstalled()
        hooksMoved = HookInstaller.isMoved() || HookInstaller.isOutdated()
    }
    @Published private(set) var costs = CostSnapshot()

    @AppStorage("showCost")       var showCost       = true
    @AppStorage("notifyWaiting")  var notifyWaiting  = true
    @AppStorage("notifyDone")     var notifyDone     = true
    @AppStorage("notifyStalled")  var notifyStalled  = true
    @AppStorage("stallMinutes")   var stallMinutes   = 5
    @AppStorage("hideFinished")   var hideFinished   = false
    @AppStorage("terminalChoice") var terminalChoice = "auto"

    /// Открытые gate-запросы: requestId → как ответить.
    private var replies: [String: (GateDecision) -> Void] = [:]
    /// Удерживаемые stop: sessionId → requestId соединения и как ответить.
    /// requestId нужен stopGone: закрытие старого соединения не должно
    /// выбросить ответчик следующего stop той же сессии.
    private var stopReplies: [String: (requestId: String, reply: (GateDecision) -> Void)] = [:]
    /// Тексты из Telegram для работающей сессии: отдаются продолжением на её stop.
    /// Только в памяти; сбрасываются на start/prompt/end и при выходе из режима.
    private var queue: [String: [String]] = [:]

    /// Файлы скриншотов Playwright текущего хода (последние 10) — альбомом к «готово».
    private var shots: [String: [String]] = [:]

    /// Снимки хода: отдать и забыть.
    private func takeShots(_ sessionId: String) -> [String] { shots.removeValue(forKey: sessionId) ?? [] }

    /// Включён ли режим «Я отошёл». Подставляет мост; без него — выключен.
    var afkActive: () -> Bool = { false }
    weak var observer: SessionObserver?

    /// Вне режима gate ждёт кнопки в панели столько же, сколько раньше ждал CLI;
    /// потом ask — Claude спросит в терминале.
    private static let gateTimeout: TimeInterval = 300
    /// Сессии без событий дольше суток — мусор (фоновые запуски без
    /// SessionEnd): убираем из списка молча, в любом состоянии.
    private static let zombieAge: TimeInterval = 24 * 3600
    private var ticker: Timer?

    private var lastCostRefresh = Date.distantPast

    init() {
        restore()
        refreshCosts()
        // Режим .common: тик (ask по 300 с, страховки stop) идёт и при открытом меню / модалке.
        let t = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        ticker = t
    }

    // MARK: - Производные значения

    var visible: [Session] {
        sessions
            .filter { s in
                guard hideFinished, s.state == .done else { return true }
                return s.age < 1800
            }
            .sorted { a, b in
                if a.state != b.state { return a.state < b.state }
                return a.age > b.age
            }
    }

    var waitingCount: Int { sessions.filter { $0.state == .waiting }.count }
    var stalledCount: Int { sessions.filter { $0.state == .stalled }.count }

    var topWaiting: Session? { visible.first { $0.state == .waiting } }

    /// Верхняя ждущая, на которую реально можно ответить (⌥⇧A).
    var topDecidable: Session? { visible.first { $0.state == .waiting && canDecide($0) } }

    /// Есть ли у pending живой ответчик (gate-запрос держит соединение).
    /// Без него «Разрешить» ничего не сделает — ответить можно только в терминале.
    func canDecide(_ s: Session) -> Bool {
        guard let p = s.pending else { return false }
        return replies[p.id] != nil
    }

    /// Имя проекта; для worktree с одинаковым именем — с родительским каталогом.
    func displayProject(_ s: Session) -> String {
        let dup = sessions.contains { $0.id != s.id && $0.project == s.project && $0.cwd != s.cwd }
        guard dup else { return s.project }
        let parent = ((s.cwd as NSString).deletingLastPathComponent as NSString).lastPathComponent
        return parent.isEmpty ? s.project : "\(parent)/\(s.project)"
    }

    // MARK: - Приём событий

    func handle(_ e: HookEvent, reply: ((GateDecision) -> Void)?) {
        let idx = sessions.firstIndex { $0.id == e.sessionId }

        if idx == nil {
            var s = Session(id: e.sessionId,
                            cwd: e.cwd,
                            project: (e.cwd as NSString).lastPathComponent,
                            branch: Git.branch(at: e.cwd),
                            tty: e.tty,
                            termProgram: e.termProgram)
            s.activity = "Запускается"
            // Git.branch ждёт процесс и крутит run loop: за это время другое событие
            // той же сессии могло её уже создать.
            if !sessions.contains(where: { $0.id == e.sessionId }) { sessions.append(s) }
        }

        guard let i = sessions.firstIndex(where: { $0.id == e.sessionId }) else { return }
        sessions[i].lastEvent = .now
        if let tty = e.tty { sessions[i].tty = tty }
        if let tp = e.termProgram { sessions[i].termProgram = tp }
        if let url = e.focusURL { sessions[i].focusURL = url }

        // Ход сменился или сессия закрылась — удерживаемый stop больше не нужен.
        if [.start, .prompt, .end].contains(e.kind) {
            releaseStop(sessionId: e.sessionId, continueWith: nil)
            // Человек сам написал в терминале / сессия закрыта — очередь неактуальна.
            queue[e.sessionId] = nil
            shots[e.sessionId] = nil
        }

        switch e.kind {
        case .start:
            clearPending(i, force: true)
            if idx != nil { refreshBranch(e.sessionId) }
            sessions[i].startedAt = .now
            sessions[i].finishedAt = nil
            sessions[i].activity = "Работает"

        case .prompt:
            // Человек написал в терминале — любой висящий вопрос уже неактуален.
            clearPending(i, force: true)
            if idx != nil { refreshBranch(e.sessionId) }
            sessions[i].finishedAt = nil
            sessions[i].activity = "Работает"

        case .tool:
            clearPending(i, force: false)
            sessions[i].activity = Self.activityText(tool: e.toolName, summary: e.summary)
            if let p = e.screenshotPath {
                var a = shots[e.sessionId] ?? []
                a.removeAll { $0 == p }   // тот же файл перезаписан — берём один раз, последним
                a.append(p)
                shots[e.sessionId] = Array(a.suffix(10))
            }

        case .subagentStart:
            clearPending(i, force: false)
            if let a = e.agentId { sessions[i].agents.insert(a) }
            sessions[i].finishedAt = nil

        case .subagentStop:
            // Только агенты, чей старт мы видели. Claude Code шлёт одинокий
            // SubagentStop и после конца хода (recap «пока вас не было») —
            // он не должен оживлять законченную сессию.
            guard let a = e.agentId, sessions[i].agents.remove(a) != nil else { persist(); return }
            clearPending(i, force: false)
            // done не объявляем: если основной агент уже остановился,
            // Claude его перезапустит и придёт новый stop.
            let n = sessions[i].agents.count
            sessions[i].activity = n > 0 ? "Ждёт агентов: \(n)" : "Работает"

        case .notify:
            let text: String
            switch e.notificationType {
            case "permission_prompt":
                // Уже висит gate-запрос с ответчиком — не затираем его requestId.
                if canDecide(sessions[i]) { persist(); return }
                text = e.summary ?? "Нужно ваше решение"
            case "elicitation_dialog", "agent_needs_input":
                text = e.summary ?? "Ждёт ответа"
            default:
                // idle_prompt («жду ввода»), auth_success и прочее — состояние не трогаем.
                persist()
                return
            }
            sessions[i].state = .waiting
            sessions[i].pending = PendingRequest(id: UUID().uuidString,
                                                 toolName: e.toolName ?? "",
                                                 summary: text,
                                                 since: .now)
            if notifyWaiting {
                Notifier.waiting(project: sessions[i].project, text: text,
                                 sessionId: e.sessionId, actionable: false)
            }
            if afkActive() { observer?.waitingInTerminal(sessions[i], text: text) }

        case .gate:
            guard let rid = e.requestId else { reply?(GateDecision(decision: "ask")); return }
            // Прежний ответчик этой сессии (если был) останется без pending —
            // его отпустит тик (ask).
            sessions[i].state = .waiting
            sessions[i].pending = PendingRequest(id: rid,
                                                 toolName: e.toolName ?? "",
                                                 summary: e.summary ?? (e.toolName ?? "Действие"),
                                                 since: .now)
            if let reply { replies[rid] = reply }
            if notifyWaiting {
                Notifier.waiting(project: sessions[i].project,
                                 text: e.summary ?? "Нужно разрешение",
                                 sessionId: e.sessionId,
                                 actionable: reply != nil)
            }
            if afkActive() {
                observer?.gateOpened(sessions[i], requestId: rid,
                                     summary: sessions[i].pending?.summary ?? "",
                                     decidable: reply != nil)
            }

        case .stop:
            // Каждая ветка обязана ответить: CLI ждёт до 4 ч.
            // Предыдущий удерживаемый stop этой сессии — сначала отпустить.
            releaseStop(sessionId: e.sessionId, continueWith: nil)
            clearPending(i, force: true)
            let n = sessions[i].agents.count
            if n > 0 {
                // Основной агент ждёт сабагентов — это ещё не «готово».
                sessions[i].activity = "Ждёт агентов: \(n)"
                reply?(GateDecision(decision: "stop"))
                refreshBranch(e.sessionId)
                break
            }
            // Снимки хода: пока ждали агентов, копились дальше.
            let shots = takeShots(e.sessionId)
            // Очередь из Telegram: ход продолжается сразу — без удержания, tty не нужен.
            // Ответчика нет (CLI не ждёт) — очередь остаётся до следующего stop.
            if afkActive(), let reply, let texts = queue.removeValue(forKey: e.sessionId) {
                reply(GateDecision(decision: "continue", reason: texts.joined(separator: "\n\n")))
                sessions[i].activity = "Продолжает из очереди Telegram"
                sessions[i].finishedAt = nil
                let sid = e.sessionId, last = e.lastMessage
                refreshBranch(sid) { [weak self] in
                    guard let self, let s = self.sessions.first(where: { $0.id == sid }) else { return }
                    self.observer?.queueDelivered(s, lastMessage: last, shots: shots)
                }
                break
            }
            sessions[i].state = .done
            sessions[i].finishedAt = .now
            sessions[i].activity = "Готово"
            if notifyDone {
                Notifier.done(project: sessions[i].project, sessionId: e.sessionId)
            }
            // Держим только в режиме «Я отошёл», только интерактивную сессию (есть tty)
            // и только если CLI ждёт (есть requestId).
            let hold = StopPolicy.shouldHold(afkActive: afkActive(), agentsRunning: n > 0,
                                             hasTTY: sessions[i].tty != nil,
                                             hasReplier: reply != nil && e.requestId != nil)
            // Ветку обновляем после решения: ответ CLI не ждёт git.
            if hold, let reply, let rid = e.requestId {
                stopReplies[e.sessionId] = (rid, reply)
                sessions[i].activity = Self.heldActivity   // видно в панели: держит режим «Я отошёл»
                // «Готово» — с актуальной веткой; если stop успели отпустить, писать не о чем.
                let sid = e.sessionId, last = e.lastMessage
                refreshBranch(sid) { [weak self] in
                    guard let self, self.isStopHeld(requestId: rid),
                          let s = self.sessions.first(where: { $0.id == sid }) else { return }
                    self.observer?.stopHeld(s, requestId: rid, lastMessage: last, shots: shots)
                }
            } else {
                reply?(GateDecision(decision: "stop"))
                refreshBranch(e.sessionId)
            }

        case .end:
            clearPending(i, force: true)
            sessions.remove(at: i)
        }
        persist()
    }

    /// Ветка могла смениться за ход (checkout). Не на .tool — это горячий путь.
    /// git — вне главного потока: waitUntilExit крутит run loop, и другое событие
    /// сдвинуло бы индексы. Сессию после git ищем заново по id; then — в любом случае.
    private func refreshBranch(_ sessionId: String, then: (() -> Void)? = nil) {
        guard let cwd = sessions.first(where: { $0.id == sessionId })?.cwd else { then?(); return }
        Task { [weak self] in
            let b = await Task.detached { Git.branch(at: cwd) }.value
            guard let self else { return }
            if let i = self.sessions.firstIndex(where: { $0.id == sessionId }), self.sessions[i].branch != b {
                self.sessions[i].branch = b
                self.persist()
            }
            then?()
        }
    }

    private static func activityText(tool: String?, summary: String?) -> String {
        guard let tool else { return "Работает" }
        let what = summary ?? ""
        switch tool {
        case "Edit", "Write":     return what.isEmpty ? "Правит файлы" : "Правит \(what)"
        case "Read":              return what.isEmpty ? "Читает" : "Читает \(what)"
        case "Bash":              return what.isEmpty ? "Выполняет команду" : "$ \(what)"
        case "Grep", "Glob":      return "Ищет по проекту"
        case "WebFetch", "WebSearch": return "Смотрит в интернете"
        case "Task", "Agent":     return what.isEmpty ? "Работает с сабагентами" : "Сабагент: \(what)"
        default:                  return tool
        }
    }

    /// Событие о работе: снимаем pending и возвращаем в working.
    /// force == false (tool / subagent*): pending с живым ответчиком не трогаем —
    /// gate ещё ждёт ответа, а событие могло прийти от параллельного сабагента
    /// той же сессии. force == true (start / prompt / stop): ход точно сменился,
    /// ответчик (если был) больше не нужен — выбрасываем его, соединение
    /// отпускаем ответом ask: CLI сразу выходит, решает сам Claude.
    private func clearPending(_ i: Int, force: Bool) {
        if let p = sessions[i].pending {
            if !force && replies[p.id] != nil { return }
            if let reply = replies.removeValue(forKey: p.id) {
                reply(GateDecision(decision: "ask"))
                observer?.resolved(sessionId: sessions[i].id, text: "Запрос закрыт")
            }
            sessions[i].pending = nil
            Notifier.dismiss(sessionId: sessions[i].id)
        }
        sessions[i].state = .working
    }

    /// CLI закрыл соединение (таймаут) — ответить больше нельзя, Claude спросит
    /// в терминале. Сессия остаётся ждущей, но уже без кнопок решения.
    func replyGone(requestId: String) {
        guard replies.removeValue(forKey: requestId) != nil else { return }
        if let s = sessions.first(where: { $0.pending?.id == requestId }) {
            observer?.resolved(sessionId: s.id, text: "Спросит в терминале")
        }
        objectWillChange.send()
    }

    // MARK: - Удерживаемый stop

    /// Сессии, чей stop ждёт ответа (только stop, не gate).
    var heldStops: [String] { Array(stopReplies.keys) }

    /// Работающие сессии — им можно писать в очередь.
    var workingSessions: [String] { sessions.filter { $0.state == .working }.map(\.id) }

    /// false — режим выключен, сессия не работает (или пропала) либо текст пустой.
    @discardableResult
    func enqueue(sessionId: String, text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, afkActive(), sessions.contains(where: { $0.id == sessionId && $0.state == .working }) else { return false }
        queue[sessionId, default: []].append(t)
        return true
    }

    /// Выход из режима: очередь не доставляем. Возвращает, сколько текстов сброшено.
    func dropQueues() -> Int {
        let n = queue.values.reduce(0) { $0 + $1.count }
        queue.removeAll()
        return n
    }

    /// Активность сессии, чей stop удерживается.
    static let heldActivity = "Ждёт ответа из Telegram"

    /// Ход кончился без продолжения — вместо «Ждёт ответа из Telegram» снова «Готово».
    private func markFinished(_ sessionId: String) {
        guard let i = sessions.firstIndex(where: { $0.id == sessionId }),
              sessions[i].activity == Self.heldActivity else { return }
        sessions[i].activity = "Готово"
    }

    /// Отпустить stop: text != nil — продолжить ход с этим текстом, иначе закончить.
    /// Пустой текст (или из одних пробелов) — как nil.
    func releaseStop(sessionId: String, continueWith text: String?) {
        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = (trimmed?.isEmpty ?? true) ? nil : trimmed
        releaseStop(sessionId: sessionId, continueWith: text,
                    resolvedText: text != nil ? "Отправлено в сессию" : "Сессия завершила ход")
    }

    /// Кнопка «Завершить» из Telegram: отпустить именно этот stop.
    /// false — он уже отпущен (новый ход, выключение режима) и кнопка устарела.
    @discardableResult
    func releaseStop(requestId: String) -> Bool {
        guard let sid = stopReplies.first(where: { $0.value.requestId == requestId })?.key else { return false }
        releaseStop(sessionId: sid, continueWith: nil)
        return true
    }

    /// Stop с этим requestId всё ещё удерживается.
    func isStopHeld(requestId: String) -> Bool {
        stopReplies.values.contains { $0.requestId == requestId }
    }

    /// Выключение режима / приложения: все сессии заканчивают ход.
    func releaseAllStops() {
        for id in Array(stopReplies.keys) {
            releaseStop(sessionId: id, continueWith: nil, resolvedText: Texts.back)
        }
    }

    private func releaseStop(sessionId: String, continueWith text: String?, resolvedText: String) {
        guard let held = stopReplies.removeValue(forKey: sessionId) else { return }
        if let text {
            held.reply(GateDecision(decision: "continue", reason: text))
            if let i = sessions.firstIndex(where: { $0.id == sessionId }) {
                sessions[i].state = .working
                sessions[i].activity = "Продолжает по ответу из Telegram"
                sessions[i].finishedAt = nil
                sessions[i].lastEvent = .now   // иначе детектор сразу объявит зависание
            }
        } else {
            held.reply(GateDecision(decision: "stop"))
            markFinished(sessionId)
        }
        observer?.resolved(sessionId: sessionId, text: resolvedText)
        persist()
    }

    /// CLI закрыл соединение stop — ответить уже некому. Убираем только ответчик
    /// этого соединения: запоздалое закрытие старого не трогает следующий stop.
    func stopGone(sessionId: String, requestId: String) {
        guard let held = stopReplies[sessionId], held.requestId == requestId else { return }
        stopReplies.removeValue(forKey: sessionId)
        markFinished(sessionId)
        observer?.resolved(sessionId: sessionId, text: "Сессия завершила ход")
        objectWillChange.send()
    }

    /// Выключение приложения: всем висящим gate — ask, чтобы CLI не ждали обрыва.
    func askAllGates() {
        for (_, reply) in replies { reply(GateDecision(decision: "ask")) }
        replies.removeAll()
    }

    // MARK: - Решения

    /// Gate ещё ждёт решения и есть кому ответить (мост: не устарело ли только что отправленное).
    func isGateOpen(requestId: String) -> Bool {
        replies[requestId] != nil && sessions.contains { $0.pending?.id == requestId }
    }

    /// Решение по requestId (кнопка из Telegram). false — запрос уже закрыт, кнопка устарела.
    @discardableResult
    func decide(requestId: String, allow: Bool) -> Bool {
        guard replies[requestId] != nil,
              let s = sessions.first(where: { $0.pending?.id == requestId }) else { return false }
        decide(sessionId: s.id, allow: allow)
        return true
    }

    func decide(sessionId: String, allow: Bool) {
        guard let i = sessions.firstIndex(where: { $0.id == sessionId }),
              let pending = sessions[i].pending else { return }

        if let reply = replies.removeValue(forKey: pending.id) {
            reply(GateDecision(decision: allow ? "allow" : "deny",
                               reason: allow ? "Разрешено в AFK Sessions" : "Отклонено в AFK Sessions"))
        }

        sessions[i].pending = nil
        sessions[i].state = .working
        sessions[i].activity = allow ? "Выполняет" : "Ищет другой путь"
        sessions[i].lastEvent = .now
        Notifier.dismiss(sessionId: sessionId)
        observer?.resolved(sessionId: sessionId, text: Texts.resolved(allow ? "разрешено" : "отклонено"))
        persist()
    }

    /// Хоткей ⌥⇧A — разрешить верхнюю ждущую.
    func approveTop() {
        guard let s = topDecidable else { return }
        decide(sessionId: s.id, allow: true)
        Notifier.hud("Разрешено · \(s.project)")
    }

    func jump(to session: Session) {
        TerminalJumper.focus(tty: session.tty,
                             termProgram: session.termProgram,
                             focusURL: session.focusURL,
                             cwd: session.cwd,
                             override: terminalChoice)
    }

    func forget(_ session: Session) {
        releaseStop(sessionId: session.id, continueWith: nil)
        if let i = sessions.firstIndex(where: { $0.id == session.id }) { clearPending(i, force: true) }
        sessions.removeAll { $0.id == session.id }
        persist()
    }

    // MARK: - Тик: зависания и обновление таймеров

    private func tick() {
        // Сначала мусор — чтобы старая сессия не успела «зависнуть» и уведомить.
        removeZombies()
        let limit = TimeInterval(stallMinutes * 60)
        let afk = afkActive()
        for i in sessions.indices where sessions[i].state == .working {
            if Date.now.timeIntervalSince(sessions[i].lastEvent) > limit {
                sessions[i].state = .stalled
                if notifyStalled {
                    Notifier.stalled(project: sessions[i].project, minutes: stallMinutes,
                                     sessionId: sessions[i].id)
                }
                if afk { observer?.stalled(sessions[i], minutes: stallMinutes) }
            }
        }

        // Вне режима gate держим не дольше gateTimeout, затем ask —
        // Claude спросит в терминале (как раньше при таймауте CLI).
        for (rid, reply) in replies {
            let owner = sessions.first { $0.pending?.id == rid }
            let expired = !afk && Date.now.timeIntervalSince(owner?.pending?.since ?? .distantPast) > Self.gateTimeout
            // Ответчик без pending (его сменил новый gate сессии) — тоже отпускаем.
            if expired || owner == nil {
                replies.removeValue(forKey: rid)
                reply(GateDecision(decision: "ask"))
                if let owner { observer?.resolved(sessionId: owner.id, text: "Спросит в терминале") }
            }
        }

        // Страховка: вне режима stop не держим; сессия пропала — отпускаем.
        if !afk { releaseAllStops() }
        for id in heldStops where !sessions.contains(where: { $0.id == id }) {
            releaseStop(sessionId: id, continueWith: nil)
        }
        queue = queue.filter { q in sessions.contains { $0.id == q.key } }
        shots = shots.filter { q in sessions.contains { $0.id == q.key } }

        objectWillChange.send()   // перерисовать таймеры в строках

        if showCost, Date.now.timeIntervalSince(lastCostRefresh) > 60 {
            refreshCosts()
        }
    }

    private func refreshCosts() {
        lastCostRefresh = .now
        CostTracker.shared.refresh { snapshot in
            Task { @MainActor [weak self] in self?.costs = snapshot }
        }
    }

    /// Сессии без событий дольше zombieAge убираем молча.
    private func removeZombies() {
        let old = sessions.filter { Date.now.timeIntervalSince($0.lastEvent) > Self.zombieAge }
        guard !old.isEmpty else { return }
        for s in old {
            releaseStop(sessionId: s.id, continueWith: nil)
            if let i = sessions.firstIndex(where: { $0.id == s.id }) { clearPending(i, force: true) }
        }
        let ids = Set(old.map(\.id))
        sessions.removeAll { ids.contains($0.id) }
        persist()
    }

    // MARK: - Персистентность: сессии переживают перезапуск приложения

    private struct Persisted: Codable {
        var id: String
        var cwd: String
        var project: String
        var branch: String
        var tty: String?
        var termProgram: String?
        var focusURL: String?
        var state: Int
        var activity: String
        var lastEvent: Date
        var startedAt: Date
        var finishedAt: Date?
    }

    private static var stateURL: URL {
        Bridge.supportDir.appendingPathComponent("sessions.json")
    }

    private func persist() {
        let items = sessions.map { s in
            Persisted(id: s.id, cwd: s.cwd, project: s.project, branch: s.branch,
                      tty: s.tty, termProgram: s.termProgram, focusURL: s.focusURL,
                      state: s.state.rawValue, activity: s.activity,
                      lastEvent: s.lastEvent, startedAt: s.startedAt, finishedAt: s.finishedAt)
        }
        try? FileManager.default.createDirectory(at: Bridge.supportDir, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(items) {
            try? data.write(to: Self.stateURL, options: .atomic)
        }
    }

    private func restore() {
        guard let data = try? Data(contentsOf: Self.stateURL),
              let items = try? JSONDecoder().decode([Persisted].self, from: data) else { return }
        // Зомби после рестарта: ответчиков ещё нет, просто не поднимаем их.
        let alive = items.filter { Date.now.timeIntervalSince($0.lastEvent) <= Self.zombieAge }
        sessions = alive.map { p in
            var s = Session(id: p.id, cwd: p.cwd, project: p.project, branch: p.branch,
                            tty: p.tty, termProgram: p.termProgram)
            s.focusURL = p.focusURL
            // Ждущие gate-запросы не переживают рестарт: закрывать нечем,
            // поэтому сессия возвращается как работающая (стоячую поймает детектор).
            s.state = SessionState(rawValue: p.state) == .done ? .done : .working
            // Удержание рестарт не переживает (соединение CLI закрылось).
            s.activity = p.activity == Self.heldActivity ? "Готово" : p.activity
            s.lastEvent = p.lastEvent
            s.startedAt = p.startedAt
            s.finishedAt = p.finishedAt
            return s
        }
    }
}

// MARK: - Git

enum Git {
    static func branch(at path: String) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["git", "-C", path, "rev-parse", "--abbrev-ref", "HEAD"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return "—" }
        p.waitUntilExit()
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return out.isEmpty ? "—" : out
    }
}
