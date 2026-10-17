import Foundation
import CryptoKit

struct ProviderResponse: Codable, Sendable {
    var data: Data
    var pages: Int?
    var cachedAt: Date
}

/// Public metadata cache; all networking passes through the shared durable usage ledger.
/// Credentials are never cached or included in error messages.
actor ProviderHTTP {
    let session: URLSession
    private var memory: [String: ProviderResponse] = [:]
    let usage: APIUsageStore
    init(session: URLSession, usage: APIUsageStore = .shared) { self.session = session; self.usage = usage }
    func request(_ source: MetadataSource, path: String, query: [URLQueryItem] = [], token: String = "", method: String = "GET", body: Data? = nil, cache: URL? = nil, ttl: TimeInterval = 21600) async throws -> ProviderResponse {
        try Task.checkCancellation()
        let base = [MetadataSource.trakt: "https://api.trakt.tv", .omdb: "https://www.omdbapi.com", .tvmaze: "https://api.tvmaze.com", .tvdb: "https://api4.thetvdb.com/v4"][source]
        guard let base else { throw RelayFailure.message("Unsupported metadata provider") }
        var components = URLComponents(string: base + path)!
        components.queryItems = query.isEmpty ? nil : query
        // The key includes all public request parameters, never API keys or login bodies.
        let key = SHA256.hash(data: Data((source.rawValue + (components.url?.absoluteString ?? path)).utf8)).map { String(format: "%02x", $0) }.joined()
        let file = cache?.appendingPathComponent("provider-\(key).json")
        guard let provider = source.apiProvider else { throw RelayFailure.message("Unsupported metadata provider") }
        if method == "GET", let value = memory[key] ?? file.flatMap({ try? JSONDecoder().decode(ProviderResponse.self, from: Data(contentsOf: $0)) }), Date().timeIntervalSince(value.cachedAt) < ttl {
            try await usage.cacheHit(provider)
            return value
        }
        if source == .omdb {
            try await usage.importLegacyOMDbBudget(cache: cache)
            components.queryItems = query + [URLQueryItem(name: "apikey", value: token)]
        }
        var request = URLRequest(url: components.url!); request.httpMethod = method; request.httpBody = body; request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("RELAY/0.1.0", forHTTPHeaderField: "User-Agent")
        if source == .trakt {
            request.setValue(token, forHTTPHeaderField: "trakt-api-key")
            request.setValue("2", forHTTPHeaderField: "trakt-api-version")
        } else if source == .tvdb, !token.isEmpty { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let (data, response) = try await APITransport.send(request, provider: provider, session: session, usage: usage)
        let status = response.statusCode
        if source == .omdb, let object = try? metadataObject(data),
           (object["Error"] as? String ?? "").lowercased().contains("limit") {
            try await usage.pause(.omdb, until: Date().addingTimeInterval(86400))
            throw RelayFailure.message("OMDb reports that its allowance is exhausted. Relay has paused OMDb for 24 hours; other sources remain available.")
        }
        guard status == 200 else { throw RelayFailure.message("\(source.rawValue) request failed (HTTP \(status)); other sources remain available") }
        guard data.count <= 16 * 1024 * 1024 else { throw RelayFailure.message("\(source.rawValue) response exceeds the metadata size limit") }
        if source == .omdb, let object = try? metadataObject(data), object["Response"] as? String == "False",
           !(object["Error"] as? String ?? "").lowercased().contains("not found") {
            if (object["Error"] as? String ?? "").lowercased().contains("limit") {
                try await usage.pause(.omdb, until: Date().addingTimeInterval(86400))
            }
            throw RelayFailure.message("OMDb rejected the request; check its API key or free daily allowance")
        }
        let value = ProviderResponse(data: data, pages: response.value(forHTTPHeaderField: "X-Pagination-Page-Count").flatMap(Int.init), cachedAt: Date())
        if method == "GET" {
            if memory.count >= 128, let first = memory.keys.first { memory.removeValue(forKey: first) }
            memory[key] = value
            if let file { try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true); try JSONEncoder().encode(value).write(to: file, options: .atomic) }
        }
        return value
    }
}

func metadataObject(_ data: Data) throws -> [String: Any] {
    guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw RelayFailure.message("Unexpected metadata response") }
    return value
}
func metadataInt(_ value: Any?) -> Int? {
    if let number = value as? Int { return number }
    if let string = value as? String { return Int(string) }
    return nil
}
func metadataYear(_ value: Any?) -> Int? { (value as? String).flatMap { Int($0.prefix(4)) } ?? metadataInt(value) }
