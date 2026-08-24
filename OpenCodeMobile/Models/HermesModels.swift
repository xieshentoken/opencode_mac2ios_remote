import Foundation

// MARK: - Lenient JSON

/// A Sendable JSON value used by the Hermes JSON-RPC boundary.
///
/// Hermes evolves quickly and intentionally adds fields to events. Keeping the
/// RPC boundary dynamic lets an older app ignore new fields without failing an
/// otherwise valid response.
enum HermesJSONValue: Codable, Hashable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: HermesJSONValue])
    case array([HermesJSONValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([HermesJSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: HermesJSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported Hermes JSON value"
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    var stringValue: String? {
        switch self {
        case .string(let value): return value
        case .number(let value):
            return value.rounded() == value ? String(Int64(value)) : String(value)
        case .bool(let value): return String(value)
        default: return nil
        }
    }

    var boolValue: Bool? {
        switch self {
        case .bool(let value): return value
        case .number(let value): return value != 0
        case .string(let value):
            switch value.lowercased() {
            case "true", "yes", "1": return true
            case "false", "no", "0": return false
            default: return nil
            }
        default: return nil
        }
    }

    var intValue: Int? {
        switch self {
        case .number(let value): return Int(exactly: value)
        case .string(let value): return Int(value)
        default: return nil
        }
    }

    var doubleValue: Double? {
        switch self {
        case .number(let value): return value
        case .string(let value): return Double(value)
        default: return nil
        }
    }

    var objectValue: HermesJSONObject? {
        guard case .object(let value) = self else { return nil }
        return value
    }

    var arrayValue: [HermesJSONValue]? {
        guard case .array(let value) = self else { return nil }
        return value
    }
}

typealias HermesJSONObject = [String: HermesJSONValue]

// MARK: - Dashboard status and authentication

struct HermesStatus: Codable, Equatable, Sendable {
    var version: String?
    var releaseDate: String?
    var gatewayRunning: Bool?
    var gatewayState: String?
    var gatewayBusy: Bool?
    var activeAgents: Int?
    var activeSessions: Int?
    var authRequired: Bool?
    var authProviders: [String]?
    var authFlows: [String]?
    var overall: String?
    var components: HermesJSONObject?

    var requiresAuthentication: Bool { authRequired ?? false }
    var isGatewayAvailable: Bool { gatewayRunning ?? true }

    enum CodingKeys: String, CodingKey {
        case version
        case releaseDate = "release_date"
        case gatewayRunning = "gateway_running"
        case gatewayState = "gateway_state"
        case gatewayBusy = "gateway_busy"
        case activeAgents = "active_agents"
        case activeSessions = "active_sessions"
        case authRequired = "auth_required"
        case authProviders = "auth_providers"
        case authFlows = "auth_flows"
        case overall, components
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = container.flexibleString(forKey: .version)
        releaseDate = container.flexibleString(forKey: .releaseDate)
        gatewayRunning = container.flexibleBool(forKey: .gatewayRunning)
        gatewayState = container.flexibleString(forKey: .gatewayState)
        gatewayBusy = container.flexibleBool(forKey: .gatewayBusy)
        activeAgents = container.flexibleInt(forKey: .activeAgents)
        activeSessions = container.flexibleInt(forKey: .activeSessions)
        authRequired = container.flexibleBool(forKey: .authRequired)
        authProviders = container.flexibleStringArray(forKey: .authProviders)
        authFlows = container.flexibleStringArray(forKey: .authFlows)
        overall = container.flexibleString(forKey: .overall)
        components = try? container.decodeIfPresent(HermesJSONObject.self, forKey: .components)
    }

    init(
        version: String? = nil,
        releaseDate: String? = nil,
        gatewayRunning: Bool? = nil,
        gatewayState: String? = nil,
        gatewayBusy: Bool? = nil,
        activeAgents: Int? = nil,
        activeSessions: Int? = nil,
        authRequired: Bool? = nil,
        authProviders: [String]? = nil,
        authFlows: [String]? = nil,
        overall: String? = nil,
        components: HermesJSONObject? = nil
    ) {
        self.version = version
        self.releaseDate = releaseDate
        self.gatewayRunning = gatewayRunning
        self.gatewayState = gatewayState
        self.gatewayBusy = gatewayBusy
        self.activeAgents = activeAgents
        self.activeSessions = activeSessions
        self.authRequired = authRequired
        self.authProviders = authProviders
        self.authFlows = authFlows
        self.overall = overall
        self.components = components
    }
}

struct HermesAuthProvider: Codable, Equatable, Identifiable, Sendable {
    var name: String
    var displayName: String?
    var supportsPassword: Bool?

    var id: String { name }

    enum CodingKeys: String, CodingKey {
        case name
        case displayName = "display_name"
        case supportsPassword = "supports_password"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = container.flexibleString(forKey: .name) ?? ""
        displayName = container.flexibleString(forKey: .displayName)
        supportsPassword = container.flexibleBool(forKey: .supportsPassword)
    }

    init(name: String, displayName: String? = nil, supportsPassword: Bool? = nil) {
        self.name = name
        self.displayName = displayName
        self.supportsPassword = supportsPassword
    }
}

struct HermesAuthProvidersResponse: Codable, Equatable, Sendable {
    var providers: [HermesAuthProvider]

    init(providers: [HermesAuthProvider] = []) {
        self.providers = providers
    }

    enum CodingKeys: CodingKey { case providers }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        providers = (try? container.decodeIfPresent([HermesAuthProvider].self, forKey: .providers)) ?? []
    }
}

struct HermesPasswordLoginResponse: Codable, Equatable, Sendable {
    var ok: Bool?
    var next: String?
}

struct HermesAuthIdentity: Codable, Equatable, Sendable {
    var userID: String?
    var email: String?
    var displayName: String?
    var orgID: String?
    var provider: String?
    var expiresAt: Int?

    enum CodingKeys: String, CodingKey {
        case userID = "user_id"
        case email
        case displayName = "display_name"
        case orgID = "org_id"
        case provider
        case expiresAt = "expires_at"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        userID = container.flexibleString(forKey: .userID)
        email = container.flexibleString(forKey: .email)
        displayName = container.flexibleString(forKey: .displayName)
        orgID = container.flexibleString(forKey: .orgID)
        provider = container.flexibleString(forKey: .provider)
        expiresAt = container.flexibleInt(forKey: .expiresAt)
    }
}

struct HermesWSTicketResponse: Codable, Equatable, Sendable {
    var ticket: String
    var ttlSeconds: Int?

    enum CodingKeys: String, CodingKey {
        case ticket
        case ttlSeconds = "ttl_seconds"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        ticket = container.flexibleString(forKey: .ticket) ?? ""
        ttlSeconds = container.flexibleInt(forKey: .ttlSeconds)
    }

    init(ticket: String, ttlSeconds: Int? = nil) {
        self.ticket = ticket
        self.ttlSeconds = ttlSeconds
    }
}

// MARK: - Dashboard REST sessions

struct HermesDashboardSession: Codable, Hashable, Identifiable, Sendable {
    var id: String
    var title: String?
    var preview: String?
    var source: String?
    var model: String?
    var cwd: String?
    var startedAt: Double?
    var lastActive: Double?
    var endedAt: Double?
    var messageCount: Int?
    var isActive: Bool?
    var archived: Bool?
    var pinned: Bool?
    var profile: String?

    enum CodingKeys: String, CodingKey {
        case id, title, preview, source, model, cwd
        case startedAt = "started_at"
        case lastActive = "last_active"
        case endedAt = "ended_at"
        case messageCount = "message_count"
        case isActive = "is_active"
        case archived, pinned, profile
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = container.flexibleString(forKey: .id) ?? ""
        title = container.flexibleString(forKey: .title)
        preview = container.flexibleString(forKey: .preview)
        source = container.flexibleString(forKey: .source)
        model = container.flexibleString(forKey: .model)
        cwd = container.flexibleString(forKey: .cwd)
        startedAt = container.flexibleDouble(forKey: .startedAt)
        lastActive = container.flexibleDouble(forKey: .lastActive)
        endedAt = container.flexibleDouble(forKey: .endedAt)
        messageCount = container.flexibleInt(forKey: .messageCount)
        isActive = container.flexibleBool(forKey: .isActive)
        archived = container.flexibleBool(forKey: .archived)
        pinned = container.flexibleBool(forKey: .pinned)
        profile = container.flexibleString(forKey: .profile)
    }
}

struct HermesDashboardSessionListResponse: Codable, Sendable {
    var sessions: [HermesDashboardSession]
    var total: Int?
    var limit: Int?
    var offset: Int?

    enum CodingKeys: CodingKey { case sessions, total, limit, offset }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sessions = (try? container.decodeIfPresent([HermesDashboardSession].self, forKey: .sessions)) ?? []
        total = container.flexibleInt(forKey: .total)
        limit = container.flexibleInt(forKey: .limit)
        offset = container.flexibleInt(forKey: .offset)
    }
}

struct HermesTranscriptMessage: Codable, Hashable, Sendable {
    var rowID: String?
    var role: String
    var text: String?
    var content: HermesJSONValue?
    var name: String?
    var context: String?
    var displayKind: String?
    var displayMetadata: HermesJSONObject?
    var toolCalls: [HermesJSONValue]?
    var createdAt: Double?

    /// Gateway transcripts use `text`; dashboard DB rows use `content`.
    var displayText: String? {
        if let text, !text.isEmpty { return text }
        guard let content else { return nil }
        switch content {
        case .string(let value): return value
        case .array(let values):
            let pieces = values.compactMap { value -> String? in
                if let string = value.stringValue { return string }
                if let object = value.objectValue {
                    return object["text"]?.stringValue ?? object["content"]?.stringValue
                }
                return nil
            }
            return pieces.isEmpty ? nil : pieces.joined(separator: "\n")
        default: return content.stringValue
        }
    }

    enum CodingKeys: String, CodingKey {
        case id
        case rowID = "row_id"
        case role, text, content, name, context
        case displayKind = "display_kind"
        case displayMetadata = "display_metadata"
        case toolCalls = "tool_calls"
        case createdAt = "created_at"
        case timestamp
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        rowID = container.flexibleString(forKey: .rowID) ?? container.flexibleString(forKey: .id)
        role = container.flexibleString(forKey: .role) ?? "system"
        text = container.flexibleString(forKey: .text)
        content = try? container.decodeIfPresent(HermesJSONValue.self, forKey: .content)
        name = container.flexibleString(forKey: .name)
        context = container.flexibleString(forKey: .context)
        displayKind = container.flexibleString(forKey: .displayKind)
        displayMetadata = try? container.decodeIfPresent(HermesJSONObject.self, forKey: .displayMetadata)
        toolCalls = try? container.decodeIfPresent([HermesJSONValue].self, forKey: .toolCalls)
        createdAt = container.flexibleDouble(forKey: .createdAt)
            ?? container.flexibleDouble(forKey: .timestamp)
    }

    init(
        rowID: String? = nil,
        role: String,
        text: String? = nil,
        content: HermesJSONValue? = nil,
        name: String? = nil,
        context: String? = nil,
        displayKind: String? = nil,
        displayMetadata: HermesJSONObject? = nil,
        toolCalls: [HermesJSONValue]? = nil,
        createdAt: Double? = nil
    ) {
        self.rowID = rowID
        self.role = role
        self.text = text
        self.content = content
        self.name = name
        self.context = context
        self.displayKind = displayKind
        self.displayMetadata = displayMetadata
        self.toolCalls = toolCalls
        self.createdAt = createdAt
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(rowID, forKey: .rowID)
        try container.encode(role, forKey: .role)
        try container.encodeIfPresent(text, forKey: .text)
        try container.encodeIfPresent(content, forKey: .content)
        try container.encodeIfPresent(name, forKey: .name)
        try container.encodeIfPresent(context, forKey: .context)
        try container.encodeIfPresent(displayKind, forKey: .displayKind)
        try container.encodeIfPresent(displayMetadata, forKey: .displayMetadata)
        try container.encodeIfPresent(toolCalls, forKey: .toolCalls)
        try container.encodeIfPresent(createdAt, forKey: .createdAt)
    }
}

struct HermesDashboardMessagesResponse: Codable, Sendable {
    var sessionID: String?
    var messages: [HermesTranscriptMessage]
    var pagination: HermesPagination?

    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case messages, pagination
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sessionID = container.flexibleString(forKey: .sessionID)
        messages = (try? container.decodeIfPresent([HermesTranscriptMessage].self, forKey: .messages)) ?? []
        pagination = try? container.decodeIfPresent(HermesPagination.self, forKey: .pagination)
    }
}

struct HermesPagination: Codable, Equatable, Sendable {
    var limit: Int?
    var offset: Int?
    var returned: Int?
}

struct HermesOperationResponse: Codable, Equatable, Sendable {
    var ok: Bool?
    var deleted: String?
    var alreadyAbsent: Bool?

    enum CodingKeys: String, CodingKey {
        case ok, deleted
        case alreadyAbsent = "already_absent"
    }
}

// MARK: - Gateway session results

struct HermesGatewaySessionListItem: Codable, Hashable, Identifiable, Sendable {
    var id: String
    var title: String
    var preview: String
    var source: String?
    var startedAt: Double
    var messageCount: Int

    enum CodingKeys: String, CodingKey {
        case id, title, preview, source
        case startedAt = "started_at"
        case messageCount = "message_count"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = container.flexibleString(forKey: .id) ?? ""
        title = container.flexibleString(forKey: .title) ?? ""
        preview = container.flexibleString(forKey: .preview) ?? ""
        source = container.flexibleString(forKey: .source)
        startedAt = container.flexibleDouble(forKey: .startedAt) ?? 0
        messageCount = container.flexibleInt(forKey: .messageCount) ?? 0
    }
}

struct HermesGatewaySessionListResponse: Codable, Sendable {
    var sessions: [HermesGatewaySessionListItem]

    init(sessions: [HermesGatewaySessionListItem] = []) {
        self.sessions = sessions
    }

    enum CodingKeys: CodingKey { case sessions }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sessions = (try? container.decodeIfPresent([HermesGatewaySessionListItem].self, forKey: .sessions)) ?? []
    }
}

struct HermesSessionInfo: Codable, Hashable, Sendable {
    var model: String?
    var provider: String?
    var cwd: String?
    var branch: String?
    var project: HermesJSONValue?
    var lazy: Bool?
}

struct HermesInflightTurn: Codable, Hashable, Sendable {
    var assistant: String?
    var streaming: Bool?
    var user: String?
}

struct HermesSessionCreateResponse: Codable, Sendable {
    /// Ephemeral runtime ID. All live RPC/events use this value.
    var sessionID: String
    /// Durable database ID. Persist this in UI/navigation state.
    var storedSessionID: String?
    var messageCount: Int?
    var messages: [HermesTranscriptMessage]
    var info: HermesSessionInfo?

    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case storedSessionID = "stored_session_id"
        case messageCount = "message_count"
        case messages, info
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sessionID = container.flexibleString(forKey: .sessionID) ?? ""
        storedSessionID = container.flexibleString(forKey: .storedSessionID)
        messageCount = container.flexibleInt(forKey: .messageCount)
        messages = (try? container.decodeIfPresent([HermesTranscriptMessage].self, forKey: .messages)) ?? []
        info = try? container.decodeIfPresent(HermesSessionInfo.self, forKey: .info)
    }
}

struct HermesSessionResumeResponse: Codable, Sendable {
    /// New ephemeral runtime ID minted for this gateway attachment.
    var sessionID: String
    /// Durable session ID actually resumed (may be a compression descendant).
    var resumed: String?
    var sessionKey: String?
    var messages: [HermesTranscriptMessage]
    var messageCount: Int?
    var running: Bool?
    var status: String?
    var inflight: HermesInflightTurn?
    var info: HermesSessionInfo?
    var startedAt: Double?

    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case resumed
        case sessionKey = "session_key"
        case messages
        case messageCount = "message_count"
        case running, status, inflight, info
        case startedAt = "started_at"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sessionID = container.flexibleString(forKey: .sessionID) ?? ""
        resumed = container.flexibleString(forKey: .resumed)
        sessionKey = container.flexibleString(forKey: .sessionKey)
        messages = (try? container.decodeIfPresent([HermesTranscriptMessage].self, forKey: .messages)) ?? []
        messageCount = container.flexibleInt(forKey: .messageCount)
        running = container.flexibleBool(forKey: .running)
        status = container.flexibleString(forKey: .status)
        inflight = try? container.decodeIfPresent(HermesInflightTurn.self, forKey: .inflight)
        info = try? container.decodeIfPresent(HermesSessionInfo.self, forKey: .info)
        startedAt = container.flexibleDouble(forKey: .startedAt)
    }
}

struct HermesSessionHistoryResponse: Codable, Sendable {
    var count: Int?
    var messages: [HermesTranscriptMessage]

    enum CodingKeys: CodingKey { case count, messages }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        count = container.flexibleInt(forKey: .count)
        messages = (try? container.decodeIfPresent([HermesTranscriptMessage].self, forKey: .messages)) ?? []
    }
}

struct HermesPromptSubmitResponse: Codable, Equatable, Sendable {
    var ok: Bool?
    var status: String?
    var voiceStopped: Bool?

    enum CodingKeys: String, CodingKey {
        case ok, status
        case voiceStopped = "voice_stopped"
    }
}

struct HermesRPCOKResponse: Codable, Equatable, Sendable {
    var ok: Bool?
    var status: String?
    var resolved: Bool?

    enum CodingKeys: CodingKey { case ok, status, resolved }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        ok = container.flexibleBool(forKey: .ok)
        status = container.flexibleString(forKey: .status)
        resolved = container.flexibleBool(forKey: .resolved)
    }

    init(ok: Bool? = nil, status: String? = nil, resolved: Bool? = nil) {
        self.ok = ok
        self.status = status
        self.resolved = resolved
    }
}

// MARK: - JSON-RPC envelope and events

enum HermesRPCID: Codable, Hashable, Sendable {
    case string(String)
    case number(Int)

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode(Int.self) {
            self = .number(value)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid JSON-RPC id")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        }
    }

    var stringValue: String {
        switch self {
        case .string(let value): return value
        case .number(let value): return String(value)
        }
    }
}

struct HermesRPCErrorPayload: Codable, Equatable, Sendable {
    var code: Int
    var message: String
    var data: HermesJSONValue?
}

struct HermesRPCEnvelope: Codable, Sendable {
    var jsonrpc: String?
    var id: HermesRPCID?
    var method: String?
    var params: HermesJSONValue?
    var result: HermesJSONValue?
    var error: HermesRPCErrorPayload?

    var gatewayEvent: HermesGatewayEvent? {
        guard method == "event", let object = params?.objectValue else { return nil }
        return HermesGatewayEvent(parameters: object)
    }
}

struct HermesGatewayEvent: Hashable, Sendable {
    var type: String
    /// Ephemeral runtime session ID, never a durable history identifier.
    var sessionID: String?
    var payload: HermesJSONObject
    var rawPayload: HermesJSONValue?

    init(type: String, sessionID: String? = nil, payload: HermesJSONObject = [:]) {
        self.type = type
        self.sessionID = sessionID
        self.payload = payload
        self.rawPayload = .object(payload)
    }

    init(parameters: HermesJSONObject) {
        type = parameters["type"]?.stringValue ?? "unknown"
        sessionID = parameters["session_id"]?.stringValue
        rawPayload = parameters["payload"]
        payload = rawPayload?.objectValue ?? [:]
    }

    var text: String? {
        payload["text"]?.stringValue
            ?? payload["rendered"]?.stringValue
            ?? payload["message"]?.stringValue
    }

    var requestID: String? { payload["request_id"]?.stringValue }

    static func disconnected(code: Int? = nil) -> HermesGatewayEvent {
        var payload: HermesJSONObject = [:]
        if let code { payload["code"] = .number(Double(code)) }
        return HermesGatewayEvent(type: "client.disconnected", payload: payload)
    }
}

struct HermesApprovalRequest: Hashable, Sendable {
    var command: String
    var description: String
    var choices: [String]
    var allowPermanent: Bool
    var smartDenied: Bool

    init?(event: HermesGatewayEvent) {
        guard event.type == "approval.request" else { return nil }
        command = event.payload["command"]?.stringValue ?? ""
        description = event.payload["description"]?.stringValue ?? ""
        choices = event.payload["choices"]?.arrayValue?.compactMap(\.stringValue) ?? []
        // Hermes omits this field for the normal permissive case; only an
        // explicit false disables persistent approval.
        allowPermanent = event.payload["allow_permanent"]?.boolValue ?? true
        smartDenied = event.payload["smart_denied"]?.boolValue ?? false
    }
}

enum HermesInputRequestKind: String, Hashable, Sendable {
    case clarify
    case sudo
    case secret
}

struct HermesInputRequest: Hashable, Identifiable, Sendable {
    var id: String
    var kind: HermesInputRequestKind
    var sessionID: String?
    var prompt: String
    var choices: [String]
    var environmentVariable: String?

    init?(event: HermesGatewayEvent) {
        guard let requestID = event.requestID else { return nil }
        switch event.type {
        case "clarify.request":
            kind = .clarify
            prompt = event.payload["question"]?.stringValue ?? "Input required"
            choices = event.payload["choices"]?.arrayValue?.compactMap(\.stringValue) ?? []
            environmentVariable = nil
        case "sudo.request":
            kind = .sudo
            prompt = "Administrator password required"
            choices = []
            environmentVariable = nil
        case "secret.request":
            kind = .secret
            environmentVariable = event.payload["env_var"]?.stringValue
            prompt = event.payload["prompt"]?.stringValue
                ?? environmentVariable.map { "Enter secret for \($0)" }
                ?? "Secret required"
            choices = []
        default:
            return nil
        }
        id = requestID
        sessionID = event.sessionID
    }
}

// MARK: - Flexible decoding helpers

private extension KeyedDecodingContainer {
    func flexibleValue(forKey key: Key) -> HermesJSONValue? {
        try? decodeIfPresent(HermesJSONValue.self, forKey: key)
    }

    func flexibleString(forKey key: Key) -> String? {
        flexibleValue(forKey: key)?.stringValue
    }

    func flexibleBool(forKey key: Key) -> Bool? {
        flexibleValue(forKey: key)?.boolValue
    }

    func flexibleInt(forKey key: Key) -> Int? {
        flexibleValue(forKey: key)?.intValue
    }

    func flexibleDouble(forKey key: Key) -> Double? {
        flexibleValue(forKey: key)?.doubleValue
    }

    func flexibleStringArray(forKey key: Key) -> [String]? {
        guard let values = flexibleValue(forKey: key)?.arrayValue else { return nil }
        let strings = values.compactMap { value -> String? in
            value.stringValue ?? value.objectValue?["name"]?.stringValue
        }
        return strings
    }
}
