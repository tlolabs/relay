import Foundation

/// A conservative evidence score, not a calibrated probability. Duplicate
/// records and provider counts do not increase it; identity constraints do.
public struct MatchConfidence: Sendable, Equatable {
    public var score: Int
    public var candidate: String?
    public var reasons: [String]
    public var identity: MediaIdentity?
    public var dimensions: [String: Int] = [:]
    public var catalogFreshness: String? = nil
    public var libraryPresence: LibraryPresence = .unknown
    public var canonicalAgreement = false
    public var metadataCompleteness = "Descriptive metadata and artwork are checked separately after choosing an identity."
    public init(score: Int, candidate: String?, reasons: [String], identity: MediaIdentity? = nil) {
        self.score = max(0, min(100, score)); self.candidate = candidate; self.reasons = reasons; self.identity = identity
    }
    public var level: String { score >= 80 ? "High" : score >= 50 ? "Medium" : "Low" }
    public var label: String { "Evidence \(score)/100 · \(level)" }
    public var explanation: String {
        ([candidate.map { "Automatic candidate: \($0)" }].compactMap { $0 } + reasons +
         [metadataCompleteness, "Evidence score, not a probability. Matches still need your review. Catalog freshness is separate from identity confidence; IMDb uses your imported dataset."]).joined(separator: "\n")
    }

    public static func local(_ local: LocalExploration, catalogs: [TVSeriesCatalog], inventory: PlexInventory? = nil, providerEvidence: [Int: [DiscoveryEvidence]] = [:], evaluatingShowID: Int? = nil, now: Date = Date()) -> MatchConfidence {
        let matches = LocalMatching.matches(local, catalogs: catalogs)
        let directShow = local.evidence.contains { $0.field == "show" && !$0.inferred }
        let batch = local.evidence.first { $0.source == "batch" }
        var reasons: [String] = []
        if directShow { reasons.append("Show named in local filename, embedded tags or subtitle introduction.") }
        if local.filename.numberToken != nil { reasons.append("Season and episode parsed from filename (\(local.filename.numberToken!)).") }
        if let batch { reasons.append("Inferred from \(batch.supportingFiles.count) matching files in this batch; inherited evidence is one contextual inference.") }
        var dimensions = ["Show / region": local.show == nil ? 0 : batch != nil ? 90 : 85,
                          "Season": local.filename.season == nil ? 0 : 90,
                          "Episode number": local.filename.episode == nil ? 0 : 90,
                          "Episode title": local.filename.title.isEmpty ? 0 : 65]
        var identity: MediaIdentity? = local.provisional
        var score = local.show == nil ? 20 : batch != nil ? 87 : 65
        var canonical = false
        var freshness: String?
        var presence = LibraryPresence.unknown
        if matches.count == 1, let match = matches.first {
            canonical = true; identity = LocalMatching.identity(match)
            score = local.show == nil ? 60 : 95
            dimensions["Show / region"] = local.show == nil ? 60 : 98
            dimensions["Season"] = 98; dimensions["Episode number"] = 98
            dimensions["Episode title"] = match.agreement == .exact ? 98 : 80
            if match.agreement == .approximate { score -= 7 }
            reasons.append("Episode title \(match.agreement == .exact ? "agrees with" : "approximately matches") cached season catalog. One match among checked candidates; this does not prove global uniqueness.")
            let date = match.catalog.seasonFetchedAt?[match.episode.seasonNumber] ?? match.catalog.fetchedAt
            freshness = date.map { "Using catalog last refreshed on \($0.formatted(date: .abbreviated, time: .shortened))\(now.timeIntervalSince($0) >= 21600 ? " (stale)" : " (recent)")." } ?? "Catalog refresh date unknown."
            reasons.append(freshness!)
            presence = inventory?.presence(tmdb: match.catalog.title.id, season: match.episode.seasonNumber, episode: match.episode.episodeNumber, now: now) ?? .unknown
            if presence == .present { reasons.append("Episode is present in the saved Plex inventory; this may be an upgrade or replacement.") }
            if presence == .absent { reasons.append("Show exists in Plex; this episode is absent from the saved inventory.") }
            if inventory != nil, presence == .unknown { reasons.append("Plex episode presence is unknown in the saved inventory.") }
            if let inventory {
                reasons.append("Plex inventory saved on \(inventory.fetchedAt.formatted(date: .abbreviated, time: .shortened))\(!inventory.complete || now.timeIntervalSince(inventory.fetchedAt) >= 86400 ? " (stale or incomplete)" : "").")
            }
            if match.episode.release(now: now) == .upcoming { reasons.append("Catalog lists this episode as upcoming; verify before applying.") }
        } else if matches.count > 1 {
            score = 30; identity = nil; reasons.append("Multiple checked canonical episodes match; choose manually.")
        } else {
            reasons.append("Provisional local clues; no canonical catalog agreement yet.")
            if let show = local.show, catalogs.contains(where: { EpisodeClues.normalized($0.title.displayTitle) == EpisodeClues.normalized(show) && $0.episodes.contains(where: { EpisodeClues.agreement($0.name, local.filename.title) != .none }) }) {
                score = 20; dimensions["Season"] = 25; dimensions["Episode number"] = 25; reasons.append("Cached episode title conflicts with the filename numbering.")
            }
        }
        if local.show.map(EpisodeClues.normalized) == "taskmaster", local.regions.isEmpty {
            score = min(score, 75); dimensions["Show / region"] = min(dimensions["Show / region"] ?? 0, 65)
            reasons.append("Taskmaster introduction does not establish a regional version; the checked catalog is only a candidate.")
        }
        if let id = identity?.tmdbId, canonical {
            let records = providerEvidence[Int(id), default: []].filter {
                EpisodeClues.agreement($0.matchedClue ?? $0.episode?.title ?? "", local.filename.title) != .none
            }
            let conflict = records.contains { record in
                if let externalID = record.ids.tmdb, externalID != Int(id) { return true }
                guard let episode = record.episode else { return false }
                return episode.season.map { $0 != identity?.season } == true || episode.number.map { $0 != identity?.episode } == true ||
                    EpisodeClues.agreement(episode.title, identity?.episodeTitle ?? "") == .none
            }
            if conflict { score = min(score, 25); reasons.append("Provider IDs, titles or numbering conflict with the canonical candidate. Review the source differences.") }
        }
        if local.conflicts { score = 5; identity = nil; dimensions = dimensions.mapValues { _ in 5 }; reasons.append("Conflicting local shows, regional versions or numbering prevent propagation.") }
        var result = MatchConfidence(score: score, candidate: identity?.display, reasons: reasons, identity: identity)
        result.dimensions = dimensions; result.catalogFreshness = freshness; result.libraryPresence = presence; result.canonicalAgreement = canonical
        if let evaluatingShowID, result.identity?.tmdbId != UInt64(evaluatingShowID) {
            result.score = 0; result.canonicalAgreement = false; result.identity = nil
            result.reasons.insert("Local evidence does not establish this show as the canonical candidate.", at: 0)
        }
        return result
    }

    public static func tv(clue: String, catalogs: [TVSeriesCatalog], evidence: [Int: [DiscoveryEvidence]], incomplete: Bool = false, showID: Int? = nil) -> MatchConfidence {
        let query = EpisodeClues.normalized(clue)
        guard !query.isEmpty else { return .init(score: 0, candidate: nil, reasons: ["No title clue to compare."]) }
        var seen = Set<Int>()
        let catalogs = catalogs.filter { seen.insert($0.title.id).inserted }
        let matches = catalogs.flatMap { catalog in
            let related = evidence[catalog.title.id, default: []].filter {
                EpisodeClues.normalized($0.matchedClue ?? $0.episode?.title ?? "") == query
            }
            let names = Set([query] + related.compactMap { $0.episode?.title }.map(EpisodeClues.normalized))
            return catalog.episodes.filter { names.contains(EpisodeClues.normalized($0.name)) }.map { (catalog.title, $0, related) }
        }
        guard let (title, episode, records) = matches.first(where: { showID == nil || $0.0.id == showID }) else {
            return .init(score: 0, candidate: nil, reasons: ["No exact episode or verified alias found in the checked TMDB catalogs."] + (incomplete ? ["Some source checks are incomplete."] : []))
        }
        guard matches.count == 1 else {
            return .init(score: 30, candidate: nil, reasons: ["\(matches.count) possible episodes across the checked catalogs; choose the show and episode manually."])
        }
        let candidate = "\(title.displayTitle) · S\(episode.seasonNumber)E\(episode.episodeNumber) · \(episode.name)"
        var identity = MediaIdentity()
        identity.kind = "tv"; identity.title = title.displayTitle; identity.year = title.year
        identity.tmdbId = UInt64(title.id); identity.season = episode.seasonNumber; identity.episode = episode.episodeNumber
        identity.episodeTitle = episode.name
        let conflicts = records.filter { record in
            guard let external = record.episode else { return false }
            return external.season.map { $0 != episode.seasonNumber } == true ||
                external.number.map { $0 != episode.episodeNumber } == true ||
                EpisodeClues.normalized(external.title) != EpisodeClues.normalized(episode.name)
        }
        if !conflicts.isEmpty {
            return .init(score: 25, candidate: candidate, reasons: ["A unique TMDB candidate was found, but source titles or episode numbering disagree.", "Conflicting sources: \(sourceNames(conflicts)). Choose the episode manually."], identity: identity)
        }
        let sources = Set(records.filter { $0.episode != nil }.map(\.source))
        let numbered = records.contains { $0.episode?.season == episode.seasonNumber && $0.episode?.number == episode.episodeNumber }
        let score = 60 + (numbered ? 10 : 0)
        var reasons = ["One unique exact episode or verified alias in the checked TMDB catalogs (+60)."]
        if !sources.isEmpty { reasons.append("\(sources.count) distinct source(s) corroborate this file's episode: \(sourceNames(records)) (correlated provider records are not independent confirmations).") }
        if numbered { reasons.append("External season and episode numbers agree with TMDB (+10).") }
        if sources.isEmpty { reasons.append("No external source corroboration for this file yet.") }
        if incomplete { reasons.append("Some optional checks are incomplete; catalog agreement remains available.") }
        return .init(score: min(95, score), candidate: candidate, reasons: reasons, identity: identity)
    }

    public static func movie(title: CatalogTitle, query: String, candidates: [CatalogTitle], evidence: [DiscoveryEvidence], incomplete: Bool = false) -> MatchConfidence {
        let exact = EpisodeClues.normalized(title.displayTitle) == EpisodeClues.normalized(query) && !EpisodeClues.normalized(query).isEmpty
        let agreeing = evidence.filter { record in
            EpisodeClues.normalized(record.title) == EpisodeClues.normalized(title.displayTitle) && (record.year == nil || record.year == title.year)
        }
        let sources = Set(agreeing.map(\.source))
        var score = exact ? 60 : 20
        var reasons = [exact ? "Exact movie title match (+60)." : "Search title does not exactly match this movie (+20)."]
        if !sources.isEmpty { reasons.append("Corroborating sources: \(sourceNames(agreeing)) (correlated provider records are not independent confirmations).") }
        if candidates.filter({ EpisodeClues.normalized($0.displayTitle) == EpisodeClues.normalized(title.displayTitle) }).count > 1 {
            score = min(score, 40); reasons.append("Multiple movies share this title; verify the year (capped at 40).")
        }
        if agreeing.count != evidence.count { score = min(score, 25); reasons.append("Source title or release year conflicts with TMDB (capped at 25).") }
        if incomplete { reasons.append("Some optional checks are incomplete.") }
        var identity = MediaIdentity()
        identity.kind = "movie"; identity.title = title.displayTitle; identity.year = title.year; identity.tmdbId = UInt64(title.id)
        return .init(score: min(95, score), candidate: title.displayTitle, reasons: reasons, identity: identity)
    }

    private static func sourceNames(_ records: [DiscoveryEvidence]) -> String {
        Set(records.map { $0.source.rawValue }).sorted().joined(separator: ", ")
    }
}
