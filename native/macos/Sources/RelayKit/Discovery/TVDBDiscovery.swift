import Foundation
import CryptoKit

extension MetadataDiscoveryClient {
    func tvdb(clues: [String], kind: String, seeds: [DiscoverySeed], key: String, cache: URL?, activity: @escaping DiscoveryActivityHandler = { _ in }) async -> DiscoveryReport {
        guard !key.isEmpty else { return missing(.tvdb) }
        var records: [DiscoveryEvidence] = [], warning: String?, visited = Set<Int>()
        do {
            let hash = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
            let token: String
            if let session = tvdbSession, session.key == hash, session.expires > Date() { token = session.token }
            else {
                let login = try await http.request(.tvdb, path: "/login", method: "POST", body: JSONSerialization.data(withJSONObject: ["apikey": key]))
                let object = try metadataObject(login.data)
                guard let value = (object["data"] as? [String: Any])?["token"] as? String else { throw RelayFailure.message("TheTVDB login failed; check the free project API key") }
                token = value; tvdbSession = (hash, value, Date().addingTimeInterval(25 * 86400))
            }
            let names = kind == "movie" ? clues.map { DiscoverySeed(title: $0) } : seeds
            for seed in names {
                try Task.checkCancellation()
                await activity(.init(source: "TheTVDB", clues: kind == "movie" ? [seed.title] : clues, detail: "Checking \(seed.title)"))
                var candidates: [(Int, String, Int?, DiscoveryIDs)] = []
                if kind == "tv", let id = seed.ids.tvdb { candidates = [(id, seed.title, seed.year, seed.ids)] }
                else {
                    let response = try await http.request(.tvdb, path: "/search", query: query(["query": seed.title, "type": kind == "movie" ? "movie" : "series", "limit": "100"]), token: token, cache: cache)
                    let result = try metadataObject(response.data)
                    for entry in result["data"] as? [[String: Any]] ?? [] {
                        guard let id = metadataInt(entry["tvdb_id"]), let name = entry["name"] as? String else { continue }
                        let year = metadataYear(entry["year"])
                        if kind == "tv", !(exact(name, [seed.title]) && (seed.year == nil || seed.year == year)) { continue }
                        candidates.append((id, name, year, tvdbIDs(entry, id: id)))
                    }
                }
                for (id, name, year, ids) in candidates where visited.insert(id).inserted {
                    if kind == "movie" {
                        // Base records include remote IDs absent from some search entries.
                        let response = try await http.request(.tvdb, path: "/movies/\(id)", token: token, cache: cache)
                        let base = (try metadataObject(response.data))["data"] as? [String: Any] ?? [:]
                        records.append(DiscoveryEvidence(source: .tvdb, recordID: String(id), kind: kind, title: name, year: year, ids: tvdbIDs(base, id: id), matchedClue: seed.title))
                        continue
                    }
                    var page = 0, hasNext = true
                    while hasNext && page < 100 {
                        let response = try await http.request(.tvdb, path: "/series/\(id)/episodes/official", query: query(["page": String(page)]), token: token, cache: cache)
                        let result = try metadataObject(response.data), value = result["data"] as? [String: Any] ?? [:]
                        let show = value["series"] as? [String: Any] ?? [:]
                        var showIDs = tvdbIDs(show, id: id)
                        if showIDs.imdb == nil { showIDs.imdb = ids.imdb }
                        // Never copy a candidate TMDB ID onto unverified provider data.
                        for episode in value["episodes"] as? [[String: Any]] ?? [] {
                            guard let title = episode["name"] as? String, exact(title, clues) else { continue }
                            records.append(DiscoveryEvidence(source: .tvdb, recordID: String(metadataInt(episode["id"]) ?? 0), title: (show["name"] as? String) ?? name, year: year, ids: showIDs, episode: DiscoveredEpisode(title: title, season: metadataInt(episode["seasonNumber"]), number: metadataInt(episode["number"]), airDate: episode["aired"] as? String)))
                        }
                        hasNext = (result["links"] as? [String: Any])?["next"] as? String != nil
                        page += 1
                    }
                    if hasNext { warning = "TheTVDB episode pagination limit reached; some records were omitted" }
                }
            }
        } catch { tvdbSession = nil; warning = failure(error) }
        await activity(.init(source: "TheTVDB", clues: clues, finished: true))
        return report(.tvdb, records, warning)
    }
    private func tvdbIDs(_ value: [String: Any], id: Int) -> DiscoveryIDs {
        var result = DiscoveryIDs(tvdb: id)
        for remote in value["remoteIds"] as? [[String: Any]] ?? value["remote_ids"] as? [[String: Any]] ?? [] {
            let source = (remote["sourceName"] as? String ?? remote["sourceNameTranslated"] as? String ?? "").lowercased()
            let raw = remote["id"] as? String ?? metadataInt(remote["id"]).map(String.init) ?? ""
            if source.contains("imdb"), raw.hasPrefix("tt") { result.imdb = raw }
            if source.contains("themoviedb") || source == "tmdb" { result.tmdb = Int(raw) }
        }
        return result
    }
}
