import CRelayCore
import Foundation

/// A single actor owns the handle. All filesystem/SQLite work executes outside
/// the main actor, and no caller can race the handle's destruction.
public actor RelayEngine {
    private var handle: UnsafeMutableRawPointer?
    public init(database: URL) throws {
        guard relay_core_api_version() == 1 else { throw RelayFailure.message("Incompatible RELAY core") }
        var error: UnsafeMutablePointer<CChar>?
        handle = database.path.withCString { relay_core_open($0, &error) }
        guard handle != nil else {
            let text = Self.take(error)
            let reply = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any]
            throw RelayFailure.message(reply?["error"] as? String ?? "Cannot open RELAY's database")
        }
    }
    public func execute<T: Decodable>(_ request: [String: Any], as type: T.Type = T.self) throws -> T {
        guard let handle else { throw RelayFailure.message("RELAY's database is closed") }
        let json = String(decoding: try JSONSerialization.data(withJSONObject: request), as: UTF8.self)
        let text = json.withCString { Self.take(relay_core_command(handle, $0)) }
        let data = Data(text.utf8)
        let envelope = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard envelope?["ok"] as? Bool == true, let value = envelope?["value"] else {
            throw RelayFailure.message(envelope?["error"] as? String ?? "Invalid core response")
        }
        let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(type, from: JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]))
    }
    public func snapshot() throws -> RelaySnapshot { try execute(["command": "snapshot"]) }
    public func configure(_ config: RelayConfig) throws -> RelaySnapshot { try execute(["command": "configure", "config": Self.object(config)]) }
    public static func object<T: Encodable>(_ value: T) -> Any {
        let encoder = JSONEncoder(); encoder.keyEncodingStrategy = .convertToSnakeCase
        // These application-owned value types contain no arbitrary encoders.
        return (try? JSONSerialization.jsonObject(with: encoder.encode(value))) ?? [:]
    }
    public func close() { if let handle { relay_core_close(handle); self.handle = nil } }
    deinit { if let handle { relay_core_close(handle) } }
    private static func take(_ value: UnsafeMutablePointer<CChar>?) -> String {
        guard let value else { return "{}" }
        defer { relay_core_free_string(value) }; return String(cString: value)
    }
}
