import Foundation

/// Presentation-only proposals. Folder discovery never approves or edits a job.
public enum FolderReview {
    public static func suggestion(for clue: String, catalogs: [TVSeriesCatalog], evidence: [Int: [DiscoveryEvidence]]) -> MediaIdentity? {
        let query = EpisodeClues.normalized(clue)
        guard !query.isEmpty else { return nil }
        // A common title such as “Pilot” must not pick the first show or season.
        let matches = catalogs.flatMap { catalog in
            catalog.episodes.filter { EpisodeClues.normalized($0.name) == query }.map { (catalog.title, $0) }
        }
        guard matches.count == 1, let (title, episode) = matches.first else { return nil }
        let records = evidence[title.id, default: []].filter {
            EpisodeClues.normalized($0.matchedClue ?? $0.episode?.title ?? "") == query
        }
        guard MetadataConsensus.episode(for: clue, episodes: catalogs.first { $0.title.id == title.id }?.episodes ?? [], evidence: records)?.id == episode.id,
              !records.contains(where: { record in
                  guard let external = record.episode else { return false }
                  return external.season.map { $0 != episode.seasonNumber } == true || external.number.map { $0 != episode.episodeNumber } == true
              }) else { return nil }
        var identity = MediaIdentity()
        identity.kind = "tv"; identity.title = title.displayTitle; identity.year = title.year
        identity.tmdbId = UInt64(title.id); identity.season = episode.seasonNumber
        identity.episode = episode.episodeNumber; identity.episodeTitle = episode.name
        return identity
    }

    public static func precedes(identity left: MediaIdentity, filename leftFilename: String, id leftID: String,
                                identity right: MediaIdentity, filename rightFilename: String, id rightID: String) -> Bool {
        if left.title.isEmpty != right.title.isEmpty { return !left.title.isEmpty }
        let titleOrder = left.group.localizedStandardCompare(right.group)
        if titleOrder != .orderedSame { return titleOrder == .orderedAscending }
        if left.season != right.season { return (left.season ?? Int.max) < (right.season ?? Int.max) }
        if left.episode != right.episode { return (left.episode ?? Int.max) < (right.episode ?? Int.max) }
        let filenameOrder = leftFilename.localizedStandardCompare(rightFilename)
        if filenameOrder != .orderedSame { return filenameOrder == .orderedAscending }
        return leftID < rightID
    }
}
