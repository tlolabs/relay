import Foundation

extension MetadataDiscoveryClient {
    func trakt(clues: [String], kind: String, key: String, cache: URL?) async -> DiscoveryReport {
        guard !key.isEmpty else { return missing(.trakt) }
        var records: [DiscoveryEvidence] = [], warning: String?
        do {
            for clue in clues {
                // Trakt treats these characters as query syntax, not literal text.
                let reserved = Set("+-&|!(){}[]^\"~*?:/\\")
                let escaped = clue.map { reserved.contains($0) ? "\\\($0)" : String($0) }.joined()
                var page = 1, pages = 1
                repeat {
                    let response = try await http.request(.trakt, path: "/search/\(kind == "movie" ? "movie" : "episode")", query: query(["query": escaped, "fields": "title", "limit": "100", "page": String(page)]), token: key, cache: cache)
                    guard let results = try JSONSerialization.jsonObject(with: response.data) as? [[String: Any]] else { throw RelayFailure.message("Trakt returned an unexpected search response") }
                    pages = response.pages ?? 1
                    for result in results {
                        let entity = result[kind == "movie" ? "movie" : "show"] as? [String: Any] ?? [:]
                        guard let title = entity["title"] as? String, !title.isEmpty else { continue }
                        let ids = entity["ids"] as? [String: Any] ?? [:]
                        var episode: DiscoveredEpisode?
                        if kind != "movie" {
                            guard let value = result["episode"] as? [String: Any], let name = value["title"] as? String, exact(name, [clue]) else { continue }
                            episode = DiscoveredEpisode(title: name, season: metadataInt(value["season"]), number: metadataInt(value["number"]))
                        }
                        let record = (result["episode"] as? [String: Any])?["ids"] as? [String: Any] ?? ids
                        records.append(DiscoveryEvidence(source: .trakt, recordID: String(metadataInt(record["trakt"]) ?? 0), kind: kind, title: title, year: metadataInt(entity["year"]), ids: DiscoveryIDs(tmdb: metadataInt(ids["tmdb"]), imdb: ids["imdb"] as? String, tvdb: metadataInt(ids["tvdb"])), episode: episode))
                    }
                    page += 1
                } while page <= min(pages, 10)
                if pages > 10 { warning = "Some Trakt results were omitted after 1,000 records per title; refine common titles" }
            }
        } catch { warning = failure(error) }
        return report(.trakt, records, warning)
    }
}
