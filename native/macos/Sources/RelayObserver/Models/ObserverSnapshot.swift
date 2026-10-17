import Foundation

struct ObserverSnapshot: Decodable, Sendable {
    var running: Bool
    var logPath: String
    var eventCount: UInt64
    var fileCount: Int
    var lastScanUnixMs: UInt64?
    var lastError: String?
    var warningCount: UInt64
    var recentEvents: [String]

    static func decode(_ text: String) throws -> Self {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(Self.self, from: Data(text.utf8))
    }
}

struct NativeNotice: Encodable, Sendable {
    let path: String
    let flags: UInt32
    let eventId: String
    let receivedUnixMs: UInt64
    let gap: Bool
    let error: String?
}

enum ObserverError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case let .message(text) = self { return text }; return nil }
}
