import Foundation

extension MetadataDiscoveryClient {
    func omdb(clues: [String], kind: String, key: String, cache: URL?, activity: @escaping DiscoveryActivityHandler = { _ in }) async -> DiscoveryReport {
        guard !key.isEmpty else { return missing(.omdb) }
        var records: [DiscoveryEvidence] = [], warning: String?
        do {
            for clue in clues {
                try Task.checkCancellation()
                await activity(.init(source: "OMDb", clues: [clue], detail: "Searching title"))
                var page = 1, pages = 1, details = 0
                repeat {
                    let response = try await http.request(.omdb, path: "/", query: query(["s": clue, "type": kind == "movie" ? "movie" : "episode", "page": String(page)]), token: key, cache: cache)
                    let value = try metadataObject(response.data)
                    if value["Response"] as? String == "False" {
                        if (value["Error"] as? String ?? "").lowercased().contains("not found") { break }
                        throw RelayFailure.message("OMDb could not search this title; check its API key or request allowance")
                    }
                    pages = ((metadataInt(value["totalResults"]) ?? 0) + 9) / 10
                    for entry in value["Search"] as? [[String: Any]] ?? [] {
                        guard let title = entry["Title"] as? String, let id = entry["imdbID"] as? String else { continue }
                        if kind == "movie" {
                            records.append(DiscoveryEvidence(source: .omdb, recordID: id, kind: kind, title: title, year: metadataYear(entry["Year"]), ids: DiscoveryIDs(imdb: id), matchedClue: clue))
                        } else if exact(title, [clue]) {
                            guard details < 50 else { warning = "Some OMDb episode details were omitted for common titles; refine the title"; continue }
                            details += 1
                            let detail = try await omdbDetail(id, key: key, cache: cache)
                            guard let series = detail["seriesID"] as? String, series.hasPrefix("tt") else { continue }
                            let show = try await omdbDetail(series, key: key, cache: cache)
                            guard let showTitle = show["Title"] as? String else { continue }
                            records.append(DiscoveryEvidence(source: .omdb, recordID: id, title: showTitle, year: metadataYear(show["Year"]), ids: DiscoveryIDs(imdb: series), episode: DiscoveredEpisode(title: title, season: metadataInt(detail["Season"]), number: metadataInt(detail["Episode"])), matchedClue: clue))
                        }
                    }
                    page += 1
                } while page <= min(pages, 10)
                if pages > 10 { warning = "Some OMDb results were omitted after 100 records per title; refine common titles" }
            }
        } catch { warning = failure(error) }
        await activity(.init(source: "OMDb", clues: clues, finished: true))
        return report(.omdb, records, warning)
    }
    private func omdbDetail(_ id: String, key: String, cache: URL?) async throws -> [String: Any] {
        let response = try await http.request(.omdb, path: "/", query: query(["i": id]), token: key, cache: cache)
        let result = try metadataObject(response.data)
        guard result["Response"] as? String != "False" else { throw RelayFailure.message("OMDb episode details are unavailable; other sources remain available") }
        return result
    }
}
