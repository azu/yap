import Foundation

// MARK: - CaptureRecord

enum CaptureRecordType: String, Codable, Sendable {
    case screenshot
    case transcription
    case camera
}

protocol CaptureRecord: Codable, Sendable {
    var type: CaptureRecordType { get }
}

struct ScreenshotRecord: CaptureRecord, Codable, Sendable {
    let type: CaptureRecordType = .screenshot
    let id: String
    let unixTimeMs: Int64
    let sessionId: String?
    let url: String?
    let app: String
    let title: String?
    let isFocused: Bool
    let isPlayingMedia: Bool
    let appContext: String?
    let idleSeconds: Double?
    let scrollPosition: Double?

    enum CodingKeys: String, CodingKey {
        case type, id, unixTimeMs, sessionId, url, app, title
        case isFocused = "is_focused"
        case isPlayingMedia = "is_playing_media"
        case appContext = "app_context"
        case idleSeconds = "idle_seconds"
        case scrollPosition = "scroll_position"
    }
}

struct TranscriptionRecord: CaptureRecord, Codable, Sendable {
    let type: CaptureRecordType = .transcription
    let unixTimeMs: Int64
    let endUnixTimeMs: Int64
    let sessionId: String?
    let rms: Float?
    let device: String?
    let speakerId: String?
    let text: String

    enum CodingKeys: String, CodingKey {
        case type, unixTimeMs, endUnixTimeMs, sessionId, text, rms, device, speakerId
    }
}

struct CameraRecord: CaptureRecord, Codable, Sendable {
    let type: CaptureRecordType = .camera
    let id: String
    let unixTimeMs: Int64
    let sessionId: String?

    enum CodingKeys: String, CodingKey {
        case type, id, unixTimeMs, sessionId
    }
}

// MARK: - Detail Records (for chronixd-capture context --detail output, resolved from tmp)

struct ScreenshotDetailRecord: Codable, Sendable {
    let type: CaptureRecordType = .screenshot
    let id: String
    let unixTimeMs: Int64
    let sessionId: String?
    let url: String?
    let app: String
    let title: String?
    let isFocused: Bool
    let isPlayingMedia: Bool
    let appContext: String?
    let idleSeconds: Double?
    let scrollPosition: Double?
    let path: String?
    let available: Bool

    enum CodingKeys: String, CodingKey {
        case type, id, unixTimeMs, sessionId, url, app, title
        case isFocused = "is_focused"
        case isPlayingMedia = "is_playing_media"
        case appContext = "app_context"
        case idleSeconds = "idle_seconds"
        case scrollPosition = "scroll_position"
        case path, available
    }
}

struct CameraDetailRecord: Codable, Sendable {
    let type: CaptureRecordType = .camera
    let id: String
    let unixTimeMs: Int64
    let sessionId: String?
    let path: String?
    let available: Bool

    enum CodingKeys: String, CodingKey {
        case type, id, unixTimeMs, sessionId, path, available
    }
}

// MARK: - NDJSON Encoding/Decoding

enum CaptureRecordCoder {
    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return e
    }()

    static func encode(_ record: any CaptureRecord) throws -> String {
        let data: Data
        switch record {
        case let r as ScreenshotRecord: data = try encoder.encode(r)
        case let r as TranscriptionRecord: data = try encoder.encode(r)
        case let r as CameraRecord: data = try encoder.encode(r)
        default: throw EncodingError.invalidValue(record, .init(codingPath: [], debugDescription: "Unknown record type"))
        }
        return String(data: data, encoding: .utf8) ?? ""
    }

    static func encodeDetail(_ record: any Encodable) throws -> String {
        let data = try encoder.encode(record)
        return String(data: data, encoding: .utf8) ?? ""
    }

    private static let decoder = JSONDecoder()

    static func decode(line: String) throws -> any CaptureRecord {
        let data = Data(line.utf8)
        let peek = try decoder.decode(TypePeek.self, from: data)
        switch peek.type {
        case .screenshot: return try decoder.decode(ScreenshotRecord.self, from: data)
        case .transcription: return try decoder.decode(TranscriptionRecord.self, from: data)
        case .camera: return try decoder.decode(CameraRecord.self, from: data)
        }
    }

    private struct TypePeek: Decodable {
        let type: CaptureRecordType
    }
}
