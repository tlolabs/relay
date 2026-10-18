import Foundation
import RelayKit

extension RelayModel {
    var cacheFolder: URL? { databaseURL?.deletingLastPathComponent().appendingPathComponent("catalog-cache") }
    func cached<T: Codable>(_ name: String, as type: T.Type) -> T? {
        guard let url = cacheFolder?.appendingPathComponent(name), let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
    func cache<T: Codable>(_ value: T, name: String) {
        guard let folder = cacheFolder else { return }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(value) { try? data.write(to: folder.appendingPathComponent(name), options: .atomic) }
    }
    var episodeSearchJobs: [RelayJob] {
        // Use the entire intake review set, rather than just the clicked row.
        jobs.filter { $0.editable && $0.identity.kind != "movie" }
    }
    var episodeSearchClues: [String] {
        EpisodeClues.unique(episodeSearchJobs.map { searchClue(for: $0) })
    }
    func savedCatalogs() -> [TVSeriesCatalog] {
        guard let folder = cacheFolder, let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else { return [] }
        return files.filter { $0.lastPathComponent.hasPrefix("tv-catalog-") }.compactMap {
            guard let data = try? Data(contentsOf: $0) else { return nil }
            return try? JSONDecoder().decode(TVSeriesCatalog.self, from: data)
        }
    }
    func beginCatalogSearch(filenamesOnly: Bool = false) {
        cancelCatalogSearch()
        folderSearchInProgress = filenamesOnly
        catalogTask = Task { await searchCatalog(filenamesOnly: filenamesOnly) }
    }
    func cancelCatalogSearch() {
        if folderSearchInProgress { folderSearchSummary = "Folder search stopped. Use Scan to search all videos again." }
        catalogTask?.cancel(); catalogRequest = UUID(); catalogBusy = false; folderSearchInProgress = false; activeSearches = [:]
    }
    func beginFolderSearchIfNeeded() {
        guard !smokeMode, !catalogBusy, !folderSearchInProgress else { return }
        let signature = episodeSearchJobs.map { "\($0.id):\($0.identity.episodeTitle)" }.sorted()
        guard signature != folderSearchSignature else { return }
        folderSearchSignature = signature
        rebuildFolderSuggestions()
        folderSearchSummary = "Found \(jobs.filter(\.editable).count) videos. Confirm identities, then press Review… to check the batch."
        guard !signature.isEmpty else { return }
        folderSearchSummary = "Found \(jobs.filter(\.editable).count) videos. Searching the folder's episode titles…"
        beginCatalogSearch(filenamesOnly: true)
    }
    func useFolderSuggestion(_ identity: MediaIdentity) {
        draft = identity; catalogKind = "tv"; season = identity.season ?? 1
        searchText = identity.title
        episodes = folderCatalogs.first { UInt64($0.title.id) == identity.tmdbId }?.episodes ?? []
        suggestions = []
        scheduleAutosave()
        startMetadataLoad()
    }
    func rebuildFolderSuggestions() {
        folderSuggestions = Dictionary(uniqueKeysWithValues: episodeSearchJobs.compactMap { job in
            guard job.identity.title.isEmpty else { return nil }
            // Saved queue rows can be shown before their sources are explored.
            guard let local = localContext(for: job) else {
                return FolderReview.suggestion(for: job.identity.episodeTitle, catalogs: folderCatalogs, evidence: folderEvidence).map { (job.id, $0) }
            }
            guard !local.conflicts else { return nil }
            let score = MatchConfidence.local(local, catalogs: folderCatalogs, inventory: plexInventory, providerEvidence: folderEvidence)
            guard let identity = score.identity, !identity.title.isEmpty else { return nil }
            return (job.id, identity)
        })
    }
    func chooseShowMatch(_ match: TVShowMatch) {
        chooseCatalogTitle(match.catalog.title)
    }
    private func fillSelectedEpisode() {
        guard let job = selectedJob else { return }
        let evidence = draft.tmdbId.flatMap { catalogEvidence[Int($0)] } ?? []
        if let match = MetadataConsensus.episode(for: job.identity.episodeTitle, episodes: episodes, evidence: evidence) { chooseEpisode(match) }
        Task { await updateSuggestions() }
    }
    private func rememberEpisodes() {
        guard let engine else { return }
        let identity = draft, values = episodes
        Task {
            for (season, episodes) in Dictionary(grouping: values, by: \.seasonNumber) {
                var show = identity; show.season = season
                let _: [String: String]? = try? await engine.execute(["command": "remember_catalog", "identity": RelayEngine.object(show), "season": season, "episodes": RelayEngine.object(episodes)])
            }
        }
    }
    private func updateSuggestions() async {
        guard let job = selectedJob, let engine else { return }
        let id = job.id, show = draft.tmdbId, request = episodeRequest
        let values: [EpisodeSuggestion] = (try? await engine.execute(["command": "suggest_episodes", "id": id, "episodes": RelayEngine.object(episodes)])) ?? []
        if editingId == id && draft.tmdbId == show && episodeRequest == request { suggestions = values }
    }
    func applyCatalogTitle(_ title: CatalogTitle) {
        cancelCatalogSearch(); episodeRequest = UUID(); episodeActivity = nil
        if draft.tmdbId != UInt64(title.id) { draft.episode = nil }
        episodes = []; suggestions = []; seriesContext = nil
        chosenTitle = title; draft.kind = catalogKind; draft.title = title.displayTitle; draft.year = title.year
        draft.tmdbId = UInt64(title.id); draft.releaseDate = title.releaseDate
        if catalogKind == "tv" {
            draft.season = season
            Task { await loadSeriesContext(id: UInt64(title.id)) }
            if let match = showMatches.first(where: { $0.id == title.id }) {
                episodes = match.catalog.episodes; fillSelectedEpisode(); rememberEpisodes()
            } else { Task { await loadAllEpisodes(id: title.id) } }
        }
        else { draft.episode = nil; draft.season = nil; draft.episodeTitle = "" }
        scheduleAutosave()
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
    func loadAllEpisodes(id: Int) async {
        guard draft.tmdbId == UInt64(id) else { return }
        let request = UUID(); episodeRequest = request
        episodeActivity = "Loading all seasons from TMDB…"
        defer { if episodeRequest == request { episodeActivity = nil } }
        let editing = editingId
        if let value = savedCatalogs().first(where: { $0.title.id == id }), let date = value.fetchedAt, Date().timeIntervalSince(date) < 6 * 60 * 60 {
            episodes = value.episodes; fillSelectedEpisode(); rememberEpisodes(); return
        }
        do {
            let value = try await catalog.seriesCatalog(id: id, token: CredentialStore.read("tmdb") ?? "")
            cache(value, name: "tv-catalog-\(id).json")
            guard episodeRequest == request, draft.tmdbId == UInt64(id), editingId == editing else { return }
            episodes = value.episodes; fillSelectedEpisode(); rememberEpisodes()
        } catch {
            guard episodeRequest == request, draft.tmdbId == UInt64(id), editingId == editing else { return }
            if let value = savedCatalogs().first(where: { $0.title.id == id }) { episodes = value.episodes; fillSelectedEpisode() }
            else { self.error = error.localizedDescription }
        }
    }
    func loadEpisodes() async {
        guard let id = draft.tmdbId, !catalogBusy else { return }
        let request = UUID(); catalogRequest = request
        episodeRequest = request
        let editing = editingId, selectedSeason = season
        catalogBusy = true; defer { if catalogRequest == request { catalogBusy = false } }
        catalogMessage = "Loading season \(selectedSeason) from TMDB…"
        let key = "tmdb-\(id)-s\(selectedSeason).json"
        var values: [EpisodeCandidate]
        do {
            values = try await catalog.episodes(series: Int(id), season: selectedSeason, token: CredentialStore.read("tmdb") ?? "")
            cache(values, name: key)
        } catch {
            guard catalogRequest == request else { return }
            if let existing: [EpisodeCandidate] = cached(key, as: [EpisodeCandidate].self) { values = existing; notice = "Showing cached episode catalog; verify numbering." }
            else { self.error = error.localizedDescription; return }
        }
        guard catalogRequest == request, episodeRequest == request, editingId == editing, draft.tmdbId == id, season == selectedSeason else { return }
        episodes = values; fillSelectedEpisode(); rememberEpisodes()
        catalogMessage = "Loaded \(values.count) episodes for season \(selectedSeason). Confirm numbering before saving."
    }
    func chooseEpisode(_ episode: EpisodeCandidate) {
        season = episode.seasonNumber
        draft.kind = "tv"; draft.season = episode.seasonNumber; draft.episode = episode.episodeNumber; draft.episodeTitle = episode.name
        scheduleAutosave()
        startMetadataLoad()
    }
    func applyShowToSelection() async {
        autosaveTask?.cancel()
        guard let engine, draft.kind == "tv", !draft.title.isEmpty else { return }
        metadataTask?.cancel(); metadataRequest = UUID(); metadataActivity = nil; artworkSelection = UUID()
        let selected = jobs.filter { $0.editable && selectedIds.contains($0.id) }
        let show = draft
        let options = draftDirect, editor = editingId, manualFields = editedMetadataFields
        await perform("Applying the selected show to review rows…") {
            for job in selected {
                var identity = job.identity
                if identity.tmdbId != show.tmdbId || identity.title != show.title { identity.episode = nil; identity.season = show.season }
                identity.kind = "tv"; identity.title = show.title; identity.year = show.year; identity.tmdbId = show.tmdbId
                identity.includeYear = show.includeYear
                identity.season = identity.season ?? show.season ?? self.season
                if !self.episodes.isEmpty {
                    let evidence = show.tmdbId.flatMap { self.catalogEvidence[Int($0)] } ?? []
                    if let best = MetadataConsensus.episode(for: job.identity.episodeTitle, episodes: self.episodes, evidence: evidence) {
                        identity.season = best.seasonNumber; identity.episode = best.episodeNumber; identity.episodeTitle = best.name
                    }
                }
                var direct = job.id == editor ? options : job.options
                if job.id != editor {
                    for key in manualFields { direct.metadata[key] = options.metadata[key] ?? ""; direct.overrides.insert(key) }
                }
                let _: RelaySnapshot = try await engine.execute(["command": "edit", "id": job.id, "revision": job.revision, "identity": RelayEngine.object(identity), "direct": RelayEngine.object(direct)])
            }
            try await self.refresh()
            if !self.smokeMode { try await self.completeCatalogMetadata(ids: selected.map(\.id)) }
            try await self.refresh(); self.loadDraft()
            self.notice = "Show applied to the selected review rows. Exact episode-title suggestions were filled; verify every included row before approval."
        }
    }
    func useRecent(_ identity: MediaIdentity) {
        cancelCatalogSearch(); episodeRequest = UUID(); episodeActivity = nil
        if draft.tmdbId != identity.tmdbId || draft.title != identity.title { draft.episode = nil }
        draft.kind = "tv"; draft.title = identity.title; draft.year = identity.year; draft.tmdbId = identity.tmdbId
        episodes = []; suggestions = []; seriesContext = nil; catalogKind = "tv"
        draft.includeYear = identity.includeYear
        draft.season = draft.season ?? identity.season ?? 1; season = draft.season ?? 1
        searchText = identity.title
        scheduleAutosave()
        if let id = identity.tmdbId {
            Task { await loadSeriesContext(id: id); await loadAllEpisodes(id: Int(id)) }
        } else { Task { await searchCatalog() } }
    }
}
