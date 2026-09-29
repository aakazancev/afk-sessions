import Foundation
import Network
import SessionsCore

/// Слушает 127.0.0.1 на случайном порту. Порт и токен кладём в файл с правами 0600.
/// Протокол: одна строка JSON на сообщение, ответ на gate — тоже строка JSON.
final class EventServer {

    private var listener: NWListener?
    private let token = UUID().uuidString
    private let queue = DispatchQueue(label: "sessions.server")
    private weak var store: SessionStore?

    init(store: SessionStore) {
        self.store = store
    }

    func start() {
        do {
            let params = NWParameters.tcp
            params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
            params.allowLocalEndpointReuse = true

            let l = try NWListener(using: params)
            l.newConnectionHandler = { [weak self] conn in self?.accept(conn) }
            l.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                if case .ready = state, let port = l.port {
                    Bridge.writeEndpoint(port: port.rawValue, token: self.token)
                }
            }
            l.start(queue: queue)
            listener = l
        } catch {
            NSLog("Sessions: не удалось поднять слушателя — \(error)")
        }
    }

    func stop() {
        listener?.cancel()
        Bridge.clearEndpoint()
    }

    // MARK: - Соединения

    private func accept(_ conn: NWConnection) {
        conn.start(queue: queue)
        receive(conn, buffer: Data())
    }

    private func receive(_ conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, done, error in
            guard let self else { return }
            var buf = buffer
            if let data { buf.append(data) }

            while let nl = buf.firstIndex(of: 0x0A) {
                let line = buf[buf.startIndex..<nl]
                buf = buf.count > nl + 1 ? Data(buf[(nl + 1)...]) : Data()
                self.dispatch(Data(line), on: conn)
            }

            if error != nil || done {
                conn.cancel()
                return
            }
            self.receive(conn, buffer: buf)
        }
    }

    private func dispatch(_ line: Data, on conn: NWConnection) {
        // Не разобрали (другая версия CLI) — закрываем, иначе CLI прождёт до 4 ч.
        guard let event = try? JSONDecoder().decode(HookEvent.self, from: line) else {
            conn.cancel()
            return
        }
        guard event.token == token else {
            NSLog("Sessions: отброшено сообщение с чужим токеном")
            conn.cancel()
            return
        }

        // Для gate и stop придерживаем соединение: ответим решением человека
        // (stop вне режима «Я отошёл» store отпускает сразу).
        let needsReply = (event.kind == .gate || event.kind == .stop)

        let reply: ((GateDecision) -> Void)? = needsReply ? { decision in
            guard var data = try? JSONEncoder().encode(decision) else { conn.cancel(); return }
            data.append(0x0A)
            conn.send(content: data, completion: .contentProcessed { _ in conn.cancel() })
        } : nil

        // Соединение закрылось (CLI вышел по таймауту) — ответчик больше не нужен.
        if needsReply {
            let kind = event.kind, sid = event.sessionId, rid = event.requestId
            conn.stateUpdateHandler = { [weak store] state in
                switch state {
                case .cancelled, .failed:
                    Task { @MainActor in
                        guard let rid else { return }
                        if kind == .stop {
                            store?.stopGone(sessionId: sid, requestId: rid)
                        } else {
                            store?.replyGone(requestId: rid)
                        }
                    }
                default: break
                }
            }
        }

        Task { @MainActor [weak store] in
            store?.handle(event, reply: reply)
        }
    }
}
