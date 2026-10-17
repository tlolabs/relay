import Foundation

public struct CatalogTitle: Codable, Identifiable, Sendable {
    public var id: Int; public var title: String?; public var name: String?; public var releaseDate: String?; public var firstAirDate: String?
    public var displayTitle: String { title ?? name ?? "Untitled" }
    public var year: Int? { (releaseDate ?? firstAirDate).flatMap { Int($0.prefix(4)) } }
}
public struct PlexTitle: Codable, Identifiable, Sendable {
    public var id: String; public var title: String; public var year: Int?; public var guid: String?; public var ordering: String?
}
public struct SeriesContext: Codable, Sendable {
    public struct NextEpisode: Codable, Sendable { public var airDate: String? }
    public var status: String?; public var inProduction: Bool?; public var nextEpisodeToAir: NextEpisode?
}
public actor CatalogClient {
    private let session: URLSession
    public init(session: URLSession = .shared) { self.session = session }
    private func get(_ url: URL, token: String, plex: Bool = false) async throws -> Data {
        var request = URLRequest(url: url); request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(plex ? token : "Bearer \(token)", forHTTPHeaderField: plex ? "X-Plex-Token" : "Authorization")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw RelayFailure.message("\(plex ? "Plex" : "TMDB") request failed (HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)). Check the connection and credentials.")
        }
        guard data.count <= 16 * 1024 * 1024 else { throw RelayFailure.message("Catalog response is too large") }
        return data
    }
    public func search(_ query: String, kind: String, token: String) async throws -> [CatalogTitle] {
        guard !token.isEmpty else { throw RelayFailure.message("Add a TMDB API Read Access Token in Settings, or use manual identity fields") }
        var url = URLComponents(string: "https://api.themoviedb.org/3/search/\(kind == "movie" ? "movie" : "tv")")!
        url.queryItems = [URLQueryItem(name: "query", value: query), URLQueryItem(name: "include_adult", value: "false")]
        struct Results: Decodable { var results: [CatalogTitle] }
        let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(Results.self, from: await get(url.url!, token: token)).results
    }
    public func episodes(series: Int, season: Int, token: String) async throws -> [EpisodeCandidate] {
        guard series > 0, season >= 0, !token.isEmpty else { throw RelayFailure.message("Choose a TMDB show, season and token first") }
        struct Results: Decodable { var episodes: [EpisodeCandidate] }
        let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(Results.self, from: await get(URL(string: "https://api.themoviedb.org/3/tv/\(series)/season/\(season)")!, token: token)).episodes
    }
    public func seriesContext(id: UInt64, token: String) async throws -> SeriesContext {
        guard !token.isEmpty else { throw RelayFailure.message("TMDB token is not configured") }
        let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(SeriesContext.self, from: await get(URL(string: "https://api.themoviedb.org/3/tv/\(id)")!, token: token))
    }
    public func plexTitles(base: URL, token: String) async throws -> [PlexTitle] {
        guard ["http", "https"].contains(base.scheme?.lowercased() ?? ""), base.host != nil, base.user == nil, base.password == nil, base.query == nil, !token.isEmpty else { throw RelayFailure.message("Enter a Plex server URL and token in Settings") }
        func container(_ data: Data) throws -> [String: Any] {
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any], let value = object["MediaContainer"] as? [String: Any] else { throw RelayFailure.message("Unexpected Plex library response") }; return value
        }
        let sections = try container(await get(base.appendingPathComponent("library/sections"), token: token, plex: true))["Directory"] as? [[String: Any]] ?? []
        var result: [PlexTitle] = []
        for section in sections where section["type"] as? String == "show" {
            guard let key = section["key"] as? String, Int(key) != nil else { continue }
            var start = 0
            while start < 10000 {
                var components = URLComponents(url: base.appendingPathComponent("library/sections/\(key)/all"), resolvingAgainstBaseURL: false)!
                components.queryItems = [URLQueryItem(name: "type", value: "2"), URLQueryItem(name: "X-Plex-Container-Start", value: String(start)), URLQueryItem(name: "X-Plex-Container-Size", value: "200")]
                let data = try container(await get(components.url!, token: token, plex: true))
                let entries = data["Metadata"] as? [[String: Any]] ?? []
                for entry in entries { if let id = entry["ratingKey"] as? String, let title = entry["title"] as? String {
                    result.append(PlexTitle(id: id, title: title, year: entry["year"] as? Int, guid: entry["guid"] as? String, ordering: entry["showOrdering"] as? String))
                }}
                start += entries.count
                if entries.isEmpty || start >= (data["totalSize"] as? Int ?? start) { break }
            }
        }
        return result
    }
}
