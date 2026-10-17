import Foundation

extension MetadataDiscoveryClient {
    func tvmaze(clues: [String], kind: String, seeds: [DiscoverySeed], cache: URL?) async -> DiscoveryReport {
        guard kind == "tv" else { return DiscoveryReport(statuses: [ProviderStatus(source: .tvmaze, message: "TV data only", incomplete: false)]) }
        var records: [DiscoveryEvidence] = [], warning: String?, visited = Set<Int>()
        do {
            for seed in seeds {
                var results: [[String: Any]] = []
                let lookup = seed.ids.imdb.map { ["imdb": $0] } ?? seed.ids.tvdb.map { ["thetvdb": String($0)] }
                if let lookup {
                    do {
                        let response = try await http.request(.tvmaze, path: "/lookup/shows", query: query(lookup), cache: cache)
                        results = [["show": try metadataObject(response.data)]]
                    } catch is CancellationError { throw CancellationError() }
                    catch { /* A provider ID may be absent from TVmaze; try name/year. */ }
                }
                if results.isEmpty {
                    let response = try await http.request(.tvmaze, path: "/search/shows", query: query(["q": seed.title]), cache: cache)
                    guard let values = try JSONSerialization.jsonObject(with: response.data) as? [[String: Any]] else { throw RelayFailure.message("TVmaze returned an unexpected search response") }
                    results = values
                }
                for result in results {
                    guard let show = result["show"] as? [String: Any], let id = metadataInt(show["id"]), let name = show["name"] as? String else { continue }
                    let external = show["externals"] as? [String: Any] ?? [:]
                    let imdb = external["imdb"] as? String, tvdb = metadataInt(external["thetvdb"]), year = metadataYear(show["premiered"])
                    let linked = (seed.ids.imdb != nil && seed.ids.imdb == imdb) || (seed.ids.tvdb != nil && seed.ids.tvdb == tvdb)
                    guard linked || (exact(name, [seed.title]) && (seed.year == nil || year == seed.year)), visited.insert(id).inserted else { continue }
                    let episodes = try await http.request(.tvmaze, path: "/shows/\(id)/episodes", query: query(["specials": "1"]), cache: cache)
                    guard let values = try JSONSerialization.jsonObject(with: episodes.data) as? [[String: Any]] else { throw RelayFailure.message("TVmaze returned an unexpected episode catalog") }
                    for value in values {
                        guard let title = value["name"] as? String, exact(title, clues) else { continue }
                        // TVmaze specials may have null numbers; keep them unknown.
                        records.append(DiscoveryEvidence(source: .tvmaze, recordID: String(metadataInt(value["id"]) ?? 0), title: name, year: year, ids: DiscoveryIDs(imdb: imdb, tvdb: tvdb), episode: DiscoveredEpisode(title: title, season: metadataInt(value["season"]), number: metadataInt(value["number"]), airDate: value["airdate"] as? String)))
                    }
                }
            }
        } catch { warning = failure(error) }
        return report(.tvmaze, records, warning)
    }
}
