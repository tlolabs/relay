import Foundation

public struct FullCatalogMetadata: Sendable {
    public var fields: [String:String]; public var artwork: [String]
}
extension CatalogClient {
    public func fullMetadata(id: Int, kind: String, season: Int? = nil, episode: Int? = nil, language: String = "en-US", token: String) async throws -> FullCatalogMetadata {
        let part = kind == "movie" ? "movie/\(id)" : season != nil && episode != nil ? "tv/\(id)/season/\(season!)/episode/\(episode!)" : "tv/\(id)"
        var url = URLComponents(string:"https://api.themoviedb.org/3/\(part)")!
        url.queryItems = [URLQueryItem(name:"append_to_response",value:kind == "movie" ? "credits,images,release_dates" : "credits,images,content_ratings"),URLQueryItem(name:"language",value:language),URLQueryItem(name:"include_image_language",value:"\(language.prefix(2)),null")]
        let object = try JSONSerialization.jsonObject(with: await get(url.url!,token:token)) as? [String:Any] ?? [:]
        var fields: [String:String] = [:]
        for (key,source) in [("description","overview"),("tagline","tagline"),("releaseDate",kind == "movie" ? "release_date" : episode != nil ? "air_date" : "first_air_date")] { if let value = object[source] as? String { fields[key] = value } }
        if let genres = object["genres"] as? [[String:Any]] { fields["genre"] = genres.compactMap { $0["name"] as? String }.joined(separator:", ") }
        if let companies = object["production_companies"] as? [[String:Any]] { fields["studio"] = companies.compactMap { $0["name"] as? String }.joined(separator:", ") }
        if let networks = object["networks"] as? [[String:Any]] { fields["network"] = networks.compactMap { $0["name"] as? String }.joined(separator:", ") }
        let credits = object["credits"] as? [String:Any] ?? [:]
        if let actors = credits["cast"] as? [[String:Any]] { fields["actors"] = actors.compactMap { $0["name"] as? String }.joined(separator:"\n") }
        let crew = credits["crew"] as? [[String:Any]] ?? []
        for (key,jobs) in [("directors",["Director"]),("coDirectors",["Co-Director"]),("producers",["Producer","Executive Producer"]),("screenwriters",["Writer","Screenplay","Story"])] {
            var seen=Set<String>(); fields[key] = crew.filter { jobs.contains($0["job"] as? String ?? "") }.compactMap { $0["name"] as? String }.filter { seen.insert($0).inserted }.joined(separator:"\n")
        }
        if kind == "movie", let releases = (object["release_dates"] as? [String:Any])?["results"] as? [[String:Any]], let us = releases.first(where: { $0["iso_3166_1"] as? String == "US" }), let dates = us["release_dates"] as? [[String:Any]] { fields["contentRating"] = dates.compactMap { $0["certification"] as? String }.first { !$0.isEmpty } }
        if let ratings = (object["content_ratings"] as? [String:Any])?["results"] as? [[String:Any]] { fields["contentRating"] = ratings.first { $0["iso_3166_1"] as? String == "US" }?["rating"] as? String }
        let images = object["images"] as? [String:Any] ?? [:]
        var paths = (images["posters"] as? [[String:Any]] ?? []).compactMap { $0["file_path"] as? String }
        if let poster = object["poster_path"] as? String { paths.insert(poster,at:0) }
        var seen=Set<String>(); let artwork = paths.filter { seen.insert($0).inserted }.map { "https://image.tmdb.org/t/p/w500\($0)" }
        return FullCatalogMetadata(fields:fields,artwork:artwork)
    }
    public func poster(url: URL) async throws -> Data {
        guard url.scheme == "https", url.host == "image.tmdb.org", url.path.hasPrefix("/t/p/") else { throw RelayFailure.message("Unsupported artwork source") }
        let (data,response) = try await APITransport.send(URLRequest(url:url),provider:.tmdb,session:session,usage:usage)
        guard response.statusCode == 200, data.count <= 16*1024*1024, response.mimeType?.hasPrefix("image/") == true else { throw RelayFailure.message("Poster download failed or exceeded the size limit") }
        return data
    }
}
