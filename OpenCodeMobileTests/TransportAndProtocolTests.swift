import Foundation
import XCTest
@testable import OpenCodeMobile

final class TransportModeTests: XCTestCase {
    func testQuickTunnelUsesPolling() {
        XCTAssertEqual(
            TransportMode.detect(baseURL: "https://temporary-name.trycloudflare.com"),
            .quickTunnelPolling
        )
    }

    func testOtherHTTPSHostUsesSSE() {
        XCTAssertEqual(
            TransportMode.detect(baseURL: "https://agent.example.com"),
            .serverSentEvents
        )
    }

    func testHermesQuickTunnelUsesWebSocketInsteadOfOpenCodePollingRule() {
        XCTAssertEqual(
            TransportMode.detect(
                baseURL: "https://temporary-name.trycloudflare.com",
                kind: .hermes
            ),
            .webSocket
        )
    }
}

final class ServerConfigMigrationTests: XCTestCase {
    func testLegacyConfigDefaultsToOpenCode() throws {
        let data = Data(#"{"id":"legacy","name":"Mac","baseURL":"https://example.test","username":"opencode","password":"old"}"#.utf8)
        let config = try JSONDecoder().decode(ServerConfig.self, from: data)

        XCTAssertEqual(config.kind, .openCode)
        XCTAssertEqual(config.id, "legacy")
    }

    func testPersistenceCopyNeverContainsPassword() throws {
        let config = ServerConfig(
            id: "stable",
            kind: .hermes,
            name: "Hermes",
            baseURL: "https://agent.example.test",
            username: "admin",
            password: "do-not-persist"
        )
        let data = try JSONEncoder().encode(config.redactedForPersistence)
        let encoded = try XCTUnwrap(String(data: data, encoding: .utf8))

        XCTAssertFalse(encoded.contains("do-not-persist"))
        XCTAssertEqual(
            try JSONDecoder().decode(ServerConfig.self, from: data).password,
            ""
        )
    }

    func testDirectEncodingAlsoNeverContainsPassword() throws {
        let config = ServerConfig(
            id: "stable",
            kind: .hermes,
            name: "Hermes",
            baseURL: "https://agent.example.test",
            username: "admin",
            password: "super-secret"
        )

        let data = try JSONEncoder().encode(config)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )

        XCTAssertNil(object["password"])
        XCTAssertFalse(data.contains(Data("super-secret".utf8)))
    }
}

final class HermesModelTests: XCTestCase {
    func testConcurrentApprovalsRemainFIFO() {
        let first = PermissionRequest(
            id: "approval-a",
            sessionID: "durable-1",
            backend: .hermes,
            runtimeSessionID: "runtime-1",
            metadata: ["command": .string("command A")]
        )
        let second = PermissionRequest(
            id: "approval-b",
            sessionID: "durable-1",
            backend: .hermes,
            runtimeSessionID: "runtime-1",
            metadata: ["command": .string("command B")]
        )
        var queue: [PermissionRequest] = []

        HermesApprovalFIFO.enqueue(first, into: &queue)
        HermesApprovalFIFO.enqueue(second, into: &queue)
        XCTAssertEqual(queue.first?.id, first.id)
        XCTAssertFalse(HermesApprovalFIFO.removeHead(expectedID: second.id, from: &queue))
        XCTAssertEqual(queue.first?.id, first.id)
        XCTAssertTrue(HermesApprovalFIFO.removeHead(expectedID: first.id, from: &queue))
        XCTAssertEqual(queue.first?.id, second.id)
    }

    func testStatusAndAuthModelsDecodeFlexibleValuesAndIgnoreUnknownFields() throws {
        let status = try JSONDecoder().decode(
            HermesStatus.self,
            from: Data(#"""
            {
              "version": 19,
              "gateway_running": "true",
              "active_sessions": "3",
              "auth_required": "1",
              "auth_providers": ["basic", {"name":"oauth"}],
              "future_field": {"safe":"to ignore"}
            }
            """#.utf8)
        )
        XCTAssertEqual(status.version, "19")
        XCTAssertEqual(status.gatewayRunning, true)
        XCTAssertEqual(status.activeSessions, 3)
        XCTAssertTrue(status.requiresAuthentication)
        XCTAssertEqual(status.authProviders, ["basic", "oauth"])

        let providers = try JSONDecoder().decode(
            HermesAuthProvidersResponse.self,
            from: Data(#"""
            {
              "providers": [
                {
                  "name":"basic",
                  "display_name":100,
                  "supports_password":"true",
                  "unknown":"ignored"
                }
              ]
            }
            """#.utf8)
        )
        XCTAssertEqual(providers.providers.first?.name, "basic")
        XCTAssertEqual(providers.providers.first?.displayName, "100")
        XCTAssertEqual(providers.providers.first?.supportsPassword, true)

        let ticket = try JSONDecoder().decode(
            HermesWSTicketResponse.self,
            from: Data(#"{"ticket":"short-lived","ttl_seconds":"30","extra":true}"#.utf8)
        )
        XCTAssertEqual(ticket.ttlSeconds, 30)
        XCTAssertFalse(ticket.ticket.isEmpty)
    }

    func testCreateAndResumeKeepDurableAndRuntimeSessionIDsSeparate() throws {
        let created = try JSONDecoder().decode(
            HermesSessionCreateResponse.self,
            from: Data(#"""
            {
              "session_id":"runtime-create-1",
              "stored_session_id":"durable-history-1",
              "message_count":"2",
              "messages":[],
              "future":true
            }
            """#.utf8)
        )
        XCTAssertEqual(created.sessionID, "runtime-create-1")
        XCTAssertEqual(created.storedSessionID, "durable-history-1")
        XCTAssertNotEqual(created.sessionID, created.storedSessionID)
        XCTAssertEqual(created.messageCount, 2)

        let resumed = try JSONDecoder().decode(
            HermesSessionResumeResponse.self,
            from: Data(#"""
            {
              "session_id":"runtime-resume-9",
              "resumed":"durable-history-1",
              "session_key":"durable-key-1",
              "running":"true",
              "messages":[],
              "inflight":{"assistant":"partial","streaming":true}
            }
            """#.utf8)
        )
        XCTAssertEqual(resumed.sessionID, "runtime-resume-9")
        XCTAssertEqual(resumed.resumed, "durable-history-1")
        XCTAssertEqual(resumed.sessionKey, "durable-key-1")
        XCTAssertEqual(resumed.running, true)
        XCTAssertEqual(resumed.inflight?.assistant, "partial")
    }

    func testTranscriptAcceptsDashboardContentAndGatewayTextShapes() throws {
        let dashboard = try JSONDecoder().decode(
            HermesTranscriptMessage.self,
            from: Data(#"""
            {
              "id":42,
              "role":"assistant",
              "content":[
                {"type":"text","text":"hello"},
                {"type":"text","content":"world"}
              ],
              "created_at":"1720000000.25",
              "unknown":false
            }
            """#.utf8)
        )
        XCTAssertEqual(dashboard.rowID, "42")
        XCTAssertEqual(dashboard.displayText, "hello\nworld")
        XCTAssertEqual(dashboard.createdAt, 1_720_000_000.25)

        let gateway = try JSONDecoder().decode(
            HermesTranscriptMessage.self,
            from: Data(#"{"row_id":"row-2","role":"user","text":"question"}"#.utf8)
        )
        XCTAssertEqual(gateway.rowID, "row-2")
        XCTAssertEqual(gateway.displayText, "question")
    }

    func testApprovalHasNoInventedRequestIDAndClarifyMapsIndependently() throws {
        let approvalEnvelope = try decodeHermesEnvelope(#"""
        {
          "jsonrpc":"2.0",
          "method":"event",
          "params":{
            "type":"approval.request",
            "session_id":"runtime-approval",
            "payload":{
              "command":"rm file.tmp",
              "description":"Remove a temporary file",
              "choices":["once","always","deny"],
              "allow_permanent":true,
              "smart_denied":"false",
              "future":123
            }
          }
        }
        """#)
        let approvalEvent = try XCTUnwrap(approvalEnvelope.gatewayEvent)
        let approval = try XCTUnwrap(HermesApprovalRequest(event: approvalEvent))

        XCTAssertEqual(approvalEvent.sessionID, "runtime-approval")
        XCTAssertNil(approvalEvent.requestID)
        XCTAssertEqual(approval.command, "rm file.tmp")
        XCTAssertEqual(approval.choices, ["once", "always", "deny"])
        XCTAssertTrue(approval.allowPermanent)
        XCTAssertFalse(approval.smartDenied)

        let clarifyEnvelope = try decodeHermesEnvelope(#"""
        {
          "jsonrpc":"2.0",
          "method":"event",
          "params":{
            "type":"clarify.request",
            "session_id":"runtime-clarify",
            "payload":{
              "request_id":"clarify-7",
              "question":"Which target?",
              "choices":["iOS","macOS"],
              "new_field":"ignored"
            }
          }
        }
        """#)
        let clarifyEvent = try XCTUnwrap(clarifyEnvelope.gatewayEvent)
        let clarify = try XCTUnwrap(HermesInputRequest(event: clarifyEvent))

        XCTAssertEqual(clarify.id, "clarify-7")
        XCTAssertEqual(clarify.kind, .clarify)
        XCTAssertEqual(clarify.sessionID, "runtime-clarify")
        XCTAssertEqual(clarify.prompt, "Which target?")
        XCTAssertEqual(clarify.choices, ["iOS", "macOS"])
    }

    func testUnknownGatewayPayloadDoesNotBreakEnvelopeDecoding() throws {
        let envelope = try decodeHermesEnvelope(#"""
        {
          "jsonrpc":"2.0",
          "method":"event",
          "params":{
            "type":"message.delta",
            "session_id":"runtime-1",
            "payload":{
              "text":"partial",
              "new_nested_shape":{"array":[1,true,null]}
            }
          }
        }
        """#)
        let event = try XCTUnwrap(envelope.gatewayEvent)
        XCTAssertEqual(event.type, "message.delta")
        XCTAssertEqual(event.sessionID, "runtime-1")
        XCTAssertEqual(event.text, "partial")
    }

    private func decodeHermesEnvelope(_ json: String) throws -> HermesRPCEnvelope {
        try JSONDecoder().decode(HermesRPCEnvelope.self, from: Data(json.utf8))
    }
}

final class EventModelTests: XCTestCase {
    func testDeltaEnvelopeKeepsRoutingIDs() throws {
        let data = Data(#"""
        {
          "type":"message.part.delta",
          "properties":{
            "sessionID":"ses_1",
            "messageID":"msg_1",
            "partID":"part_1",
            "field":"text",
            "delta":"hello"
          }
        }
        """#.utf8)

        let envelope = try JSONDecoder.oc.decode(SSEEvent.self, from: data)
        let delta = try XCTUnwrap(envelope.properties?.decode(MessagePartDeltaEvent.self))
        XCTAssertEqual(delta.sessionID, "ses_1")
        XCTAssertEqual(delta.messageID, "msg_1")
        XCTAssertEqual(delta.partID, "part_1")
        XCTAssertEqual(delta.delta, "hello")
    }

    func testPartKeepsServerRoutingAndToolFields() throws {
        let data = Data(#"""
        {
          "id":"part_1",
          "sessionID":"ses_1",
          "messageID":"msg_1",
          "type":"tool",
          "callID":"call_1",
          "toolName":"bash"
        }
        """#.utf8)

        let part = try JSONDecoder.oc.decode(Part.self, from: data)
        XCTAssertEqual(part.sessionID, "ses_1")
        XCTAssertEqual(part.messageID, "msg_1")
        XCTAssertEqual(part.callID, "call_1")
        XCTAssertEqual(part.toolName, "bash")
    }
}

final class DirectoryRoutingTests: XCTestCase {
    override func tearDown() {
        RequestCaptureURLProtocol.reset()
        super.tearDown()
    }

    func testAbortCarriesDirectoryInQueryAndHeader() async throws {
        let api = makeAPI(responseBody: Data("true".utf8))
        _ = try await api.abortSession(id: "ses_1", directory: "/workspace/project")

        let request = try XCTUnwrap(RequestCaptureURLProtocol.lastRequest)
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-opencode-directory"), "/workspace/project")
        let components = try XCTUnwrap(URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.queryItems?.first(where: { $0.name == "directory" })?.value, "/workspace/project")
    }

    func testPermissionReplyCarriesDirectory() async throws {
        let api = makeAPI(responseBody: Data("true".utf8))
        _ = try await api.replyPermission(
            sessionID: "ses_1",
            permissionID: "per_1",
            response: .once,
            directory: "/workspace/project"
        )

        let request = try XCTUnwrap(RequestCaptureURLProtocol.lastRequest)
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-opencode-directory"), "/workspace/project")
    }

    private func makeAPI(responseBody: Data) -> OpenCodeAPI {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RequestCaptureURLProtocol.self]
        RequestCaptureURLProtocol.handler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, responseBody)
        }
        let server = ServerConfig(
            name: "test",
            baseURL: "https://example.test",
            username: "opencode",
            password: "test"
        )
        return OpenCodeAPI(client: OpenCodeClient(config: server, sessionConfiguration: configuration))
    }
}

final class HermesClientTests: XCTestCase {
    override func tearDown() {
        RequestCaptureURLProtocol.reset()
        super.tearDown()
    }

    func testPasswordLoginCookieTicketAndDashboardRESTFlow() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RequestCaptureURLProtocol.self]

        var loginCompleted = false
        var loginBodyWasCorrect = false
        var protectedRequestsReusedCookie = true
        var credentialAppearedInURLOrAuthorization = false
        RequestCaptureURLProtocol.handler = { request in
            let url = try XCTUnwrap(request.url)
            let path = url.path
            if url.absoluteString.contains("correct-horse-battery-staple")
                || request.value(forHTTPHeaderField: "Authorization") != nil {
                credentialAppearedInURLOrAuthorization = true
            }

            switch path {
            case "/hermes/api/status":
                return makeHTTPResponse(
                    request,
                    body: #"{"version":"0.19.1","auth_required":true,"gateway_running":true}"#
                )

            case "/hermes/api/auth/me" where !loginCompleted:
                return makeHTTPResponse(request, status: 401, body: #"{"detail":"login required"}"#)

            case "/hermes/api/auth/providers":
                return makeHTTPResponse(
                    request,
                    body: #"{"providers":[{"name":"basic","display_name":"Basic","supports_password":true}]}"#
                )

            case "/hermes/auth/password-login":
                let body = try XCTUnwrap(requestBodyData(request))
                let object = try XCTUnwrap(
                    JSONSerialization.jsonObject(with: body) as? [String: Any]
                )
                loginBodyWasCorrect = object["provider"] as? String == "basic"
                    && object["username"] as? String == "mobile"
                    && (object["password"] as? String)?.count == 28
                    && object["next"] as? String == ""
                loginCompleted = true
                return makeHTTPResponse(
                    request,
                    body: #"{"ok":true,"next":""}"#,
                    headers: [
                        "Set-Cookie": "hermes_session=memory-only-cookie; Path=/; Secure; HttpOnly; SameSite=Lax"
                    ]
                )

            case "/hermes/api/auth/me":
                protectedRequestsReusedCookie = protectedRequestsReusedCookie
                    && request.value(forHTTPHeaderField: "Cookie")?.contains("hermes_session=") == true
                return makeHTTPResponse(
                    request,
                    body: #"{"user_id":"user-1","provider":"basic","future":"ignored"}"#
                )

            case "/hermes/api/auth/ws-ticket":
                protectedRequestsReusedCookie = protectedRequestsReusedCookie
                    && request.value(forHTTPHeaderField: "Cookie")?.contains("hermes_session=") == true
                XCTAssertEqual(request.httpMethod, "POST")
                return makeHTTPResponse(
                    request,
                    body: #"{"ticket":"one-time-ticket-value","ttl_seconds":30}"#
                )

            case "/hermes/api/sessions":
                protectedRequestsReusedCookie = protectedRequestsReusedCookie
                    && request.value(forHTTPHeaderField: "Cookie")?.contains("hermes_session=") == true
                return makeHTTPResponse(
                    request,
                    body: #"{"sessions":[{"id":"durable-1","title":"Test","message_count":"4","new":true}],"total":"1"}"#
                )

            case "/hermes/api/sessions/durable-1/messages":
                protectedRequestsReusedCookie = protectedRequestsReusedCookie
                    && request.value(forHTTPHeaderField: "Cookie")?.contains("hermes_session=") == true
                return makeHTTPResponse(
                    request,
                    body: #"{"session_id":"durable-1","messages":[{"id":"row-1","role":"user","content":"hello"}],"pagination":{"returned":1}}"#
                )

            case "/hermes/api/sessions/durable-1":
                protectedRequestsReusedCookie = protectedRequestsReusedCookie
                    && request.value(forHTTPHeaderField: "Cookie")?.contains("hermes_session=") == true
                XCTAssertEqual(request.httpMethod, "DELETE")
                return makeHTTPResponse(request, body: #"{"ok":true,"deleted":"durable-1"}"#)

            default:
                throw URLError(.badURL)
            }
        }

        let client = try HermesClient(
            baseURL: "https://agent.example.test/hermes",
            username: "mobile",
            password: "correct-horse-battery-staple",
            sessionConfiguration: configuration
        )
        defer { client.invalidate() }

        let auth = try await client.authenticate()
        XCTAssertEqual(auth.status.version, "0.19.1")
        XCTAssertEqual(auth.identity?.userID, "user-1")
        XCTAssertEqual(auth.provider, "basic")
        XCTAssertTrue(auth.usesCookieAuthentication)

        let gatewayURL = try await client.gatewayWebSocketURL(for: auth.status)
        let components = try XCTUnwrap(
            URLComponents(url: gatewayURL, resolvingAgainstBaseURL: false)
        )
        XCTAssertEqual(components.scheme, "wss")
        XCTAssertEqual(components.host, "agent.example.test")
        XCTAssertEqual(components.path, "/hermes/api/ws")
        XCTAssertEqual(components.queryItems?.map(\.name), ["ticket"])
        XCTAssertFalse(components.queryItems?.first?.value?.isEmpty ?? true)

        let sessions = try await client.sessions(limit: 20, offset: 0)
        XCTAssertEqual(sessions.sessions.first?.id, "durable-1")
        XCTAssertEqual(sessions.sessions.first?.messageCount, 4)
        XCTAssertEqual(sessions.total, 1)

        let history = try await client.messages(sessionID: "durable-1", limit: 50)
        XCTAssertEqual(history.sessionID, "durable-1")
        XCTAssertEqual(history.messages.first?.displayText, "hello")
        XCTAssertEqual(history.pagination?.returned, 1)

        let deleted = try await client.deleteSession(sessionID: "durable-1")
        XCTAssertEqual(deleted.deleted, "durable-1")
        XCTAssertTrue(loginBodyWasCorrect)
        XCTAssertTrue(protectedRequestsReusedCookie)
        XCTAssertFalse(credentialAppearedInURLOrAuthorization)
        XCTAssertNil(client.urlSession.configuration.identifier)
    }

    func testLoopbackTokenBuildsWSURLWithoutLeakingItInErrors() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RequestCaptureURLProtocol.self]
        let sessionToken = "session-super-secret"
        let password = "password-super-secret"
        var protectedHeaderWasPresent = false

        RequestCaptureURLProtocol.handler = { request in
            switch request.url?.path {
            case "/api/status":
                return makeHTTPResponse(
                    request,
                    body: #"{"version":"0.19.1","auth_required":false}"#
                )
            case "/api/sessions":
                protectedHeaderWasPresent = request.value(
                    forHTTPHeaderField: "X-Hermes-Session-Token"
                )?.isEmpty == false
                return makeHTTPResponse(
                    request,
                    status: 500,
                    body: #"{"detail":"session-super-secret rejected with password-super-secret"}"#
                )
            default:
                throw URLError(.badURL)
            }
        }

        let client = try HermesClient(
            baseURL: "http://127.0.0.1:9119",
            username: "mobile",
            password: password,
            sessionToken: sessionToken,
            sessionConfiguration: configuration
        )
        defer { client.invalidate() }

        let auth = try await client.authenticate()
        let gatewayURL = try await client.gatewayWebSocketURL(for: auth.status)
        let components = try XCTUnwrap(
            URLComponents(url: gatewayURL, resolvingAgainstBaseURL: false)
        )
        XCTAssertEqual(components.scheme, "ws")
        XCTAssertEqual(components.path, "/api/ws")
        XCTAssertEqual(components.queryItems?.map(\.name), ["token"])
        XCTAssertFalse(components.queryItems?.first?.value?.isEmpty ?? true)

        do {
            _ = try await client.sessions()
            XCTFail("Expected sanitized server error")
        } catch {
            let description = error.localizedDescription
            XCTAssertFalse(description.contains(sessionToken))
            XCTAssertFalse(description.contains(password))
            XCTAssertTrue(description.contains("[redacted]"))
        }
        XCTAssertTrue(protectedHeaderWasPresent)
    }

    func testRemoteHTTPRefusesCredentialTransportBeforeLogin() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RequestCaptureURLProtocol.self]
        RequestCaptureURLProtocol.handler = { request in
            makeHTTPResponse(
                request,
                body: #"{"auth_required":true,"auth_providers":["basic"]}"#
            )
        }
        let client = try HermesClient(
            baseURL: "http://agent.example.test",
            username: "mobile",
            password: "must-not-travel-in-cleartext",
            sessionConfiguration: configuration
        )
        defer { client.invalidate() }

        do {
            _ = try await client.authenticate()
            XCTFail("Expected insecure transport rejection")
        } catch let error as HermesClientError {
            XCTAssertEqual(error, .insecureCredentialTransport)
            XCTAssertFalse(error.localizedDescription.contains("must-not-travel-in-cleartext"))
        }
        XCTAssertEqual(RequestCaptureURLProtocol.requests.count, 1)
        XCTAssertEqual(RequestCaptureURLProtocol.requests.first?.url?.path, "/api/status")
    }

    func testRemoteStatusWithoutAuthFlagFailsClosedToPasswordMode() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RequestCaptureURLProtocol.self]
        RequestCaptureURLProtocol.handler = { request in
            switch request.url?.path {
            case "/api/status":
                return makeHTTPResponse(request, body: #"{"version":"future"}"#)
            case "/api/auth/me":
                return makeHTTPResponse(request, status: 401, body: #"{"detail":"login required"}"#)
            default:
                throw URLError(.badURL)
            }
        }
        let client = try HermesClient(
            baseURL: "https://agent.example.test",
            username: "",
            password: "",
            sessionConfiguration: configuration
        )
        defer { client.invalidate() }

        do {
            _ = try await client.authenticate()
            XCTFail("Expected password-mode credential validation")
        } catch let error as HermesClientError {
            XCTAssertEqual(error, .missingCredentials)
        }
        XCTAssertEqual(
            RequestCaptureURLProtocol.requests.compactMap(\.url?.path),
            ["/api/status", "/api/auth/me"]
        )
    }

    func testRemoteUnauthenticatedStatusNeverTreatsLoginPasswordAsSessionToken() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RequestCaptureURLProtocol.self]
        RequestCaptureURLProtocol.handler = { request in
            makeHTTPResponse(
                request,
                body: #"{"version":"0.19.1","auth_required":false}"#
            )
        }
        let password = "must-never-enter-a-websocket-query"
        let client = try HermesClient(
            baseURL: "https://agent.example.test",
            username: "mobile",
            password: password,
            sessionConfiguration: configuration
        )
        defer { client.invalidate() }

        do {
            _ = try await client.authenticate()
            XCTFail("Expected remote ungated server rejection")
        } catch let error as HermesClientError {
            XCTAssertEqual(error, .unexpectedUnauthenticatedRemote)
            XCTAssertFalse(error.localizedDescription.contains(password))
        }
        XCTAssertEqual(RequestCaptureURLProtocol.requests.count, 1)
        XCTAssertFalse(
            RequestCaptureURLProtocol.requests.contains {
                $0.url?.absoluteString.contains(password) == true
            }
        )
    }
}

final class HermesGatewaySocketProtocolTests: XCTestCase {
    func testRPCPayloadUsesTextWebSocketFrame() throws {
        let payload = Data(#"{"jsonrpc":"2.0","id":"1","method":"session.list","params":{}}"#.utf8)

        switch HermesGatewaySocket.outboundRPCMessage(payload) {
        case .string(let text):
            XCTAssertEqual(Data(text.utf8), payload)
        case .data:
            XCTFail("Hermes gateway requires a WebSocket text frame")
        @unknown default:
            XCTFail("Unexpected WebSocket frame type")
        }
    }

    func testGatewayErrorsNeverContainCredentialBearingURL() {
        let sensitiveMarker = "single-use-ticket-marker"
        let errors: [HermesGatewayError] = [
            .readyTimeout,
            .expectedGatewayReady,
            .connectionClosed(code: 1006),
            .transport(code: -1005),
            .requestTimeout(method: "session.list"),
        ]

        for error in errors {
            XCTAssertFalse(error.localizedDescription.contains(sensitiveMarker))
            XCTAssertFalse(error.localizedDescription.contains("ticket="))
        }
    }
}

private final class RequestCaptureURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?
    static var lastRequest: URLRequest?
    static var requests: [URLRequest] = []

    static func reset() {
        handler = nil
        lastRequest = nil
        requests = []
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            Self.lastRequest = request
            Self.requests.append(request)
            let handler = try XCTUnwrap(Self.handler)
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private func makeHTTPResponse(
    _ request: URLRequest,
    status: Int = 200,
    body: String,
    headers: [String: String] = [:]
) -> (HTTPURLResponse, Data) {
    var responseHeaders = ["Content-Type": "application/json"]
    responseHeaders.merge(headers) { _, new in new }
    let response = HTTPURLResponse(
        url: request.url!,
        statusCode: status,
        httpVersion: "HTTP/1.1",
        headerFields: responseHeaders
    )!
    return (response, Data(body.utf8))
}

private func requestBodyData(_ request: URLRequest) -> Data? {
    if let body = request.httpBody { return body }
    guard let stream = request.httpBodyStream else { return nil }

    stream.open()
    defer { stream.close() }
    var result = Data()
    var buffer = [UInt8](repeating: 0, count: 4_096)
    while stream.hasBytesAvailable {
        let count = stream.read(&buffer, maxLength: buffer.count)
        guard count >= 0 else { return nil }
        if count == 0 { break }
        result.append(buffer, count: count)
    }
    return result
}
