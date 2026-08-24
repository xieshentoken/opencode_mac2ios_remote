import Foundation

// MARK: - Server / Health

struct Health: Codable, Equatable {
    var healthy: Bool
    var version: String
}

// MARK: - Provider & Model

struct Provider: Codable, Identifiable {
    var id: String
    var name: String?
    var source: String?
    var env: [String]?
    var key: String?
    var models: [String: ProviderModel]?
    var npm: String?
}

struct ProviderModel: Codable, Identifiable {
    var id: String
    var name: String?
    var limit: ProviderModelLimit?
    var options: [String: JSONValue]?
    var cost: ProviderModelCost?
    var reasoning: Bool?
    var tool: Bool?
    var web: Bool?
    /// Reasoning-effort levels: a DICT keyed by variant name
    /// (`{"low": {...}, "high": {...}}`) — NOT an array.
    var variants: [String: JSONValue]?
}

struct ProviderModelLimit: Codable {
    var context: Int?
    var output: Int?
}

struct ProviderModelCost: Codable {
    var input: Double?
    var output: Double?
    var cacheRead: Double?
    var cacheWrite: Double?
}

struct ProvidersResponse: Codable {
    var providers: [Provider]?
    var defaultModel: [String: String]?

    enum CodingKeys: String, CodingKey {
        case providers
        case defaultModel = "default"
    }
}

// MARK: - Agent

struct Agent: Codable, Identifiable {
    var id: String { name }
    var name: String
    var description: String?
    var mode: String?
    var model: ModelRef?
    var hidden: Bool?
    var native: Bool?
}

struct Command: Codable, Identifiable, Hashable {
    var id: String { name }
    var name: String
    var description: String?
    var agent: String?
    var model: String?
    var source: String?
    var template: String?
    var subtask: Bool?
    var hints: [String]?
}

struct Skill: Codable, Identifiable, Hashable {
    var id: String { name }
    var name: String
    var description: String?
    var location: String?
}

struct MCPStatus: Codable, Hashable {
    var status: String?
    var error: String?
    var connected: Bool { status == "connected" }
}

// MARK: - Model reference

struct ModelRef: Codable, Equatable, Hashable {
    var id: String
    var providerID: String?
    var variant: String?

    init(id: String, providerID: String? = nil, variant: String? = nil) {
        self.id = id
        self.providerID = providerID
        self.variant = variant
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id)
            ?? c.decode(String.self, forKey: .modelID)
        providerID = try c.decodeIfPresent(String.self, forKey: .providerID)
        variant = try c.decodeIfPresent(String.self, forKey: .variant)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encodeIfPresent(providerID, forKey: .providerID)
        try c.encodeIfPresent(variant, forKey: .variant)
    }

    enum CodingKeys: String, CodingKey {
        case id, modelID, providerID, variant
    }
}

// MARK: - Session

struct Session: Codable, Identifiable, Hashable {
    var id: String
    var slug: String?
    var directory: String?
    var projectID: String?
    var workspaceID: String?
    var path: String?
    var parentID: String?
    var title: String?
    var agent: String?
    var model: ModelRef?
    var summary: SessionSummary?
    var cost: Double?
    var tokens: TokenUsage?
    var time: SessionTime?
    var version: String?
    var share: SessionShare?
}

struct SessionSummary: Codable, Hashable {
    var additions: Int?
    var deletions: Int?
    var files: Int?
    var diffs: [SnapshotFileDiff]?
}

struct SnapshotFileDiff: Codable, Hashable {
    var file: String?
    var patch: String?
    var additions: Int?
    var deletions: Int?
    var status: String?
}

struct TokenUsage: Codable, Hashable {
    var input: Int?
    var output: Int?
    var reasoning: Int?
    var cache: TokenCache?
}

struct TokenCache: Codable, Hashable {
    var read: Int?
    var write: Int?
}

struct SessionTime: Codable, Hashable {
    var created: Int?
    var updated: Int?
}

struct SessionShare: Codable, Hashable {
    var url: String?
}

struct SessionStatus: Codable, Hashable {
    var type: String?
    var message: String?
    var attempt: Int?
    var running: Bool { type == "busy" || type == "retry" }
}

// MARK: - Message & Parts

struct MessageInfo: Codable, Identifiable, Hashable {
    var id: String
    var sessionID: String?
    var role: String
    var modelID: String?
    var providerID: String?
    var agent: String?
    var time: MessageTime?
    var error: JSONValue?
    var metadata: JSONObject?
    var token: MessageToken?
}

struct MessageTime: Codable, Hashable {
    var created: Int?
    var completed: Int?
    var updated: Int?
}

struct MessageToken: Codable, Hashable {
    var input: Int?
    var output: Int?
    var reasoning: Int?
    var cache: TokenCache?
}

struct Message: Codable, Identifiable, Hashable {
    var id: String { info.id }
    var info: MessageInfo
    var parts: [Part]?
}

enum PartType: String, Codable {
    case text
    case reasoning
    case tool
    case stepStart = "step-start"
    case stepFinish = "step-finish"
    case file
    case patch
    case snapshot
    case compaction
    case agent
    case subtask
    case retry
}

struct Part: Codable, Identifiable, Hashable {
    var id: String
    var sessionID: String?
    var messageID: String?
    var type: String
    var text: String?
    var state: PartState?
    var tool: String?
    var callID: String?
    var input: JSONValue?
    var output: JSONValue?
    var metadata: JSONObject?
    var time: MessageTime?
    var stepID: String?
    var duration: Int?
    var tokens: TokenUsage?
    var progress: PartProgress?
    var file: PartFile?
    var toolName: String?

    enum CodingKeys: String, CodingKey {
        case id, sessionID, messageID, type, text, state, tool, callID, input, output, metadata, time, stepID, duration, tokens, progress, file, toolName
    }
}

struct PartProgress: Codable, Hashable {
    var current: Int?
    var total: Int?
}

struct PartFile: Codable, Hashable {
    var path: String?
    var content: String?
}

enum PartState: String, Hashable {
    case pending
    case running
    case completed
    case error
    case cancelled
    case loading
    case accepted
    case rejected
    case unknown
}

extension PartState: Codable {
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(String.self) {
            self = PartState(rawValue: value) ?? .unknown
            return
        }
        if let object = try? container.decode(JSONObject.self),
           case .string(let value)? = object["status"] {
            self = PartState(rawValue: value) ?? .unknown
            return
        }
        self = .unknown
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

// MARK: - Permission

struct PermissionRequest: Codable, Identifiable, Hashable {
    var id: String
    var sessionID: String?
    /// Originating backend. nil decodes as legacy OpenCode state.
    var backend: ServerKind? = nil
    /// Hermes approvals are routed to a short-lived live session ID and are
    /// answered FIFO; OpenCode leaves this nil and uses request `id`.
    var runtimeSessionID: String? = nil
    /// Directory-scoped opencode instance that emitted this request. This is
    /// client routing state, retained so approval still reaches the right
    /// instance after the user switches projects.
    var directory: String?
    var permission: String?
    var patterns: [String]?
    var metadata: JSONObject?
    var always: [String]?
    var tool: PermissionTool?
}

struct PermissionTool: Codable, Hashable {
    var messageID: String?
    var callID: String?
}

extension PermissionRequest {
    /// Human-readable summary of what the agent wants to do, extracted from
    /// the request metadata (command/pattern/description), falling back to
    /// the first pattern.
    var commandText: String? {
        if case .string(let c)? = metadata?["command"] { return c }
        if case .string(let s)? = metadata?["pattern"] { return s }
        if case .string(let s)? = metadata?["description"] { return s }
        return patterns?.first
    }
}

enum PermissionResponse: String, Codable, CaseIterable {
    case once
    case always
    case reject
}

// MARK: - Agent interaction (Hermes clarify / sudo / secret)

enum AgentInputKind: String, Codable, Hashable {
    case clarify
    case sudo
    case secret

    var requiresSecureEntry: Bool { self == .sudo || self == .secret }
}

struct AgentInputRequest: Identifiable, Codable, Hashable {
    var id: String
    var sessionID: String
    var runtimeSessionID: String
    var kind: AgentInputKind
    var prompt: String
    var choices: [String]
    var multiSelect: Bool
}

// MARK: - Project

struct Project: Codable, Identifiable, Hashable {
    var id: String
    var worktree: String?
    var workspaceID: String?
    var status: String?
}

// MARK: - File tree

struct FileNode: Codable, Hashable, Identifiable {
    var id: String { path }
    var name: String
    var path: String
    var type: String
    var children: [FileNode]?
}

struct FileContent: Codable {
    var name: String?
    var path: String?
    var content: String?
}

// MARK: - Lenient JSON values (tolerate anything the server sends)

enum JSONValue: Codable, Hashable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null; return }
        if let b = try? c.decode(Bool.self) { self = .bool(b); return }
        if let n = try? c.decode(Double.self) { self = .number(n); return }
        if let s = try? c.decode(String.self) { self = .string(s); return }
        if let a = try? c.decode([JSONValue].self) { self = .array(a); return }
        if let o = try? c.decode([String: JSONValue].self) { self = .object(o); return }
        throw DecodingError.dataCorruptedError(in: c, debugDescription: "Unknown JSON value")
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let s): try c.encode(s)
        case .number(let n): try c.encode(n)
        case .bool(let b): try c.encode(b)
        case .object(let o): try c.encode(o)
        case .array(let a): try c.encode(a)
        case .null: try c.encodeNil()
        }
    }
}

typealias JSONObject = [String: JSONValue]
