// ServerClient.swift — ChorographOpenCodeServerPlugin
// HTTP client for the OpenCode server REST API.

import Foundation

// MARK: - Client

actor ChorographServerClient {
    let baseURL: URL
    let projectDirectory: String
    private let urlSession: URLSession
    private let decoder: JSONDecoder
    private let encoder: JSONEncoder

    static let defaultBaseURL = URL(string: "http://127.0.0.1:4096")!

    init(
        baseURL: URL = ChorographServerClient.defaultBaseURL,
        projectDirectory: String,
        urlSession: URLSession = .shared
    ) {
        self.baseURL = baseURL
        self.projectDirectory = projectDirectory
        self.urlSession = urlSession
        self.decoder = JSONDecoder()
        self.encoder = JSONEncoder()
    }

    // MARK: - Generic helpers

    private func request<T: Decodable>(
        method: String,
        path: String,
        queryItems: [URLQueryItem]? = nil,
        body: (any Encodable)? = nil
    ) async throws -> T {
        let url = try buildURL(path: path, queryItems: queryItems)
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(projectDirectory, forHTTPHeaderField: "x-opencode-directory")
        if let body {
            req.httpBody = try encoder.encode(body)
        }

        let (data, response) = try await urlSession.data(for: req)
        try validate(response: response, data: data)

        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw ChorographServerError.invalidResponse
        }
    }

    private func requestVoid(
        method: String,
        path: String,
        queryItems: [URLQueryItem]? = nil,
        body: (any Encodable)? = nil
    ) async throws {
        let url = try buildURL(path: path, queryItems: queryItems)
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(projectDirectory, forHTTPHeaderField: "x-opencode-directory")
        if let body {
            req.httpBody = try encoder.encode(body)
        }

        let (data, response) = try await urlSession.data(for: req)
        try validate(response: response, data: data)
    }

    private func buildURL(path: String, queryItems: [URLQueryItem]?) throws -> URL {
        var components = URLComponents(
            url: baseURL.appendingPathComponent(path),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = queryItems
        guard let url = components.url else {
            throw ChorographServerError.connectionFailed
        }
        return url
    }

    private func validate(response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else {
            throw ChorographServerError.serverUnavailable
        }
        guard (200...299).contains(http.statusCode) else {
            throw ChorographServerError.invalidResponse
        }
    }

    // MARK: - Global

    func health() async throws -> OCHealth {
        try await request(method: "GET", path: "/global/health")
    }

    func config() async throws -> OCConfig {
        try await request(method: "GET", path: "/config")
    }

    func configProviders() async throws -> OCConfigProviders {
        try await request(method: "GET", path: "/config/providers")
    }

    // MARK: - Session

    func createSession(title: String? = nil) async throws -> OCSession {
        struct Body: Encodable { let title: String? }
        return try await request(
            method: "POST",
            path: "/session",
            body: Body(title: title)
        )
    }

    func sendMessage(
        sessionID: String,
        text: String,
        providerID: String? = nil,
        modelID: String? = nil
    ) async throws {
        struct Part: Encodable { let type: String; let text: String }
        struct ModelRef: Encodable { let providerID: String; let modelID: String }
        struct Body: Encodable { let parts: [Part]; let model: ModelRef? }
        let modelRef: ModelRef? = (providerID != nil && modelID != nil)
            ? ModelRef(providerID: providerID!, modelID: modelID!)
            : nil
        try await requestVoid(
            method: "POST",
            path: "/session/\(sessionID)/prompt_async",
            body: Body(parts: [Part(type: "text", text: text)], model: modelRef)
        )
    }

    func abortSession(id: String) async throws {
        try await requestVoid(method: "POST", path: "/session/\(id)/abort")
    }

    func fetchLastAssistantText(sessionID: String) async throws -> String {
        struct TextPart: Decodable {
            let type: String
            let text: String?
        }
        struct MessageInfo: Decodable {
            let role: String
        }
        struct Message: Decodable {
            let info: MessageInfo
            let parts: [TextPart]
        }
        let messages: [Message] = try await request(
            method: "GET",
            path: "/session/\(sessionID)/message"
        )
        let text = messages
            .filter { $0.info.role == "assistant" }
            .last?
            .parts
            .filter { $0.type == "text" }
            .compactMap { $0.text }
            .joined(separator: "\n") ?? ""
        return text
    }

    // MARK: - Symbol search

    func findSymbols(query: String) async throws -> [OCSymbol] {
        try await request(
            method: "GET",
            path: "/find/symbol",
            queryItems: [URLQueryItem(name: "query", value: query)]
        )
    }

    // MARK: - SSE / EventStream

    func makeEventStreamClient() -> EventStreamClient {
        var components = URLComponents(
            url: baseURL.appendingPathComponent("/global/event"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [URLQueryItem(name: "directory", value: projectDirectory)]
        let url = components.url!

        let config = URLSessionConfiguration.default
        config.httpAdditionalHeaders = ["x-opencode-directory": projectDirectory]
        let session = URLSession(configuration: config)

        return EventStreamClient(eventURL: url, urlSession: session)
    }
}

// MARK: - Errors

enum ChorographServerError: Error {
    case connectionFailed
    case serverUnavailable
    case invalidResponse
}
