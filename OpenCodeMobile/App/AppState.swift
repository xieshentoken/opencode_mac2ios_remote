import SwiftUI
import Combine
import OSLog
import UserNotifications

// MARK: - AppState

private let log = Logger(subsystem: "dev.opencodemobile.app", category: "appstate")

/// File-backed debug log (readable from the host via `simctl get_app_container`).
enum DebugLog {
    static var url: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("debug.log")
    }
    static func write(_ msg: String) {
        #if DEBUG
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
}

/// Hermes 0.19.1 has no approval request IDs: both gateway events and replies
/// are ordered per session. Keep the queue operation explicit and testable so
/// concurrent agent threads cannot replace an older request with a newer card.
enum HermesApprovalFIFO {
    static func enqueue(_ request: PermissionRequest, into queue: inout [PermissionRequest]) {
        queue.append(request)
    }

    @discardableResult
    static func removeHead(
        expectedID: String? = nil,
        from queue: inout [PermissionRequest]
    ) -> Bool {
        guard let head = queue.first else { return false }
        if let expectedID, head.id != expectedID { return false }
        queue.removeFirst()
        return true
    }
}

@MainActor
final class AppState: ObservableObject {
    // Server
    @Published var servers: [ServerConfig] = []
    @Published var activeServer: ServerConfig?
    @Published var connectionState: ConnectionState = .disconnected
    @Published var serverVersion: String?
    @Published private(set) var transportMode: TransportMode = .serverSentEvents
    @Published private(set) var quickTunnelMayNeedPermission = false
    @Published private(set) var realtimeWarning: String?

    // Catalog
    @Published var providers: ProvidersResponse?
    @Published var agents: [Agent] = []
    @Published var projects: [Project] = []
    @Published var commands: [Command] = []
    @Published var skills: [Skill] = []
    @Published var selectedModel: ModelRef?
    @Published var selectedAgentID: String = "build"
    @Published var selectedVariant: String?
    /// Display assistant output as rendered markdown (default: source view).
    @Published var renderedMarkdown: Bool = false

    // Sessions (of the current server/directory)
    @Published var sessions: [Session] = []
    @Published var activeSessionID: String?

    // Messages of the active session
    @Published var messages: [Message] = []
    @Published var activeSessionRunning = false

    // Permissions awaiting approval
    @Published var pendingPermissions: [PermissionRequest] = []
    @Published var pendingInputRequests: [AgentInputRequest] = []

    // MCP servers on the Mac
    @Published var mcpStatuses: [String: MCPStatus] = [:]

    // Errors
    @Published var lastError: String?
    @Published var errorShown = false

    /// Active workspace directory (nil = server default instance).
    var activeDirectory: String?

    /// Whether the app is currently in the foreground. Set by the App from
    /// scenePhase; used to decide when to surface a permission request as a
    /// local notification.
    var isForeground = true

    #if DEBUG
    /// Set when launched with `-OCE2E`: run the scripted end-to-end flow.
    var e2eRequested = false
    private var debugSessionID: String?
    #endif

    /// Streams keyed by directory. Multiple directory-scoped SSE connections.
    private var streams: [String: EventStream] = [:]
    private var streamConsumerTasks: [String: Task<Void, Never>] = [:]

    /// One long-lived REST stack per active server. Recreating URLSession for
    /// every action prevents predictable HTTP/2/TLS connection reuse.
    private var connectionClient: OpenCodeClient?
    private var connectionAPI: OpenCodeAPI?

    /// Hermes uses its dashboard REST API for authentication/history and a
    /// JSON-RPC WebSocket for live control. Dashboard session IDs are durable;
    /// gateway session IDs are attachment-scoped and are rebuilt after every
    /// reconnect.
    private var hermesClient: HermesClient?
    private var hermesClientConfig: ServerConfig?
    private var hermesStatus: HermesStatus?
    private var hermesSocket: HermesGatewaySocket?
    private var hermesEventConsumerTask: Task<Void, Never>?
    private var hermesReconnectTask: Task<Void, Never>?
    private var hermesConnectionEpoch: UInt64 = 0
    private var hermesDurableToRuntime: [String: String] = [:]
    private var hermesRuntimeToDurable: [String: String] = [:]
    /// Compression can redirect a stored root ID to a descendant tip. Keep
    /// that alias locally so session.list/REST refreshes cannot re-introduce
    /// duplicate rows that point at the same live runtime.
    private var hermesDurableAliases: [String: String] = [:]
    private var hermesDesiredAttachments = Set<String>()
    private var hermesResumeTasks: [String: Task<HermesSessionResumeResponse, Error>] = [:]
    private var hermesApprovalQueues: [String: [PermissionRequest]] = [:]
    private var hermesApprovalSequence: UInt64 = 0
    private var hermesLiveMessageIDs: [String: String] = [:]
    private var hermesLiveToolParts: [String: (messageID: String, partID: String)] = [:]
    private var hermesCurrentToolIDs: [String: String] = [:]
    private var hermesLiveSequence: UInt64 = 0
    /// A resumed Hermes agent can emit events after its transport is rebound
    /// but before the session.resume response reaches the client. Never guess
    /// which durable session owns those events: keep a small, short-lived queue
    /// keyed by connection epoch and runtime ID, then replay after commit.
    private struct PendingHermesEvent {
        let event: HermesGatewayEvent
        let epoch: UInt64
        let receivedAt: Date
    }
    private var hermesPendingEvents: [String: [PendingHermesEvent]] = [:]
    private static let hermesPendingEventTTL: TimeInterval = 15
    private static let hermesPendingRuntimeLimit = 8
    private static let hermesPendingEventsPerRuntime = 64

    /// Last moment any SSE event (or heartbeat) arrived. Used to detect a
    /// buffered/blocked SSE path (e.g. Cloudflare quick tunnels) and fall back
    /// to REST polling while a task runs.
    private var lastSSEEventAt = Date()
    private var pollTask: Task<Void, Never>?
    private var loadMessagesTask: Task<Void, Never>?
    private var lastPolledMessageHash: Int?
    private var lastPolledMessageChangeAt = Date()
    private var pollSawBusy = false
    private var consecutiveIdlePolls = 0
    private var pollGeneration = 0

    private var sseSilent: Bool { Date().timeIntervalSince(lastSSEEventAt) > 20 }

    private struct DeltaKey: Hashable {
        let messageID: String
        let partID: String
    }

    private var pendingDeltas: [DeltaKey: String] = [:]
    private var deltaFlushTask: Task<Void, Never>?
    private var messageMutationRevision = 0

    /// The API client bound to the active server.
    var api: OpenCodeAPI? {
        connectionAPI
    }

    var client: OpenCodeClient? {
        connectionClient
    }

    var activeSession: Session? {
        guard let id = activeSessionID else { return nil }
        return sessions.first { $0.id == id }
    }

    var activeServerKind: ServerKind { activeServer?.kind ?? .openCode }
    var supportsOpenCodeFeatures: Bool { activeServerKind == .openCode }
    var canSendPrompts: Bool {
        connectionState == .connected && (activeServerKind == .openCode || transportMode == .webSocket)
    }
    var canMutateSessions: Bool {
        connectionState == .connected && (activeServerKind == .openCode || transportMode == .webSocket)
    }
    var canRespondToAgentRequests: Bool {
        connectionState == .connected
            && (activeServerKind == .openCode || transportMode == .webSocket)
    }

    init() {
        servers = KeychainStore.storedConfigs()
        activeServer = servers.first
        if let activeServer {
            self.activeServer = KeychainStore.resolvePassword(for: activeServer)
        }

        // Debug injection via launch arguments (simulator / CI testing).
        // Usage: -OCServerURL http://127.0.0.1:4096 -OCServerUser opencode -OCServerPass x
        let args = ProcessInfo.processInfo.arguments
        if let idx = args.firstIndex(of: "-OCServerURL"), args.indices.contains(idx + 1) {
            let url = args[idx + 1]
            let user = args.firstIndex(of: "-OCServerUser").flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } ?? "opencode"
            let pass = args.firstIndex(of: "-OCServerPass").flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } ?? ""
            let cfg = ServerConfig(name: "Debug", baseURL: url, username: user, password: pass)
            activeServer = cfg
            servers = [cfg]
        }
        if args.contains("-OCRendered") {
            renderedMarkdown = true
        }
        #if DEBUG
        e2eRequested = args.contains("-OCE2E")
        debugSessionID = args.firstIndex(of: "-OCSessionID").flatMap {
            $0 + 1 < args.count ? args[$0 + 1] : nil
        }
        #endif
    }

    // MARK: - Connection

    func connect() async {
        guard let server = activeServer, !server.baseURL.isEmpty else {
            connectionState = .disconnected
            return
        }
        transportMode = TransportMode.detect(baseURL: server.baseURL, kind: server.kind)
        quickTunnelMayNeedPermission = false
        realtimeWarning = nil
        switch server.kind {
        case .openCode:
            await connectOpenCode(server)
        case .hermes:
            await connectHermes(server)
        }
    }

    private func connectOpenCode(_ server: ServerConfig) async {
        await stopHermesTransport(invalidateClient: true)
        if connectionClient?.config != server {
            await stopStreams()
            connectionClient?.invalidate()
            let newClient = OpenCodeClient(config: server)
            connectionClient = newClient
            connectionAPI = OpenCodeAPI(client: newClient)
        }
        guard let client = connectionClient else { return }
        connectionState = .connecting
        log.info("connecting to \(server.baseURL, privacy: .public)")
        do {
            let health = try await client.health()
            guard connectionClient === client else { return }
            serverVersion = health.version
            log.info("health OK, version \(health.version, privacy: .public)")
            connectionState = .connected
            await openStreams()
            await refreshCatalog()
            await refreshSessions()
            #if DEBUG
            if let debugSessionID {
                await loadMessages(sessionID: debugSessionID)
            }
            #endif
            log.info("connect complete: \(self.sessions.count, privacy: .public) sessions, \(self.projects.count, privacy: .public) projects")
        } catch {
            guard connectionClient === client else { return }
            log.error("connect failed: \(error.localizedDescription, privacy: .public)")
            connectionState = .failed((error as? OpenCodeError)?.errorDescription ?? error.localizedDescription)
        }
    }

    private func connectHermes(_ server: ServerConfig) async {
        await stopStreams()
        cancelPolling()
        connectionClient?.invalidate()
        connectionClient = nil
        connectionAPI = nil

        if hermesClientConfig != server || hermesClient == nil {
            await stopHermesTransport(invalidateClient: true)
            do {
                hermesClient = try HermesClient(config: server)
                hermesClientConfig = server
            } catch {
                connectionState = .failed(error.localizedDescription)
                return
            }
        } else {
            await stopHermesSocket(preserveDesiredAttachments: true)
        }
        guard let client = hermesClient else { return }

        connectionState = .connecting
        log.info("connecting to Hermes at \(server.baseURL, privacy: .public)")
        do {
            let authentication = try await client.authenticate()
            guard activeServer?.id == server.id, hermesClient === client else { return }
            hermesStatus = authentication.status
            serverVersion = authentication.status.version

            do {
                try await openHermesGateway(client: client, status: authentication.status)
                guard activeServer?.id == server.id, hermesClient === client else { return }
                transportMode = .webSocket
                realtimeWarning = nil
                connectionState = .connected
                await restoreHermesAttachments()
            } catch {
                guard activeServer?.id == server.id, hermesClient === client else { return }
                enterHermesRESTFallback(reason: error)
                connectionState = .connected
                scheduleHermesReconnect(after: hermesConnectionEpoch)
            }
            await refreshSessions()
        } catch {
            guard activeServer?.id == server.id, hermesClient === client else { return }
            log.error("Hermes authentication failed: \(error.localizedDescription, privacy: .public)")
            connectionState = .failed(error.localizedDescription)
        }
    }

    /// Performs a full HTTP auth + gateway.ready probe without disturbing the
    /// active connection. A Hermes probe deliberately verifies WSS rather than
    /// accepting dashboard REST alone, because REST-only mode cannot execute.
    func probeServer(_ config: ServerConfig) async throws -> String {
        switch config.kind {
        case .openCode:
            let probe = OpenCodeClient(config: config)
            defer { probe.invalidate() }
            let health = try await probe.health()
            return "OpenCode \(health.version) · healthy"
        case .hermes:
            let probe = try HermesClient(config: config)
            defer { probe.invalidate() }
            let authentication = try await probe.authenticate()
            let socket = try await probe.makeGatewaySocket(for: authentication.status)
            do {
                try await socket.connect()
                await socket.close()
            } catch {
                await socket.close()
                throw error
            }
            return "Hermes \(authentication.status.version ?? "unknown") · gateway.ready"
        }
    }

    func disconnect() async {
        await stopStreams()
        await stopHermesTransport(invalidateClient: true)
        cancelPolling()
        loadMessagesTask?.cancel()
        loadMessagesTask = nil
        refreshTask?.cancel()
        refreshTask = nil
        cancelDeltaFlush(clearPending: true)
        connectionClient?.invalidate()
        connectionClient = nil
        connectionAPI = nil
        connectionState = .disconnected
        activeSessionRunning = false
        quickTunnelMayNeedPermission = false
        realtimeWarning = nil
        messages = []
        sessions = []
        // Keep pendingPermissions across a disconnect: SSE is severed on iOS
        // backgrounding and reopened on foreground, and the server-side task
        // keeps waiting for a reply. Dropping them here would orphan the
        // request. They are cleared only on an explicit server switch.
    }

    private func openHermesGateway(client: HermesClient, status: HermesStatus) async throws {
        await stopHermesSocket(preserveDesiredAttachments: true, cancelReconnect: false)
        let socket = try await client.makeGatewaySocket(for: status)
        hermesConnectionEpoch &+= 1
        let epoch = hermesConnectionEpoch
        hermesSocket = socket
        do {
            try await socket.connect()
        } catch {
            if hermesConnectionEpoch == epoch, hermesSocket === socket {
                hermesSocket = nil
            }
            await socket.close()
            throw error
        }
        guard hermesConnectionEpoch == epoch,
              hermesSocket === socket,
              hermesClient === client else {
            await socket.close()
            throw HermesGatewayError.requestCancelled
        }
        hermesEventConsumerTask = Task { [weak self] in
            for await event in socket.events {
                guard !Task.isCancelled else { return }
                self?.consumeHermes(event: event, epoch: epoch)
            }
        }
    }

    private func stopHermesSocket(
        preserveDesiredAttachments: Bool,
        cancelReconnect: Bool = true
    ) async {
        hermesConnectionEpoch &+= 1
        hermesEventConsumerTask?.cancel()
        hermesEventConsumerTask = nil
        if cancelReconnect {
            hermesReconnectTask?.cancel()
            hermesReconnectTask = nil
        }
        hermesResumeTasks.values.forEach { $0.cancel() }
        hermesResumeTasks.removeAll()
        let socket = hermesSocket
        hermesSocket = nil
        await socket?.close()
        hermesDurableToRuntime.removeAll()
        hermesRuntimeToDurable.removeAll()
        hermesPendingEvents.removeAll()
        hermesLiveMessageIDs.removeAll()
        hermesLiveToolParts.removeAll()
        hermesCurrentToolIDs.removeAll()
        if !preserveDesiredAttachments {
            hermesDesiredAttachments.removeAll()
            clearHermesInteractionState()
        }
    }

    private func stopHermesTransport(invalidateClient: Bool) async {
        await stopHermesSocket(preserveDesiredAttachments: !invalidateClient)
        hermesStatus = nil
        if invalidateClient {
            hermesClient?.invalidate()
            hermesClient = nil
            hermesClientConfig = nil
            hermesDurableAliases.removeAll()
        }
    }

    private func enterHermesRESTFallback(reason: Error) {
        transportMode = .restReadOnly
        realtimeWarning = "WebSocket unavailable; Hermes is read-only over dashboard REST. Prompts are never retried automatically."
        log.warning("Hermes gateway unavailable: \(reason.localizedDescription, privacy: .public)")
    }

    private func scheduleHermesReconnect(after epoch: UInt64) {
        guard hermesReconnectTask == nil, let client = hermesClient else { return }
        enterHermesRESTFallback(reason: HermesGatewayError.connectionClosed(code: nil))
        hermesReconnectTask = Task { [weak self] in
            let delays: [UInt64] = [1, 2, 4, 8, 15, 30]
            var attempt = 0
            while !Task.isCancelled {
                guard let self,
                      self.activeServerKind == .hermes,
                      self.hermesClient === client,
                      self.connectionState == .connected else { return }
                if attempt > 0 || self.hermesConnectionEpoch == epoch {
                    let seconds = delays[min(attempt, delays.count - 1)]
                    try? await Task.sleep(nanoseconds: seconds * 1_000_000_000)
                }
                guard !Task.isCancelled,
                      self.activeServerKind == .hermes,
                      self.hermesClient === client else { return }
                do {
                    let authentication = try await client.authenticate()
                    try await self.openHermesGateway(client: client, status: authentication.status)
                    self.hermesStatus = authentication.status
                    self.serverVersion = authentication.status.version
                    self.transportMode = .webSocket
                    self.realtimeWarning = nil
                    self.connectionState = .connected
                    await self.restoreHermesAttachments()
                    await self.refreshSessions()
                    if let id = self.activeSessionID {
                        await self.loadMessages(sessionID: id)
                    }
                    self.hermesReconnectTask = nil
                    return
                } catch {
                    guard !Task.isCancelled, self.hermesClient === client else { return }
                    self.enterHermesRESTFallback(reason: error)
                    await self.refreshHermesSessionsUsingREST(client: client, surfaceError: false)
                    attempt += 1
                }
            }
        }
    }

    private func restoreHermesAttachments() async {
        guard transportMode == .webSocket || hermesSocket != nil else { return }
        var durableIDs = Array(hermesDesiredAttachments)
        if let activeSessionID {
            durableIDs.removeAll { $0 == activeSessionID }
            durableIDs.insert(activeSessionID, at: 0)
        }
        for durableID in durableIDs {
            guard hermesSocket != nil else { return }
            do {
                let resumed = try await resumeHermesSession(durableID: durableID)
                if durableID == activeSessionID {
                    activeSessionRunning = resumed.running == true
                }
            } catch {
                // One missing/deleted history must not prevent other sessions
                // from being reattached after transport recovery.
                log.warning("Hermes session resume failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func clearHermesInteractionState() {
        hermesApprovalQueues.removeAll()
        pendingPermissions.removeAll { $0.backend == .hermes }
        pendingInputRequests.removeAll()
    }

    func switchServer(to server: ServerConfig) {
        Task {
            await disconnect()
            activeServer = server
            activeDirectory = nil
            activeSessionID = nil
            messages = []
            pendingPermissions = []
            pendingInputRequests = []
            await connect()
        }
    }

    /// The opencode server reports only the *current* project via GET /project
    /// (never a list), so the switch-project list is derived from real
    /// workspaces: the distinct session directories plus the current project.
    /// The degenerate filesystem-root project ("/") is excluded.
    func refreshProjects() async {
        guard supportsOpenCodeFeatures else {
            projects = []
            return
        }
        guard let api else { return }
        let requestedClient = api.client
        var byWorktree: [String: Project] = [:]
        if let all = try? await api.sessions(directory: nil) {
            for session in all {
                guard let directory = session.directory, !directory.isEmpty, directory != "/" else {
                    continue
                }
                if byWorktree[directory] == nil {
                    byWorktree[directory] = Project(
                        id: "dir-" + directory,
                        worktree: directory,
                        workspaceID: session.workspaceID,
                        status: nil
                    )
                }
            }
        }
        if let current = try? await api.projects() {
            for project in current {
                let worktree = project.worktree ?? project.id
                guard worktree != "/" else { continue }
                if byWorktree[worktree] == nil {
                    byWorktree[worktree] = project
                }
            }
        }
        guard connectionClient === requestedClient else { return }
        projects = byWorktree.values.sorted {
            ($0.worktree ?? $0.id) < ($1.worktree ?? $1.id)
        }
    }

    /// Switch the active workspace: stop all streams, reopen one scoped to the
    /// new directory, then reload its sessions.
    func switchProject(to worktree: String) async {
        guard supportsOpenCodeFeatures else { return }
        guard worktree != activeDirectory else { return }
        await stopStreams()
        cancelPolling()
        loadMessagesTask?.cancel()
        loadMessagesTask = nil
        refreshTask?.cancel()
        refreshTask = nil
        cancelDeltaFlush(clearPending: true)
        activeDirectory = worktree
        activeSessionID = nil
        activeSessionRunning = false
        messages = []
        // Same-server workspace switch: keep pending permission requests so a
        // task waiting for approval survives the directory-scoped stream swap.
        await openStreams()
        await refreshSessions()
    }

    // MARK: - Hermes gateway events

    private func consumeHermes(
        event: HermesGatewayEvent,
        epoch: UInt64,
        bufferIfUnmapped: Bool = true
    ) {
        guard activeServerKind == .hermes, epoch == hermesConnectionEpoch else { return }
        if event.type == "client.disconnected" {
            scheduleHermesReconnect(after: epoch)
            return
        }
        if event.type == "gateway.ready" {
            connectionState = .connected
            return
        }

        let runtimeID = event.sessionID
        let durableID = runtimeID.flatMap { hermesRuntimeToDurable[$0] }
        if let runtimeID, durableID == nil {
            if bufferIfUnmapped {
                bufferUnmappedHermesEvent(event, runtimeID: runtimeID, epoch: epoch)
            }
            return
        }

        switch event.type {
        case "message.start":
            guard let runtimeID, let durableID, durableID == activeSessionID else { return }
            messageMutationRevision &+= 1
            _ = beginHermesLiveMessage(runtimeID: runtimeID, durableID: durableID)
            activeSessionRunning = true

        case "message.delta":
            guard let runtimeID, let durableID, durableID == activeSessionID,
                  let text = event.text, !text.isEmpty else { return }
            messageMutationRevision &+= 1
            let messageID = currentHermesLiveMessage(runtimeID: runtimeID, durableID: durableID)
            enqueueDelta(
                sessionID: durableID,
                messageID: messageID,
                partID: "\(messageID)-text",
                delta: text
            )
            activeSessionRunning = true

        case "message.interim":
            guard event.payload["already_streamed"]?.boolValue != true,
                  let runtimeID, let durableID, durableID == activeSessionID,
                  let text = event.text, !text.isEmpty else { return }
            messageMutationRevision &+= 1
            let messageID = currentHermesLiveMessage(runtimeID: runtimeID, durableID: durableID)
            enqueueDelta(
                sessionID: durableID,
                messageID: messageID,
                partID: "\(messageID)-text",
                delta: text
            )

        case "thinking.delta", "reasoning.delta":
            guard let runtimeID, let durableID, durableID == activeSessionID,
                  let text = event.text, !text.isEmpty else { return }
            messageMutationRevision &+= 1
            let messageID = currentHermesLiveMessage(runtimeID: runtimeID, durableID: durableID)
            enqueueDelta(
                sessionID: durableID,
                messageID: messageID,
                partID: "\(messageID)-reasoning",
                delta: text
            )

        case "message.complete":
            guard let runtimeID, let durableID, durableID == activeSessionID else { return }
            messageMutationRevision &+= 1
            let messageID = currentHermesLiveMessage(runtimeID: runtimeID, durableID: durableID)
            flushPendingDeltas(sessionID: durableID)
            if let text = event.text, !text.isEmpty {
                upsertPart(
                    Part(
                        id: "\(messageID)-text",
                        sessionID: durableID,
                        messageID: messageID,
                        type: "text",
                        text: text,
                        time: MessageTime(
                            created: messages.first(where: { $0.id == messageID })?.info.time?.created,
                            completed: Int(Date().timeIntervalSince1970 * 1_000),
                            updated: Int(Date().timeIntervalSince1970 * 1_000)
                        )
                    ),
                    messageID: messageID
                )
            }
            if let reasoning = event.payload["reasoning"]?.stringValue, !reasoning.isEmpty {
                upsertPart(
                    Part(
                        id: "\(messageID)-reasoning",
                        sessionID: durableID,
                        messageID: messageID,
                        type: "reasoning",
                        text: reasoning
                    ),
                    messageID: messageID
                )
            }
            activeSessionRunning = false
            clearHermesInteractions(runtimeID: runtimeID)
            reconcileHermesTranscriptSoon(durableID: durableID, epoch: epoch)
            refreshSessionsTask()

        case "tool.start":
            guard let runtimeID, let durableID, durableID == activeSessionID else { return }
            messageMutationRevision &+= 1
            let messageID = currentHermesLiveMessage(runtimeID: runtimeID, durableID: durableID)
            let toolID = event.payload["tool_id"]?.stringValue
                ?? event.payload["call_id"]?.stringValue
                ?? UUID().uuidString
            let partID = "hermes-tool-\(toolID)"
            hermesLiveToolParts["\(runtimeID):\(toolID)"] = (messageID, partID)
            hermesCurrentToolIDs[runtimeID] = toolID
            upsertPart(
                Part(
                    id: partID,
                    sessionID: durableID,
                    messageID: messageID,
                    type: "tool",
                    state: .running,
                    tool: event.payload["name"]?.stringValue ?? "tool",
                    callID: toolID,
                    input: event.payload["args_text"]?.stringValue.map(JSONValue.string)
                ),
                messageID: messageID
            )
            activeSessionRunning = true

        case "tool.progress":
            guard let runtimeID, let durableID, durableID == activeSessionID else { return }
            let toolID = event.payload["tool_id"]?.stringValue
                ?? event.payload["call_id"]?.stringValue
            updateHermesToolPart(
                runtimeID: runtimeID,
                toolID: toolID,
                name: event.payload["name"]?.stringValue,
                output: event.payload["preview"]?.stringValue,
                state: .running,
                durableID: durableID
            )

        case "tool.complete":
            guard let runtimeID, let durableID, durableID == activeSessionID else { return }
            messageMutationRevision &+= 1
            let toolID = event.payload["tool_id"]?.stringValue
                ?? event.payload["call_id"]?.stringValue
            let output = event.payload["result_text"]?.stringValue
                ?? event.payload["summary"]?.stringValue
                ?? event.payload["result"].map(hermesDisplayText)
                ?? event.payload["error"]?.stringValue
            let failed = event.payload["error"] != nil
                && event.payload["error"] != .null
            updateHermesToolPart(
                runtimeID: runtimeID,
                toolID: toolID,
                name: event.payload["name"]?.stringValue,
                output: output,
                state: failed ? .error : .completed,
                durableID: durableID,
                durationSeconds: event.payload["duration_s"]?.doubleValue
            )
            if hermesCurrentToolIDs[runtimeID] == toolID {
                hermesCurrentToolIDs.removeValue(forKey: runtimeID)
            }

        case "approval.request":
            guard let runtimeID, let durableID,
                  let approval = HermesApprovalRequest(event: event) else { return }
            hermesApprovalSequence &+= 1
            let request = PermissionRequest(
                id: "hermes-approval-\(hermesConnectionEpoch)-\(hermesApprovalSequence)",
                sessionID: durableID,
                backend: .hermes,
                runtimeSessionID: runtimeID,
                directory: nil,
                permission: "command",
                patterns: approval.command.isEmpty ? nil : [approval.command],
                metadata: [
                    "command": .string(approval.command),
                    "description": .string(approval.description),
                ],
                always: approval.allowPermanent ? ["permanent"] : nil,
                tool: nil
            )
            // Hermes can run multiple agent threads under one durable session.
            // approval.respond resolves the server-side FIFO and carries no
            // request ID, so replacing A with a newer B would display B while
            // actually approving A. Preserve arrival order and expose only A.
            var queue = hermesApprovalQueues[runtimeID] ?? []
            let becameHead = queue.isEmpty
            HermesApprovalFIFO.enqueue(request, into: &queue)
            hermesApprovalQueues[runtimeID] = queue
            syncHermesPermissionHeads()
            if becameHead { notifyPermissionIfNeeded(request) }

        case "approval.expired", "approval.cancelled":
            guard let runtimeID else { return }
            if var queue = hermesApprovalQueues[runtimeID] {
                HermesApprovalFIFO.removeHead(from: &queue)
                if queue.isEmpty {
                    hermesApprovalQueues.removeValue(forKey: runtimeID)
                } else {
                    hermesApprovalQueues[runtimeID] = queue
                }
            }
            syncHermesPermissionHeads()
            if let next = hermesApprovalQueues[runtimeID]?.first {
                notifyPermissionIfNeeded(next)
            }

        case "clarify.request", "sudo.request", "secret.request":
            guard let runtimeID, let durableID,
                  let input = HermesInputRequest(event: event) else { return }
            let kind: AgentInputKind
            switch input.kind {
            case .clarify: kind = .clarify
            case .sudo: kind = .sudo
            case .secret: kind = .secret
            }
            let request = AgentInputRequest(
                id: input.id,
                sessionID: durableID,
                runtimeSessionID: runtimeID,
                kind: kind,
                prompt: input.prompt,
                choices: input.choices,
                multiSelect: event.payload["multi_select"]?.boolValue ?? false
            )
            pendingInputRequests.removeAll { $0.id == request.id }
            pendingInputRequests.append(request)

        case "clarify.expire", "clarify.expired", "clarify.resolved",
             "sudo.expire", "sudo.expired", "sudo.resolved",
             "secret.expire", "secret.expired", "secret.resolved":
            if let requestID = event.requestID {
                pendingInputRequests.removeAll { $0.id == requestID }
            }

        case "session.info", "session.status":
            guard let durableID, durableID == activeSessionID else { return }
            let info = event.payload["info"]?.objectValue ?? event.payload
            if let status = event.payload["status"]?.stringValue {
                activeSessionRunning = ["busy", "running", "streaming"].contains(status.lowercased())
            } else if let running = event.payload["running"]?.boolValue {
                activeSessionRunning = running
            }
            updateHermesSessionInfo(durableID: durableID, info: info)

        case "session.closed", "session.ended":
            guard let runtimeID, let durableID else { return }
            clearHermesInteractions(runtimeID: runtimeID)
            hermesRuntimeToDurable.removeValue(forKey: runtimeID)
            hermesDurableToRuntime.removeValue(forKey: durableID)
            if durableID == activeSessionID { activeSessionRunning = false }

        case "error":
            if let runtimeID { clearHermesInteractions(runtimeID: runtimeID) }
            if let durableID, durableID == activeSessionID {
                activeSessionRunning = false
            }
            if let message = event.text, !message.isEmpty {
                lastError = message
            }

        default:
            break
        }
    }

    private func bufferUnmappedHermesEvent(
        _ event: HermesGatewayEvent,
        runtimeID: String,
        epoch: UInt64
    ) {
        let now = Date()
        let cutoff = now.addingTimeInterval(-Self.hermesPendingEventTTL)
        hermesPendingEvents = hermesPendingEvents.compactMapValues { queue in
            let fresh = queue.filter { $0.epoch == epoch && $0.receivedAt >= cutoff }
            return fresh.isEmpty ? nil : fresh
        }
        if hermesPendingEvents[runtimeID] == nil,
           hermesPendingEvents.count >= Self.hermesPendingRuntimeLimit,
           let oldestRuntime = hermesPendingEvents.min(by: {
               ($0.value.first?.receivedAt ?? .distantFuture)
                   < ($1.value.first?.receivedAt ?? .distantFuture)
           })?.key {
            hermesPendingEvents.removeValue(forKey: oldestRuntime)
        }
        var queue = hermesPendingEvents[runtimeID] ?? []
        if queue.count >= Self.hermesPendingEventsPerRuntime {
            queue.removeFirst(queue.count - Self.hermesPendingEventsPerRuntime + 1)
        }
        queue.append(PendingHermesEvent(event: event, epoch: epoch, receivedAt: now))
        hermesPendingEvents[runtimeID] = queue
    }

    private func replayPendingHermesEvents(runtimeID: String, epoch: UInt64) {
        guard let queue = hermesPendingEvents.removeValue(forKey: runtimeID) else { return }
        let cutoff = Date().addingTimeInterval(-Self.hermesPendingEventTTL)
        for pending in queue where pending.epoch == epoch && pending.receivedAt >= cutoff {
            consumeHermes(event: pending.event, epoch: epoch, bufferIfUnmapped: false)
        }
    }

    private func beginHermesLiveMessage(runtimeID: String, durableID: String) -> String {
        hermesLiveSequence &+= 1
        let messageID = "hermes-live-\(hermesConnectionEpoch)-\(hermesLiveSequence)"
        hermesLiveMessageIDs[runtimeID] = messageID
        let now = Int(Date().timeIntervalSince1970 * 1_000)
        let info = MessageInfo(
            id: messageID,
            sessionID: durableID,
            role: "assistant",
            modelID: activeSession?.model?.id ?? "hermes",
            providerID: "hermes",
            agent: "hermes",
            time: MessageTime(created: now, updated: now)
        )
        upsertMessageInfo(info)
        return messageID
    }

    private func currentHermesLiveMessage(runtimeID: String, durableID: String) -> String {
        hermesLiveMessageIDs[runtimeID]
            ?? beginHermesLiveMessage(runtimeID: runtimeID, durableID: durableID)
    }

    private func updateHermesToolPart(
        runtimeID: String,
        toolID: String?,
        name: String?,
        output: String?,
        state: PartState,
        durableID: String,
        durationSeconds: Double? = nil
    ) {
        let resolvedToolID = toolID ?? hermesCurrentToolIDs[runtimeID]
        let key = resolvedToolID.map { "\(runtimeID):\($0)" }
        let location = key.flatMap { hermesLiveToolParts[$0] }
        let messageID = location?.messageID
            ?? currentHermesLiveMessage(runtimeID: runtimeID, durableID: durableID)
        let partID = location?.partID ?? "hermes-tool-\(resolvedToolID ?? UUID().uuidString)"
        var part = messages
            .first(where: { $0.id == messageID })?.parts?
            .first(where: { $0.id == partID })
            ?? Part(
                id: partID,
                sessionID: durableID,
                messageID: messageID,
                type: "tool",
                state: state,
                tool: name ?? "tool",
                callID: resolvedToolID
            )
        part.state = state
        part.tool = name ?? part.tool
        if let output { part.output = .string(output) }
        if let durationSeconds { part.duration = Int(durationSeconds * 1_000) }
        upsertPart(part, messageID: messageID)
    }

    private func hermesDisplayText(_ value: HermesJSONValue) -> String {
        if let string = value.stringValue { return string }
        let converted = hermesJSONValue(value)
        guard let data = try? JSONSerialization.data(
            withJSONObject: converted.anyValue,
            options: [.sortedKeys]
        ) else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }

    private func updateHermesSessionInfo(durableID: String, info: HermesJSONObject) {
        guard let index = sessions.firstIndex(where: { $0.id == durableID }) else { return }
        if let cwd = info["cwd"]?.stringValue { sessions[index].directory = cwd }
        if let model = info["model"]?.stringValue { sessions[index].model = hermesModelRef(model) }
        sessions[index].time?.updated = Int(Date().timeIntervalSince1970 * 1_000)
    }

    private func reconcileHermesTranscriptSoon(durableID: String, epoch: UInt64) {
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard let self,
                  self.hermesConnectionEpoch == epoch,
                  self.activeSessionID == durableID else { return }
            await self.loadMessages(sessionID: durableID)
        }
    }

    private func syncHermesPermissionHeads() {
        pendingPermissions.removeAll { $0.backend == .hermes }
        let heads = hermesApprovalQueues.values.compactMap(\.first).sorted {
            let lhsActive = $0.sessionID == activeSessionID
            let rhsActive = $1.sessionID == activeSessionID
            if lhsActive != rhsActive { return lhsActive }
            return $0.id < $1.id
        }
        pendingPermissions.append(contentsOf: heads)
    }

    private func clearHermesInteractions(runtimeID: String) {
        hermesApprovalQueues.removeValue(forKey: runtimeID)
        pendingInputRequests.removeAll { $0.runtimeSessionID == runtimeID }
        syncHermesPermissionHeads()
    }

    // MARK: - SSE

    /// Open the event stream for the active directory (or nil/default).
    func openStreams() async {
        guard transportMode == .serverSentEvents, let client else { return }

        // The key one: stream scoped to the active directory.
        let key = activeDirectory ?? ""
        if streams[key] == nil {
            let stream = EventStream(directory: activeDirectory, client: client)
            streams[key] = stream
            let events = await stream.events()
            let sourceDirectory = activeDirectory
            streamConsumerTasks[key] = Task {
                await consume(events: events, sourceDirectory: sourceDirectory)
            }
            await stream.start()
        }
    }

    private func stopStreams() async {
        streamConsumerTasks.values.forEach { $0.cancel() }
        streamConsumerTasks.removeAll()
        let activeStreams = Array(streams.values)
        streams.removeAll()
        for stream in activeStreams {
            await stream.stop()
        }
    }

    private func consume(events: AsyncStream<SSEEvent>, sourceDirectory: String?) async {
        for await event in events {
            handle(event: event, sourceDirectory: sourceDirectory)
        }
    }

    private func handle(event: SSEEvent, sourceDirectory: String?) {
        lastSSEEventAt = Date()
        let props = event.properties ?? [:]
        if event.type.hasPrefix("message.") {
            messageMutationRevision &+= 1
        }

        #if DEBUG
        log.info("SSE event: \(event.type, privacy: .public)")
        #endif

        switch event.type {
        case "server.connected":
            connectionState = .connected

        case "client.reconnected":
            Task { await reconcileAfterStreamReconnect() }

        case "session.status":
            if let e = props.decode(SessionStatusEvent.self) {
                if e.sessionID == activeSessionID {
                    activeSessionRunning = e.status?.running ?? false
                    if activeSessionRunning {
                        startPollingIfNeeded()
                    } else {
                        cancelPolling()
                    }
                }
            }

        case "busy":
            if let sessionID = props["sessionID"]?.stringValue {
                if sessionID == activeSessionID {
                    activeSessionRunning = true
                    startPollingIfNeeded()
                }
            }

        case "idle", "session.idle":
            if let sessionID = props["sessionID"]?.stringValue {
                if sessionID == activeSessionID {
                    flushPendingDeltas()
                    activeSessionRunning = false
                    cancelPolling()
                    quickTunnelMayNeedPermission = false
                }
            }

        case "message.updated":
            if let e = props.decode(MessageUpdatedEvent.self),
               e.sessionID == activeSessionID, let info = e.info {
                upsertMessageInfo(info)
            }

        case "message.part.updated":
            if let e = props.decode(MessagePartUpdatedEvent.self),
               e.sessionID == activeSessionID, let part = e.part {
                upsertPart(part, messageID: e.messageID)
            }

        case "message.part.delta":
            if let e = props.decode(MessagePartDeltaEvent.self),
               e.sessionID == activeSessionID, e.field == "text" {
                enqueueDelta(
                    sessionID: e.sessionID,
                    messageID: e.messageID,
                    partID: e.partID,
                    delta: e.delta ?? ""
                )
            }

        case "message.removed":
            if let e = props.decode(MessageRemovedEvent.self), e.sessionID == activeSessionID, let mid = e.messageID {
                messages.removeAll { $0.info.id == mid }
            }

        case "message.part.removed":
            if let e = props.decode(MessagePartRemovedEvent.self),
               e.sessionID == activeSessionID, let mid = e.messageID, let pid = e.partID {
                if let idx = messages.firstIndex(where: { $0.info.id == mid }) {
                    messages[idx].parts?.removeAll { $0.id == pid }
                }
            }

        case "permission.asked":
            if let e = props.decode(PermissionAskedEvent.self), let id = e.id {
                DebugLog.write("PERMISSION.asked id=\(id) perm=\(e.permission ?? "?")")
                let req = PermissionRequest(
                    id: id,
                    sessionID: e.sessionID,
                    directory: sourceDirectory,
                    permission: e.permission,
                    patterns: e.patterns,
                    metadata: e.metadata,
                    always: e.always,
                    tool: e.tool
                )
                if !pendingPermissions.contains(where: { $0.id == req.id }) {
                    pendingPermissions.append(req)
                    notifyPermissionIfNeeded(req)
                }
            }

        case "permission.replied":
            if let e = props.decode(PermissionRepliedEvent.self), let rid = e.requestID {
                pendingPermissions.removeAll { $0.id == rid }
            }

        case "session.updated", "session.created":
            refreshSessionsTask()

        case "session.deleted":
            if let e = props.decode(SessionDeletedEvent.self) {
                sessions.removeAll { $0.id == e.sessionID }
                if activeSessionID == e.sessionID {
                    activeSessionID = nil
                    messages = []
                }
            }

        case "session.diff":
            // Summaries arrive via session.updated; ignore raw diffs for now.
            break

        default:
            break
        }
    }

    // MARK: - Message mutation helpers

    private func upsertMessageInfo(_ info: MessageInfo) {
        if info.role == "user", !info.id.hasPrefix("local-") {
            // Only one prompt can be in flight for the active session. Replace
            // its optimistic echo as soon as the authoritative user message
            // arrives over SSE.
            messages.removeAll {
                $0.info.id.hasPrefix("local-") && $0.info.sessionID == info.sessionID
            }
        }
        if let idx = messages.firstIndex(where: { $0.info.id == info.id }) {
            messages[idx].info = info
        } else {
            messages.append(Message(info: info, parts: []))
        }
        sortMessagesChronologically()
    }

    private func upsertPart(_ incomingPart: Part, messageID: String? = nil) {
        let mid = messageID ?? incomingPart.messageID ?? currentMessageID(for: incomingPart)
        guard let mid else { return }

        var part = incomingPart
        part.messageID = mid
        part.sessionID = part.sessionID ?? activeSessionID
        pendingDeltas.removeValue(forKey: DeltaKey(messageID: mid, partID: part.id))

        ensureMessageExists(id: mid, sessionID: part.sessionID)
        guard let mi = messages.firstIndex(where: { $0.info.id == mid }) else { return }
        var parts = messages[mi].parts ?? []
        if let pi = parts.firstIndex(where: { $0.id == part.id }) {
            parts[pi] = part
        } else {
            parts.append(part)
            parts.sort { ($0.time?.created ?? 0) < ($1.time?.created ?? 0) }
        }
        messages[mi].parts = parts
    }

    private func enqueueDelta(sessionID: String?, messageID: String?, partID: String?, delta: String) {
        guard !delta.isEmpty, let partID else { return }
        let resolvedMessageID = messageID
            ?? messages.reversed().first(where: { $0.info.role == "assistant" })?.info.id
        guard let resolvedMessageID else { return }
        let key = DeltaKey(messageID: resolvedMessageID, partID: partID)
        pendingDeltas[key, default: ""] += delta
        guard deltaFlushTask == nil else { return }
        deltaFlushTask = Task {
            try? await Task.sleep(nanoseconds: 50_000_000)
            guard !Task.isCancelled else { return }
            flushPendingDeltas(sessionID: sessionID)
        }
    }

    private func flushPendingDeltas(sessionID: String? = nil) {
        deltaFlushTask?.cancel()
        deltaFlushTask = nil
        let batch = pendingDeltas
        pendingDeltas.removeAll(keepingCapacity: true)
        for (key, delta) in batch {
            appendDelta(
                sessionID: sessionID ?? activeSessionID,
                messageID: key.messageID,
                partID: key.partID,
                delta: delta
            )
        }
    }

    private func cancelDeltaFlush(clearPending: Bool) {
        deltaFlushTask?.cancel()
        deltaFlushTask = nil
        if clearPending {
            pendingDeltas.removeAll()
        }
    }

    private func appendDelta(sessionID: String?, messageID: String, partID: String, delta: String) {
        ensureMessageExists(id: messageID, sessionID: sessionID)
        guard let mi = messages.firstIndex(where: { $0.info.id == messageID }) else { return }
        var parts = messages[mi].parts ?? []
        guard let pi = parts.firstIndex(where: { $0.id == partID }) else {
            // Create a stub part so deltas still stream before part.updated lands.
            parts.append(Part(id: partID, sessionID: sessionID, messageID: messageID, type: "text", text: delta))
            parts.sort { ($0.time?.created ?? 0) < ($1.time?.created ?? 0) }
            messages[mi].parts = parts
            return
        }
        parts[pi].text = (parts[pi].text ?? "") + delta
        messages[mi].parts = parts
    }

    private func ensureMessageExists(id: String, sessionID: String?) {
        guard !messages.contains(where: { $0.info.id == id }) else { return }
        let now = Int(Date().timeIntervalSince1970 * 1_000)
        let info = MessageInfo(
            id: id,
            sessionID: sessionID,
            role: "assistant",
            time: MessageTime(created: now, updated: now)
        )
        messages.append(Message(info: info, parts: []))
        sortMessagesChronologically()
    }

    private func currentMessageID(for part: Part) -> String? {
        if let messageID = part.messageID { return messageID }
        for message in messages.reversed() where message.info.role == "assistant" {
            if message.parts?.contains(where: { $0.id == part.id }) == true {
                return message.info.id
            }
        }
        return messages.last?.info.id
    }

    private func appendOptimisticUserMessage(text: String, sessionID: String) -> String {
        let messageID = "local-\(UUID().uuidString)"
        let now = Int(Date().timeIntervalSince1970 * 1_000)
        let info = MessageInfo(
            id: messageID,
            sessionID: sessionID,
            role: "user",
            time: MessageTime(created: now, updated: now)
        )
        let part = Part(
            id: "local-part-\(UUID().uuidString)",
            sessionID: sessionID,
            messageID: messageID,
            type: "text",
            text: text
        )
        messages.append(Message(info: info, parts: [part]))
        return messageID
    }

    private func mergeRemoteMessages(
        _ remote: [Message],
        replacing: Bool,
        preserveLocalProgress: Bool = false
    ) {
        let localBeforeMerge = messages
        let optimistic = localBeforeMerge.filter { $0.info.id.hasPrefix("local-") }
        var merged = replacing
            ? remote
            : localBeforeMerge.filter { !$0.info.id.hasPrefix("local-") }

        if !replacing {
            var indexes = Dictionary(uniqueKeysWithValues: merged.enumerated().map { ($0.element.id, $0.offset) })
            for message in remote {
                if let index = indexes[message.id] {
                    merged[index] = message
                } else {
                    indexes[message.id] = merged.count
                    merged.append(message)
                }
            }
        }

        if preserveLocalProgress {
            let liveByID = Dictionary(
                uniqueKeysWithValues: localBeforeMerge
                    .filter { !$0.info.id.hasPrefix("local-") }
                    .map { ($0.id, $0) }
            )
            var mergedIDs = Set<String>()
            for index in merged.indices {
                let id = merged[index].id
                mergedIDs.insert(id)
                if let live = liveByID[id] {
                    merged[index] = mergeSnapshot(authoritative: merged[index], live: live)
                }
            }
            for live in localBeforeMerge where
                !live.info.id.hasPrefix("local-") && !mergedIDs.contains(live.id) {
                merged.append(live)
            }
        }

        let retainedOptimistic = optimistic.filter { local in
            let localText = local.parts?.compactMap(\.text).joined() ?? ""
            let localCreated = local.info.time?.created ?? 0
            return !remote.contains { candidate in
                guard candidate.info.role == "user" else { return false }
                let candidateText = candidate.parts?.compactMap(\.text).joined() ?? ""
                let candidateCreated = candidate.info.time?.created ?? 0
                return candidateText == localText && abs(candidateCreated - localCreated) < 60_000
            }
        }
        // REST already returns messages in server order (newest-N, ascending
        // within the page). Preserve that order instead of round-tripping via a
        // Dictionary and randomly reordering equal/missing timestamps.
        messages = merged + retainedOptimistic
    }

    private func mergeSnapshot(authoritative: Message, live: Message) -> Message {
        var result = authoritative
        var parts = authoritative.parts ?? []
        var indexes = Dictionary(uniqueKeysWithValues: parts.enumerated().map { ($0.element.id, $0.offset) })
        for livePart in live.parts ?? [] {
            guard let index = indexes[livePart.id] else {
                indexes[livePart.id] = parts.count
                parts.append(livePart)
                continue
            }
            var selected = parts[index]
            let authoritativeUpdated = selected.time?.updated ?? selected.time?.completed ?? 0
            let liveUpdated = livePart.time?.updated ?? livePart.time?.completed ?? 0
            if liveUpdated > authoritativeUpdated {
                selected = livePart
            }
            selected.text = mergeAppendOnlyText(authoritative: parts[index].text, live: livePart.text)
            parts[index] = selected
        }
        result.parts = parts
        if (live.info.time?.updated ?? 0) > (authoritative.info.time?.updated ?? 0) {
            result.info = live.info
        }
        return result
    }

    private func mergeAppendOnlyText(authoritative: String?, live: String?) -> String? {
        guard let authoritative else { return live }
        guard let live else { return authoritative }
        if authoritative == live { return authoritative }
        if live.hasPrefix(authoritative) { return live }
        if authoritative.hasPrefix(live) || authoritative.contains(live) { return authoritative }

        let maximumOverlap = min(authoritative.count, live.count)
        for length in stride(from: maximumOverlap, through: 1, by: -1) {
            if authoritative.suffix(length) == live.prefix(length) {
                return authoritative + live.dropFirst(length)
            }
        }
        // Text and reasoning parts are append-only in the verified protocol.
        // A non-overlapping live fragment is therefore the post-snapshot tail.
        return authoritative + live
    }

    private func sortMessagesChronologically() {
        messages = messages.enumerated().sorted { lhs, rhs in
            let left = lhs.element.info.time?.created
            let right = rhs.element.info.time?.created
            switch (left, right) {
            case let (l?, r?) where l != r: return l < r
            default: return lhs.offset < rhs.offset
            }
        }.map(\.element)
    }

    private func messageHash(_ messages: [Message]) -> Int {
        var hasher = Hasher()
        hasher.combine(messages)
        return hasher.finalize()
    }

    // MARK: - Data refresh

    private var refreshTask: Task<Void, Never>?

    private func refreshSessionsTask() {
        refreshTask?.cancel()
        refreshTask = Task {
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            await refreshSessions()
        }
    }

    private func refreshHermesSessions() async {
        guard let client = hermesClient else { return }
        if transportMode == .webSocket, let socket = hermesSocket,
           await socket.isConnected {
            do {
                let response = try await socket.listSessions(limit: 200)
                guard activeServerKind == .hermes,
                      hermesClient === client,
                      hermesSocket === socket else { return }
                applyHermesSessions(response.sessions.map(hermesSession))
                return
            } catch {
                if !(await socket.isConnected) {
                    let epoch = hermesConnectionEpoch
                    enterHermesRESTFallback(reason: error)
                    scheduleHermesReconnect(after: epoch)
                }
            }
        }
        await refreshHermesSessionsUsingREST(client: client, surfaceError: true)
    }

    private func refreshHermesSessionsUsingREST(
        client: HermesClient,
        surfaceError: Bool
    ) async {
        do {
            let response = try await client.sessions(limit: 200)
            guard activeServerKind == .hermes, hermesClient === client else { return }
            applyHermesSessions(response.sessions.map(hermesSession))
        } catch {
            if surfaceError, activeServerKind == .hermes, hermesClient === client {
                setError(error)
            }
        }
    }

    private func applyHermesSessions(_ incoming: [Session]) {
        if let activeSessionID {
            self.activeSessionID = canonicalHermesDurableID(activeSessionID)
        }
        var existing: [String: Session] = [:]
        for var item in sessions {
            item.id = canonicalHermesDurableID(item.id)
            existing[item.id] = mergeHermesSession(primary: existing[item.id] ?? item, fallback: item)
        }
        var incomingByID: [String: Session] = [:]
        for var candidate in incoming where !candidate.id.isEmpty {
            candidate.id = canonicalHermesDurableID(candidate.id)
            if let prior = incomingByID[candidate.id] {
                let candidateIsNewer = (candidate.time?.updated ?? 0) >= (prior.time?.updated ?? 0)
                incomingByID[candidate.id] = candidateIsNewer
                    ? mergeHermesSession(primary: candidate, fallback: prior)
                    : mergeHermesSession(primary: prior, fallback: candidate)
            } else {
                incomingByID[candidate.id] = candidate
            }
        }
        sessions = incomingByID.values.map { candidate in
            mergeHermesSession(primary: candidate, fallback: existing[candidate.id])
        }.sorted { ($0.time?.updated ?? 0) > ($1.time?.updated ?? 0) }

        if let activeSessionID, !sessions.contains(where: { $0.id == activeSessionID }) {
            // A live attachment may not be committed to the dashboard list yet.
            // Preserve it until the next authoritative refresh rather than
            // discarding an in-flight transcript.
            if let old = existing[activeSessionID] { sessions.insert(old, at: 0) }
        }
        if activeSessionID == nil, let first = sessions.first {
            selectSession(first.id)
        }
    }

    private func mergeHermesSession(primary: Session, fallback: Session?) -> Session {
        guard let fallback else { return primary }
        var merged = primary
        merged.slug = merged.slug ?? fallback.slug
        merged.directory = merged.directory ?? fallback.directory
        merged.path = merged.path ?? fallback.path
        merged.parentID = merged.parentID ?? fallback.parentID
        merged.title = merged.title ?? fallback.title
        merged.agent = merged.agent ?? fallback.agent
        merged.model = merged.model ?? fallback.model
        merged.summary = merged.summary ?? fallback.summary
        merged.time = merged.time ?? fallback.time
        merged.version = merged.version ?? fallback.version
        return merged
    }

    private func canonicalHermesDurableID(_ id: String) -> String {
        var current = id
        var visited = Set<String>()
        while let next = hermesDurableAliases[current],
              !next.isEmpty,
              next != current,
              visited.insert(current).inserted {
            current = next
        }
        return current
    }

    private func canonicalHermesResumeID(
        _ response: HermesSessionResumeResponse,
        fallback: String
    ) -> String {
        for candidate in [response.resumed, response.sessionKey] {
            let value = candidate?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !value.isEmpty { return canonicalHermesDurableID(value) }
        }
        return canonicalHermesDurableID(fallback)
    }

    private func migrateHermesDurableSession(from oldID: String, to newID: String) {
        let targetID = canonicalHermesDurableID(newID)
        guard !oldID.isEmpty, !targetID.isEmpty, oldID != targetID else { return }
        hermesDurableAliases[oldID] = targetID
        hermesDesiredAttachments.remove(oldID)
        hermesDesiredAttachments.insert(targetID)
        if activeSessionID == oldID { activeSessionID = targetID }

        let source = sessions.first { $0.id == oldID }
        sessions.removeAll { $0.id == oldID }
        if var source {
            source.id = targetID
            if let index = sessions.firstIndex(where: { $0.id == targetID }) {
                sessions[index] = mergeHermesSession(primary: sessions[index], fallback: source)
            } else {
                sessions.append(source)
            }
        }
        sessions.sort { ($0.time?.updated ?? 0) > ($1.time?.updated ?? 0) }
    }

    private func loadHermesMessages(durableSessionID: String) async {
        guard let client = hermesClient else { return }
        let requestedDurableID = canonicalHermesDurableID(durableSessionID)
        let revisionAtRequest = messageMutationRevision
        if transportMode == .webSocket, let socket = hermesSocket,
           await socket.isConnected {
            do {
                let runtimeID = try await ensureHermesRuntimeSession(durableID: requestedDurableID)
                let history = try await socket.sessionHistory(runtimeSessionID: runtimeID)
                let effectiveDurableID = hermesRuntimeToDurable[runtimeID]
                    ?? canonicalHermesDurableID(requestedDurableID)
                guard activeServerKind == .hermes,
                      activeSessionID == effectiveDurableID,
                      hermesClient === client,
                      hermesSocket === socket,
                      hermesRuntimeToDurable[runtimeID] == effectiveDurableID else { return }
                let preserveLiveProgress = messageMutationRevision != revisionAtRequest
                    || activeSessionRunning
                if preserveLiveProgress {
                    flushPendingDeltas(sessionID: effectiveDurableID)
                } else {
                    cancelDeltaFlush(clearPending: true)
                }
                mergeRemoteMessages(
                    hermesMessages(history.messages, durableSessionID: effectiveDurableID),
                    replacing: true,
                    preserveLocalProgress: preserveLiveProgress
                )
                return
            } catch {
                if !(await socket.isConnected) {
                    let epoch = hermesConnectionEpoch
                    enterHermesRESTFallback(reason: error)
                    scheduleHermesReconnect(after: epoch)
                }
            }
        }
        do {
            let response = try await client.messages(sessionID: requestedDurableID)
            let effectiveDurableID = response.sessionID?.isEmpty == false
                ? response.sessionID!
                : canonicalHermesDurableID(requestedDurableID)
            if effectiveDurableID != requestedDurableID {
                migrateHermesDurableSession(from: requestedDurableID, to: effectiveDurableID)
            }
            guard activeServerKind == .hermes,
                  activeSessionID == effectiveDurableID,
                  hermesClient === client else { return }
            let preserveLiveProgress = messageMutationRevision != revisionAtRequest
                || activeSessionRunning
            if preserveLiveProgress {
                flushPendingDeltas(sessionID: effectiveDurableID)
            } else {
                cancelDeltaFlush(clearPending: true)
            }
            mergeRemoteMessages(
                hermesMessages(response.messages, durableSessionID: effectiveDurableID),
                replacing: true,
                preserveLocalProgress: preserveLiveProgress
            )
        } catch {
            if activeServerKind == .hermes,
               activeSessionID == canonicalHermesDurableID(requestedDurableID),
               hermesClient === client {
                setError(error)
            }
        }
    }

    private func ensureHermesRuntimeSession(durableID: String) async throws -> String {
        let canonicalID = canonicalHermesDurableID(durableID)
        if let runtimeID = hermesDurableToRuntime[canonicalID] { return runtimeID }
        let resumed = try await resumeHermesSession(durableID: canonicalID)
        return resumed.sessionID
    }

    private func resumeHermesSession(durableID: String) async throws -> HermesSessionResumeResponse {
        guard let socket = hermesSocket, await socket.isConnected else {
            throw HermesGatewayError.notConnected
        }
        let requestedID = canonicalHermesDurableID(durableID)
        if let task = hermesResumeTasks[requestedID] {
            let response = try await task.value
            return try commitHermesResume(
                response,
                requestedID: requestedID,
                socket: socket,
                epoch: hermesConnectionEpoch
            )
        }
        let epoch = hermesConnectionEpoch
        let task = Task {
            try await socket.resumeSession(durableSessionID: requestedID, source: "desktop")
        }
        hermesResumeTasks[requestedID] = task
        do {
            let response = try await task.value
            hermesResumeTasks.removeValue(forKey: requestedID)
            return try commitHermesResume(
                response,
                requestedID: requestedID,
                socket: socket,
                epoch: epoch
            )
        } catch {
            hermesResumeTasks.removeValue(forKey: requestedID)
            throw error
        }
    }

    private func commitHermesResume(
        _ response: HermesSessionResumeResponse,
        requestedID: String,
        socket: HermesGatewaySocket,
        epoch: UInt64
    ) throws -> HermesSessionResumeResponse {
        guard hermesConnectionEpoch == epoch,
              hermesSocket === socket,
              !response.sessionID.isEmpty else {
            throw HermesGatewayError.invalidResult(method: "session.resume")
        }
        let canonicalID = canonicalHermesResumeID(response, fallback: requestedID)
        if canonicalID != requestedID {
            migrateHermesDurableSession(from: requestedID, to: canonicalID)
        }
        let alreadyCommitted = hermesDurableToRuntime[canonicalID] == response.sessionID
            && hermesRuntimeToDurable[response.sessionID] == canonicalID
        if let previous = hermesRuntimeToDurable[response.sessionID], previous != canonicalID {
            migrateHermesDurableSession(from: previous, to: canonicalID)
            hermesDurableToRuntime.removeValue(forKey: previous)
        }
        hermesDurableToRuntime.removeValue(forKey: requestedID)
        hermesDurableToRuntime[canonicalID] = response.sessionID
        hermesRuntimeToDurable[response.sessionID] = canonicalID
        hermesDesiredAttachments.insert(canonicalID)
        if !alreadyCommitted {
            rebindHermesInteractions(
                fromDurableID: requestedID,
                toDurableID: canonicalID,
                runtimeID: response.sessionID
            )
            if canonicalID == activeSessionID {
                activeSessionRunning = response.running == true
                applyHermesResumeSnapshot(
                    response,
                    durableID: canonicalID,
                    runtimeID: response.sessionID
                )
            }
        }
        replayPendingHermesEvents(runtimeID: response.sessionID, epoch: epoch)
        return response
    }

    private func rebindHermesInteractions(
        fromDurableID: String,
        toDurableID: String,
        runtimeID: String
    ) {
        var carried: [PermissionRequest] = []
        for key in Array(hermesApprovalQueues.keys) {
            guard var queue = hermesApprovalQueues[key] else { continue }
            let matching = queue.filter {
                $0.sessionID == fromDurableID || $0.sessionID == toDurableID
            }
            queue.removeAll {
                $0.sessionID == fromDurableID || $0.sessionID == toDurableID
            }
            if queue.isEmpty {
                hermesApprovalQueues.removeValue(forKey: key)
            } else {
                hermesApprovalQueues[key] = queue
            }
            carried.append(contentsOf: matching)
        }
        if !carried.isEmpty {
            carried = carried.map { request in
                var rebound = request
                rebound.sessionID = toDurableID
                rebound.runtimeSessionID = runtimeID
                return rebound
            }
            hermesApprovalQueues[runtimeID, default: []].append(contentsOf: carried)
            syncHermesPermissionHeads()
        }
        for index in pendingInputRequests.indices where
            pendingInputRequests[index].sessionID == fromDurableID
                || pendingInputRequests[index].sessionID == toDurableID {
            pendingInputRequests[index].sessionID = toDurableID
            pendingInputRequests[index].runtimeSessionID = runtimeID
        }
    }

    private func applyHermesResumeSnapshot(
        _ response: HermesSessionResumeResponse,
        durableID: String,
        runtimeID: String
    ) {
        var snapshot = hermesMessages(response.messages, durableSessionID: durableID)
        let now = Int(Date().timeIntervalSince1970 * 1_000)

        if let userText = response.inflight?.user, !userText.isEmpty,
           !snapshot.contains(where: {
               $0.info.role == "user"
                   && ($0.parts?.compactMap(\.text).joined() ?? "") == userText
           }) {
            snapshot.append(
                hermesTextMessage(
                    id: "hermes-inflight-user-\(durableID)-\(hermesConnectionEpoch)",
                    sessionID: durableID,
                    role: "user",
                    text: userText,
                    created: now
                )
            )
        }

        let assistantText = response.inflight?.assistant ?? ""
        let existingAssistant = snapshot.last(where: {
            $0.info.role == "assistant"
                && ($0.parts?.contains(where: { $0.type == "text" }) == true)
                && ($0.parts?.compactMap(\.text).joined() ?? "") == assistantText
        })
        let liveMessageID: String
        if let existingAssistant, !assistantText.isEmpty {
            liveMessageID = existingAssistant.id
        } else {
            liveMessageID = "hermes-inflight-assistant-\(durableID)-\(hermesConnectionEpoch)"
            if !assistantText.isEmpty || response.inflight?.streaming == true || response.running == true {
                snapshot.append(
                    hermesTextMessage(
                        id: liveMessageID,
                        sessionID: durableID,
                        role: "assistant",
                        text: assistantText,
                        created: now
                    )
                )
            }
        }

        cancelDeltaFlush(clearPending: true)
        messages = snapshot
        sortMessagesChronologically()
        if response.inflight?.streaming == true || response.running == true {
            hermesLiveMessageIDs[runtimeID] = liveMessageID
            activeSessionRunning = true
            messageMutationRevision &+= 1
        } else {
            hermesLiveMessageIDs.removeValue(forKey: runtimeID)
            activeSessionRunning = false
        }
    }

    private func hermesTextMessage(
        id: String,
        sessionID: String,
        role: String,
        text: String,
        created: Int
    ) -> Message {
        Message(
            info: MessageInfo(
                id: id,
                sessionID: sessionID,
                role: role,
                modelID: role == "assistant" ? (activeSession?.model?.id ?? "hermes") : nil,
                providerID: role == "assistant" ? "hermes" : nil,
                agent: "hermes",
                time: MessageTime(created: created, updated: created)
            ),
            parts: [
                Part(
                    id: "\(id)-text",
                    sessionID: sessionID,
                    messageID: id,
                    type: "text",
                    text: text,
                    time: MessageTime(created: created, updated: created)
                )
            ]
        )
    }

    private func hermesSession(_ item: HermesGatewaySessionListItem) -> Session {
        let timestamp = hermesTimestamp(item.startedAt)
        return Session(
            id: item.id,
            slug: item.preview.isEmpty ? nil : item.preview,
            directory: nil,
            title: item.title.isEmpty ? item.preview : item.title,
            agent: "hermes",
            time: SessionTime(created: timestamp, updated: timestamp),
            version: serverVersion
        )
    }

    private func hermesSession(_ item: HermesDashboardSession) -> Session {
        Session(
            id: item.id,
            slug: item.preview,
            directory: item.cwd,
            title: item.title?.isEmpty == false ? item.title : item.preview,
            agent: "hermes",
            model: hermesModelRef(item.model),
            time: SessionTime(
                created: hermesTimestamp(item.startedAt),
                updated: hermesTimestamp(item.lastActive ?? item.endedAt ?? item.startedAt)
            ),
            version: serverVersion
        )
    }

    private func hermesModelRef(_ raw: String?) -> ModelRef? {
        guard let raw, !raw.isEmpty else { return nil }
        let pieces = raw.split(separator: "/", maxSplits: 1).map(String.init)
        if pieces.count == 2 {
            return ModelRef(id: pieces[1], providerID: pieces[0])
        }
        return ModelRef(id: raw, providerID: "hermes")
    }

    private func hermesMessages(
        _ transcript: [HermesTranscriptMessage],
        durableSessionID: String
    ) -> [Message] {
        transcript.enumerated().map { index, item in
            let messageID = item.rowID?.isEmpty == false
                ? "hermes-\(item.rowID!)"
                : "hermes-\(durableSessionID)-\(index)"
            let created = hermesTimestamp(item.createdAt) ?? index
            let role = item.role.lowercased()
            let isTool = role == "tool" || item.displayKind?.lowercased().contains("tool") == true
            let normalizedRole = isTool ? "assistant" : role
            let info = MessageInfo(
                id: messageID,
                sessionID: durableSessionID,
                role: normalizedRole.isEmpty ? "assistant" : normalizedRole,
                modelID: isTool ? nil : (activeSession?.model?.id ?? "hermes"),
                providerID: isTool ? nil : "hermes",
                agent: "hermes",
                time: MessageTime(created: created, completed: created, updated: created),
                metadata: item.displayMetadata?.mapValues(hermesJSONValue)
            )
            let text = item.displayText ?? item.context ?? ""
            let part: Part
            if isTool {
                part = Part(
                    id: "\(messageID)-tool",
                    sessionID: durableSessionID,
                    messageID: messageID,
                    type: "tool",
                    state: .completed,
                    tool: item.name ?? item.displayKind ?? "tool",
                    callID: item.rowID ?? messageID,
                    output: text.isEmpty ? nil : .string(text),
                    time: MessageTime(created: created, completed: created, updated: created)
                )
            } else {
                let partType = item.displayKind?.lowercased().contains("reason") == true
                    ? "reasoning" : "text"
                part = Part(
                    id: "\(messageID)-\(partType)",
                    sessionID: durableSessionID,
                    messageID: messageID,
                    type: partType,
                    text: text,
                    time: MessageTime(created: created, completed: created, updated: created)
                )
            }
            return Message(info: info, parts: [part])
        }
    }

    private func hermesJSONValue(_ value: HermesJSONValue) -> JSONValue {
        switch value {
        case .string(let value): return .string(value)
        case .number(let value): return .number(value)
        case .bool(let value): return .bool(value)
        case .object(let value): return .object(value.mapValues(hermesJSONValue))
        case .array(let value): return .array(value.map(hermesJSONValue))
        case .null: return .null
        }
    }

    private func hermesTimestamp(_ value: Double?) -> Int? {
        guard let value, value.isFinite else { return nil }
        return Int(value > 100_000_000_000 ? value : value * 1_000)
    }

    private func createHermesSession() async {
        guard transportMode == .webSocket,
              let socket = hermesSocket,
              await socket.isConnected else {
            setError(HermesGatewayError.notConnected)
            return
        }
        do {
            let response = try await socket.createSession(cwd: activeDirectory, source: "desktop")
            guard hermesSocket === socket,
                  let durableID = response.storedSessionID,
                  !durableID.isEmpty,
                  !response.sessionID.isEmpty else {
                throw HermesGatewayError.invalidResult(method: "session.create")
            }
            hermesDurableToRuntime[durableID] = response.sessionID
            hermesRuntimeToDurable[response.sessionID] = durableID
            hermesDesiredAttachments.insert(durableID)
            let now = Int(Date().timeIntervalSince1970 * 1_000)
            let session = Session(
                id: durableID,
                directory: response.info?.cwd ?? activeDirectory,
                title: "New Hermes session",
                agent: "hermes",
                model: hermesModelRef(response.info?.model),
                time: SessionTime(created: now, updated: now),
                version: serverVersion
            )
            sessions.removeAll { $0.id == durableID }
            sessions.insert(session, at: 0)
            activeSessionID = durableID
            activeSessionRunning = false
            messages = hermesMessages(response.messages, durableSessionID: durableID)
            replayPendingHermesEvents(runtimeID: response.sessionID, epoch: hermesConnectionEpoch)
        } catch {
            await handleHermesGatewayFailure(error)
        }
    }

    private func sendHermesPrompt(_ prompt: String) async {
        guard !prompt.isEmpty, let requestedDurableID = activeSessionID else { return }
        guard transportMode == .webSocket,
              let socket = hermesSocket,
              await socket.isConnected else {
            setError(HermesGatewayError.notConnected)
            return
        }
        let runtimeID: String
        let effectiveDurableID: String
        do {
            runtimeID = try await ensureHermesRuntimeSession(durableID: requestedDurableID)
            effectiveDurableID = hermesRuntimeToDurable[runtimeID]
                ?? canonicalHermesDurableID(requestedDurableID)
            guard activeSessionID == effectiveDurableID,
                  hermesSocket === socket,
                  transportMode == .webSocket,
                  await socket.isConnected else {
                throw HermesGatewayError.requestCancelled
            }
        } catch {
            await handleHermesGatewayFailure(error)
            return
        }

        // Resume can replace the transcript with a server snapshot, so append
        // the local echo only after its runtime/durable mapping is committed.
        // From this point onward any RPC failure is ambiguous: the server may
        // already have accepted the prompt, therefore the echo is retained and
        // the prompt is never resent automatically.
        _ = appendOptimisticUserMessage(text: prompt, sessionID: effectiveDurableID)
        activeSessionRunning = true
        do {
            _ = try await socket.submitPrompt(runtimeSessionID: runtimeID, text: prompt)
        } catch {
            realtimeWarning = "Hermes prompt delivery is uncertain after a WebSocket failure. It will not be resent automatically."
            await handleHermesGatewayFailure(error, surfaceError: false)
        }
    }

    private func abortHermesSession() async {
        guard transportMode == .webSocket,
              let durableID = activeSessionID,
              let socket = hermesSocket,
              await socket.isConnected else { return }
        do {
            let runtimeID = try await ensureHermesRuntimeSession(durableID: durableID)
            _ = try await socket.interrupt(runtimeSessionID: runtimeID)
            flushPendingDeltas(sessionID: durableID)
            clearHermesInteractions(runtimeID: runtimeID)
            activeSessionRunning = false
        } catch {
            await handleHermesGatewayFailure(error)
        }
    }

    private func handleHermesGatewayFailure(
        _ error: Error,
        surfaceError: Bool = true
    ) async {
        if let socket = hermesSocket, !(await socket.isConnected) {
            let epoch = hermesConnectionEpoch
            enterHermesRESTFallback(reason: error)
            scheduleHermesReconnect(after: epoch)
        }
        if surfaceError { setError(error) }
    }

    func refreshSessions() async {
        if activeServerKind == .hermes {
            await refreshHermesSessions()
            return
        }
        guard let api else { return }
        let requestedDirectory = activeDirectory
        let requestedClient = api.client
        do {
            let all = try await api.sessions(directory: requestedDirectory)
            guard !Task.isCancelled,
                  activeDirectory == requestedDirectory,
                  connectionClient === requestedClient else { return }
            sessions = all.sorted { ($0.time?.updated ?? 0) > ($1.time?.updated ?? 0) }
            DebugLog.write("sessions: \(self.sessions.count) dir=\(self.activeDirectory ?? "nil")")
            log.info("sessions refreshed: \(self.sessions.count, privacy: .public) (dir=\(self.activeDirectory ?? "nil", privacy: .public))")
            if activeSessionID == nil, let first = sessions.first {
                activeSessionID = first.id
                await loadMessages(sessionID: first.id)
            }
        } catch {
            if !Task.isCancelled,
               activeDirectory == requestedDirectory,
               connectionClient === requestedClient {
                setError(error)
            }
        }
    }

    func refreshCatalog() async {
        guard supportsOpenCodeFeatures else {
            providers = nil
            agents = []
            projects = []
            commands = []
            skills = []
            mcpStatuses = [:]
            selectedModel = nil
            return
        }
        guard let api else { return }
        let requestedDirectory = activeDirectory
        let requestedClient = api.client
        async let prov = try? api.providers()
        async let ags = try? api.agents()
        async let projs = try? api.projects()
        async let cmds = try? api.commands(directory: requestedDirectory)
        async let skls = try? api.skills()
        let results = await (prov, ags, projs, cmds, skls)
        guard activeDirectory == requestedDirectory,
              connectionClient === requestedClient else { return }
        providers = results.0
        agents = results.1 ?? []
        projects = results.2 ?? []
        commands = results.3 ?? []
        skills = results.4 ?? []

        if !agents.contains(where: { $0.id == selectedAgentID }) {
            selectedAgentID = agents.first(where: { $0.id == "build" })?.id
                ?? agents.first(where: { $0.mode == "primary" && $0.hidden != true })?.id
                ?? agents.first?.id
                ?? "build"
        }
        if selectedModel == nil {
            selectedModel = activeSession?.model ?? firstAvailableModel
        }
    }

    func loadMessages(sessionID: String) async {
        if activeServerKind == .hermes {
            await loadHermesMessages(durableSessionID: sessionID)
            return
        }
        guard let api else { return }
        let requestedDirectory = activeDirectory
        let requestedClient = api.client
        let revisionAtRequest = messageMutationRevision
        do {
            let remote = try await api.messages(sessionID: sessionID, directory: requestedDirectory)
            guard activeSessionID == sessionID,
                  activeDirectory == requestedDirectory,
                  connectionClient === requestedClient else { return }
            let preserveLiveProgress = messageMutationRevision != revisionAtRequest
            if preserveLiveProgress {
                flushPendingDeltas(sessionID: sessionID)
            } else {
                cancelDeltaFlush(clearPending: true)
            }
            mergeRemoteMessages(
                remote,
                replacing: true,
                preserveLocalProgress: preserveLiveProgress
            )
            if let session = sessions.first(where: { $0.id == sessionID }) {
                selectedModel = session.model ?? selectedModel
                selectedAgentID = session.agent ?? selectedAgentID
            }
            log.info("messages loaded: \(self.messages.count, privacy: .public) for \(sessionID, privacy: .public)")
            if transportMode == .quickTunnelPolling,
               let statuses = try? await api.sessionStatuses(directory: requestedDirectory),
               activeSessionID == sessionID,
               activeDirectory == requestedDirectory,
               connectionClient === requestedClient {
                activeSessionRunning = statuses[sessionID]?.running ?? false
                if activeSessionRunning {
                    pollSawBusy = true
                    startPollingIfNeeded()
                }
            }
        } catch {
            if activeSessionID == sessionID,
               activeDirectory == requestedDirectory,
               connectionClient === requestedClient {
                setError(error)
            }
        }
    }

    /// Called on foreground: re-open the SSE stream (it was severed in
    /// background) and pull fresh message + session state to fill the gap.
    func reconcileOnForeground() async {
        guard connectionState == .connected else { return }
        DebugLog.write("reconcile on foreground")
        if activeServerKind == .hermes {
            guard let client = hermesClient else { return }
            await stopHermesSocket(preserveDesiredAttachments: true)
            do {
                let authentication = try await client.authenticate()
                try await openHermesGateway(client: client, status: authentication.status)
                hermesStatus = authentication.status
                serverVersion = authentication.status.version
                transportMode = .webSocket
                realtimeWarning = nil
                await restoreHermesAttachments()
            } catch {
                enterHermesRESTFallback(reason: error)
                scheduleHermesReconnect(after: hermesConnectionEpoch)
            }
            await refreshSessions()
            if let id = activeSessionID { await loadMessages(sessionID: id) }
            return
        }
        // Backgrounding can leave a URLSession byte stream half-open. Recreate
        // the active directory stream, then fill its event gap from REST.
        await stopStreams()
        await openStreams()
        await refreshSessions()
        if let id = activeSessionID {
            await loadMessages(sessionID: id)
            if activeSessionRunning { startPollingIfNeeded() }
        }
    }

    private func reconcileAfterStreamReconnect() async {
        guard connectionState == .connected else { return }
        await refreshSessions()
        if let id = activeSessionID {
            await loadMessages(sessionID: id)
        }
    }

    func createSession() async {
        if activeServerKind == .hermes {
            await createHermesSession()
            return
        }
        guard let api else { return }
        do {
            let session = try await api.createSession(
                directory: activeDirectory,
                agent: selectedAgentID,
                model: selectedModel
            )
            sessions.insert(session, at: 0)
            selectSession(session.id)
        } catch {
            setError(error)
        }
    }

    func selectSession(_ id: String) {
        loadMessagesTask?.cancel()
        activeSessionID = id
        if activeServerKind == .hermes {
            hermesDesiredAttachments.insert(id)
        }
        activeSessionRunning = false
        cancelPolling()
        cancelDeltaFlush(clearPending: true)
        consecutiveIdlePolls = 0
        lastPolledMessageHash = nil
        messages = []
        loadMessagesTask = Task { await loadMessages(sessionID: id) }
    }

    func deleteSession(_ id: String) async {
        do {
            switch activeServerKind {
            case .openCode:
                guard let api else { return }
                _ = try await api.deleteSession(id: id, directory: activeDirectory)
            case .hermes:
                guard transportMode == .webSocket else {
                    throw HermesGatewayError.notConnected
                }
                guard let client = hermesClient else { return }
                _ = try await client.deleteSession(sessionID: id)
                if let runtimeID = hermesDurableToRuntime.removeValue(forKey: id) {
                    hermesRuntimeToDurable.removeValue(forKey: runtimeID)
                    hermesApprovalQueues.removeValue(forKey: runtimeID)
                    hermesLiveMessageIDs.removeValue(forKey: runtimeID)
                    hermesLiveToolParts = hermesLiveToolParts.filter {
                        !$0.key.hasPrefix(runtimeID + ":")
                    }
                }
                hermesDesiredAttachments.remove(id)
                pendingPermissions.removeAll { $0.sessionID == id && $0.backend == .hermes }
                pendingInputRequests.removeAll { $0.sessionID == id }
            }
            sessions.removeAll { $0.id == id }
            if activeSessionID == id {
                activeSessionID = nil
                activeSessionRunning = false
                messages = []
                if let next = sessions.first { selectSession(next.id) }
            }
        } catch {
            setError(error)
        }
    }

    func sendPrompt(_ text: String) async {
        let prompt = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if activeServerKind == .hermes {
            await sendHermesPrompt(prompt)
            return
        }
        guard let api, let id = activeSessionID, !prompt.isEmpty else { return }
        let optimisticID = appendOptimisticUserMessage(text: prompt, sessionID: id)
        activeSessionRunning = true
        pollSawBusy = false
        consecutiveIdlePolls = 0
        quickTunnelMayNeedPermission = false
        lastPolledMessageHash = nil
        lastPolledMessageChangeAt = Date()
        do {
            try await api.promptAsync(
                sessionID: id,
                text: prompt,
                directory: activeDirectory,
                agent: selectedAgentID,
                model: selectedModel,
                variant: selectedVariant
            )
            startPollingIfNeeded()
        } catch {
            messages.removeAll { $0.info.id == optimisticID }
            activeSessionRunning = false
            cancelPolling()
            setError(error)
        }
    }

    func abortSession() async {
        if activeServerKind == .hermes {
            await abortHermesSession()
            return
        }
        guard let api, let id = activeSessionID else { return }
        _ = try? await api.abortSession(id: id, directory: activeDirectory)
        cancelPolling()
        flushPendingDeltas()
        activeSessionRunning = false
        quickTunnelMayNeedPermission = false
    }

    // MARK: - REST polling fallback (SSE silent / buffered)

    /// Start a lightweight poll loop while a task is running and SSE is silent.
    /// Mirrors the SSE-driven state updates via REST so streaming and task
    /// status still work through tunnels that buffer SSE entirely.
    func startPollingIfNeeded() {
        guard pollTask == nil, connectionState == .connected, activeSessionID != nil else { return }
        pollGeneration &+= 1
        let generation = pollGeneration
        pollTask = Task {
            var iteration = 0
            if self.transportMode == .serverSentEvents {
                try? await Task.sleep(nanoseconds: 20_000_000_000)
            }
            while !Task.isCancelled {
                guard self.activeSessionRunning, self.activeSessionID != nil else { break }
                if self.transportMode == .quickTunnelPolling || self.sseSilent {
                    await self.pollActiveSession()
                    iteration += 1
                }
                guard self.activeSessionRunning, !Task.isCancelled else { break }
                try? await Task.sleep(nanoseconds: self.pollDelayNanoseconds(iteration: iteration))
            }
            if self.pollGeneration == generation {
                self.pollTask = nil
            }
        }
    }

    private func cancelPolling() {
        pollGeneration &+= 1
        pollTask?.cancel()
        pollTask = nil
    }

    private func pollActiveSession() async {
        guard let api, let id = activeSessionID else { return }
        let requestedDirectory = activeDirectory
        let requestedClient = api.client
        let revisionAtRequest = messageMutationRevision
        async let statusesRequest = try? api.sessionStatuses(directory: requestedDirectory)
        async let messagesRequest = try? api.messages(sessionID: id, directory: requestedDirectory, limit: 20)
        let (statuses, remoteMessages) = await (statusesRequest, messagesRequest)
        guard activeSessionID == id,
              activeDirectory == requestedDirectory,
              connectionClient === requestedClient else { return }

        var shouldFinalize = false
        if let statuses {
            if statuses[id]?.running == true {
                pollSawBusy = true
                consecutiveIdlePolls = 0
                shouldFinalize = false
                if !activeSessionRunning { activeSessionRunning = true }
            } else {
                consecutiveIdlePolls += 1
                // A single absent status can race prompt registration. Only a
                // prior busy observation or two consecutive successful idle
                // reads can finalize; a just-completed previous turn must not
                // terminate a newly submitted prompt.
                if pollSawBusy || consecutiveIdlePolls >= 2 {
                    shouldFinalize = true
                }
            }
        }

        if let remoteMessages {
            let hash = messageHash(remoteMessages)
            if hash != lastPolledMessageHash {
                lastPolledMessageHash = hash
                lastPolledMessageChangeAt = Date()
                if quickTunnelMayNeedPermission { quickTunnelMayNeedPermission = false }
                let preserveLiveProgress = messageMutationRevision != revisionAtRequest
                if preserveLiveProgress {
                    flushPendingDeltas(sessionID: id)
                }
                mergeRemoteMessages(
                    remoteMessages,
                    replacing: false,
                    preserveLocalProgress: preserveLiveProgress
                )
            } else if transportMode == .quickTunnelPolling,
                      activeSessionRunning,
                      Date().timeIntervalSince(lastPolledMessageChangeAt) > 20,
                      !quickTunnelMayNeedPermission {
                quickTunnelMayNeedPermission = true
            }
        }

        if shouldFinalize {
            // Status and messages above deliberately run in parallel. The
            // message request can be served just before the status flips idle,
            // so fetch once more *after* observing idle before stopping the only
            // Quick Tunnel update channel.
            let finalRevisionAtRequest = messageMutationRevision
            guard let finalMessages = try? await api.messages(
                sessionID: id,
                directory: requestedDirectory,
                limit: 20
            ), activeSessionID == id,
               activeDirectory == requestedDirectory,
               connectionClient === requestedClient else {
                return
            }
            lastPolledMessageHash = messageHash(finalMessages)
            let preserveLiveProgress = messageMutationRevision != finalRevisionAtRequest
            if preserveLiveProgress {
                flushPendingDeltas(sessionID: id)
            }
            mergeRemoteMessages(
                finalMessages,
                replacing: false,
                preserveLocalProgress: preserveLiveProgress
            )
            activeSessionRunning = false
            if quickTunnelMayNeedPermission { quickTunnelMayNeedPermission = false }
            cancelPolling()
        }
    }

    private func pollDelayNanoseconds(iteration: Int) -> UInt64 {
        switch iteration {
        case 0..<3: return 750_000_000
        case 3..<8: return 1_000_000_000
        case 8..<20: return 2_000_000_000
        default: return 4_000_000_000
        }
    }

    // MARK: - Permissions

    /// Surface a permission request as a local notification while the app is
    /// backgrounded (the in-app bar is not visible then). Foreground requests
    /// render in-app only.
    private func notifyPermissionIfNeeded(_ request: PermissionRequest) {
        guard !isForeground else { return }
        let content = UNMutableNotificationContent()
        content.title = request.backend == .hermes
            ? "Hermes permission requested"
            : "OpenCode permission requested"
        content.body = request.commandText ?? request.permission ?? "A task needs your approval"
        content.sound = .default
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 0.1, repeats: false)
        let notification = UNNotificationRequest(identifier: "perm-\(request.id)", content: content, trigger: trigger)
        UNUserNotificationCenter.current().add(notification)
    }

    /// Remove delivered permission notifications once the app is back in the
    /// foreground (the in-app bar takes over).
    func clearPermissionNotifications() {
        UNUserNotificationCenter.current().removeDeliveredNotifications(
            withIdentifiers: pendingPermissions.map { "perm-\($0.id)" }
        )
    }

    func respond(to permission: PermissionRequest, response: PermissionResponse) async {
        if permission.backend == .hermes {
            guard transportMode == .webSocket,
                  let socket = hermesSocket,
                  await socket.isConnected,
                  let runtimeID = permission.runtimeSessionID,
                  hermesApprovalQueues[runtimeID]?.first?.id == permission.id else {
                return
            }
            let choice: String
            switch response {
            case .once: choice = "once"
            case .always: choice = "always"
            case .reject: choice = "deny"
            }
            do {
                _ = try await socket.respondToApproval(
                    runtimeSessionID: runtimeID,
                    choice: choice,
                    resolveAll: false
                )
                guard hermesSocket === socket else { return }
                if var queue = hermesApprovalQueues[runtimeID],
                   HermesApprovalFIFO.removeHead(expectedID: permission.id, from: &queue) {
                    if queue.isEmpty {
                        hermesApprovalQueues.removeValue(forKey: runtimeID)
                    } else {
                        hermesApprovalQueues[runtimeID] = queue
                    }
                }
                syncHermesPermissionHeads()
                if let next = hermesApprovalQueues[runtimeID]?.first {
                    notifyPermissionIfNeeded(next)
                }
            } catch {
                await handleHermesGatewayFailure(error)
            }
            return
        }
        guard let api, let sessionID = permission.sessionID else {
            pendingPermissions.removeAll { $0.id == permission.id }
            return
        }
        do {
            _ = try await api.replyPermission(
                sessionID: sessionID,
                permissionID: permission.id,
                response: response,
                directory: permission.directory
            )
            pendingPermissions.removeAll { $0.id == permission.id }
        } catch {
            setError(error)
        }
    }

    func respond(to request: AgentInputRequest, answer: String) async {
        guard activeServerKind == .hermes,
              let socket = hermesSocket,
              await socket.isConnected,
              pendingInputRequests.contains(where: { $0.id == request.id }) else { return }
        do {
            switch request.kind {
            case .clarify:
                _ = try await socket.respondToClarification(
                    runtimeSessionID: request.runtimeSessionID,
                    requestID: request.id,
                    answer: answer
                )
            case .sudo:
                _ = try await socket.respondToSudo(
                    runtimeSessionID: request.runtimeSessionID,
                    requestID: request.id,
                    password: answer
                )
            case .secret:
                _ = try await socket.respondToSecret(
                    runtimeSessionID: request.runtimeSessionID,
                    requestID: request.id,
                    value: answer
                )
            }
            guard hermesSocket === socket else { return }
            pendingInputRequests.removeAll { $0.id == request.id }
        } catch {
            await handleHermesGatewayFailure(error)
        }
    }

    // MARK: - Misc

    private func setError(_ error: any Error) {
        let desc = (error as? OpenCodeError)?.errorDescription ?? error.localizedDescription
        lastError = desc
        errorShown = true
        log.error("ERROR: \(desc, privacy: .public)")
        DebugLog.write("ERROR: \(String(reflecting: error))")
    }

    var availableModels: [(provider: Provider, model: ProviderModel)] {
        (providers?.providers ?? []).flatMap { provider in
            (provider.models ?? [:]).values.map { (provider, $0) }
        }.sorted { ($0.model.name ?? $0.model.id) < ($1.model.name ?? $1.model.id) }
    }

    var firstAvailableModel: ModelRef? {
        guard let first = availableModels.first else { return nil }
        return ModelRef(id: first.model.id, providerID: first.provider.id)
    }

    func selectModel(providerID: String, modelID: String) {
        selectedModel = ModelRef(id: modelID, providerID: providerID)
        // Reasoning effort is per-model: reset to the new model's default.
        selectedVariant = nil
    }

    /// Reasoning effort levels for the currently selected model, derived
    /// from its `variants` keys (per the Mac-side model config). nil = the
    /// model exposes no thinking levels (or none selected yet).
    var selectedModelVariants: [String]? {
        guard let selectedModel,
              let provider = (providers?.providers ?? []).first(where: { $0.id == selectedModel.providerID }),
              let model = provider.models?[selectedModel.id] else { return nil }
        let order = ["minimal", "low", "medium", "high", "xhigh", "max"]
        return model.variants?.keys.sorted { order.firstIndex(of: $0) ?? 99 < order.firstIndex(of: $1) ?? 99 }
    }

    func saveAPIKey(providerID: String, key: String, baseURL: String? = nil) async throws {
        guard let api else { return }
        _ = try await api.saveAPIKey(providerID: providerID, key: key, baseURL: baseURL)
        await refreshCatalog()
        await mergeAddedProvider(providerID: providerID)
    }

    /// Remove a stored API key. The provider disappears from the list after a
    /// serve restart (list is computed at startup); we drop it client-side
    /// immediately so the UI reflects the deletion right away.
    func deleteAPIKey(providerID: String) async {
        guard let api else { return }
        _ = try? await api.deleteAPIKey(providerID: providerID)
        if var list = providers?.providers {
            list.removeAll { $0.id == providerID }
            providers = ProvidersResponse(providers: list, defaultModel: providers?.defaultModel)
        }
        if selectedModel?.providerID == providerID {
            selectedModel = nil
            selectedModel = firstAvailableModel
        }
    }

    /// Per-provider usage aggregated from every session's `cost` + `tokens`
    /// (the server reports these on GET /session). Balance is NOT available
    /// through opencode — only cumulative usage.
    var providerUsage: [String: (cost: Double, input: Int, output: Int)] {
        var acc: [String: (cost: Double, input: Int, output: Int)] = [:]
        for session in sessions {
            guard let pid = session.model?.providerID else { continue }
            let cost = session.cost ?? 0
            let input = session.tokens?.input ?? 0
            let output = session.tokens?.output ?? 0
            let current = acc[pid] ?? (0, 0, 0)
            acc[pid] = (current.cost + cost, current.input + input, current.output + output)
        }
        return acc
    }

    /// `GET /config/providers` is computed at serve STARTUP, so a provider
    /// just added via `PUT /auth/{id}` won't appear until restart. Merge it
    /// client-side from the full `GET /provider` registry so the UI updates
    /// immediately; a serve restart makes it authoritative.
    private func mergeAddedProvider(providerID: String) async {
        guard let api else { return }
        guard let all = try? await api.providerRegistry() else { return }
        guard let reg = all.first(where: { $0.id == providerID }) else { return }
        let entry = Provider(id: reg.id, name: reg.name, source: reg.source, key: "set", models: reg.models)
        var list = providers?.providers ?? []
        list.removeAll { $0.id == entry.id }
        list.insert(entry, at: 0)
        providers = ProvidersResponse(providers: list, defaultModel: providers?.defaultModel)
        if selectedModel == nil {
            selectedModel = firstAvailableModel
        }
    }

    func findFiles(_ query: String) async -> [String] {
        guard let api else { return [] }
        return (try? await api.findFiles(query: query, directory: activeDirectory)) ?? []
    }

    /// List a directory inside the active workspace. `path` is relative to
    /// the workspace root (nil = root); the server returns relative `path`s.
    func fileTree(path: String?) async -> [FileNode] {
        guard let api else { return [] }
        return (try? await api.fileTree(directory: path ?? activeDirectory ?? "~")) ?? []
    }

    /// Toggle every configured MCP server (connect <-> disconnect).
    func toggleMCPs() async {
        guard let api else { return }
        let statuses = (try? await api.mcpStatuses()) ?? [:]
        DebugLog.write("toggleMCPs: \(statuses.count) servers")
        for (name, status) in statuses {
            if status.connected {
                _ = try? await api.mcpDisconnect(name: name)
                DebugLog.write("toggleMCPs: disconnected \(name)")
            } else {
                _ = try? await api.mcpConnect(name: name)
                DebugLog.write("toggleMCPs: connected \(name)")
            }
        }
        await refreshMCPs()
    }

    /// Fetch the Mac's MCP server statuses (`GET /mcp`).
    func refreshMCPs() async {
        guard let api else { return }
        mcpStatuses = (try? await api.mcpStatuses()) ?? [:]
    }

    /// Connect/disconnect a single MCP server, then refresh the list.
    func toggleMCP(name: String) async {
        guard let api else { return }
        if mcpStatuses[name]?.connected == true {
            _ = try? await api.mcpDisconnect(name: name)
        } else {
            _ = try? await api.mcpConnect(name: name)
        }
        await refreshMCPs()
    }

    // MARK: - End-to-end verification (DEBUG)

    /// Scripted E2E: new project -> session -> prompt -> permission approve ->
    /// streamed reply. Uses the exact same code paths as the UI. Results are
    /// appended to `Documents/debug.log`.
    func runE2ETest() async {
        DebugLog.write("E2E START")
        guard let api else { DebugLog.write("E2E FAIL no api"); return }
        await refreshCatalog()
        guard let model = firstAvailableModel else {
            DebugLog.write("E2E FAIL no model available")
            return
        }
        DebugLog.write("E2E model=\(model.id) provider=\(model.providerID ?? "-")")

        let args = ProcessInfo.processInfo.arguments
        let dir: String
        if let idx = args.firstIndex(of: "-OCE2EDir"), args.indices.contains(idx + 1) {
            dir = args[idx + 1]
        } else {
            dir = "/tmp/oc-e2e-\(Int(Date().timeIntervalSince1970))"
        }
        do {
            _ = try await api.gitInit(directory: dir)
            DebugLog.write("E2E gitInit OK \(dir)")
        } catch {
            DebugLog.write("E2E gitInit warn: \(error)")
        }
        await switchProject(to: dir)

        do {
            let session = try await api.createSession(directory: dir, agent: "build", model: model)
            sessions.insert(session, at: 0)
            selectSession(session.id)
            DebugLog.write("E2E session=\(session.id)")
        } catch {
            DebugLog.write("E2E FAIL createSession: \(error)")
            return
        }

        let e2eArgs = ProcessInfo.processInfo.arguments
        let prompt: String
        if let idx = e2eArgs.firstIndex(of: "-OCE2EPrompt"), e2eArgs.indices.contains(idx + 1) {
            prompt = e2eArgs[idx + 1]
        } else {
            prompt = "Create the file /tmp/oc-outside/e2e-\(Int(Date().timeIntervalSince1970)).txt containing the text e2e-perm-ok using the bash tool."
        }
        await sendPrompt(prompt)
        DebugLog.write("E2E prompt sent")

        var handledIDs = Set<String>()
        let replyDelay: UInt64
        if let idx = e2eArgs.firstIndex(of: "-OCE2EDelay"), e2eArgs.indices.contains(idx + 1), let s = Double(e2eArgs[idx + 1]) {
            replyDelay = UInt64(s * 1_000_000_000)
        } else {
            replyDelay = 400_000_000
        }
        for _ in 0..<150 {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            let pending = pendingPermissions
            for p in pending where !handledIDs.contains(p.id) {
                DebugLog.write("E2E permission.asked id=\(p.id) perm=\(p.permission ?? "-")")
                try? await Task.sleep(nanoseconds: replyDelay)
                await respond(to: p, response: .once)
                handledIDs.insert(p.id)
                DebugLog.write("E2E permission.replied id=\(p.id)")
            }
            if !activeSessionRunning && pendingPermissions.isEmpty { break }
        }
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        if let id = activeSessionID {
            await loadMessages(sessionID: id)
        }
        let assistantText = messages
            .filter { $0.info.role == "assistant" }
            .flatMap { $0.parts ?? [] }
            .filter { $0.type == "text" }
            .compactMap { $0.text }
            .joined(separator: "\n")
        DebugLog.write("E2E messages=\(messages.count) assistantTextLen=\(assistantText.count) permsHandled=\(handledIDs.count)")
        DebugLog.write("E2E assistantText=\(String(assistantText.prefix(200)))")
        DebugLog.write("E2E DONE")
    }
}

// MARK: - Connection state

enum ConnectionState: Equatable {
    case disconnected
    case connecting
    case connected
    case failed(String)
}

// MARK: - JSON helpers

extension JSONValue {
    var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }
}

extension Dictionary where Key == String, Value == JSONValue {
    func decode<T: Decodable>(_ type: T.Type) -> T? {
        guard let data = try? JSONSerialization.data(withJSONObject: compactMapValues { $0.anyValue }) else { return nil }
        return try? JSONDecoder.oc.decode(T.self, from: data)
    }
}

extension JSONValue {
    var anyValue: Any {
        switch self {
        case .string(let s): return s
        case .number(let n): return n
        case .bool(let b): return b
        case .object(let o): return o.mapValues { $0.anyValue }
        case .array(let a): return a.map { $0.anyValue }
        case .null: return NSNull()
        }
    }
}
