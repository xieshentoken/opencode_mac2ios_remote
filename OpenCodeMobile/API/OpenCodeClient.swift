import Foundation

// MARK: - Server configuration

struct ServerConfig: Codable, Identifiable, Hashable {
    var id: String = UUID().uuidString
    var name: String
    var baseURL: String
    var username: String = "opencode"
    var password: String = ""

    enum CodingKeys: String, CodingKey {
        case id, name, baseURL, username, password
    }
}

enum OpenCodeError: LocalizedError {
    case invalidURL
    case httpError(status: Int, body: String)
    case transport(Error)
    case serverUnreachable

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Invalid server URL"
        case .httpError(let status, let body):
            let snippet = String(body.prefix(200))
            return "Server error \(status): \(snippet)"
        case .transport(let err): return err.localizedDescription
        case .serverUnreachable: return "Server unreachable"
        }
    }
}

// MARK: - REST client

/// Thin HTTP client over the opencode REST API.
///
/// Every request may carry a `directory` — used to scope the request to a
/// specific workspace instance. The same value is sent both as a query param
/// and as the `x-opencode-directory` header (server accepts both; header is
/// what SSE/event routing keys on).
final class OpenCodeClient {
    let config: ServerConfig
    let session: URLSession

    init(config: ServerConfig) {
        self.config = config
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 30
        cfg.waitsForConnectivity = false
        self.session = URLSession(configuration: cfg)
    }

    // MARK: - Core request

    func request(
        _ method: String,
        _ path: String,
        query: [String: String] = [:],
        directory: String? = nil,
        body: (any Encodable)? = nil
    ) async throws -> Data {
        guard let base = URL(string: config.baseURL) else { throw OpenCodeError.invalidURL }
        var url = base.appending(path: path)

        var queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        if let directory, !directory.isEmpty {
            queryItems.append(URLQueryItem(name: "directory", value: directory))
        }
        if !queryItems.isEmpty {
            url.append(queryItems: queryItems)
        }

        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue(authHeader, forHTTPHeaderField: "Authorization")
        if let directory, !directory.isEmpty {
            req.setValue(directory, forHTTPHeaderField: "x-opencode-directory")
        }
        if let body {
            req.httpBody = try JSONEncoder.oc.encode(body)
        }

        do {
            let (data, resp) = try await session.data(for: req)
            guard let http = resp as? HTTPURLResponse else { throw OpenCodeError.serverUnreachable }
            guard (200...299).contains(http.statusCode) else {
                let text = String(data: data, encoding: .utf8) ?? ""
                throw OpenCodeError.httpError(status: http.statusCode, body: text)
            }
            return data
        } catch let err as OpenCodeError {
            throw err
        } catch {
            throw OpenCodeError.transport(error)
        }
    }

    func get<T: Decodable>(_ type: T.Type, _ path: String, query: [String: String] = [:], directory: String? = nil) async throws -> T {
        let data = try await request("GET", path, query: query, directory: directory)
        return try JSONDecoder.oc.decode(T.self, from: data)
    }

    func post<T: Decodable>(_ type: T.Type, _ path: String, query: [String: String] = [:], directory: String? = nil, body: (any Encodable)? = nil) async throws -> T {
        let data = try await request("POST", path, query: query, directory: directory, body: body)
        return try JSONDecoder.oc.decode(T.self, from: data)
    }

    func delete<T: Decodable>(_ type: T.Type, _ path: String, query: [String: String] = [:], directory: String? = nil) async throws -> T {
        let data = try await request("DELETE", path, query: query, directory: directory)
        return try JSONDecoder.oc.decode(T.self, from: data)
    }

    func put<T: Decodable>(_ type: T.Type, _ path: String, directory: String? = nil, body: (any Encodable)? = nil) async throws -> T {
        let data = try await request("PUT", path, directory: directory, body: body)
        return try JSONDecoder.oc.decode(T.self, from: data)
    }

    /// POST that returns no meaningful body (204).
    func postNoContent(_ path: String, query: [String: String] = [:], directory: String? = nil, body: (any Encodable)? = nil) async throws {
        _ = try await request("POST", path, query: query, directory: directory, body: body)
    }

    // MARK: - Auth

    private var authHeader: String {
        let creds = "\(config.username):\(config.password)"
        let data = Data(creds.utf8)
        return "Basic \(data.base64EncodedString())"
    }

    // MARK: - Health

    func health() async throws -> Health {
        try await get(Health.self, "/global/health")
    }
}

// MARK: - Encoders / decoders

extension JSONEncoder {
    static let oc: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .secondsSince1970
        e.keyEncodingStrategy = .useDefaultKeys
        return e
    }()
}

extension JSONDecoder {
    static let oc: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .secondsSince1970
        d.keyDecodingStrategy = .useDefaultKeys
        return d
    }()
}
