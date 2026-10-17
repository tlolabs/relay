import Foundation
import RelayKit

extension RelayModel {
    private var cacheFolder: URL? { databaseURL?.deletingLastPathComponent().appendingPathComponent("catalog-cache") }
    private func cached<T: Codable>(_ name: String, as type: T.Type) -> T? {
        guard let url = cacheFolder?.appendingPathComponent(name), let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
    private func cache<T: Codable>(_ value: T, name: String) {
        guard let folder = cacheFolder else { return }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(value) { try? data.write(to: folder.appendingPathComponent(name), options: .atomic) }
    }
    func searchCatalog() async {
        guard !catalogBusy else { return }; catalogBusy = true; error = nil
        defer { catalogBusy = false }
        do {
            let token = try CredentialStore.read("tmdb") ?? ""
            catalogTitles = try await catalog.search(searchText, kind: catalogKind, token: token)
            if catalogTitles.isEmpty { notice = "No catalog matches. You can enter the identity manually." }
        } catch { self.error = error.localizedDescription }
    }
    func chooseCatalogTitle(_ title: CatalogTitle) {
        chosenTitle = title; draft.kind = catalogKind; draft.title = title.displayTitle; draft.year = title.year
        draft.tmdbId = UInt64(title.id); draft.releaseDate = title.releaseDate
        if catalogKind == "tv" { draft.season = season; Task { await loadSeriesContext(id: UInt64(title.id)) } }
        else { draft.episode = nil; draft.season = nil; draft.episodeTitle = "" }
    }
    func loadSeriesContext(id: UInt64) async {
        let key = "tmdb-series-\(id).json"
        do {
            let value = try await catalog.seriesContext(id: id, token: CredentialStore.read("tmdb") ?? "")
            cache(value, name: key)
            if draft.tmdbId == id { seriesContext = value; seriesContextCached = false }
        } catch {
            if draft.tmdbId == id { seriesContext = cached(key, as: SeriesContext.self); seriesContextCached = true }
        }
    }
    func loadEpisodes() async {
        guard let id = draft.tmdbId, !catalogBusy else { return }
        catalogBusy = true; defer { catalogBusy = false }
        let key = "tmdb-\(id)-s\(season).json"
        do {
            episodes = try await catalog.episodes(series: Int(id), season: season, token: CredentialStore.read("tmdb") ?? "")
            cache(episodes, name: key)
        } catch {
            if let existing: [EpisodeCandidate] = cached(key, as: [EpisodeCandidate].self) { episodes = existing; notice = "Showing cached episode catalog; verify numbering." }
            else { self.error = error.localizedDescription; return }
        }
        if let engine {
            let _: [String: String]? = try? await engine.execute(["command": "remember_catalog", "identity": RelayEngine.object(draft), "season": season, "episodes": RelayEngine.object(episodes)])
        }
        if let job = selectedJob, let engine {
            suggestions = (try? await engine.execute(["command": "suggest_episodes", "id": job.id, "episodes": RelayEngine.object(episodes)])) ?? []
        }
    }
    func chooseEpisode(_ episode: EpisodeCandidate) {
        draft.kind = "tv"; draft.season = episode.seasonNumber; draft.episode = episode.episodeNumber; draft.episodeTitle = episode.name
    }
    func applyShowToSelection() async {
        guard let engine, draft.kind == "tv", !draft.title.isEmpty else { return }
        let selected = jobs.filter { $0.editable && selectedIds.contains($0.id) }
        let show = draft
        await perform {
            for job in selected {
                var identity = job.identity
                identity.kind = "tv"; identity.title = show.title; identity.year = show.year; identity.tmdbId = show.tmdbId
                identity.includeYear = show.includeYear
                identity.season = show.season ?? self.season
                if !self.episodes.isEmpty {
                    let matches: [EpisodeSuggestion] = try await engine.execute(["command": "suggest_episodes", "id": job.id, "episodes": RelayEngine.object(self.episodes)])
                    if let best = matches.first, best.score == 1, matches.dropFirst().first?.score != 1 {
                        identity.season = best.episode.seasonNumber; identity.episode = best.episode.episodeNumber; identity.episodeTitle = best.episode.name
                    }
                }
                let _: RelaySnapshot = try await engine.execute(["command": "edit", "id": job.id, "revision": job.revision, "identity": RelayEngine.object(identity)])
            }
            try await self.refresh(); self.loadDraft()
            self.notice = "Show applied to the selected review rows. Exact episode-title suggestions were filled; verify every included row before approval."
        }
    }
    func loadPlex() async {
        guard !catalogBusy else { return }; catalogBusy = true; defer { catalogBusy = false }
        do {
            guard let base = URL(string: UserDefaults.standard.string(forKey: "plexURL") ?? "") else { throw RelayFailure.message("Enter a Plex server URL in Settings") }
            plexTitles = try await catalog.plexTitles(base: base, token: CredentialStore.read("plex") ?? "")
            cache(plexTitles, name: "plex-shows.json")
            notice = "Plex library context refreshed. Library membership is a suggestion, not an identity confirmation."
        } catch {
            if let existing: [PlexTitle] = cached("plex-shows.json", as: [PlexTitle].self) { plexTitles = existing; notice = "Showing cached Plex context; the server is unavailable." }
            else { self.error = error.localizedDescription }
        }
    }
    func useRecent(_ identity: MediaIdentity) {
        draft.kind = "tv"; draft.title = identity.title; draft.year = identity.year; draft.tmdbId = identity.tmdbId
        draft.includeYear = identity.includeYear
        draft.season = draft.season ?? identity.season ?? 1; season = draft.season ?? 1
        searchText = identity.title
    }
}
