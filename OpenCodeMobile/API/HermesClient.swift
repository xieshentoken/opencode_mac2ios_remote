import Foundation

enum HermesClientError: LocalizedError, Equatable, Sendable {
    case invalidBaseURL
    case insecureCredentialTransport
    case unexpectedUnauthenticatedRemote
    case missingCredentials
    case missingSessionToken
    case noPasswordProvider
    case authenticationFailed
    case invalidTicket
    case invalidResponse(endpoint: String)
    case http(status: Int, endpoint: String, detail: String?)
    case network(code: Int, message: String)
    case decoding(endpoint: String)

    var errorDescription: String? {
        switch self {
        case .invalidBaseURL:
            return "Invalid Hermes server URL"
        case .insecureCredentialTransport:
            return "Hermes credentials require HTTPS (HTTP is allowed only on loopback)"
        case .unexpectedUnauthenticatedRemote:
            return "Remote Hermes server reports that authentication is disabled"
        case .missingCredentials:
            return "Hermes username and password are required"
        case .missingSessionToken:
            return "Hermes dashboard session token is required for this server"
        case .noPasswordProvider:
            return "Hermes does not advertise a password login provider"
        case .authenticationFailed:
            return "Hermes authentication failed"
        case .invalidTicket:
            return "Hermes returned an invalid WebSocket ticket"
        case .invalidResponse(let endpoint):
            return "Hermes returned an invalid response from \(endpoint)"
        case .http(let status, let endpoint, let detail):
            if let detail, !detail.isEmpty {
                return "Hermes \(endpoint) failed (HTTP \(status)): \(detail)"
            }
            return "Hermes \(endpoint) failed (HTTP \(status))"
        case .network(_, let message):
            return "Hermes connection failed: \(message)"
        case .decoding(let endpoint):
            return "Hermes response from \(endpoint) could not be decoded"
        }
    }
}

struct HermesAuthenticationResult: Sendable {
    var status: HermesStatus
    var identity: HermesAuthIdentity?
    var provider: String?
    var usesCookieAuthentication: Bool
}

/// HTTP/authentication side of `hermes serve`.
///
/// The URLSession is deliberately long-lived and ephemeral: it reuses TLS and
/// HTTP/2 connections, keeps login cookies in memory, and does not persist the
/// Hermes dashboard session to disk. This type never logs request bodies,
/// cookies, passwords, dashboard tokens, or WebSocket tickets.
final class HermesClient: @unchecked Sendable {
    let baseURL: URL
    let urlSession: URLSession

    private let username: String
    private let password: String
    private let explicitSessionToken: String?
    private let preferredPasswordProvider: String?

    private enum CredentialMode {
        case none
        case cookie
        case sessionToken
    }

    private let stateLock = NSLock()
    private var credentialMode: CredentialMode = .none
    /// Authentication cookies mirrored from Set-Cookie so protected requests
    /// remain deterministic even when a custom URLProtocol/proxy bypasses
    /// URLSession's automatic cookie injection. They are process-memory only.
    private var authenticationCookies: [String: HTTPCookie] = [:]

    init(
        baseURL: String,
        username: String,
        password: String,
        sessionToken: String? = nil,
        passwordProvider: String? = nil,
        sessionConfiguration: URLSessionConfiguration? = nil
    ) throws {
        guard
            let parsed = URL(string: baseURL.trimmingCharacters(in: .whitespacesAndNewlines)),
            let scheme = parsed.scheme?.lowercased(),
            (scheme == "http" || scheme == "https"),
            parsed.host != nil,
            parsed.user == nil,
            parsed.password == nil
        else {
            throw HermesClientError.invalidBaseURL
        }

        self.baseURL = parsed
        self.username = username
        self.password = password
        self.explicitSessionToken = sessionToken?.nilIfBlank
        self.preferredPasswordProvider = passwordProvider?.nilIfBlank

        let configuration = sessionConfiguration ?? URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60
        configuration.waitsForConnectivity = false
        configuration.httpShouldSetCookies = true
        configuration.httpCookieAcceptPolicy = .always
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        self.urlSession = URLSession(configuration: configuration)
    }

    convenience init(
        config: ServerConfig,
        sessionToken: String? = nil,
        passwordProvider: String? = nil,
        sessionConfiguration: URLSessionConfiguration? = nil
    ) throws {
        try self.init(
            baseURL: config.baseURL,
            username: config.username,
            password: config.password,
            sessionToken: sessionToken,
            passwordProvider: passwordProvider,
            sessionConfiguration: sessionConfiguration
        )
    }

    func invalidate() {
        urlSession.invalidateAndCancel()
    }

    // MARK: - Authentication

    /// Performs the full native-client bootstrap. Call this before protected
    /// REST operations or minting a gateway URL.
    func authenticate() async throws -> HermesAuthenticationResult {
        var serverStatus = try await status()
        // Fail closed for a version-skewed remote server that omits the flag.
        // Loopback remains compatible with Hermes' local session-token mode.
        if serverStatus.authRequired == nil {
            serverStatus.authRequired = !isLoopbackHost
        }

        if serverStatus.requiresAuthentication {
            try requireSecureCredentialTransport()
            setCredentialMode(.cookie)

            // Reuse an existing in-memory cookie when reconnecting within the
            // same app process. A 401 simply falls through to password login.
            if let currentIdentity = try? await identity() {
                return HermesAuthenticationResult(
                    status: serverStatus,
                    identity: currentIdentity,
                    provider: currentIdentity.provider,
                    usesCookieAuthentication: true
                )
            }

            guard !username.isEmpty, !password.isEmpty else {
                throw HermesClientError.missingCredentials
            }

            let advertised = try await authProviders().providers
            let provider = selectPasswordProvider(from: advertised)
            guard let provider else { throw HermesClientError.noPasswordProvider }

            let login = try await passwordLogin(provider: provider.name)
            guard login.ok != false else { throw HermesClientError.authenticationFailed }
            let currentIdentity = try await identity()
            return HermesAuthenticationResult(
                status: serverStatus,
                identity: currentIdentity,
                provider: provider.name,
                usesCookieAuthentication: true
            )
        }

        // Loopback/--insecure Hermes uses a process-lifetime dashboard token.
        // For compatibility with the app's existing four-field server form,
        // its password field may carry that token when no explicit token was
        // supplied. It is sent only after /api/status confirms ungated mode.
        _ = try sessionTokenForUngatedServer()
        try requireSecureCredentialTransport()
        setCredentialMode(.sessionToken)
        return HermesAuthenticationResult(
            status: serverStatus,
            identity: nil,
            provider: nil,
            usesCookieAuthentication: false
        )
    }

    func status() async throws -> HermesStatus {
        try await get(HermesStatus.self, endpoint: "/api/status", protected: false)
    }

    func authProviders() async throws -> HermesAuthProvidersResponse {
        try await get(
            HermesAuthProvidersResponse.self,
            endpoint: "/api/auth/providers",
            protected: false
        )
    }

    func passwordLogin(provider: String) async throws -> HermesPasswordLoginResponse {
        try requireSecureCredentialTransport()
        guard !username.isEmpty, !password.isEmpty else {
            throw HermesClientError.missingCredentials
        }
        let body = PasswordLoginBody(
            provider: provider,
            username: username,
            password: password,
            next: ""
        )
        return try await post(
            HermesPasswordLoginResponse.self,
            endpoint: "/auth/password-login",
            body: body,
            protected: false
        )
    }

    func identity() async throws -> HermesAuthIdentity {
        try await get(HermesAuthIdentity.self, endpoint: "/api/auth/me", protected: true)
    }

    func webSocketTicket() async throws -> HermesWSTicketResponse {
        let response = try await post(
            HermesWSTicketResponse.self,
            endpoint: "/api/auth/ws-ticket",
            body: EmptyBody(),
            protected: true
        )
        guard !response.ticket.isEmpty else { throw HermesClientError.invalidTicket }
        return response
    }

    /// Produces a short-lived, credential-bearing URL. Do not display, persist,
    /// log, or place this URL in an error message. Prefer `makeGatewaySocket`.
    func gatewayWebSocketURL(for status: HermesStatus) async throws -> URL {
        try requireSecureCredentialTransport()
        let credentialName: String
        let credentialValue: String

        if status.requiresAuthentication {
            setCredentialMode(.cookie)
            let ticket = try await webSocketTicket()
            credentialName = "ticket"
            credentialValue = ticket.ticket
        } else {
            let token = try sessionTokenForUngatedServer()
            setCredentialMode(.sessionToken)
            credentialName = "token"
            credentialValue = token
        }

        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw HermesClientError.invalidBaseURL
        }
        switch components.scheme?.lowercased() {
        case "https": components.scheme = "wss"
        case "http": components.scheme = "ws"
        default: throw HermesClientError.invalidBaseURL
        }
        components.path = joinedPath(base: components.path, endpoint: "/api/ws")
        components.query = nil
        components.fragment = nil
        components.queryItems = [URLQueryItem(name: credentialName, value: credentialValue)]
        guard let url = components.url else { throw HermesClientError.invalidBaseURL }
        return url
    }

    func makeGatewaySocket(for status: HermesStatus) async throws -> HermesGatewaySocket {
        let url = try await gatewayWebSocketURL(for: status)
        return HermesGatewaySocket(url: url, session: urlSession)
    }

    // MARK: - Dashboard REST fallback

    func sessions(
        limit: Int = 200,
        offset: Int = 0,
        order: String = "recent"
    ) async throws -> HermesDashboardSessionListResponse {
        try await get(
            HermesDashboardSessionListResponse.self,
            endpoint: "/api/sessions",
            query: [
                URLQueryItem(name: "limit", value: String(max(1, min(limit, 500)))),
                URLQueryItem(name: "offset", value: String(max(0, offset))),
                URLQueryItem(name: "order", value: order),
            ],
            protected: true
        )
    }

    func messages(
        sessionID: String,
        limit: Int? = nil,
        offset: Int = 0
    ) async throws -> HermesDashboardMessagesResponse {
        var query = [URLQueryItem(name: "offset", value: String(max(0, offset)))]
        if let limit {
            query.append(URLQueryItem(name: "limit", value: String(max(1, min(limit, 500)))))
        }
        return try await get(
            HermesDashboardMessagesResponse.self,
            endpoint: "/api/sessions/\(escapedPathSegment(sessionID))/messages",
            query: query,
            protected: true
        )
    }

    func deleteSession(sessionID: String) async throws -> HermesOperationResponse {
        let endpoint = "/api/sessions/\(escapedPathSegment(sessionID))"
        let data = try await request(method: "DELETE", endpoint: endpoint, protected: true)
        if data.isEmpty { return HermesOperationResponse(ok: true, deleted: nil, alreadyAbsent: nil) }
        return try decode(HermesOperationResponse.self, from: data, endpoint: endpoint)
    }

    // MARK: - Request core

    private func get<T: Decodable>(
        _ type: T.Type,
        endpoint: String,
        query: [URLQueryItem] = [],
        protected: Bool
    ) async throws -> T {
        let data = try await request(
            method: "GET",
            endpoint: endpoint,
            query: query,
            protected: protected
        )
        return try decode(type, from: data, endpoint: endpoint)
    }

    private func post<T: Decodable, Body: Encodable>(
        _ type: T.Type,
        endpoint: String,
        body: Body,
        protected: Bool
    ) async throws -> T {
        let encoder = JSONEncoder()
        let bodyData: Data
        do {
            bodyData = try encoder.encode(body)
        } catch {
            throw HermesClientError.invalidResponse(endpoint: endpoint)
        }
        let data = try await request(
            method: "POST",
            endpoint: endpoint,
            body: bodyData,
            protected: protected
        )
        return try decode(type, from: data, endpoint: endpoint)
    }

    private func request(
        method: String,
        endpoint: String,
        query: [URLQueryItem] = [],
        body: Data? = nil,
        protected: Bool
    ) async throws -> Data {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw HermesClientError.invalidBaseURL
        }
        components.path = joinedPath(base: components.path, endpoint: endpoint)
        components.query = nil
        components.fragment = nil
        components.queryItems = query.isEmpty ? nil : query
        guard let url = components.url else { throw HermesClientError.invalidBaseURL }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if protected, currentCredentialMode() == .sessionToken {
            let token = try sessionTokenForUngatedServer()
            request.setValue(token, forHTTPHeaderField: "X-Hermes-Session-Token")
        } else if protected,
                  currentCredentialMode() == .cookie,
                  let cookieHeader = authenticationCookieHeader(for: url) {
            request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        }

        do {
            let (data, response) = try await urlSession.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw HermesClientError.invalidResponse(endpoint: endpoint)
            }
            captureAuthenticationCookies(from: http, for: url)
            guard (200...299).contains(http.statusCode) else {
                throw HermesClientError.http(
                    status: http.statusCode,
                    endpoint: endpoint,
                    detail: safeServerDetail(from: data)
                )
            }
            return data
        } catch let error as HermesClientError {
            throw error
        } catch {
            throw safeNetworkError(error)
        }
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data, endpoint: String) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw HermesClientError.decoding(endpoint: endpoint)
        }
    }

    private func selectPasswordProvider(from providers: [HermesAuthProvider]) -> HermesAuthProvider? {
        let candidates = providers.filter { $0.supportsPassword == true && !$0.name.isEmpty }
        if let preferredPasswordProvider {
            return candidates.first { $0.name == preferredPasswordProvider }
        }
        return candidates.first { $0.name == "basic" } ?? candidates.first
    }

    private func sessionTokenForUngatedServer() throws -> String {
        if let explicitSessionToken { return explicitSessionToken }
        if isLoopbackHost, let localToken = password.nilIfBlank { return localToken }
        if !isLoopbackHost { throw HermesClientError.unexpectedUnauthenticatedRemote }
        throw HermesClientError.missingSessionToken
    }

    private func setCredentialMode(_ mode: CredentialMode) {
        stateLock.lock()
        credentialMode = mode
        stateLock.unlock()
    }

    private func currentCredentialMode() -> CredentialMode {
        stateLock.lock()
        defer { stateLock.unlock() }
        return credentialMode
    }

    private func captureAuthenticationCookies(from response: HTTPURLResponse, for url: URL) {
        let headerFields = response.allHeaderFields.reduce(into: [String: String]()) { result, entry in
            guard let key = entry.key as? String else { return }
            result[key] = String(describing: entry.value)
        }
        let cookies = HTTPCookie.cookies(withResponseHeaderFields: headerFields, for: url)
        guard !cookies.isEmpty else { return }
        let now = Date()
        stateLock.lock()
        for cookie in cookies {
            if cookie.expiresDate.map({ $0 <= now }) == true {
                authenticationCookies.removeValue(forKey: cookie.name)
            } else {
                authenticationCookies[cookie.name] = cookie
            }
        }
        stateLock.unlock()
    }

    private func authenticationCookieHeader(for url: URL) -> String? {
        let host = url.host?.lowercased() ?? ""
        let path = url.path.isEmpty ? "/" : url.path
        let secure = url.scheme?.lowercased() == "https"
        let now = Date()
        stateLock.lock()
        authenticationCookies = authenticationCookies.filter {
            $0.value.expiresDate.map { $0 > now } ?? true
        }
        let cookies = authenticationCookies.values.filter { cookie in
            let domain = cookie.domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
            let domainMatches = host == domain || host.hasSuffix(".\(domain)")
            let pathMatches = path.hasPrefix(cookie.path.isEmpty ? "/" : cookie.path)
            return domainMatches && pathMatches && (!cookie.isSecure || secure)
        }
        stateLock.unlock()
        guard !cookies.isEmpty else { return nil }
        return HTTPCookie.requestHeaderFields(with: cookies)["Cookie"]
    }

    private func requireSecureCredentialTransport() throws {
        if baseURL.scheme?.lowercased() == "https" { return }
        if isLoopbackHost { return }
        throw HermesClientError.insecureCredentialTransport
    }

    private var isLoopbackHost: Bool {
        let host = baseURL.host?.lowercased() ?? ""
        return host == "localhost" || host == "127.0.0.1" || host == "::1"
    }

    private func safeServerDetail(from data: Data) -> String? {
        guard
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let raw = object["detail"] as? String
        else { return nil }
        var detail = String(raw.prefix(240))
        for secret in [password.nilIfBlank, explicitSessionToken].compactMap({ $0 }) where !secret.isEmpty {
            detail = detail.replacingOccurrences(of: secret, with: "[redacted]")
        }
        return detail
    }

    private func safeNetworkError(_ error: Error) -> HermesClientError {
        let nsError = error as NSError
        let message: String
        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut: message = "request timed out"
            case .cannotFindHost: message = "server hostname was not found"
            case .cannotConnectToHost: message = "could not connect to server"
            case .networkConnectionLost: message = "network connection was lost"
            case .notConnectedToInternet: message = "device is offline"
            case .secureConnectionFailed: message = "TLS connection failed"
            case .serverCertificateUntrusted,
                 .serverCertificateHasBadDate,
                 .serverCertificateHasUnknownRoot,
                 .serverCertificateNotYetValid:
                message = "server certificate is not trusted"
            case .cancelled: message = "request was cancelled"
            default: message = "transport error (\(urlError.errorCode))"
            }
        } else {
            message = "transport error (\(nsError.code))"
        }
        return .network(code: nsError.code, message: message)
    }

    private func joinedPath(base: String, endpoint: String) -> String {
        let lhs = base.hasSuffix("/") ? String(base.dropLast()) : base
        let rhs = endpoint.hasPrefix("/") ? endpoint : "/\(endpoint)"
        return "\(lhs)\(rhs)"
    }

    private func escapedPathSegment(_ value: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/?#%")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
    }
}

private struct PasswordLoginBody: Encodable {
    var provider: String
    var username: String
    var password: String
    var next: String
}

private struct EmptyBody: Encodable {}

private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
