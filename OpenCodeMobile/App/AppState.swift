import SwiftUI
import Combine
import OSLog

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

@MainActor
final class AppState: ObservableObject {
    // Server
    @Published var servers: [ServerConfig] = []
    @Published var activeServer: ServerConfig?
    @Published var connectionState: ConnectionState = .disconnected
    @Published var serverVersion: String?

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

    // Errors
    @Published var lastError: String?
    @Published var errorShown = false

    /// Active workspace directory (nil = server default instance).
    var activeDirectory: String?

    #if DEBUG
    /// Set when launched with `-OCE2E`: run the scripted end-to-end flow.
    var e2eRequested = false
    private var debugSessionID: String?
    #endif

    /// Streams keyed by directory. Multiple directory-scoped SSE connections.
    private var streams: [String: EventStream] = [:]

    /// Last moment any SSE event (or heartbeat) arrived. Used to detect a
    /// buffered/blocked SSE path (e.g. Cloudflare quick tunnels) and fall back
    /// to REST polling while a task runs.
    private var lastSSEEventAt = Date()
    private var pollTask: Task<Void, Never>?

    private var sseSilent: Bool { Date().timeIntervalSince(lastSSEEventAt) > 20 }

    /// The API client bound to the active server.
    var api: OpenCodeAPI? {
        guard let server = activeServer else { return nil }
        return OpenCodeAPI(client: OpenCodeClient(config: server))
    }

    var client: OpenCodeClient? {
        guard let server = activeServer else { return nil }
        return OpenCodeClient(config: server)
    }

    var activeSession: Session? {
        guard let id = activeSessionID else { return nil }
        return sessions.first { $0.id == id }
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
        connectionState = .connecting
        log.info("connecting to \(server.baseURL, privacy: .public)")
        let client = OpenCodeClient(config: server)
        do {
            let health = try await client.health()
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
            log.error("connect failed: \(error.localizedDescription, privacy: .public)")
            connectionState = .failed((error as? OpenCodeError)?.errorDescription ?? error.localizedDescription)
        }
    }

    func disconnect() {
        streams.values.forEach { $0.stop() }
        streams.removeAll()
        connectionState = .disconnected
        messages = []
        sessions = []
        pendingPermissions = []
    }

    func switchServer(to server: ServerConfig) {
        disconnect()
        activeServer = server
        activeSessionID = nil
        messages = []
        Task { await connect() }
    }

    /// The opencode server reports only the *current* project via GET /project
    /// (never a list), so the switch-project list is derived from real
    /// workspaces: the distinct session directories plus the current project.
    /// The degenerate filesystem-root project ("/") is excluded.
    func refreshProjects() async {
        guard let api else { return }
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
        projects = byWorktree.values.sorted {
            ($0.worktree ?? $0.id) < ($1.worktree ?? $1.id)
        }
    }

    /// Switch the active workspace: stop all streams, reopen one scoped to the
    /// new directory, then reload its sessions.
    func switchProject(to worktree: String) async {
        guard worktree != activeDirectory else { return }
        streams.values.forEach { $0.stop() }
        streams.removeAll()
        activeDirectory = worktree
        activeSessionID = nil
        messages = []
        pendingPermissions = []
        await openStreams()
        await refreshSessions()
    }

    // MARK: - SSE

    /// Open the event stream for the active directory (or nil/default).
    func openStreams() async {
        guard let server = activeServer else { return }
        let client = OpenCodeClient(config: server)

        // The key one: stream scoped to the active directory.
        let key = activeDirectory ?? ""
        if streams[key] == nil {
            let stream = EventStream(directory: activeDirectory, client: client)
            streams[key] = stream
            stream.start()
            let events = stream.events()
            Task { await consume(events: events) }
        }
    }

    private func consume(events: AsyncStream<SSEEvent>) async {
        for await event in events {
            handle(event: event)
        }
    }

    private func handle(event: SSEEvent) {
        lastSSEEventAt = Date()
        let props = event.properties ?? [:]

        #if DEBUG
        log.info("SSE event: \(event.type, privacy: .public)")
        DebugLog.write("SSE: \(event.type)")
        #endif

        switch event.type {
        case "server.connected":
            connectionState = .connected

        case "session.status":
            if let e = props.decode(SessionStatusEvent.self) {
                if e.sessionID == activeSessionID {
                    activeSessionRunning = e.status?.running ?? false
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
                if sessionID == activeSessionID { activeSessionRunning = false }
            }

        case "message.updated":
            if let e = props.decode(MessageUpdatedEvent.self),
               e.sessionID == activeSessionID, let info = e.info {
                upsertMessageInfo(info)
            }

        case "message.part.updated":
            if let e = props.decode(MessagePartUpdatedEvent.self),
               e.sessionID == activeSessionID, let part = e.part {
                upsertPart(part)
            }

        case "message.part.delta":
            if let e = props.decode(MessagePartDeltaEvent.self),
               e.sessionID == activeSessionID, e.field == "text" {
                appendDelta(partID: e.partID, delta: e.delta ?? "")
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
                    permission: e.permission,
                    patterns: e.patterns,
                    metadata: e.metadata,
                    always: e.always,
                    tool: e.tool
                )
                if !pendingPermissions.contains(where: { $0.id == req.id }) {
                    pendingPermissions.append(req)
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
        if let idx = messages.firstIndex(where: { $0.info.id == info.id }) {
            messages[idx].info = info
        } else {
            messages.append(Message(info: info, parts: []))
            messages.sort { ($0.info.time?.created ?? 0) < ($1.info.time?.created ?? 0) }
        }
    }

    private func upsertPart(_ part: Part) {
        guard let mid = currentMessageID(for: part) else { return }
        if let mi = messages.firstIndex(where: { $0.info.id == mid }) {
            var parts = messages[mi].parts ?? []
            if let pi = parts.firstIndex(where: { $0.id == part.id }) {
                parts[pi] = part
            } else {
                parts.append(part)
                parts.sort { ($0.time?.created ?? 0) < ($1.time?.created ?? 0) }
            }
            messages[mi].parts = parts
        }
    }

    private func appendDelta(partID: String?, delta: String) {
        guard let partID else { return }
        // Find the message containing this part; usually the newest assistant msg.
        guard let mi = messages.indices.last else { return }
        var parts = messages[mi].parts ?? []
        guard let pi = parts.firstIndex(where: { $0.id == partID }) else {
            // Create a stub part so deltas still stream before part.updated lands.
            parts.append(Part(id: partID, type: "text", text: delta))
            parts.sort { ($0.time?.created ?? 0) < ($1.time?.created ?? 0) }
            messages[mi].parts = parts
            return
        }
        parts[pi].text = (parts[pi].text ?? "") + delta
        messages[mi].parts = parts
    }

    private func currentMessageID(for part: Part) -> String? {
        // Part carries no session message id; use the last assistant message,
        // which is where streaming lands.
        for message in messages.reversed() where message.info.role == "assistant" {
            if message.parts?.contains(where: { $0.id == part.id }) == true {
                return message.info.id
            }
        }
        return messages.last?.info.id
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

    func refreshSessions() async {
        guard let api else { return }
        do {
            let all = try await api.sessions(directory: activeDirectory)
            sessions = all.sorted { ($0.time?.updated ?? 0) > ($1.time?.updated ?? 0) }
            DebugLog.write("sessions: \(self.sessions.count) dir=\(self.activeDirectory ?? "nil")")
            log.info("sessions refreshed: \(self.sessions.count, privacy: .public) (dir=\(self.activeDirectory ?? "nil", privacy: .public))")
            if activeSessionID == nil, let first = sessions.first {
                activeSessionID = first.id
                await loadMessages(sessionID: first.id)
            }
        } catch {
            setError(error)
        }
    }

    func refreshCatalog() async {
        guard let api else { return }
        async let prov = try? api.providers()
        async let ags = try? api.agents()
        async let projs = try? api.projects()
        async let cmds = try? api.commands(directory: activeDirectory)
        async let skls = try? api.skills()
        providers = await prov
        agents = await ags ?? []
        projects = await projs ?? []
        commands = await cmds ?? []
        skills = await skls ?? []

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
        guard let api else { return }
        do {
            messages = try await api.messages(sessionID: sessionID, directory: activeDirectory)
            activeSessionID = sessionID
            if let session = sessions.first(where: { $0.id == sessionID }) {
                selectedModel = session.model ?? selectedModel
                selectedAgentID = session.agent ?? selectedAgentID
            }
            log.info("messages loaded: \(self.messages.count, privacy: .public) for \(sessionID, privacy: .public)")
        } catch {
            setError(error)
        }
    }

    /// Called on foreground: re-open the SSE stream (it was severed in
    /// background) and pull fresh message + session state to fill the gap.
    func reconcileOnForeground() async {
        guard connectionState == .connected else { return }
        DebugLog.write("reconcile on foreground")
        // Re-open streams (openStreams is idempotent — no-op if already alive).
        await openStreams()
        await refreshSessions()
        if let id = activeSessionID {
            await loadMessages(sessionID: id)
            if activeSessionRunning { startPollingIfNeeded() }
        }
    }

    func createSession() async {
        guard let api else { return }
        do {
            let session = try await api.createSession(
                directory: activeDirectory,
                agent: selectedAgentID,
                model: selectedModel
            )
            sessions.insert(session, at: 0)
            activeSessionID = session.id
            messages = []
        } catch {
            setError(error)
        }
    }

    func selectSession(_ id: String) {
        activeSessionID = id
        messages = []
        Task { await loadMessages(sessionID: id) }
    }

    func sendPrompt(_ text: String) async {
        guard let api, let id = activeSessionID, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        activeSessionRunning = true
        startPollingIfNeeded()
        do {
            try await api.promptAsync(
                sessionID: id,
                text: text,
                directory: activeDirectory,
                agent: selectedAgentID,
                model: selectedModel,
                variant: selectedVariant
            )
            // Refresh immediately so the user message appears; stream fills the rest.
            try? await Task.sleep(nanoseconds: 400_000_000)
            messages = try await api.messages(sessionID: id, directory: activeDirectory)
        } catch {
            activeSessionRunning = false
            setError(error)
        }
    }

    func abortSession() async {
        guard let api, let id = activeSessionID else { return }
        _ = try? await api.abortSession(id: id)
        activeSessionRunning = false
    }

    // MARK: - REST polling fallback (SSE silent / buffered)

    /// Start a lightweight poll loop while a task is running and SSE is silent.
    /// Mirrors the SSE-driven state updates via REST so streaming and task
    /// status still work through tunnels that buffer SSE entirely.
    func startPollingIfNeeded() {
        guard pollTask == nil, connectionState == .connected, activeSessionID != nil else { return }
        pollTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                guard !Task.isCancelled else { break }
                guard self.activeSessionRunning, self.activeSessionID != nil else { break }
                guard self.sseSilent else { continue }
                await self.pollActiveSession()
            }
            self.pollTask = nil
        }
    }

    private func pollActiveSession() async {
        guard let api, let id = activeSessionID else { return }
        if let statuses = try? await api.sessionStatuses(directory: activeDirectory) {
            // The dict only lists busy sessions; an absent entry means idle.
            activeSessionRunning = statuses[id]?.running ?? false
        }
        if let msgs = try? await api.messages(sessionID: id, directory: activeDirectory) {
            messages = msgs
        }
    }

    // MARK: - Permissions

    func respond(to permission: PermissionRequest, response: PermissionResponse) async {
        guard let api, let sessionID = permission.sessionID else {
            pendingPermissions.removeAll { $0.id == permission.id }
            return
        }
        do {
            _ = try await api.replyPermission(sessionID: sessionID, permissionID: permission.id, response: response)
            pendingPermissions.removeAll { $0.id == permission.id }
        } catch {
            setError(error)
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
        activeDirectory = dir
        await openStreams()

        do {
            let session = try await api.createSession(directory: dir, agent: "build", model: model)
            sessions.insert(session, at: 0)
            activeSessionID = session.id
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
