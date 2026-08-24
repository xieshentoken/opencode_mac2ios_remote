import Foundation
import OSLog

private let log = Logger(subsystem: "dev.opencodemobile.app", category: "eventstream")

private func streamDebug(_ msg: String) {
    #if DEBUG
    let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    let url = docs.appendingPathComponent("stream.log")
    let line = "[\(Date().formatted(.dateTime.hour().minute().second()))] \(msg)\n"
    if let data = line.data(using: .utf8) {
        if FileManager.default.fileExists(atPath: url.path) {
            if let fh = try? FileHandle(forWritingTo: url) {
                fh.seekToEndOfFile()
                fh.write(data)
                try? fh.close()
            }
        } else {
            try? data.write(to: url)
        }
    }
    #endif
}

// MARK: - Event stream status

enum EventStreamStatus: Equatable {
    case disconnected
    case connecting
    case connected
    case reconnecting(attempt: Int)
}

// MARK: - EventStream

/// SSE connection to `GET /event`, scoped to one directory (or nil for the
/// server's own instance).
///
/// Design notes (verified 2026-08-16 on opencode 1.18.18):
/// - The stream is PER-INSTANCE: events for sessions of directory D are only
///   delivered on a connection carrying `x-opencode-directory: D`. A bare
///   connection only receives the default cwd instance's events + heartbeats.
/// - First event is `server.connected`. Heartbeats every ~60-70s. Cloudflare
///   idles out SSE at ~100s => the URL loading request-idle timeout is 90s.
/// - After reconnect the stream only carries NEW events; caller MUST reconcile
///   against REST (`GET /session/:id/message`) to fill the gap.
actor EventStream {
    let directory: String?
    let client: OpenCodeClient

    private(set) var status: EventStreamStatus = .disconnected
    private var task: Task<Void, Never>?
    private var isUserCancelled = false
    private var reconnectAttempt = 0
    private var hasConnectedBefore = false

    /// Dedicated session: SSE must NOT inherit the REST client's short
    /// request timeout (heartbeats arrive only every ~60-70s, Cloudflare
    /// idles out ~100s). The watchdog handles dead connections instead.
    private let streamSession: URLSession

    /// Continuation queue for downstream consumers. Multiple subscribers allowed.
    private var continuations: [UUID: AsyncStream<SSEEvent>.Continuation] = [:]

    init(directory: String?, client: OpenCodeClient) {
        self.directory = directory
        self.client = client
        let cfg = URLSessionConfiguration.ephemeral
        // `timeoutIntervalForRequest` is an idle-data timeout. The server's
        // 60-70s heartbeat keeps a healthy stream alive; 90s of silence forces
        // URLSession to end the byte sequence so runLoop can reconnect.
        cfg.timeoutIntervalForRequest = 90
        cfg.timeoutIntervalForResource = .greatestFiniteMagnitude
        cfg.waitsForConnectivity = true
        cfg.httpMaximumConnectionsPerHost = 2
        self.streamSession = URLSession(configuration: cfg)
    }

    // MARK: - Lifecycle

    func start() {
        guard task == nil else { return }
        streamDebug("start dir=\(directory ?? "nil")")
        isUserCancelled = false
        task = Task { await self.runLoop() }
    }

    func stop() {
        isUserCancelled = true
        task?.cancel()
        task = nil
        streamSession.invalidateAndCancel()
        status = .disconnected
        continuations.forEach { $0.value.finish() }
        continuations.removeAll()
    }

    // MARK: - Event subscription

    func events() -> AsyncStream<SSEEvent> {
        AsyncStream { continuation in
            let id = UUID()
            self.continuations[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeContinuation(id) }
            }
        }
    }

    private func removeContinuation(_ id: UUID) {
        continuations.removeValue(forKey: id)
    }

    // MARK: - Run loop

    private func runLoop() async {
        while !Task.isCancelled && !isUserCancelled {
            await connectOnce()
            guard !Task.isCancelled && !isUserCancelled else { break }
            try? await Task.sleep(nanoseconds: backoffNanoseconds())
        }
    }

    private func backoffNanoseconds() -> UInt64 {
        let base: UInt64 = 500_000_000 // 0.5s
        let attempt = min(reconnectAttempt, 6)
        reconnectAttempt += 1
        return base * UInt64(pow(2.0, Double(attempt)))
    }

    private func connectOnce() async {
        guard let base = URL(string: client.config.baseURL) else {
            status = .disconnected
            return
        }
        var url = base.appending(path: "/event")
        if let directory, !directory.isEmpty {
            url.append(queryItems: [URLQueryItem(name: "directory", value: directory)])
        }

        var req = URLRequest(url: url)
        req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        req.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        req.setValue(authHeader, forHTTPHeaderField: "Authorization")
        req.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        if let directory, !directory.isEmpty {
            req.setValue(directory, forHTTPHeaderField: "x-opencode-directory")
        }
        req.timeoutInterval = 90

        status = reconnectAttempt == 0 ? .connecting : .reconnecting(attempt: reconnectAttempt)
        streamDebug("connectOnce start url=\(url.absoluteString) dir=\(self.directory ?? "nil")")

        do {
            let (bytes, response) = try await streamSession.bytes(for: req)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                throw OpenCodeError.serverUnreachable
            }
            let isReconnect = hasConnectedBefore
            hasConnectedBefore = true
            reconnectAttempt = 0
            status = .connected
            streamDebug("connected, http=\(http.statusCode)")
            if isReconnect {
                broadcast(SSEEvent(id: nil, type: "client.reconnected", properties: nil))
            }

            var buffer = Data()

            // Verified on opencode 1.18.18: each SSE event is a SINGLE
            // `data: {...}` line with NO empty separator between events. So
            // emit per data line, buffering only across a multi-line payload
            // in the same event (rare). Never wait for a blank line.
            var lineCount = 0
            for try await line in bytes.lines {
                lineCount += 1
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty {
                    if !buffer.isEmpty {
                        emitEvent(from: buffer)
                        buffer = Data()
                    }
                    continue
                }
                if trimmed.hasPrefix(":") { continue } // comment/keep-alive
                guard trimmed.hasPrefix("data:") else {
                    // Continuation of a multi-line `data:` payload.
                    if !buffer.isEmpty {
                        buffer.append(contentsOf: trimmed.utf8)
                        buffer.append(contentsOf: "\n".utf8)
                    }
                    continue
                }
                let payload = trimmed.dropFirst(5).trimmingCharacters(in: .whitespaces)
                if buffer.isEmpty {
                    // Fast path: one data line per event.
                    emitEvent(from: Data(payload.utf8))
                } else {
                    buffer.append(contentsOf: payload.utf8)
                    buffer.append(contentsOf: "\n".utf8)
                }
            }
            streamDebug("stream ended normally after \(lineCount) lines")
            log.info("stream ended normally after \(lineCount, privacy: .public) lines")
        } catch {
            let err = error as NSError
            streamDebug("stream END: code=\(err.code) domain=\(err.domain) desc=\(err.localizedDescription)")
            log.error("stream \(self.directory ?? "nil", privacy: .public): \(err.code) \(err.localizedDescription, privacy: .public)")
        }
        status = .disconnected
    }

    private var authHeader: String {
        let creds = "\(client.config.username):\(client.config.password)"
        let data = Data(creds.utf8)
        return "Basic \(data.base64EncodedString())"
    }

    private func emitEvent(from buffer: Data) {
        guard let event = try? JSONDecoder.oc.decode(SSEEvent.self, from: buffer) else { return }
        broadcast(event)
    }

    private func broadcast(_ event: SSEEvent) {
        let continuations = self.continuations.values
        continuations.forEach { $0.yield(event) }
    }
}
