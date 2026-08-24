import Foundation

/// Envelope of every SSE event. Unknown `type` values are preserved as raw
/// JSON so the app tolerates version skew without crashing.
struct SSEEvent: Codable {
    var id: String?
    var type: String
    var properties: JSONObject?
}

// MARK: - Typed event properties (decoded lazily from `properties`)

struct MessageUpdatedEvent: Codable {
    var sessionID: String?
    var info: MessageInfo?
}

struct MessagePartUpdatedEvent: Codable {
    var sessionID: String?
    var messageID: String?
    var part: Part?
    var time: Double?
}

struct MessagePartDeltaEvent: Codable {
    var sessionID: String?
    var messageID: String?
    var partID: String?
    var field: String?
    var delta: String?
}

struct MessageRemovedEvent: Codable {
    var sessionID: String?
    var messageID: String?
}

struct MessagePartRemovedEvent: Codable {
    var sessionID: String?
    var messageID: String?
    var partID: String?
}

struct SessionUpdatedEvent: Codable {
    var sessionID: String?
    var session: Session?
}

struct SessionCreatedEvent: Codable {
    var session: Session?
}

struct SessionDeletedEvent: Codable {
    var sessionID: String?
}

struct SessionStatusEvent: Codable {
    var sessionID: String?
    var status: SessionStatus?
}

struct PermissionAskedEvent: Codable {
    var id: String?
    var sessionID: String?
    var permission: String?
    var patterns: [String]?
    var metadata: JSONObject?
    var always: [String]?
    var tool: PermissionTool?
}

struct PermissionRepliedEvent: Codable {
    var sessionID: String?
    var requestID: String?
    var reply: String?
}

struct SessionNextStepStartedEvent: Codable {
    var sessionID: String?
    var assistantMessageID: String?
    var agent: String?
    var model: ModelRef?
}

struct SessionNextTextDeltaEvent: Codable {
    var sessionID: String?
    var assistantMessageID: String?
    var textID: String?
    var delta: String?
}

struct SessionNextToolInputStartedEvent: Codable {
    var sessionID: String?
    var assistantMessageID: String?
    var callID: String?
    var name: String?
}

struct SessionNextToolInputDeltaEvent: Codable {
    var sessionID: String?
    var assistantMessageID: String?
    var callID: String?
    var delta: String?
}

struct SessionNextToolInputEndedEvent: Codable {
    var sessionID: String?
    var assistantMessageID: String?
    var callID: String?
    var tool: String?
    var input: JSONObject?
}

struct SessionNextToolCalledEvent: Codable {
    var sessionID: String?
    var assistantMessageID: String?
    var callID: String?
    var tool: String?
    var input: JSONObject?
}

struct SessionNextToolSuccessEvent: Codable {
    var sessionID: String?
    var assistantMessageID: String?
    var callID: String?
    var tool: String?
    var output: JSONObject?
}

struct SessionNextToolFailedEvent: Codable {
    var sessionID: String?
    var assistantMessageID: String?
    var callID: String?
    var tool: String?
    var error: String?
}

struct SessionNextToolProgressEvent: Codable {
    var sessionID: String?
    var assistantMessageID: String?
    var callID: String?
    var tool: String?
    var output: JSONObject?
}

struct SessionNextStepEndedEvent: Codable {
    var sessionID: String?
    var assistantMessageID: String?
    var duration: Int?
    var tokens: Int?
}

struct SessionIdleEvent: Codable {
    var sessionID: String?
}

struct SessionDiffEvent: Codable {
    var sessionID: String?
    var diff: JSONObject?
}

struct TodoUpdatedEvent: Codable {
    var sessionID: String?
    var todo: JSONObject?
}
