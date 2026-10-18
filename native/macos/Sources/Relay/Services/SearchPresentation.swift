import Foundation
import RelayKit

extension RelayModel {
    var searchHasIncompleteChecks: Bool { providerStatuses.contains(where: \.incomplete) || !discoveryIssues.isEmpty }

    func searchClue(for job: RelayJob) -> String {
        if job.identity.kind != "movie", let local = localContext(for: job) { return local.filename.title }
        return job.identity.kind == "movie" ? job.identity.title : job.identity.episodeTitle.isEmpty
            ? URL(fileURLWithPath: job.originalPath).deletingPathExtension().lastPathComponent : job.identity.episodeTitle
    }

    func confidence(for job: RelayJob) -> MatchConfidence? {
        guard var confidence = matchConfidence[job.id] else { return nil }
        let metadata = job.id == editingId ? draftDirect : job.options
        let count = metadata.metadata.values.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.count
        confidence.metadataCompleteness = "Descriptive metadata: \(count) populated fields · \(metadata.artworkPath.isEmpty && metadata.artworkUrl.isEmpty ? "no artwork selected" : "artwork selected"). Metadata completeness does not affect identity confidence."
        guard let candidate = confidence.identity else { return confidence }
        let current = job.id == editingId ? draft : job.identity
        let differs = !current.title.isEmpty && (
            EpisodeClues.normalized(current.title) != EpisodeClues.normalized(candidate.title) ||
            (!current.kind.isEmpty && current.kind != candidate.kind) ||
            (current.tmdbId != nil && current.tmdbId != candidate.tmdbId) ||
            (current.season != nil && current.season != candidate.season) ||
            (current.episode != nil && current.episode != candidate.episode) ||
            (current.year != nil && candidate.year != nil && current.year != candidate.year))
        if differs {
            confidence.score = 0
            confidence.reasons.insert("Your current identity differs from the automatic candidate. This search does not support the current identity.", at: 0)
        }
        return confidence
    }

    func searchSources(for job: RelayJob) -> [String] {
        guard let clue = searchJobClues[job.id] else { return [] }
        return activeSearches.values.filter { $0.clues.contains { EpisodeClues.normalized($0) == clue } }.map(\.source).sorted()
    }

    var searchingFiles: [String] {
        searchJobClues.keys.sorted().filter { id in
            guard let clue = searchJobClues[id] else { return false }
            return activeSearches.values.contains { $0.clues.contains { EpisodeClues.normalized($0) == clue } }
        }.compactMap { searchFileNames[$0] }
    }

    func updateSearchActivity(_ activity: DiscoverySearchActivity, request: UUID) {
        guard catalogRequest == request, catalogBusy else { return }
        if activity.finished {
            activeSearches.removeValue(forKey: activity.source)
            for (id, clue) in searchJobClues where activity.clues.contains(where: { EpisodeClues.normalized($0) == clue }) { searchedJobIDs.insert(id) }
        } else { activeSearches[activity.source] = activity }
    }

    func rebuildMatchConfidence(incomplete: Bool = false) {
        for job in episodeSearchJobs {
            if let local = localContext(for: job) {
                matchConfidence[job.id] = MatchConfidence.local(local, catalogs: folderCatalogs, inventory: plexInventory, providerEvidence: folderEvidence)
            } else {
                matchConfidence[job.id] = MatchConfidence.tv(clue: searchClue(for: job), catalogs: folderCatalogs, evidence: folderEvidence, incomplete: incomplete)
            }
        }
    }
}
