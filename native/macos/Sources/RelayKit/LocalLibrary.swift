import Foundation

public enum LibraryPresence: String, Codable, Sendable { case present, absent, unknown }
public enum EpisodeRelease: String, Codable, Sendable { case released, upcoming, unknown }
public struct PlexEpisodeRecord: Codable, Sendable, Equatable {
    public var showID: String
    public var season: Int
    public var episode: Int
    public var title: String
    public init(showID: String, season: Int, episode: Int, title: String) { self.showID = showID; self.season = season; self.episode = episode; self.title = title }
}
/// Published only after all pages are read. No credentials or request URLs.
public struct PlexInventory: Codable, Sendable {
    public var server: String
    public var fetchedAt: Date
    public var shows: [PlexTitle]
    public var episodes: [PlexEpisodeRecord]
    public var complete: Bool
    public init(server: String, fetchedAt: Date = Date(), shows: [PlexTitle], episodes: [PlexEpisodeRecord], complete: Bool = true) {
        self.server = server; self.fetchedAt = fetchedAt; self.shows = shows; self.episodes = episodes; self.complete = complete
    }
    public func presence(tmdb: Int, season: Int, episode: Int, now: Date = Date()) -> LibraryPresence {
        let linked = shows.filter { $0.tmdbId == tmdb }
        guard linked.allSatisfy({ $0.ordering == nil || $0.ordering == "aired" }) else { return .unknown }
        let ids = Set(linked.map(\.id))
        if episodes.contains(where: { ids.contains($0.showID) && $0.season == season && $0.episode == episode }) { return .present }
        guard complete, now.timeIntervalSince(fetchedAt) < 86400, !ids.isEmpty else { return .unknown }
        return .absent
    }
    public func save(to url: URL) throws { try JSONEncoder().encode(self).write(to: url, options: .atomic) }
    public static func load(from url: URL) -> PlexInventory? { (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(Self.self, from: $0) } }
}
public struct CatalogRefreshState: Codable, Sendable {
    public var server: String?
    public var attemptedAt: Date?
    public var succeededAt: Date?
    public var failure: String?
    public init() {}
    public func due(now: Date = Date()) -> Bool {
        if let attemptedAt, now.timeIntervalSince(attemptedAt) < 3600 { return false }
        return succeededAt.map { now.timeIntervalSince($0) >= 21600 } ?? true
    }
}
public extension EpisodeCandidate {
    func release(now: Date = Date()) -> EpisodeRelease {
        guard let airDate, airDate.count == 10 else { return .unknown }
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = TimeZone(secondsFromGMT: 0); formatter.dateFormat = "yyyy-MM-dd"
        guard let date = formatter.date(from: airDate) else { return .unknown }
        return date > now ? .upcoming : .released
    }
}
public struct LocalCatalogMatch: Sendable {
    public var catalog: TVSeriesCatalog
    public var episode: EpisodeCandidate
    public var agreement: TitleAgreement
}
public enum LocalMatching {
    public static func matches(_ local: LocalExploration, catalogs: [TVSeriesCatalog]) -> [LocalCatalogMatch] {
        guard !local.conflicts else { return [] }
        return catalogs.flatMap { catalog -> [LocalCatalogMatch] in
            let canonicalName = EpisodeClues.normalized(catalog.title.displayTitle)
            let region = ["taskmaster": "unitedkingdom", "taskmasteraustralia": "australia", "taskmasternewzealand": "newzealand"][canonicalName]
            if let region, !local.regions.isEmpty, !local.regions.contains(region) { return [] }
            if let show = local.show, EpisodeClues.normalized(show) != canonicalName {
                guard EpisodeClues.normalized(show) == "taskmaster", region.map({ local.regions.contains($0) }) == true else { return [] }
            }
            return catalog.episodes.compactMap { episode in
                guard local.filename.season.map({ $0 == episode.seasonNumber }) ?? true,
                      local.filename.episode.map({ $0 == episode.episodeNumber }) ?? true else { return nil }
                let agreement = EpisodeClues.agreement(local.filename.title, episode.name)
                guard agreement != .none else { return nil }
                return LocalCatalogMatch(catalog: catalog, episode: episode, agreement: agreement)
            }
        }
    }
    public static func identity(_ match: LocalCatalogMatch) -> MediaIdentity {
        var value = MediaIdentity(); value.kind = "tv"; value.title = match.catalog.title.displayTitle
        value.year = match.catalog.title.year; value.tmdbId = UInt64(match.catalog.title.id)
        value.season = match.episode.seasonNumber; value.episode = match.episode.episodeNumber; value.episodeTitle = match.episode.name
        return value
    }
}

public extension CatalogClient {
    func plexInventory(base: URL, token: String) async throws -> PlexInventory {
        let library = try await plexLibrary(base: base, token: token)
        var episodes: [PlexEpisodeRecord] = []
        for show in library.titles {
            guard Int(show.id) != nil else { throw RelayFailure.message("Invalid Plex show key; inventory remains incomplete") }
            var start = 0
            while true {
                try Task.checkCancellation()
                var url = URLComponents(url: base.appendingPathComponent("library/metadata/\(show.id)/allLeaves"), resolvingAgainstBaseURL: false)!
                url.queryItems = [.init(name: "X-Plex-Container-Start", value: String(start)), .init(name: "X-Plex-Container-Size", value: "200")]
                let data = try await get(url.url!, token: token, plex: true)
                guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any], let container = root["MediaContainer"] as? [String: Any],
                      let page = container["Metadata"] as? [[String: Any]] ?? ((container["size"] as? Int) == 0 ? [] : nil) else { throw RelayFailure.message("Incomplete Plex episode inventory") }
                for row in page {
                    guard let season = row["parentIndex"] as? Int, let number = row["index"] as? Int, let title = row["title"] as? String else { throw RelayFailure.message("Plex episode numbering is incomplete") }
                    episodes.append(.init(showID: show.id, season: season, episode: number, title: title))
                }
                start += page.count
                let total = container["totalSize"] as? Int
                if let total, start >= total { break }
                if total == nil, page.count < 200 { break }
                guard !page.isEmpty, start < 100000 else { throw RelayFailure.message("Plex episode inventory was truncated") }
            }
        }
        return PlexInventory(server: base.absoluteString, shows: library.titles, episodes: episodes)
    }
}
