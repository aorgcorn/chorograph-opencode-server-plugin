// OpenCodeModels.swift — ChorographOpenCodeServerPlugin
// Codable model types matching the OpenCode server REST + SSE API.

import Foundation

// MARK: - AnyCodable (type-erased JSON value)

struct AnyCodable: Codable, @unchecked Sendable {
    let value: Any

    init(_ value: Any) { self.value = value }

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil()                                         { value = NSNull() }
        else if let b = try? c.decode(Bool.self)                 { value = b }
        else if let i = try? c.decode(Int.self)                  { value = i }
        else if let d = try? c.decode(Double.self)               { value = d }
        else if let s = try? c.decode(String.self)               { value = s }
        else if let a = try? c.decode([AnyCodable].self)         { value = a.map(\.value) }
        else if let d = try? c.decode([String: AnyCodable].self) { value = d.mapValues(\.value) }
        else { throw DecodingError.dataCorruptedError(in: c, debugDescription: "Undecodable value") }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch value {
        case is NSNull:               try c.encodeNil()
        case let b as Bool:           try c.encode(b)
        case let i as Int:            try c.encode(i)
        case let d as Double:         try c.encode(d)
        case let s as String:         try c.encode(s)
        case let a as [Any]:          try c.encode(a.map { AnyCodable($0) })
        case let d as [String: Any]:  try c.encode(d.mapValues { AnyCodable($0) })
        default:
            throw EncodingError.invalidValue(value, .init(codingPath: encoder.codingPath,
                                                          debugDescription: "Unencodable value"))
        }
    }
}

// MARK: - Symbol

struct OCSymbol: Codable, Sendable {
    let name: String
    let kind: Int
    let location: OCSymbolLocation

    struct OCSymbolLocation: Codable, Sendable {
        let uri: String
        let range: OCRange
    }
}

struct OCRange: Codable, Sendable {
    let start: OCPosition
    let end: OCPosition

    struct OCPosition: Codable, Sendable {
        let line: Int
        let character: Int
    }
}

// MARK: - Session

struct OCSession: Codable, Sendable {
    let id: String
    let projectID: String
    let directory: String
    let title: String
    let version: String?
    let time: OCSessionTime

    struct OCSessionTime: Codable, Sendable {
        let created: Double
        let updated: Double
    }
}

// MARK: - Health

struct OCHealth: Codable, Sendable {
    let healthy: Bool
    let version: String
}

// MARK: - Config

struct OCConfig: Decodable, Sendable {
    let model: String?
}

// MARK: - Config/Providers

struct OCConfigProviders: Decodable, Sendable {
    let providers: [OCConfigProvider]
    let `default`: [String: String]
}

struct OCConfigProvider: Decodable, Sendable {
    let id: String
    let name: String
    let models: [String: OCConfigModel]
}

struct OCConfigModel: Decodable, Sendable {
    let id: String
    let name: String
}

// MARK: - SSE Envelope

struct OCGlobalEvent: Decodable, Sendable {
    let directory: String?
    let payload: OCEventPayload
}

struct OCEventPayload: Decodable, Sendable {
    let type: String
    let properties: [String: Any]?

    private enum CodingKeys: String, CodingKey { case type, properties }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        type = try c.decode(String.self, forKey: .type)
        if let props = try? c.decode([String: AnyCodable].self, forKey: .properties) {
            properties = props.mapValues(\.value)
        } else {
            properties = nil
        }
    }
}

// MARK: - SSE Raw Event

struct SSERawEvent: Sendable {
    let event: String
    let data: String
}
