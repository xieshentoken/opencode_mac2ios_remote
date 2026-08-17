import Foundation

// MARK: - Typed API surface

/// High-level wrappers over the opencode REST endpoints.
/// Endpoint shapes verified against `/doc` on opencode 1.18.18.
struct OpenCodeAPI {
    let client: OpenCodeClient

    // MARK: Config

    func providers() async throws -> ProvidersResponse {
        try await client.get(ProvidersResponse.self, "/config/providers")
    }

    /// Full built-in provider registry (`GET /provider` → `{all: [...]}`),
    /// including providers that are not configured on the Mac yet. Used to
    /// show preset chips and to merge a freshly-added provider client-side.
    func providerRegistry() async throws -> [Provider] {
        let resp: ProviderRegistryResponse = try await client.get(ProviderRegistryResponse.self, "/provider")
        return resp.all ?? []
    }

    func agents() async throws -> [Agent] {
        try await client.get([Agent].self, "/agent")
    }

    func commands(directory: String?) async throws -> [Command] {
        try await client.get([Command].self, "/command", directory: directory)
    }

    func skills() async throws -> [Skill] {
        try await client.get([Skill].self, "/skill")
    }

    // MARK: MCP

    func mcpStatuses() async throws -> [String: MCPStatus] {
        try await client.get([String: MCPStatus].self, "/mcp")
    }

    func mcpConnect(name: String) async throws {
        let safe = name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? name
        _ = try await client.request("POST", "/mcp/\(safe)/connect")
    }

    func mcpDisconnect(name: String) async throws {
        let safe = name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? name
        _ = try await client.request("POST", "/mcp/\(safe)/disconnect")
    }

    func saveAPIKey(providerID: String, key: String, baseURL: String? = nil) async throws -> Bool {
        try await client.put(Bool.self, "/auth/\(providerID)", body: APIKeyBody(key: key, baseURL: baseURL))
    }

    func deleteAPIKey(providerID: String) async throws -> Bool {
        try await client.delete(Bool.self, "/auth/\(providerID)")
    }

    // MARK: Projects

    func projects() async throws -> [Project] {
        try await client.get([Project].self, "/project")
    }

    func gitInit(directory: String) async throws -> Project {
        try await client.post(Project.self, "/project/git/init", query: ["directory": directory])
    }

    func fileTree(directory: String) async throws -> [FileNode] {
        try await client.get([FileNode].self, "/file", query: ["path": directory])
    }

    func fileContent(path: String) async throws -> FileContent {
        try await client.get(FileContent.self, "/file/content", query: ["path": path])
    }

    func findFiles(query: String, directory: String?) async throws -> [String] {
        try await client.get(
            [String].self,
            "/find/file",
            query: ["query": query, "type": "file", "limit": "60"],
            directory: directory
        )
    }

    // MARK: Sessions

    func sessions(directory: String?) async throws -> [Session] {
        try await client.get([Session].self, "/session", directory: directory)
    }

    func sessionStatuses(directory: String?) async throws -> [String: SessionStatus] {
        try await client.get([String: SessionStatus].self, "/session/status", directory: directory)
    }

    func createSession(directory: String?, title: String? = nil, agent: String? = nil, model: ModelRef? = nil) async throws -> Session {
        try await client.post(Session.self, "/session", directory: directory, body: SessionCreateBody(title: title, agent: agent, model: model))
    }

    func session(id: String) async throws -> Session {
        try await client.get(Session.self, "/session/\(id)")
    }

    func deleteSession(id: String) async throws -> Bool {
        try await client.delete(Bool.self, "/session/\(id)")
    }

    func patchSession(id: String, title: String) async throws -> Session {
        let data = try await client.request("PATCH", "/session/\(id)", body: ["title": title])
        return try JSONDecoder.oc.decode(Session.self, from: data)
    }

    func abortSession(id: String) async throws -> Bool {
        try await client.post(Bool.self, "/session/\(id)/abort")
    }

    // MARK: Messages

    func messages(sessionID: String, directory: String? = nil, limit: Int = 1000) async throws -> [Message] {
        try await client.get([Message].self, "/session/\(sessionID)/message", query: ["limit": "\(limit)"], directory: directory)
    }

    /// Non-blocking prompt. Progress arrives over SSE. `variant` is the
    /// model's reasoning effort (e.g. low/medium/high/max) from its
    /// `variants` list; nil = model default.
    func promptAsync(sessionID: String, text: String, directory: String? = nil, agent: String? = nil, model: ModelRef? = nil, variant: String? = nil) async throws {
        let promptModel = model.flatMap { m in
            m.providerID.map { PromptModel(modelID: m.id, providerID: $0) }
        }
        let body = PromptBody(parts: [PromptBody.Part(text: text)], agent: agent, model: promptModel, variant: variant)
        try await client.postNoContent("/session/\(sessionID)/prompt_async", directory: directory, body: body)
    }

    // MARK: Permissions

    func replyPermission(sessionID: String, permissionID: String, response: PermissionResponse) async throws -> Bool {
        try await client.post(Bool.self, "/session/\(sessionID)/permissions/\(permissionID)", body: PermissionReplyBody(response: response))
    }
}

// MARK: - Request bodies

struct SessionCreateBody: Codable {
    var title: String?
    var agent: String?
    var model: ModelRef?
}

struct PromptBody: Codable {
    struct Part: Codable {
        var type: String = "text"
        var text: String
    }
    var parts: [Part]
    var agent: String?
    var model: PromptModel?
    var variant: String?
}

/// The prompt endpoints want `modelID` (session create wants `id`).
struct PromptModel: Codable {
    var modelID: String
    var providerID: String
}

struct PermissionReplyBody: Codable {
    var response: PermissionResponse
}

struct APIKeyBody: Codable {
    var type = "api"
    var key: String
    var metadata: [String: String]?

    init(key: String, baseURL: String?) {
        self.key = key
        if let baseURL, !baseURL.trimmingCharacters(in: .whitespaces).isEmpty {
            self.metadata = ["baseURL": baseURL]
        }
    }
}

struct ProviderRegistryResponse: Codable {
    var all: [Provider]?
}
