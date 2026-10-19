import Foundation

public struct CatalogTitle: Codable, Identifiable, Sendable {
    public var posterPath: String?
    public var posterURL: String? { posterPath.map { "https://image.tmdb.org/t/p/w185\($0)" } }
    public var id: Int; public var title: String?; public var name: String?; public var releaseDate: String?; public var firstAirDate: String?
    public var displayTitle: String { title ?? name ?? "Untitled" }
    public var year: Int? { (releaseDate ?? firstAirDate).flatMap { Int($0.prefix(4)) } }
    public init(id: Int, title: String? = nil, name: String? = nil, releaseDate: String? = nil, firstAirDate: String? = nil) {
        self.id = id; self.title = title; self.name = name; self.releaseDate = releaseDate; self.firstAirDate = firstAirDate
    }
}
public struct PlexTitle: Codable, Identifiable, Sendable {
    public var id: String; public var title: String; public var year: Int?; public var guid: String?; public var ordering: String?
    public var tmdbId: Int?
    public var imdbId: String? = nil
    public var tvdbId: Int? = nil
    public var addedAt: Date? = nil
}
public struct SeriesContext: Codable, Sendable {
    public struct NextEpisode: Codable, Sendable { public var airDate: String? }
    public var status: String?; public var inProduction: Bool?; public var nextEpisodeToAir: NextEpisode?
}
public actor CatalogClient {
    let session: URLSession
    let usage: APIUsageStore
    var metadataCache: [String: (date: Date, value: FullCatalogMetadata)] = [:]
    public init(session: URLSession? = nil, usage: APIUsageStore = .shared) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        self.session = session ?? URLSession(configuration: configuration)
        self.usage = usage
    }
    func get(_ url: URL, token: String, plex: Bool = false) async throws -> Data {
        var request = URLRequest(url: url); request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(plex ? token : "Bearer \(token)", forHTTPHeaderField: plex ? "X-Plex-Token" : "Authorization")
        if plex {
            request.setValue("com.tlolabs.relay", forHTTPHeaderField: "X-Plex-Client-Identifier")
            request.setValue("RELAY", forHTTPHeaderField: "X-Plex-Product")
            request.setValue("0.2.2", forHTTPHeaderField: "X-Plex-Version")
        }
        let (data, http) = try await APITransport.send(request, provider: plex ? .plex : .tmdb, session: session, usage: usage)
        guard http.statusCode == 200 else {
            if plex, [401, 403].contains(http.statusCode) {
                throw RelayFailure.message("Plex rejected the token (HTTP \(http.statusCode)). Save a current token from an account with access to this server.")
            }
            throw RelayFailure.message("\(plex ? "Plex" : "TMDB") request failed (HTTP \(http.statusCode)). Check the connection and credentials.")
        }
        guard data.count <= 16 * 1024 * 1024 else { throw RelayFailure.message("Catalog response is too large") }
        return data
    }
    public func checkTMDB(token: String) async throws {
        guard !token.isEmpty else { throw RelayFailure.message("TMDB token is not configured.") }
        let data = try await get(URL(string: "https://api.themoviedb.org/3/configuration")!, token: token)
        guard (try metadataObject(data))["images"] is [String: Any] else { throw RelayFailure.message("Unexpected TMDB configuration response.") }
    }
    public func search(_ query: String, kind: String, token: String, language: String = "en-US") async throws -> [CatalogTitle] {
        guard !token.isEmpty else { throw RelayFailure.message("Add a TMDB API Read Access Token in Settings, or use manual identity fields") }
        var url = URLComponents(string: "https://api.themoviedb.org/3/search/\(kind == "movie" ? "movie" : "tv")")!
        url.queryItems = [URLQueryItem(name: "query", value: query), URLQueryItem(name: "include_adult", value: "false"), URLQueryItem(name: "language", value: language)]
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
    public func seriesCatalog(id: Int, token: String, seasons requested: Set<Int>? = nil, existing: TVSeriesCatalog? = nil) async throws -> TVSeriesCatalog {
        struct Details: Decodable {
            struct Season: Decodable { var seasonNumber: Int }
            struct IDs: Decodable { var imdbId: String?; var tvdbId: Int? }
            var id: Int; var name: String; var firstAirDate: String?; var seasons: [Season]
            var status: String?; var inProduction: Bool?; var externalIds: IDs?
        }
        let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
        let details = try decoder.decode(Details.self, from: await get(URL(string: "https://api.themoviedb.org/3/tv/\(id)?append_to_response=external_ids")!, token: token))
        var all: [EpisodeCandidate] = existing?.episodes ?? []
        var dates = existing?.seasonFetchedAt ?? [:]
        // Include specials and every season: title-only batches can span seasons.
        for season in details.seasons where requested == nil || requested!.contains(season.seasonNumber) {
            try Task.checkCancellation()
            let values = try await episodes(series: id, season: season.seasonNumber, token: token)
            all.removeAll { $0.seasonNumber == season.seasonNumber }; all += values
            dates[season.seasonNumber] = Date()
        }
        var result = TVSeriesCatalog(title: CatalogTitle(id: details.id, name: details.name, firstAirDate: details.firstAirDate), episodes: all)
        result.fetchedAt = requested == nil ? Date() : existing?.fetchedAt
        result.status = details.status; result.inProduction = details.inProduction
        result.imdbID = details.externalIds?.imdbId; result.tvdbID = details.externalIds?.tvdbId
        result.availableSeasons = details.seasons.map(\.seasonNumber); result.seasonFetchedAt = dates
        return result
    }
    public func title(id: Int, kind: String, token: String) async throws -> CatalogTitle {
        guard id > 0, !token.isEmpty else { throw RelayFailure.message("A TMDB ID and token are required") }
        let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(CatalogTitle.self, from: await get(URL(string: "https://api.themoviedb.org/3/\(kind == "movie" ? "movie" : "tv")/\(id)")!, token: token))
    }
    public func find(externalID: String, source: String, kind: String, token: String) async throws -> [CatalogTitle] {
        guard ["imdb_id", "tvdb_id"].contains(source), !token.isEmpty,
              !externalID.isEmpty, externalID.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else { throw RelayFailure.message("Invalid external catalog ID") }
        var url = URLComponents(string: "https://api.themoviedb.org/3/find/\(externalID)")!
        url.queryItems = [URLQueryItem(name: "external_source", value: source)]
        struct Result: Decodable { var movieResults: [CatalogTitle]; var tvResults: [CatalogTitle] }
        let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
        let value = try decoder.decode(Result.self, from: await get(url.url!, token: token))
        return kind == "movie" ? value.movieResults : value.tvResults
    }
    public func plexTitles(base: URL, token: String) async throws -> [PlexTitle] {
        try await plexLibrary(base: base, token: token).titles
    }
    public func plexLibrary(base: URL, token: String) async throws -> PlexLibrary {
        guard Self.validPlexBase(base), !token.isEmpty else { throw RelayFailure.message("Enter a Plex server URL and token in Settings. Use a server address without /web, credentials or query parameters.") }
        func container(_ data: Data) throws -> [String: Any] {
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any], let value = object["MediaContainer"] as? [String: Any] else { throw RelayFailure.message("Unexpected Plex library response") }; return value
        }
        let sectionData = try container(await get(base.appendingPathComponent("library/sections"), token: token, plex: true))
        guard let sections = sectionData["Directory"] as? [[String: Any]] ?? ((sectionData["size"] as? Int) == 0 ? [] : nil) else {
            throw RelayFailure.message("Plex returned an unexpected library list. Check the server address and account access.")
        }
        var result: [PlexTitle] = []
        for section in sections where section["type"] as? String == "show" {
            guard let key = section["key"] as? String, Int(key) != nil else { continue }
            var start = 0
            while start < 10000 {
                var components = URLComponents(url: base.appendingPathComponent("library/sections/\(key)/all"), resolvingAgainstBaseURL: false)!
                components.queryItems = [URLQueryItem(name: "type", value: "2"), URLQueryItem(name: "includeGuids", value: "1"), URLQueryItem(name: "X-Plex-Container-Start", value: String(start)), URLQueryItem(name: "X-Plex-Container-Size", value: "200")]
                let data = try container(await get(components.url!, token: token, plex: true))
                guard let entries = data["Metadata"] as? [[String: Any]] ?? ((data["size"] as? Int) == 0 || (data["totalSize"] as? Int) == 0 ? [] : nil) else {
                    throw RelayFailure.message("Plex returned an unexpected TV library page. The library was not loaded completely.")
                }
                for entry in entries { if let id = entry["ratingKey"] as? String, let title = entry["title"] as? String {
                    let guids = (entry["Guid"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String } + [entry["guid"] as? String].compactMap { $0 }
                    let tmdbId = guids.compactMap { guid -> Int? in
                        guard guid.hasPrefix("tmdb://") else { return nil }
                        return Int(guid.dropFirst(7).prefix(while: \.isNumber))
                    }.first
                    var show = PlexTitle(id: id, title: title, year: entry["year"] as? Int, guid: entry["guid"] as? String, ordering: entry["showOrdering"] as? String, tmdbId: tmdbId)
                    show.imdbId = guids.first { $0.hasPrefix("imdb://") }.map { String($0.dropFirst(7)) }
                    show.tvdbId = guids.first { $0.hasPrefix("tvdb://") }.flatMap { Int($0.dropFirst(7)) }
                    show.addedAt = (entry["addedAt"] as? Double).map { Date(timeIntervalSince1970: $0) }
                    result.append(show)
                }}
                start += entries.count
                guard let total = data["totalSize"] as? Int ?? (entries.count < 200 ? start : nil) else {
                    throw RelayFailure.message("Plex omitted the total for a full page; library completeness is unknown.")
                }
                if entries.isEmpty && start < total { throw RelayFailure.message("Plex stopped returning shows before the library was fully loaded. Try Test Connection again.") }
                if start >= total { break }
                if start >= 10000 { throw RelayFailure.message("Plex TV library exceeds the 10,000-show lookup limit. The library was not loaded completely.") }
            }
        }
        return PlexLibrary(titles: result, televisionLibraries: sections.filter { $0["type"] as? String == "show" }.count)
    }
}
