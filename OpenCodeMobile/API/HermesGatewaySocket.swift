import Foundation

enum HermesGatewayError: LocalizedError, Equatable, Sendable {
    case alreadyConnected
    case notConnected
    case readyTimeout
    case expectedGatewayReady
    case connectionClosed(code: Int?)
    case requestTimeout(method: String)
    case requestCancelled
    case rpc(code: Int, message: String)
    case transport(code: Int)
    case encoding(method: String)
    case decoding(method: String)
    case invalidResult(method: String)

    var errorDescription: String? {
        switch self {
        case .alreadyConnected:
            return "Hermes WebSocket is already connected"
        case .notConnected:
            return "Hermes WebSocket is not connected"
        case .readyTimeout:
            return "Hermes WebSocket connected but gateway.ready did not arrive in time"
        case .expectedGatewayReady:
            return "Hermes WebSocket did not start with gateway.ready"
        case .connectionClosed(let code):
            return code.map { "Hermes WebSocket closed (code \($0))" }
                ?? "Hermes WebSocket closed"
        case .requestTimeout(let method):
            return "Hermes RPC \(method) timed out"
        case .requestCancelled:
            return "Hermes RPC request was cancelled"
        case .rpc(let code, let message):
            return "Hermes RPC error \(code): \(String(message.prefix(240)))"
        case .transport(let code):
            return "Hermes WebSocket transport failed (\(code))"
        case .encoding(let method):
            return "Hermes RPC \(method) could not be encoded"
        case .decoding(let method):
            return "Hermes RPC \(method) response could not be decoded"
        case .invalidResult(let method):
            return "Hermes RPC \(method) returned an invalid result"
        }
    }
}

/// Native JSON-RPC transport for `hermes serve` `/api/ws`.
///
/// A ticket-bearing URL is sensitive and intentionally remains private. Error
/// values contain only close/error codes and never interpolate the URL. On an
/// unexpected disconnect the event stream stays alive, allowing the owner to
/// mint a fresh single-use ticket and call `reconnect(to:)`.
actor HermesGatewaySocket {
    nonisolated let events: AsyncStream<HermesGatewayEvent>

    private var endpointURL: URL
    private let session: URLSession
    private let ownsSession: Bool
    private let eventContinuation: AsyncStream<HermesGatewayEvent>.Continuation

    private var socket: URLSessionWebSocketTask?
    private var receiveLoopTask: Task<Void, Never>?
    private var pingLoopTask: Task<Void, Never>?
    private var connected = false
    private var permanentlyClosed = false

    private var pending: [String: CheckedContinuation<HermesJSONValue, Error>] = [:]
    private var pendingMethods: [String: String] = [:]
    private var timeoutTasks: [String: Task<Void, Never>] = [:]

    init(url: URL, session: URLSession? = nil) {
        let streamPair = AsyncStream<HermesGatewayEvent>.makeStream(
            bufferingPolicy: .bufferingNewest(1_024)
        )
        events = streamPair.stream
        eventContinuation = streamPair.continuation
        endpointURL = url
        if let session {
            self.session = session
            ownsSession = false
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 30
            configuration.waitsForConnectivity = false
            self.session = URLSession(configuration: configuration)
            ownsSession = true
        }
    }

    deinit {
        receiveLoopTask?.cancel()
        pingLoopTask?.cancel()
        socket?.cancel(with: .goingAway, reason: nil)
        for task in timeoutTasks.values { task.cancel() }
        for continuation in pending.values {
            continuation.resume(throwing: HermesGatewayError.connectionClosed(code: nil))
        }
        eventContinuation.finish()
        if ownsSession { session.invalidateAndCancel() }
    }

    var isConnected: Bool { connected }

    /// Waits for the mandatory first `gateway.ready` event before returning.
    func connect(timeout: TimeInterval = 12) async throws {
        guard !permanentlyClosed else { throw HermesGatewayError.connectionClosed(code: nil) }
        guard !connected, socket == nil else { throw HermesGatewayError.alreadyConnected }

        let newSocket = session.webSocketTask(with: endpointURL)
        socket = newSocket
        newSocket.resume()

        do {
            let firstMessage = try await receiveFirst(from: newSocket, timeout: timeout)
            let envelope = try decodeEnvelope(from: firstMessage)
            guard let ready = envelope.gatewayEvent, ready.type == "gateway.ready" else {
                throw HermesGatewayError.expectedGatewayReady
            }
            guard socket === newSocket else { throw HermesGatewayError.connectionClosed(code: nil) }

            connected = true
            eventContinuation.yield(ready)
            receiveLoopTask = Task { [weak self] in
                await self?.runReceiveLoop(newSocket)
            }
            pingLoopTask = Task { [weak self] in
                await self?.runPingLoop(newSocket)
            }
        } catch {
            if socket === newSocket {
                socket = nil
                connected = false
            }
            newSocket.cancel(with: .protocolError, reason: nil)
            if let gatewayError = error as? HermesGatewayError { throw gatewayError }
            throw sanitizedTransportError(error)
        }
    }

    /// Reconnects with a newly minted ticket/token URL. Hermes tickets are
    /// single-use, so callers must never reuse the previous endpoint.
    func reconnect(to freshURL: URL, timeout: TimeInterval = 12) async throws {
        await disconnectCurrent(emitEvent: connected || socket != nil)
        endpointURL = freshURL
        try await connect(timeout: timeout)
    }

    /// Closes the current connection but keeps the event stream reusable for a
    /// later `reconnect(to:)` with a fresh ticket.
    func disconnect() async {
        await disconnectCurrent(emitEvent: false)
    }

    /// Permanently closes the socket and finishes `events`.
    func close() async {
        guard !permanentlyClosed else { return }
        permanentlyClosed = true
        await disconnectCurrent(emitEvent: false)
        eventContinuation.finish()
        if ownsSession { session.finishTasksAndInvalidate() }
    }

    // MARK: - Generic JSON-RPC

    /// Sends one JSON-RPC request and returns its dynamic `result` value.
    func request(
        method: String,
        params: HermesJSONObject = [:],
        timeout: TimeInterval = 30
    ) async throws -> HermesJSONValue {
        guard connected, let activeSocket = socket else {
            throw HermesGatewayError.notConnected
        }

        let identifier = UUID().uuidString
        let rpc = RPCRequest(
            jsonrpc: "2.0",
            id: .string(identifier),
            method: method,
            params: params
        )
        let data: Data
        do {
            data = try JSONEncoder().encode(rpc)
        } catch {
            throw HermesGatewayError.encoding(method: method)
        }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pending[identifier] = continuation
                pendingMethods[identifier] = method
                timeoutTasks[identifier] = Task { [weak self] in
                    do {
                        try await Task.sleep(nanoseconds: Self.nanoseconds(for: timeout))
                    } catch {
                        return
                    }
                    await self?.timeoutRequest(identifier)
                }
                Task { [weak self] in
                    await self?.send(data, requestID: identifier, over: activeSocket)
                }
            }
        } onCancel: {
            Task { [weak self] in
                await self?.cancelRequest(identifier)
            }
        }
    }

    func requestObject(
        method: String,
        params: HermesJSONObject = [:],
        timeout: TimeInterval = 30
    ) async throws -> HermesJSONObject {
        let result = try await request(method: method, params: params, timeout: timeout)
        guard let object = result.objectValue else {
            throw HermesGatewayError.invalidResult(method: method)
        }
        return object
    }

    func call<Result: Decodable & Sendable>(
        _ type: Result.Type,
        method: String,
        params: HermesJSONObject = [:],
        timeout: TimeInterval = 30
    ) async throws -> Result {
        let result = try await request(method: method, params: params, timeout: timeout)
        do {
            let data = try JSONEncoder().encode(result)
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw HermesGatewayError.decoding(method: method)
        }
    }

    // MARK: - Typed Hermes gateway operations

    func listSessions(limit: Int = 200) async throws -> HermesGatewaySessionListResponse {
        try await call(
            HermesGatewaySessionListResponse.self,
            method: "session.list",
            params: ["limit": .number(Double(max(1, min(limit, 500))))]
        )
    }

    func createSession(
        cwd: String? = nil,
        source: String = "desktop",
        cols: Int = 80
    ) async throws -> HermesSessionCreateResponse {
        var params: HermesJSONObject = [
            "source": .string(source),
            "cols": .number(Double(max(40, cols))),
            "close_on_disconnect": .bool(false),
        ]
        if let cwd, !cwd.isEmpty { params["cwd"] = .string(cwd) }
        return try await call(
            HermesSessionCreateResponse.self,
            method: "session.create",
            params: params
        )
    }

    /// `durableSessionID` is the stored ID from session.list/create, not an
    /// ephemeral event/RPC session_id.
    func resumeSession(
        durableSessionID: String,
        source: String = "desktop",
        cols: Int = 80
    ) async throws -> HermesSessionResumeResponse {
        try await call(
            HermesSessionResumeResponse.self,
            method: "session.resume",
            params: [
                "session_id": .string(durableSessionID),
                "source": .string(source),
                "cols": .number(Double(max(40, cols))),
                "close_on_disconnect": .bool(false),
            ]
        )
    }

    func sessionHistory(runtimeSessionID: String) async throws -> HermesSessionHistoryResponse {
        try await call(
            HermesSessionHistoryResponse.self,
            method: "session.history",
            params: ["session_id": .string(runtimeSessionID)]
        )
    }

    func submitPrompt(runtimeSessionID: String, text: String) async throws -> HermesPromptSubmitResponse {
        try await call(
            HermesPromptSubmitResponse.self,
            method: "prompt.submit",
            params: [
                "session_id": .string(runtimeSessionID),
                "text": .string(text),
            ]
        )
    }

    func interrupt(runtimeSessionID: String) async throws -> HermesRPCOKResponse {
        try await call(
            HermesRPCOKResponse.self,
            method: "session.interrupt",
            params: ["session_id": .string(runtimeSessionID)]
        )
    }

    /// Hermes approvals have no request_id. The server resolves the oldest
    /// pending approval for this runtime session, so the UI must preserve FIFO.
    func respondToApproval(
        runtimeSessionID: String,
        choice: String,
        resolveAll: Bool = false
    ) async throws -> HermesRPCOKResponse {
        try await call(
            HermesRPCOKResponse.self,
            method: "approval.respond",
            params: [
                "session_id": .string(runtimeSessionID),
                "choice": .string(choice),
                "all": .bool(resolveAll),
            ]
        )
    }

    func respondToClarification(
        runtimeSessionID: String,
        requestID: String,
        answer: String
    ) async throws -> HermesRPCOKResponse {
        try await call(
            HermesRPCOKResponse.self,
            method: "clarify.respond",
            params: [
                "session_id": .string(runtimeSessionID),
                "request_id": .string(requestID),
                "answer": .string(answer),
            ]
        )
    }

    func respondToSudo(
        runtimeSessionID: String,
        requestID: String,
        password: String
    ) async throws -> HermesRPCOKResponse {
        try await call(
            HermesRPCOKResponse.self,
            method: "sudo.respond",
            params: [
                "session_id": .string(runtimeSessionID),
                "request_id": .string(requestID),
                "password": .string(password),
            ]
        )
    }

    func respondToSecret(
        runtimeSessionID: String,
        requestID: String,
        value: String
    ) async throws -> HermesRPCOKResponse {
        try await call(
            HermesRPCOKResponse.self,
            method: "secret.respond",
            params: [
                "session_id": .string(runtimeSessionID),
                "request_id": .string(requestID),
                "value": .string(value),
            ]
        )
    }

    // MARK: - Receive/send machinery

    private func receiveFirst(
        from activeSocket: URLSessionWebSocketTask,
        timeout: TimeInterval
    ) async throws -> URLSessionWebSocketTask.Message {
        try await withThrowingTaskGroup(of: URLSessionWebSocketTask.Message.self) { group in
            group.addTask {
                try await activeSocket.receive()
            }
            group.addTask {
                try await Task.sleep(nanoseconds: Self.nanoseconds(for: timeout))
                // Cancelling only the Swift child task is not guaranteed to
                // wake URLSessionWebSocketTask.receive(). Actively closing the
                // upgrade makes the timeout bounded even when a proxy/VPS
                // accepts TCP but never completes the WebSocket handshake.
                activeSocket.cancel(with: .goingAway, reason: nil)
                throw HermesGatewayError.readyTimeout
            }
            guard let first = try await group.next() else {
                throw HermesGatewayError.readyTimeout
            }
            group.cancelAll()
            return first
        }
    }

    private func runReceiveLoop(_ activeSocket: URLSessionWebSocketTask) async {
        while !Task.isCancelled, connected, socket === activeSocket {
            do {
                let message = try await activeSocket.receive()
                try handle(message)
            } catch {
                if !Task.isCancelled {
                    await handleUnexpectedDisconnect(activeSocket, error: error)
                }
                return
            }
        }
    }

    private func runPingLoop(_ activeSocket: URLSessionWebSocketTask) async {
        while !Task.isCancelled, connected, socket === activeSocket {
            do {
                try await Task.sleep(nanoseconds: 25_000_000_000)
            } catch {
                return
            }
            guard connected, socket === activeSocket else { return }
            let succeeded = await sendPing(activeSocket)
            if !succeeded {
                await handleUnexpectedDisconnect(activeSocket, error: HermesGatewayError.transport(code: -1))
                return
            }
        }
    }

    private func sendPing(_ activeSocket: URLSessionWebSocketTask) async -> Bool {
        await withCheckedContinuation { continuation in
            let completion = HermesPingCompletion(continuation)
            activeSocket.sendPing { error in
                completion.resolve(error == nil)
            }
            let timeoutTask = Task {
                do {
                    try await Task.sleep(nanoseconds: 10_000_000_000)
                } catch {
                    return
                }
                // A half-open proxy can leave sendPing's callback suspended
                // forever. Close the upgrade so the receive loop also wakes
                // and AppState can mint a fresh ticket.
                activeSocket.cancel(with: .goingAway, reason: nil)
                completion.resolve(false)
            }
            completion.arm(timeoutTask)
        }
    }

    private func send(
        _ data: Data,
        requestID: String,
        over activeSocket: URLSessionWebSocketTask
    ) async {
        guard connected, socket === activeSocket else {
            failRequest(requestID, error: HermesGatewayError.notConnected)
            return
        }
        do {
            // Hermes' FastAPI gateway reads `receive_text()`. A binary frame
            // is a protocol violation even when its bytes contain valid JSON.
            try await activeSocket.send(Self.outboundRPCMessage(data))
        } catch {
            failRequest(requestID, error: sanitizedTransportError(error))
            await handleUnexpectedDisconnect(activeSocket, error: error)
        }
    }

    private func handle(_ message: URLSessionWebSocketTask.Message) throws {
        let envelope: HermesRPCEnvelope
        do {
            envelope = try decodeEnvelope(from: message)
        } catch {
            // A future server may add a non-JSON diagnostic frame. Ignore it
            // without taking down otherwise healthy sessions.
            eventContinuation.yield(HermesGatewayEvent(type: "client.protocol-warning"))
            return
        }

        if let event = envelope.gatewayEvent {
            eventContinuation.yield(event)
            return
        }

        guard let identifier = envelope.id?.stringValue else { return }
        guard let continuation = takePending(identifier) else { return }
        pendingMethods.removeValue(forKey: identifier)
        if let rpcError = envelope.error {
            continuation.resume(
                throwing: HermesGatewayError.rpc(code: rpcError.code, message: rpcError.message)
            )
        } else {
            continuation.resume(returning: envelope.result ?? .null)
        }
    }

    private func decodeEnvelope(from message: URLSessionWebSocketTask.Message) throws -> HermesRPCEnvelope {
        let data: Data
        switch message {
        case .data(let value): data = value
        case .string(let value): data = Data(value.utf8)
        @unknown default: throw HermesGatewayError.expectedGatewayReady
        }
        do {
            return try JSONDecoder().decode(HermesRPCEnvelope.self, from: data)
        } catch {
            throw HermesGatewayError.expectedGatewayReady
        }
    }

    private func timeoutRequest(_ identifier: String) {
        guard let continuation = takePending(identifier) else { return }
        let method = pendingMethods.removeValue(forKey: identifier) ?? "request"
        continuation.resume(throwing: HermesGatewayError.requestTimeout(method: method))
    }

    private func cancelRequest(_ identifier: String) {
        guard let continuation = takePending(identifier) else { return }
        pendingMethods.removeValue(forKey: identifier)
        continuation.resume(throwing: HermesGatewayError.requestCancelled)
    }

    private func failRequest(_ identifier: String, error: HermesGatewayError) {
        guard let continuation = takePending(identifier) else { return }
        pendingMethods.removeValue(forKey: identifier)
        continuation.resume(throwing: error)
    }

    private func takePending(_ identifier: String) -> CheckedContinuation<HermesJSONValue, Error>? {
        timeoutTasks.removeValue(forKey: identifier)?.cancel()
        return pending.removeValue(forKey: identifier)
    }

    private func failAllPending(_ error: HermesGatewayError) {
        let continuations = pending
        pending.removeAll()
        pendingMethods.removeAll()
        for task in timeoutTasks.values { task.cancel() }
        timeoutTasks.removeAll()
        for continuation in continuations.values {
            continuation.resume(throwing: error)
        }
    }

    private func handleUnexpectedDisconnect(
        _ activeSocket: URLSessionWebSocketTask,
        error: Error
    ) async {
        guard socket === activeSocket else { return }
        let closeCode = activeSocket.closeCode.rawValue
        connected = false
        socket = nil
        receiveLoopTask?.cancel()
        receiveLoopTask = nil
        pingLoopTask?.cancel()
        pingLoopTask = nil
        activeSocket.cancel(with: .goingAway, reason: nil)
        failAllPending(.connectionClosed(code: closeCode == 0 ? nil : closeCode))
        eventContinuation.yield(.disconnected(code: closeCode == 0 ? nil : closeCode))
        _ = error // Never interpolate the underlying error; it may contain the ticket URL.
    }

    private func disconnectCurrent(emitEvent: Bool) async {
        let previousSocket = socket
        let wasOpen = connected || previousSocket != nil
        connected = false
        socket = nil
        receiveLoopTask?.cancel()
        receiveLoopTask = nil
        pingLoopTask?.cancel()
        pingLoopTask = nil
        previousSocket?.cancel(with: .goingAway, reason: nil)
        failAllPending(.connectionClosed(code: nil))
        if emitEvent, wasOpen { eventContinuation.yield(.disconnected()) }
    }

    private func sanitizedTransportError(_ error: Error) -> HermesGatewayError {
        if let gatewayError = error as? HermesGatewayError { return gatewayError }
        return .transport(code: (error as NSError).code)
    }

    private static func nanoseconds(for interval: TimeInterval) -> UInt64 {
        guard interval.isFinite, interval > 0 else { return 1_000_000 }
        let capped = min(interval, 86_400)
        return UInt64(capped * 1_000_000_000)
    }

    /// Kept internal so protocol tests can assert the WebSocket opcode without
    /// opening a real socket.
    nonisolated static func outboundRPCMessage(_ data: Data) -> URLSessionWebSocketTask.Message {
        .string(String(decoding: data, as: UTF8.self))
    }
}

private struct RPCRequest: Encodable, Sendable {
    var jsonrpc: String
    var id: HermesRPCID
    var method: String
    var params: HermesJSONObject
}

private final class HermesPingCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Bool, Never>?
    private var timeoutTask: Task<Void, Never>?

    init(_ continuation: CheckedContinuation<Bool, Never>) {
        self.continuation = continuation
    }

    func arm(_ task: Task<Void, Never>) {
        lock.lock()
        if continuation == nil {
            lock.unlock()
            task.cancel()
            return
        }
        timeoutTask = task
        lock.unlock()
    }

    func resolve(_ result: Bool) {
        lock.lock()
        guard let continuation else {
            lock.unlock()
            return
        }
        self.continuation = nil
        let timeoutTask = self.timeoutTask
        self.timeoutTask = nil
        lock.unlock()
        timeoutTask?.cancel()
        continuation.resume(returning: result)
    }
}
