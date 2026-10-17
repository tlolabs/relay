import Foundation

extension MetadataDiscoveryClient {
    public func checkConnection(_ source: MetadataSource, key: String = "") async throws {
        guard source == .tvmaze || !key.isEmpty else { throw RelayFailure.message("No API key is saved.") }
        switch source {
        case .trakt:
            let response = try await http.request(.trakt, path: "/search/episode", query: query(["query": "A Witch Hunt", "fields": "title", "limit": "1"]), token: key, ttl: 0)
            guard (try JSONSerialization.jsonObject(with: response.data)) is [[String: Any]] else { throw RelayFailure.message("Unexpected Trakt search response.") }
        case .omdb:
            let response = try await http.request(.omdb, path: "/", query: query(["i": "tt0944947"]), token: key, ttl: 0)
            guard (try metadataObject(response.data))["Response"] as? String == "True" else { throw RelayFailure.message("OMDb key could not retrieve metadata. Check key activation and allowance.") }
        case .tvmaze:
            let response = try await http.request(.tvmaze, path: "/shows/86558", ttl: 0)
            guard metadataInt((try metadataObject(response.data))["id"]) == 86558 else { throw RelayFailure.message("Unexpected TVmaze show response.") }
        case .tvdb:
            let response = try await http.request(.tvdb, path: "/login", method: "POST", body: JSONSerialization.data(withJSONObject: ["apikey": key]), ttl: 0)
            guard let token = ((try metadataObject(response.data))["data"] as? [String: Any])?["token"] as? String else { throw RelayFailure.message("TheTVDB rejected the project key.") }
            let languages = try await http.request(.tvdb, path: "/languages", token: token, ttl: 0)
            guard (try metadataObject(languages.data))["data"] is [[String: Any]] else { throw RelayFailure.message("TheTVDB login worked but data access could not be verified.") }
        case .imdb: throw RelayFailure.message("IMDb search uses local files, not an online API.")
        }
    }
}
