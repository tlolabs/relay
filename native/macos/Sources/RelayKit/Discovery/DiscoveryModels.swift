import Foundation

public enum MetadataSource: String, Codable, CaseIterable, Sendable {
    case trakt = "Trakt", omdb = "OMDb", tvmaze = "TVmaze", tvdb = "TheTVDB", imdb = "IMDb"
    public var website: URL {
        URL(string: [Self.trakt: "https://trakt.tv", .omdb: "https://www.omdbapi.com", .tvmaze: "https://www.tvmaze.com", .tvdb: "https://thetvdb.com", .imdb: "https://www.imdb.com"][self]!)!
    }
}
public struct DiscoveryIDs: Codable, Hashable, Sendable {
    public var tmdb: Int?; public var imdb: String?; public var tvdb: Int?
    public init(tmdb: Int? = nil, imdb: String? = nil, tvdb: Int? = nil) { self.tmdb = tmdb; self.imdb = imdb; self.tvdb = tvdb }
}
public struct DiscoveredEpisode: Codable, Hashable, Sendable {
    public var title: String; public var season: Int?; public var number: Int?; public var airDate: String?
    public init(title: String, season: Int? = nil, number: Int? = nil, airDate: String? = nil) {
        self.title = title; self.season = season; self.number = number; self.airDate = airDate
    }
}
public struct DiscoveryEvidence: Codable, Hashable, Sendable {
    public var source: MetadataSource; public var recordID: String; public var kind: String
    public var title: String; public var year: Int?; public var ids: DiscoveryIDs; public var episode: DiscoveredEpisode?
    public var matchedClue: String?
    public init(source: MetadataSource, recordID: String, kind: String = "tv", title: String, year: Int? = nil, ids: DiscoveryIDs = .init(), episode: DiscoveredEpisode? = nil, matchedClue: String? = nil) {
        self.source = source; self.recordID = recordID; self.kind = kind; self.title = title; self.year = year; self.ids = ids; self.episode = episode; self.matchedClue = matchedClue
    }
}
public struct DiscoverySeed: Hashable, Sendable {
    public var title: String; public var year: Int?; public var ids: DiscoveryIDs
    public init(title: String, year: Int? = nil, ids: DiscoveryIDs = .init()) { self.title = title; self.year = year; self.ids = ids }
}
public struct ProviderStatus: Codable, Identifiable, Sendable {
    public var source: MetadataSource; public var message: String; public var incomplete: Bool
    public var id: String { source.rawValue }
    public init(source: MetadataSource, message: String, incomplete: Bool) { self.source = source; self.message = message; self.incomplete = incomplete }
}
public struct DiscoveryReport: Sendable {
    public var evidence: [DiscoveryEvidence] = []; public var statuses: [ProviderStatus] = []
    public init(evidence: [DiscoveryEvidence] = [], statuses: [ProviderStatus] = []) { self.evidence = evidence; self.statuses = statuses }
}
public struct DiscoveryCredentials: Sendable {
    public var trakt: String; public var omdb: String; public var tvdb: String
    public init(trakt: String = "", omdb: String = "", tvdb: String = "") { self.trakt = trakt; self.omdb = omdb; self.tvdb = tvdb }
}

public enum MetadataConsensus {
    /// Count distinct title clues and sources, never duplicate records or search
    /// pages. Sources may share upstream data, so these counts are not probabilities.
    public static func rank(_ catalogs: [TVSeriesCatalog], clues: [String], evidence: [Int: [DiscoveryEvidence]]) -> [TVShowMatch] {
        var matches = EpisodeClues.rank(catalogs, clues: clues)
        for index in matches.indices {
            let records = Array(Set(evidence[matches[index].id] ?? []))
            matches[index].evidence = records
            let externalClues = Set(records.compactMap { $0.matchedClue ?? $0.episode?.title }.map(EpisodeClues.normalized))
            matches[index].supportedTitles = EpisodeClues.unique(clues).filter { clue in
                matches[index].matchedTitles.contains(clue) || externalClues.contains(EpisodeClues.normalized(clue))
            }
            var conflicts = Set<String>()
            for record in records {
                guard let external = record.episode else { continue }
                let canonical = matches[index].catalog.episodes.filter { EpisodeClues.normalized($0.name) == EpisodeClues.normalized(external.title) }
                if canonical.count == 1, let tmdb = canonical.first {
                    if let season = external.season, let number = external.number,
                       season != tmdb.seasonNumber || number != tmdb.episodeNumber {
                        conflicts.insert("\(record.source.rawValue): “\(external.title)” is S\(season)E\(number); TMDB uses S\(tmdb.seasonNumber)E\(tmdb.episodeNumber).")
                    }
                } else if canonical.isEmpty {
                    conflicts.insert("\(record.source.rawValue): “\(external.title)” has no exact title match in TMDB. Choose the TMDB episode manually.")
                } else {
                    conflicts.insert("TMDB has multiple episodes named “\(external.title)”; choose the episode manually.")
                }
            }
            for clue in EpisodeClues.unique(clues) {
                let related = records.filter { EpisodeClues.normalized($0.matchedClue ?? $0.episode?.title ?? "") == EpisodeClues.normalized(clue) }
                if !related.isEmpty, episode(for: clue, episodes: matches[index].catalog.episodes, evidence: related) == nil {
                    conflicts.insert("“\(clue)” has no unique verified TMDB episode mapping; choose the episode manually.")
                }
            }
            matches[index].disagreements = conflicts.sorted()
        }
        return matches.sorted {
            if $0.supportedTitles.count != $1.supportedTitles.count { return $0.supportedTitles.count > $1.supportedTitles.count }
            if $0.matchedTitles.count != $1.matchedTitles.count { return $0.matchedTitles.count > $1.matchedTitles.count }
            let left = Set($0.evidence.map(\.source)).count, right = Set($1.evidence.map(\.source)).count
            if left != right { return left > right }
            return $0.catalog.title.displayTitle.localizedStandardCompare($1.catalog.title.displayTitle) == .orderedAscending
        }
    }
    /// Return a TMDB episode only when every exact-title/known-alias mapping
    /// leads to one unique canonical episode. Foreign numbering is never used.
    public static func episode(for clue: String, episodes: [EpisodeCandidate], evidence: [DiscoveryEvidence]) -> EpisodeCandidate? {
        let query = EpisodeClues.normalized(clue)
        guard !query.isEmpty else { return nil }
        var names = Set([query])
        for record in evidence {
            if let external = record.episode, EpisodeClues.normalized(record.matchedClue ?? external.title) == query {
                if !episodes.contains(where: { EpisodeClues.normalized($0.name) == EpisodeClues.normalized(external.title) }) { return nil }
                names.insert(EpisodeClues.normalized(external.title))
            }
        }
        let matches = episodes.filter { names.contains(EpisodeClues.normalized($0.name)) }
        return matches.count == 1 ? matches[0] : nil
    }
}
