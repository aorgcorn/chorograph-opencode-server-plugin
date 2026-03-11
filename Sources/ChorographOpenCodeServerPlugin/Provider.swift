// Provider.swift — OpenCodeServerProvider
// AIProvider implementation wrapping the OpenCode server REST API and SSE event stream.

import Foundation
import ChorographPluginSDK

actor OpenCodeServerProvider: AIProvider {

    // MARK: - Identity

    nonisolated let id: ProviderID = "opencode-server"
    nonisolated let displayName: String = "OpenCode Server"
    nonisolated let supportsSymbolSearch: Bool = true

    // MARK: - Configuration

    static let defaultBaseURLString = "http://localhost:4096"

    var baseURLString: String {
        get { UserDefaults.standard.string(forKey: "opencodeServerURL") ?? Self.defaultBaseURLString }
        set { UserDefaults.standard.set(newValue, forKey: "opencodeServerURL") }
    }

    var projectDirectory: String {
        get { UserDefaults.standard.string(forKey: "opencodeServerDirectory") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "opencodeServerDirectory") }
    }

    var selectedModelKey: String {
        get { UserDefaults.standard.string(forKey: "opencodeModel") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "opencodeModel") }
    }

    private var selectedModelRef: (providerID: String, modelID: String)? {
        let key = selectedModelKey
        guard !key.isEmpty else { return nil }
        let parts = key.split(separator: "/", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return nil }
        return (parts[0], parts[1])
    }

    // MARK: - Internal state

    private var eventStreamClient: EventStreamClient?
    private var eventContinuation: AsyncStream<any ProviderEvent>.Continuation?

    // MARK: - Health

    func health() async -> ProviderHealth {
        guard let client = makeClient() else {
            return ProviderHealth(isReachable: false, version: nil, detail: "Invalid server URL.", activeModel: nil)
        }
        do {
            let h = try await client.health()
            let modelLabel = selectedModelKey.isEmpty ? nil : selectedModelKey
            return ProviderHealth(isReachable: true, version: h.version, detail: nil, activeModel: modelLabel)
        } catch {
            return ProviderHealth(isReachable: false, version: nil, detail: "Server unreachable.", activeModel: nil)
        }
    }

    // MARK: - Model selection

    func availableModels() async throws -> [ProviderModel] {
        let client = try requireClient()
        let result = try await client.configProviders()
        return result.providers.flatMap { provider in
            provider.models.values
                .sorted { $0.name < $1.name }
                .map { model in
                    ProviderModel(
                        id: "\(provider.id)/\(model.id)",
                        displayName: "\(model.name) (\(provider.name))"
                    )
                }
        }
    }

    func setSelectedModel(_ id: String?) {
        selectedModelKey = id ?? ""
    }

    // MARK: - Sessions

    func createSession(title: String?) async throws -> ProviderSession {
        let client = try requireClient()
        let session = try await client.createSession(title: title)
        return ProviderSession(id: session.id, title: session.title)
    }

    func sendMessage(sessionID: String, text: String) async throws {
        let client = try requireClient()
        let ref = selectedModelRef
        try await client.sendMessage(
            sessionID: sessionID,
            text: text,
            providerID: ref?.providerID,
            modelID: ref?.modelID
        )
    }

    func abortSession(id: String) async throws {
        let client = try requireClient()
        try await client.abortSession(id: id)
    }

    func fetchLastAssistantText(sessionID: String) async throws -> String {
        let client = try requireClient()
        return try await client.fetchLastAssistantText(sessionID: sessionID)
    }

    // MARK: - Event stream

    func eventStream() -> AsyncStream<any ProviderEvent> {
        var capturedCont: AsyncStream<any ProviderEvent>.Continuation?
        let stream = AsyncStream<any ProviderEvent> { cont in
            capturedCont = cont
        }
        self.eventContinuation = capturedCont

        Task {
            if let previous = self.eventStreamClient {
                await previous.stop()
            }
            guard let client = makeClient() else {
                capturedCont?.finish()
                return
            }
            let sseClient = await client.makeEventStreamClient()
            self.eventStreamClient = sseClient
            let rawStream = await sseClient.start()
            for await event in rawStream {
                capturedCont?.yield(self.translateSSEEvent(event))
            }
            capturedCont?.finish()
        }
        return stream
    }

    func stopEventStream() {
        let client = eventStreamClient
        eventStreamClient = nil
        eventContinuation?.finish()
        eventContinuation = nil
        if let client {
            Task { await client.stop() }
        }
    }

    // MARK: - Symbol search

    func findSymbols(query: String) async throws -> [ProviderSymbol] {
        let client = try requireClient()
        let ocSymbols = try await client.findSymbols(query: query)
        return ocSymbols.map { s in
            ProviderSymbol(
                name: s.name,
                location: FileLocation(uri: s.location.uri)
            )
        }
    }

    // MARK: - Private helpers

    private func makeClient() -> ChorographServerClient? {
        guard let url = URL(string: baseURLString) else { return nil }
        let dir = projectDirectory.isEmpty
            ? FileManager.default.currentDirectoryPath
            : projectDirectory
        return ChorographServerClient(baseURL: url, projectDirectory: dir)
    }

    private func requireClient() throws -> ChorographServerClient {
        guard let client = makeClient() else {
            throw ProviderError.connectionFailed("Invalid server URL '\(baseURLString)'.")
        }
        return client
    }

    private func translateSSEEvent(_ event: SSEEvent) -> any ProviderEvent {
        switch event {
        case .toolActivity(_, let tool, let path, let isWrite):
            if isWrite {
                return tool == "patch" ? PatchFileEvent(path: path) : WriteFileEvent(path: path)
            } else {
                return ReadFileEvent(path: path)
            }
        case .toolCall(_, let tool, let input):
            let stringInput = input.mapValues { "\($0)" }
            return ToolCallEvent(name: tool, input: stringInput)
        case .fileEdited(let path):
            return WriteFileEvent(path: path)
        case .messageFinished(let sessionID):
            return TurnFinishedEvent(sessionID: sessionID)
        case .connected:
            return ConnectedEvent()
        case .other(let type):
            return OtherEvent(type: type)
        }
    }
}
