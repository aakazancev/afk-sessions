import SwiftUI
import ImageIO
import SessionsTelegram

/// Кнопка Bot API (в SwiftUI есть своя Button).
private typealias BotButton = SessionsTelegram.Button

/// Мост в Telegram: polling, привязка чата, команды, сообщения о сессиях
/// в режиме «Я отошёл». Сеть — в Task, главный поток не ждёт.
@MainActor
final class TelegramBridge: ObservableObject, SessionObserver {

    enum Status: Equatable { case noToken, pairing(code: String), connected, error(String) }

    @Published private(set) var status: Status = .noToken
    /// Последняя сетевая ошибка polling; nil — связь есть. Код привязки при этом остаётся виден.
    @Published private(set) var lastError: String?
    /// @AppStorage внутри ObservableObject не публикует изменения — храним сами.
    @Published var approvals = UserDefaults.standard.object(forKey: "telegramApprovals") as? Bool ?? true {
        didSet { UserDefaults.standard.set(approvals, forKey: "telegramApprovals") }
    }

    private let store: SessionStore
    private let afk: AfkController

    private var api: BotAPI?
    private var pollTask: Task<Void, Never>?
    /// Поколение api: растёт при каждом start(). Ошибки старого поколения игнорируются.
    private var generation = 0
    /// Последний подтверждённый update + 1 — чтобы перезапуск не повторил старые.
    private var offset: Int?

    private var pairingCode: String?
    /// Неверные «/start …» из непривязанного чата; после 5 — новый код.
    private var wrongAttempts = 0

    private var map = MessageMap()
    /// Сообщения с кнопками: message_id → исходный текст (для редактирования в том же формате).
    private var sentText: [Int: RichText] = [:]
    /// Последнее сообщение gate / «готово» каждой сессии.
    private var gateMessage: [String: Int] = [:]
    private var stopMessage: [String: Int] = [:]

    private var chatId: Int64? {
        get { UserDefaults.standard.string(forKey: "telegramChatId").flatMap(Int64.init) }
        set {
            if let newValue { UserDefaults.standard.set(String(newValue), forKey: "telegramChatId") }
            else { UserDefaults.standard.removeObject(forKey: "telegramChatId") }
        }
    }

    init(store: SessionStore, afk: AfkController) {
        self.store = store
        self.afk = afk

        afk.onChange = { [weak self] old, new in
            guard let self else { return }
            if old == .off, new != .off {
                let lines = self.sessionLines()
                self.send(Texts.afkOn(sessions: lines), buttons: self.writeButtons(lines))
            } else if old != .off, new == .off {
                let dropped = self.store.dropQueues()
                // Сначала отпустить: resolved отредактирует «готово» в «вы вернулись».
                self.store.releaseAllStops()
                // Открытые gate остаются ждать решения в панели — кнопки в Telegram снять.
                for sid in Array(self.gateMessage.keys) {
                    self.resolved(sessionId: sid, text: "Вы вернулись — решайте на маке")
                }
                self.send(Texts.afkOffText(dropped: dropped))
            }
        }
        afk.onWillSleep = { [weak self] in
            guard let self else { return }
            self.send(Texts.sleeping(held: self.store.heldStops.count))
        }
    }

    // MARK: - Управление

    /// Сохраняет токен в файл и перезапускает polling.
    func setToken(_ token: String?) {
        let trimmed = token?.trimmingCharacters(in: .whitespacesAndNewlines)
        let t = (trimmed?.isEmpty ?? true) ? nil : trimmed
        let changed = t != TokenStore.token()
        if changed {
            // Пока старый чат известен: выключить режим, отпустить stop, снять кнопки.
            afk.linked = false
        }
        guard TokenStore.setToken(t) else {
            stop()
            status = .error("Не удалось сохранить токен")
            syncLinked()
            return
        }
        if changed {
            // Другой бот: старые message_id и offset ничего не значат, привязку — заново.
            offset = nil
            forgetMessages()
            resetPairing()
        }
        start()
    }

    func unpair() {
        // Пока чат известен: выключить режим, отпустить stop, снять кнопки.
        afk.linked = false
        resetPairing()
        forgetMessages()
        refreshStatus()
    }

    func start() {
        stop()
        guard let token = TokenStore.token() else {
            status = .noToken
            syncLinked()
            return
        }
        let api = BotAPI(transport: HTTPTransport(token: token))
        self.api = api
        refreshStatus()
        let gen = generation
        pollTask = Task { [weak self] in await self?.poll(api, gen) }
    }

    private func stop() {
        pollTask?.cancel()
        pollTask = nil
        api = nil
        lastError = nil
        generation += 1
    }

    private func resetPairing() {
        chatId = nil
        pairingCode = nil   // новый код создаст refreshStatus
        wrongAttempts = 0
    }

    // MARK: - Polling

    private func poll(_ api: BotAPI, _ gen: Int) async {
        try? await api.setMyCommands(Texts.commands)
        var delay: UInt64 = 2
        // Накопленное до запуска не обрабатываем: старая /afk_start включила бы
        // режим человеку, который сидит за маком.
        var backlogSkipped = false
        while !Task.isCancelled {
            do {
                if !backlogSkipped {
                    let old = try await api.getUpdates(offset: -1, timeout: 0)
                    if Task.isCancelled { return }
                    if let last = old.last { offset = last.updateId + 1 }
                    backlogSkipped = true
                } else {
                    let updates = try await api.getUpdates(offset: offset, timeout: 50)
                    if Task.isCancelled { return }
                    for u in updates {
                        offset = u.updateId + 1
                        handle(u)
                    }
                }
                delay = 2
                lastError = nil
                refreshStatus()
            } catch {
                // Отмена приходит тоже ошибкой (BotError из URLError.cancelled).
                if Task.isCancelled { return }
                if noteAuthError(error, gen) { return }
                lastError = (error as? BotError)?.message ?? "Ошибка Telegram"
                try? await Task.sleep(nanoseconds: delay * 1_000_000_000)
                delay = min(delay * 2, 60)
            }
        }
    }

    /// Статус по привязке; код генерируется при входе в состояние привязки.
    private func refreshStatus() {
        defer { syncLinked() }
        guard api != nil else { status = .noToken; return }
        if chatId != nil {
            status = .connected
        } else {
            if pairingCode == nil { pairingCode = Router.newPairingCode() }
            status = .pairing(code: pairingCode!)
        }
    }

    /// Режим действует, только пока бот привязан: есть токен (api) и чат.
    private func syncLinked() {
        let linked = api != nil && chatId != nil
        if afk.linked != linked { afk.linked = linked }
    }

    // MARK: - Входящие

    private func handle(_ u: Update) {
        let action = Router.route(u, pairedChat: chatId, pairingCode: pairingCode,
                                  map: map, waiting: store.heldStops, working: afk.isOn ? store.workingSessions : [])
        countWrongPairing(u, action)

        switch action {
        case .pair(let chat):
            chatId = chat
            pairingCode = nil
            wrongAttempts = 0
            status = .connected
            syncLinked()
            send(Texts.paired)

        case .afkStart:
            afk.send(.manualOn)
        case .afkBack:
            afk.send(.manualOff)
        case .afkStatus:
            let lines = sessionLines()
            // «Написать» — только в режиме: вне его очереди нет.
            send(Texts.status(afkOn: afk.isOn, sessions: lines), buttons: afk.isOn ? writeButtons(lines) : [])

        case .reply(let sid, let text):
            store.releaseStop(sessionId: sid, continueWith: text)
        case .enqueue(let sid, let text):
            // Сессия могла закончить ход между разбором и сюда — тогда честно «не работает».
            send(store.enqueue(sessionId: sid, text: text) ? Texts.queued : Texts.idle)
        case .notWaiting:
            send(Texts.notWaiting)
        case .needReplyTarget:
            // Никто не ждёт — объяснить, что писать пока некому; иначе просить reply.
            if store.heldStops.isEmpty {
                let lines = sessionLines()
                send(Texts.nobodyWaiting(afkOn: afk.isOn, sessions: lines),
                     buttons: afk.isOn ? writeButtons(lines) : [])
            } else {
                send(Texts.needReplyTarget)
            }

        case .decide(let requestId, let allow, let cb):
            // Для gate в callback_data — requestId, а не сессия.
            if !approvals {
                answer(cb, "Разрешения из Telegram выключены")
                stripButtons(u, note: "Разрешения из Telegram выключены")
            } else if store.decide(requestId: requestId, allow: allow) {
                answer(cb, nil)
            } else {
                answer(cb, "Запрос уже неактуален")
                stripButtons(u, note: "Запрос уже неактуален")
            }

        case .finish(let requestId, let cb):
            // Кнопка адресует конкретный stop: после нового хода она устарела.
            if store.releaseStop(requestId: requestId) {
                answer(cb, nil)
            } else {
                answer(cb, Texts.notWaiting)
                stripButtons(u, note: Texts.notWaiting)
            }

        case .compose(let sid, let cb):
            // Старая кнопка вне режима: очереди нет.
            guard afk.isOn else {
                answer(cb, "Режим «Я отошёл» выключен")
                return
            }
            guard let s = store.sessions.first(where: { $0.id == sid }) else {
                answer(cb, Texts.sessionGone)
                return
            }
            // Текст примет только работающая сессия (в очередь) или удерживаемый stop.
            guard accepting.contains(sid) else {
                answer(cb, Texts.idle)
                return
            }
            answer(cb, nil)
            send(Texts.compose(project: store.displayProject(s), branch: s.branch),
                 forceReply: Texts.composePlaceholder) { [weak self] id in
                self?.map.remember(id, session: sid)
            }

        case .ignore:
            break
        }
    }

    /// «/start <неверный код>» из непривязанного чата: после 5 попыток — новый код.
    private func countWrongPairing(_ u: Update, _ action: BotAction) {
        guard chatId == nil, case .ignore = action,
              let text = u.message?.text?.trimmingCharacters(in: .whitespacesAndNewlines),
              text.hasPrefix("/start") else { return }
        wrongAttempts += 1
        guard wrongAttempts >= 5 else { return }
        wrongAttempts = 0
        pairingCode = Router.newPairingCode()
        refreshStatus()
    }

    /// Список сессий, как в /afk_status.
    private func sessionLines() -> [SessionLine] {
        let held = Set(store.heldStops)
        return store.sessions.map { s in
            SessionLine(project: store.displayProject(s), branch: s.branch,
                        state: Self.stateText(s, held: held.contains(s.id)), id: s.id)
        }
    }

    private static func stateText(_ s: Session, held: Bool) -> String {
        switch s.state {
        case .working: return "работает"
        case .waiting: return "ждёт"
        case .stalled: return "молчит"
        case .done:    return held ? "готово, ждёт ответа" : "готово"
        }
    }

    // MARK: - SessionObserver

    func gateOpened(_ s: Session, requestId: String, summary: String, decidable: Bool) {
        let text = Texts.gate(project: store.displayProject(s), branch: s.branch, summary: summary)
        let buttons = approvals && decidable
            ? [[BotButton(text: "Разрешить", data: CallbackData.approve(requestId)),
                BotButton(text: "Отклонить", data: CallbackData.deny(requestId))]]
            : []
        notify(text, buttons: buttons) { [weak self] id in
            guard let self else { return }
            self.map.remember(id, session: s.id)
            self.sentText[id] = RichText(plain: text)
            self.gateMessage[s.id] = id
            // Решили раньше, чем Telegram вернул id, — resolved сообщение не нашёл.
            if !buttons.isEmpty, !self.store.isGateOpen(requestId: requestId) {
                self.closeStale(id, sessionId: s.id, note: "Запрос закрыт")
            }
        }
    }

    func stopHeld(_ s: Session, requestId: String, lastMessage: String?, shots: [String]) {
        let text = Texts.doneRich(project: store.displayProject(s), branch: s.branch, lastMessage: lastMessage)
        let buttons = [[BotButton(text: "Завершить", data: CallbackData.finish(requestId))]]
        notify(text, buttons: buttons) { [weak self] id in
            guard let self else { return }
            self.map.remember(id, session: s.id)
            self.sentText[id] = text
            self.stopMessage[s.id] = id
            self.sendShots(shots, replyTo: id)
            // Отпустили раньше, чем Telegram вернул id.
            if !self.store.isStopHeld(requestId: requestId) {
                self.closeStale(id, sessionId: s.id, note: Texts.notWaiting)
            }
        }
    }

    func queueDelivered(_ s: Session, lastMessage: String?, shots: [String]) {
        let text = Texts.doneQueued(project: store.displayProject(s), branch: s.branch, lastMessage: lastMessage)
        notify(text) { [weak self] id in
            self?.map.remember(id, session: s.id)
            self?.sendShots(shots, replyTo: id)
        }
    }

    /// Сессии, которым сейчас можно написать: работающие (очередь) и удерживаемые stop.
    private var accepting: Set<String> { Set(store.workingSessions + store.heldStops) }

    /// «Написать» — только тем, кто примет текст; иначе ответ был бы потерян.
    private func writeButtons(_ lines: [SessionLine]) -> [[BotButton]] {
        Texts.writeButtons(lines.filter { accepting.contains($0.id) })
    }

    /// Снимки хода — ответом на «готово»: фото альбомом, не влезающие в лимиты фото — документами.
    /// Ошибки глотаем: «готово» уже доставлено.
    private func sendShots(_ paths: [String], replyTo: Int) {
        guard !paths.isEmpty, afk.isOn, let api, let chat = chatId else { return }
        Task {
            let (photos, docs) = await Task.detached { Self.loadShots(paths) }.value
            try? await api.sendMedia(chatId: chat, kind: .photo, files: photos, replyTo: replyTo)
            try? await api.sendMedia(chatId: chat, kind: .document, files: docs, replyTo: replyTo)
        }
    }

    /// Читает файлы и делит по лимитам Telegram. Пропавшие и слишком большие пропускает.
    nonisolated private static func loadShots(_ paths: [String]) -> (photos: [MediaFile], docs: [MediaFile]) {
        var photos: [MediaFile] = [], docs: [MediaFile] = []
        for p in paths {
            guard let data = FileManager.default.contents(atPath: p), MediaPlan.fitsDocument(bytes: data.count) else { continue }
            var w = 0, h = 0
            if let src = CGImageSourceCreateWithData(data as CFData, nil),
               let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] {
                w = props[kCGImagePropertyPixelWidth] as? Int ?? 0
                h = props[kCGImagePropertyPixelHeight] as? Int ?? 0
            }
            let f = MediaFile(filename: (p as NSString).lastPathComponent, data: data)
            if MediaPlan.fitsPhoto(ImageInfo(bytes: data.count, width: w, height: h)) { photos.append(f) } else { docs.append(f) }
        }
        return (photos, docs)
    }

    func waitingInTerminal(_ s: Session, text: String) {
        notify(Texts.waiting(project: store.displayProject(s), branch: s.branch, text: text)) { [weak self] id in
            self?.map.remember(id, session: s.id)
        }
    }

    func stalled(_ s: Session, minutes: Int) {
        notify(Texts.stalled(project: store.displayProject(s), branch: s.branch, minutes: minutes)) { [weak self] id in
            self?.map.remember(id, session: s.id)
        }
    }

    /// Не зависит от режима: выключение режима и решение в панели тоже редактируют сообщения.
    func resolved(sessionId: String, text: String) {
        let ids = [gateMessage.removeValue(forKey: sessionId), stopMessage.removeValue(forKey: sessionId)]
        for id in ids.compactMap({ $0 }) {
            let original = sentText.removeValue(forKey: id) ?? RichText(plain: "")
            edit(id, original.appending(text))
        }
    }

    // MARK: - Отправка

    /// Сообщение о сессии: только в режиме и при привязке.
    private func notify(_ text: String, buttons: [[BotButton]] = [], forceReply: String? = nil,
                        sent: ((Int) -> Void)? = nil) {
        notify(RichText(plain: text), buttons: buttons, forceReply: forceReply, sent: sent)
    }

    private func notify(_ text: RichText, buttons: [[BotButton]] = [], forceReply: String? = nil,
                        sent: ((Int) -> Void)? = nil) {
        guard afk.isOn else { return }
        send(text, buttons: buttons, forceReply: forceReply, sent: sent)
    }

    private func send(_ text: String, buttons: [[BotButton]] = [], forceReply: String? = nil,
                      sent: ((Int) -> Void)? = nil) {
        send(RichText(plain: text), buttons: buttons, forceReply: forceReply, sent: sent)
    }

    /// HTML-вариант с откатом на plain делает BotAPI.send.
    /// forceReply — подсказка в поле ввода: Telegram сразу открывает ответ на это сообщение.
    private func send(_ text: RichText, buttons: [[BotButton]] = [], forceReply: String? = nil,
                      sent: ((Int) -> Void)? = nil) {
        guard let api, let chat = chatId else { return }
        let gen = generation
        Task { [weak self] in
            do {
                let id = try await api.send(chatId: chat, text, buttons: buttons, forceReply: forceReply)
                // Другой бот / отвязка за время запроса — id уже чужой.
                guard self?.generation == gen, self?.chatId == chat else { return }
                sent?(id)
            } catch {
                self?.noteAuthError(error, gen)
            }
        }
    }

    /// Ошибки редактирования глотаем: «message is not modified», сообщение удалено и т. п.
    private func edit(_ messageId: Int, _ text: RichText) {
        guard let api, let chat = chatId else { return }
        Task {
            try? await api.edit(chatId: chat, messageId: messageId, text, buttons: [])
        }
    }

    private func answer(_ callbackId: String, _ text: String?) {
        guard let api else { return }
        let gen = generation
        Task { [weak self] in
            do {
                try await api.answerCallbackQuery(id: callbackId, text: text.map { BotAPI.clip($0, limit: 200) })
            } catch {
                self?.noteAuthError(error, gen)
            }
        }
    }

    /// Устаревшая кнопка: убрать клавиатуру у её сообщения (если знаем исходный текст).
    private func stripButtons(_ u: Update, note: String) {
        guard let id = u.callbackQuery?.message?.messageId,
              let original = sentText.removeValue(forKey: id) else { return }
        if gateMessage.values.contains(id) { gateMessage = gateMessage.filter { $0.value != id } }
        if stopMessage.values.contains(id) { stopMessage = stopMessage.filter { $0.value != id } }
        edit(id, original.appending(note))
    }

    /// Сообщение устарело к моменту отправки: снять кнопки сразу.
    private func closeStale(_ id: Int, sessionId: String, note: String) {
        if gateMessage[sessionId] == id { gateMessage.removeValue(forKey: sessionId) }
        if stopMessage[sessionId] == id { stopMessage.removeValue(forKey: sessionId) }
        guard let original = sentText.removeValue(forKey: id) else { return }
        edit(id, original.appending(note))
    }

    /// 401 текущего поколения — токен не принят, polling стоп. Возвращает true, если это он.
    /// Прочие ошибки (и ошибки прежнего токена) глотаем.
    @discardableResult
    private func noteAuthError(_ error: Error, _ gen: Int) -> Bool {
        guard gen == generation, (error as? BotError)?.code == 401 else { return false }
        pollTask?.cancel()
        // Бот больше не считается привязанным: режим выключится, stop отпустятся,
        // gate получат обычный ask по 300 с. Сообщения этим токеном уже не отредактировать.
        api = nil
        lastError = nil
        status = .error("Токен не принят")
        syncLinked()
        return true
    }

    private func forgetMessages() {
        map = MessageMap()
        sentText.removeAll()
        gateMessage.removeAll()
        stopMessage.removeAll()
    }
}
