// SSEClient.swift — ChorographOpenCodeServerPlugin
// Server-Sent Events client for the OpenCode /global/event endpoint.

import Foundation

// MARK: - SSE Line Parser

struct SSELineParser: Sendable {
    private var currentEvent: String = ""
    private var currentData: [String] = []

    mutating func feed(_ line: String) -> SSERawEvent? {
        if line.isEmpty {
            guard !currentData.isEmpty else { reset(); return nil }
            let e = SSERawEvent(
                event: currentEvent.isEmpty ? "message" : currentEvent,
                data: currentData.joined(separator: "\n")
            )
            reset()
            return e
        }

        if line.hasPrefix(":") { return nil }

        if let colon = line.firstIndex(of: ":") {
            let field = String(line[line.startIndex..<colon])
            var value = String(line[line.index(after: colon)...])
            if value.hasPrefix(" ") { value.removeFirst() }

            switch field {
            case "event": currentEvent = value
            case "data":  currentData.append(value)
            default:      break
            }
        }
        return nil
    }

    private mutating func reset() { currentEvent = ""; currentData = [] }
}

// MARK: - Typed SSE events

enum SSEEvent: Sendable {
    case toolActivity(sessionID: String, tool: String, path: String, isWrite: Bool)
    case toolCall(sessionID: String, tool: String, input: [String: Any])
    case connected
    case fileEdited(path: String)
    case messageFinished(sessionID: String)
    case other(type: String)
}

// MARK: - EventStreamClient

actor EventStreamClient {
    private let eventURL: URL
    private let urlSession: URLSession
    private let decoder = JSONDecoder()

    private let initialBackoff: TimeInterval = 1.0
    private let maxBackoff: TimeInterval = 30.0

    private var isStopped = true
    private var currentTask: Task<Void, Never>?
    private var continuation: AsyncStream<SSEEvent>.Continuation?

    init(eventURL: URL, urlSession: URLSession = .shared) {
        self.eventURL = eventURL
        self.urlSession = urlSession
    }

    func start() -> AsyncStream<SSEEvent> {
        var capturedCont: AsyncStream<SSEEvent>.Continuation?
        let stream = AsyncStream<SSEEvent> { cont in
            capturedCont = cont
        }
        self.continuation = capturedCont

        guard isStopped else { return stream }
        isStopped = false
        currentTask = Task { [weak self] in await self?.connectionLoop() }
        return stream
    }

    func stop() {
        isStopped = true
        currentTask?.cancel()
        currentTask = nil
        continuation?.finish()
        continuation = nil
    }

    private func connectionLoop() async {
        var attempt = 0
        while !isStopped && !Task.isCancelled {
            if attempt > 0 {
                let backoff = min(initialBackoff * pow(2.0, Double(attempt - 1)), maxBackoff)
                try? await Task.sleep(nanoseconds: UInt64(backoff * 1_000_000_000))
                if isStopped || Task.isCancelled { break }
            }

            do {
                try await connect()
                attempt = 0
            } catch is CancellationError {
                break
            } catch {
                attempt += 1
                if attempt > 12 { break }
            }
        }
    }

    private func connect() async throws {
        var req = URLRequest(url: eventURL)
        req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 0

        let (bytes, response) = try await urlSession.bytes(for: req)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }

        continuation?.yield(.connected)

        var parser = SSELineParser()
        for try await line in bytes.allSSELines() {
            if isStopped || Task.isCancelled { break }
            if let raw = parser.feed(line) {
                if let event = parseEvent(raw) {
                    continuation?.yield(event)
                }
            }
        }
    }

    private func parseEvent(_ raw: SSERawEvent) -> SSEEvent? {
        guard let data = raw.data.data(using: .utf8) else { return nil }

        let globalEvent: OCGlobalEvent
        do {
            globalEvent = try decoder.decode(OCGlobalEvent.self, from: data)
        } catch {
            if let payload = try? decoder.decode(OCEventPayload.self, from: data) {
                return handlePayload(payload)
            }
            return nil
        }
        return handlePayload(globalEvent.payload)
    }

    private func handlePayload(_ payload: OCEventPayload) -> SSEEvent? {
        switch payload.type {
        case "server.connected":
            return .connected

        case "file.edited":
            if let file = payload.properties?["file"] as? String {
                return .fileEdited(path: file)
            }
            return nil

        case "message.part.updated":
            return extractToolActivity(from: payload)

        case "message.updated":
            if let info = payload.properties?["info"] as? [String: Any],
               let sessionID = info["sessionID"] as? String,
               let finish = info["finish"] as? String,
               finish != "tool-calls" {
                return .messageFinished(sessionID: sessionID)
            }
            return nil

        case "session.idle":
            if let sessionID = payload.properties?["sessionID"] as? String {
                return .messageFinished(sessionID: sessionID)
            }
            return nil

        default:
            return .other(type: payload.type)
        }
    }

    private func extractToolActivity(from payload: OCEventPayload) -> SSEEvent? {
        guard let props = payload.properties,
              let partDict = props["part"] as? [String: Any],
              let partType = partDict["type"] as? String,
              partType == "tool",
              let toolName = partDict["tool"] as? String,
              let sessionID = partDict["sessionID"] as? String else {
            return nil
        }

        guard let stateDict = partDict["state"] as? [String: Any],
              let status = stateDict["status"] as? String,
              status == "running" || status == "completed",
              let input = stateDict["input"] as? [String: Any] else { return nil }

        let path: String?
        switch toolName {
        case "read":
            path = (input["filePath"] ?? input["path"]) as? String
        case "write", "edit":
            path = (input["path"] ?? input["filePath"]) as? String
        case "patch":
            path = (input["file"] ?? input["path"]) as? String
        default:
            path = (input["path"] ?? input["file"] ?? input["filePath"]) as? String
        }

        if let filePath = path {
            let isWrite = ["write", "edit", "patch"].contains(toolName)
            return .toolActivity(sessionID: sessionID, tool: toolName, path: filePath, isWrite: isWrite)
        } else {
            // Non-file tool — emit as toolCall
            return .toolCall(sessionID: sessionID, tool: toolName, input: input)
        }
    }
}

// MARK: - URLSession.AsyncBytes extension

extension URLSession.AsyncBytes {
    func allSSELines() -> AsyncThrowingStream<String, Error> {
        var iter = self.makeAsyncIterator()
        return AsyncThrowingStream {
            var buffer: [UInt8] = []
            while true {
                guard let byte = try await iter.next() else {
                    if !buffer.isEmpty {
                        let line = String(decoding: buffer, as: UTF8.self)
                        buffer.removeAll()
                        return line
                    }
                    return nil
                }
                if byte == UInt8(ascii: "\n") {
                    if buffer.last == UInt8(ascii: "\r") { buffer.removeLast() }
                    let line = String(decoding: buffer, as: UTF8.self)
                    buffer.removeAll()
                    return line
                }
                buffer.append(byte)
            }
        }
    }
}
