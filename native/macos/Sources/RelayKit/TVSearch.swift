import Foundation

public struct TVSeriesCatalog: Codable, Sendable {
    public var title: CatalogTitle
    public var episodes: [EpisodeCandidate]
    public var fetchedAt: Date? = Date()
}
public struct TVShowMatch: Identifiable, Sendable {
    public var catalog: TVSeriesCatalog
    public var matchedTitles: [String]
    public var supportedTitles: [String] = []
    public var evidence: [DiscoveryEvidence] = []
    public var disagreements: [String] = []
    public var id: Int { catalog.title.id }
}

public enum EpisodeClues {
    public static func normalized(_ value: String) -> String {
        value.lowercased().filter { $0.isLetter || $0.isNumber }
    }
    public static func unique(_ titles: [String]) -> [String] {
        var seen = Set<String>()
        return titles.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert(normalized($0)).inserted }
    }
    public static func rank(_ catalogs: [TVSeriesCatalog], clues: [String]) -> [TVShowMatch] {
        let titles = unique(clues)
        return catalogs.map { catalog in
            let names = Set(catalog.episodes.map { normalized($0.name) })
            return TVShowMatch(catalog: catalog, matchedTitles: titles.filter { names.contains(normalized($0)) })
        }.sorted {
            if $0.matchedTitles.count != $1.matchedTitles.count { return $0.matchedTitles.count > $1.matchedTitles.count }
            return $0.catalog.title.displayTitle.localizedStandardCompare($1.catalog.title.displayTitle) == .orderedAscending
        }
    }
    public static func exactMatch(_ title: String, episodes: [EpisodeCandidate]) -> EpisodeCandidate? {
        let matches = episodes.filter { normalized($0.name) == normalized(title) && !normalized(title).isEmpty }
        return matches.count == 1 ? matches[0] : nil
    }
}

/// Web results supply candidate show IDs only. Episode identity always comes
/// from the TMDB catalog and is ranked against the complete set of file clues.
public actor EpisodeWebSearch {
    private let session: URLSession
    private let usage: APIUsageStore
    public init(session: URLSession? = nil, usage: APIUsageStore = .shared) {
        let configuration = URLSessionConfiguration.ephemeral; configuration.urlCache = nil
        self.session = session ?? URLSession(configuration: configuration); self.usage = usage
    }
    public func showIDs(titles: [String], token: String) async throws -> [Int] {
        guard !token.isEmpty else { return [] }
        let clues = EpisodeClues.unique(titles)
        var ids: [Int] = []
        // Each title participates, including batches containing multiple shows.
        for start in stride(from: 0, to: clues.count, by: 3) {
            try Task.checkCancellation()
            let group = clues[start..<min(start + 3, clues.count)]
            let terms = group.map { "\"\($0.replacingOccurrences(of: "\"", with: " ").prefix(120))\"" }.joined(separator: " OR ")
            var url = URLComponents(string: "https://api.search.brave.com/res/v1/web/search")!
            url.queryItems = [URLQueryItem(name: "q", value: "site:themoviedb.org/tv/ (\(terms))"), URLQueryItem(name: "count", value: "10")]
            var request = URLRequest(url: url.url!); request.timeoutInterval = 15
            request.setValue(token, forHTTPHeaderField: "X-Subscription-Token")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            let (data, response) = try await APITransport.send(request, provider: .brave, session: session, usage: usage)
            guard response.statusCode == 200, data.count < 4 * 1024 * 1024 else {
                throw RelayFailure.message("Episode web search failed. Check the Brave Search connection in Settings.")
            }
            struct Response: Decodable {
                struct Web: Decodable {
                    struct Result: Decodable { var url: String }
                    var results: [Result]
                }
                var web: Web?
            }
            let result = try JSONDecoder().decode(Response.self, from: data)
            for entry in result.web?.results ?? [] {
                guard let url = URL(string: entry.url), ["www.themoviedb.org", "themoviedb.org"].contains(url.host?.lowercased() ?? ""), url.scheme == "https" else { continue }
                let path = url.pathComponents
                guard path.count > 2, path[1] == "tv", let id = Int(path[2].prefix(while: \.isNumber)), id > 0 else { continue }
                if !ids.contains(id) { ids.append(id) }
            }
        }
        return ids
    }
}
