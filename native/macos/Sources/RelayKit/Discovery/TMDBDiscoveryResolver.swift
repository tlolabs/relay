import Foundation

public struct ResolvedDiscovery: Sendable {
    public var titles: [CatalogTitle] = []
    public var evidence: [Int: [DiscoveryEvidence]] = [:]
    public var unresolved: [String] = []
    public init() {}
}

public actor TMDBDiscoveryResolver {
    private let catalog: CatalogClient
    private struct Key: Hashable { var kind: String; var ids: DiscoveryIDs; var name: String; var year: Int? }
    private var resolved: [Key: (Date, [CatalogTitle])] = [:]
    public init(catalog: CatalogClient) { self.catalog = catalog }
    public func resolve(_ evidence: [DiscoveryEvidence], token: String, activity: @escaping DiscoveryActivityHandler = { _ in }) async throws -> ResolvedDiscovery {
        var result = ResolvedDiscovery(), seen = Set<Int>()
        for record in Set(evidence) {
            try Task.checkCancellation()
            await activity(.init(source: "TMDB", clues: [record.matchedClue ?? record.episode?.title ?? record.title], detail: "Verifying \(record.title)"))
            let key = Key(kind: record.kind, ids: record.ids, name: EpisodeClues.normalized(record.title), year: record.year)
            let candidates: [CatalogTitle]
            do {
                if let saved = resolved[key], Date().timeIntervalSince(saved.0) < 21600 { candidates = saved.1 }
                else {
                    candidates = try await lookup(record, token: token)
                    resolved[key] = (Date(), candidates)
                }
                if candidates.count != 1 {
                    result.unresolved.append("\(record.source.rawValue): “\(record.title)” \(candidates.isEmpty ? "has no verified TMDB match" : "maps to multiple TMDB titles").")
                    continue
                }
                let title = candidates[0]
                if seen.insert(title.id).inserted { result.titles.append(title) }
                result.evidence[title.id, default: []].append(record)
            } catch is CancellationError { throw CancellationError() }
            catch {
                try Task.checkCancellation()
                result.unresolved.append("\(record.source.rawValue): “\(record.title)” could not be verified in TMDB. \((error as? RelayFailure)?.localizedDescription ?? "Try again later.")")
            }
        }
        await activity(.init(source: "TMDB", clues: [], finished: true))
        result.unresolved = Array(Set(result.unresolved)).sorted()
        return result
    }
    private func lookup(_ record: DiscoveryEvidence, token: String) async throws -> [CatalogTitle] {
        var linked: [CatalogTitle]?
        if let id = record.ids.tmdb { linked = [try await catalog.title(id: id, kind: record.kind, token: token)] }
        var lookups: [(String, String)] = []
        if let imdb = record.ids.imdb { lookups.append((imdb, "imdb_id")) }
        if let tvdb = record.ids.tvdb, record.kind == "tv" { lookups.append((String(tvdb), "tvdb_id")) }
        for (id, source) in lookups {
            let found = try await catalog.find(externalID: id, source: source, kind: record.kind, token: token)
            if !found.isEmpty {
                if let existing = linked {
                    let intersection = existing.filter { value in found.contains { $0.id == value.id } }
                    guard !intersection.isEmpty else { throw RelayFailure.message("Provider identifiers disagree about the TMDB title") }
                    linked = intersection
                } else { linked = found }
            }
        }
        if let linked { return linked }
        // Exact name/year is a fallback only. Never take the first fuzzy result.
        return try await catalog.search(record.title, kind: record.kind, token: token).filter {
            EpisodeClues.normalized($0.displayTitle) == EpisodeClues.normalized(record.title) && (record.year == nil || $0.year == record.year)
        }
    }
}
