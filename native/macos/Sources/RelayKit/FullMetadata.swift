import Foundation

public struct FullCatalogMetadata: Sendable {
    public var fields: [String:String]; public var artwork: [String]
    public init(fields: [String: String], artwork: [String] = []) { self.fields = fields; self.artwork = artwork }

    public func applying(to draft: DirectDraft) -> DirectDraft {
        var result = draft
        for (key, value) in fields where !draft.overrides.contains(key) { result.metadata[key] = value }
        return result
    }
}
extension CatalogClient {
    public func fullMetadata(id: Int, kind: String, season: Int? = nil, episode: Int? = nil, language: String = "en-US", token: String) async throws -> FullCatalogMetadata {
        guard id > 0, ["movie", "tv"].contains(kind), !token.isEmpty else { throw RelayFailure.message("Choose a catalog identity and configure a TMDB token before loading metadata.") }
        if kind == "tv", let season, let episode {
            guard season >= 0, episode > 0 else { throw RelayFailure.message("Choose valid season and episode numbers before loading metadata.") }
            let show = try await metadataRecord(part: "tv/\(id)", scope: "tv", language: language, token: token)
            let seasonValues = try await metadataRecord(part: "tv/\(id)/season/\(season)", scope: "season", language: language, token: token)
            let episodeValues = try await metadataRecord(part: "tv/\(id)/season/\(season)/episode/\(episode)", scope: "episode", language: language, token: token)
            // Shared series fields accompany every episode. Cast, plot, dates and
            // episode crew come only from that episode, never other episodes.
            var fields = episodeValues.fields
            for key in ["tagline", "genre", "studio", "network", "contentRating", "tags"] { fields[key] = show.fields[key] ?? "" }
            fields["seasonDescription"] = seasonValues.fields["description"] ?? ""
            fields["producers"] = Self.uniqueNames([show.fields["producers"] ?? "", seasonValues.fields["producers"] ?? "", episodeValues.fields["producers"] ?? ""].flatMap { $0.components(separatedBy: "\n") }).joined(separator: "\n")
            fields["episodeID"] = String(format: "S%02dE%02d", season, episode)
            return FullCatalogMetadata(fields: fields, artwork: show.artwork)
        }
        return try await metadataRecord(part: kind == "movie" ? "movie/\(id)" : "tv/\(id)", scope: kind, language: language, token: token)
    }

    private static func uniqueNames(_ names: [String]) -> [String] {
        var seen = Set<String>()
        return names.filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    private func metadataRecord(part: String, scope: String, language: String, token: String) async throws -> FullCatalogMetadata {
        let key = "\(part)|\(language)"
        if let cached = metadataCache[key], Date().timeIntervalSince(cached.date) < 6 * 60 * 60 {
            try await usage.cacheHit(.tmdb)
            return cached.value
        }
        var url = URLComponents(string:"https://api.themoviedb.org/3/\(part)")!
        let appended = scope == "movie" ? "credits,images,release_dates,keywords" : scope == "tv" ? "credits,images,content_ratings,keywords" : "credits"
        url.queryItems = [URLQueryItem(name:"append_to_response",value:appended),URLQueryItem(name:"language",value:language),URLQueryItem(name:"include_image_language",value:"\(language.prefix(2)),null")]
        guard let object = try JSONSerialization.jsonObject(with: await get(url.url!,token:token)) as? [String:Any], object["id"] is NSNumber,
              let credits = object["credits"] as? [String: Any], credits["status_code"] == nil else {
            throw RelayFailure.message("TMDB returned incomplete metadata for \(part). Try loading it again before processing.")
        }
        for resource in appended.components(separatedBy: ",") {
            guard let value = object[resource] as? [String: Any], value["status_code"] == nil else {
                throw RelayFailure.message("TMDB did not return \(resource) for \(part). Try loading metadata again before processing.")
            }
        }
        var fields: [String:String] = ["genre": "", "studio": "", "network": "", "seasonDescription": ""]
        for (key,source) in [("description","overview"),("tagline","tagline"),("releaseDate",scope == "movie" ? "release_date" : scope == "episode" || scope == "season" ? "air_date" : "first_air_date")] { fields[key] = object[source] as? String ?? "" }
        fields["rating"] = (object["vote_count"] as? Int ?? 0) > 0 ? (object["vote_average"] as? NSNumber)?.stringValue ?? "" : ""
        if let genres = object["genres"] as? [[String:Any]] { fields["genre"] = genres.compactMap { $0["name"] as? String }.joined(separator:", ") }
        if let companies = object["production_companies"] as? [[String:Any]] { fields["studio"] = companies.compactMap { $0["name"] as? String }.joined(separator:", ") }
        if let networks = object["networks"] as? [[String:Any]] { fields["network"] = networks.compactMap { $0["name"] as? String }.joined(separator:", ") }
        let cast = credits["cast"] as? [[String:Any]] ?? []
        let guests = (credits["guest_stars"] as? [[String:Any]] ?? []) + (object["guest_stars"] as? [[String:Any]] ?? [])
        fields["actors"] = Self.uniqueNames((cast + guests).compactMap { $0["name"] as? String }).joined(separator:"\n")
        let crew = (credits["crew"] as? [[String:Any]] ?? []) + (object["crew"] as? [[String:Any]] ?? [])
        for (key,jobs) in [("directors",["Director"]),("coDirectors",["Co-Director"]),("producers",["Producer","Executive Producer"]),("screenwriters",["Writer","Screenplay","Story"])] {
            var seen=Set<String>(); fields[key] = crew.filter { jobs.contains($0["job"] as? String ?? "") }.compactMap { $0["name"] as? String }.filter { seen.insert($0).inserted }.joined(separator:"\n")
        }
        fields["contentRating"] = ""
        if scope == "movie", let releases = (object["release_dates"] as? [String:Any])?["results"] as? [[String:Any]], let us = releases.first(where: { $0["iso_3166_1"] as? String == "US" }), let dates = us["release_dates"] as? [[String:Any]] { fields["contentRating"] = dates.compactMap { $0["certification"] as? String }.first { !$0.isEmpty } ?? "" }
        if let ratings = (object["content_ratings"] as? [String:Any])?["results"] as? [[String:Any]] { fields["contentRating"] = ratings.first { $0["iso_3166_1"] as? String == "US" }?["rating"] as? String ?? "" }
        let keywords = object["keywords"] as? [String: Any] ?? [:]
        let words = keywords["results"] as? [[String: Any]] ?? keywords["keywords"] as? [[String: Any]] ?? []
        fields["tags"] = Self.uniqueNames(words.compactMap { $0["name"] as? String }).joined(separator: "\n")
        let images = object["images"] as? [String:Any] ?? [:]
        var paths = (images["posters"] as? [[String:Any]] ?? []).compactMap { $0["file_path"] as? String }
        if let poster = object["poster_path"] as? String { paths.insert(poster,at:0) }
        var seen=Set<String>(); let artwork = paths.filter { seen.insert($0).inserted }.map { "https://image.tmdb.org/t/p/w500\($0)" }
        let result = FullCatalogMetadata(fields:fields,artwork:artwork)
        metadataCache[key] = (Date(), result)
        return result
    }
    public func poster(url: URL) async throws -> Data {
        guard url.scheme == "https", url.host == "image.tmdb.org", url.path.hasPrefix("/t/p/") else { throw RelayFailure.message("Unsupported artwork source") }
        let (data,response) = try await APITransport.send(URLRequest(url:url),provider:.tmdb,session:session,usage:usage)
        guard response.statusCode == 200, data.count <= 16*1024*1024, response.mimeType?.hasPrefix("image/") == true else { throw RelayFailure.message("Poster download failed or exceeded the size limit") }
        return data
    }
}
