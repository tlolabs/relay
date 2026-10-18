import Foundation
import RelayKit

extension RelayModel {
    func restoreLocalContext() {
        folderCatalogs = savedCatalogs()
        localExplorations = cached("local-evidence.json", as: [String: LocalExploration].self) ?? [:]
        if let saved = cached("plex-inventory.json", as: PlexInventory.self), saved.server == preferences.string(forKey: "plexURL") {
            plexInventory = saved; plexTitles = saved.shows; plexLoadedAt = saved.fetchedAt
        }
        catalogRefreshState = cached("catalog-refresh.json", as: CatalogRefreshState.self) ?? CatalogRefreshState()
        if catalogRefreshState.server != preferences.string(forKey: "plexURL") { catalogRefreshState = CatalogRefreshState() }
    }
    func prepareLocalEvidence() async {
        let inputs = jobs.filter(\.editable).map { URL(fileURLWithPath: $0.originalPath) }
        var values: [LocalExploration] = []
        for url in inputs {
            if Task.isCancelled { return }
            // Re-read bounded companions to notice newly arrived subtitles. Embedded
            // media tags are reused only while the source fingerprint is unchanged.
            let job = jobs.first { $0.originalPath == url.path }
            let fingerprint = job.map { "\($0.fingerprint.size):\($0.fingerprint.modifiedNs)" } ?? ""
            let tags: [String: String]
            if localFingerprints[url.path] == fingerprint { tags = localEmbeddedTags[url.path] ?? [:] }
            else { tags = await LocalExplorer.embeddedTags(url); localEmbeddedTags[url.path] = tags; localFingerprints[url.path] = fingerprint }
            let value = await Task.detached { LocalExplorer.explore(url, tags: tags) }.value
            values.append(value)
        }
        guard !Task.isCancelled, !closing else { return }
        let related = LocalExplorer.relate(values)
        localExplorations = Dictionary(uniqueKeysWithValues: related.map { ($0.file, $0) })
        cache(localExplorations, name: "local-evidence.json")
        folderCatalogs = savedCatalogs()
        rebuildFolderSuggestions(); rebuildMatchConfidence()
    }
    func localContext(for job: RelayJob) -> LocalExploration? { localExplorations[job.originalPath] }

    /// Called after local IMDb search, before broad discovery. The plan groups
    /// files by show ID and season so a season request is shared by the batch.
    func resolveTargetedCatalogs(_ existing: [TVSeriesCatalog], localRecords: [DiscoveryEvidence], token: String) async throws -> (catalogs: [TVSeriesCatalog], handled: Set<String>) {
        var catalogs = existing
        var plans: [Int: Set<Int>] = [:], fullShows = Set<Int>(), handled = Set<String>()
        var searchedShows: [String: [CatalogTitle]] = [:]
        for job in episodeSearchJobs {
            guard let local = localContext(for: job), !local.conflicts else { continue }
            if LocalMatching.matches(local, catalogs: catalogs).count == 1 { handled.insert(job.id); continue }
            let indexed = localRecords.filter { record in
                EpisodeClues.agreement(record.matchedClue ?? record.episode?.title ?? "", local.filename.title) != .none &&
                (local.filename.season == nil || record.episode?.season == local.filename.season) &&
                (local.filename.episode == nil || record.episode?.number == local.filename.episode)
            }
            let indexedShows = Set(indexed.map { "\($0.ids.imdb ?? ""):\($0.ids.tmdb.map(String.init) ?? ""):\($0.title)" })
            var namedShow = local.show
            if namedShow == "Taskmaster", local.regions == ["australia"] { namedShow = "Taskmaster Australia" }
            if namedShow == "Taskmaster", local.regions == ["newzealand"] { namedShow = "Taskmaster New Zealand" }
            guard let show = namedShow ?? (indexedShows.count == 1 ? indexed.first?.title : nil) else { continue }
            handled.insert(job.id)
            let normalized = EpisodeClues.normalized(show)
            var ids = Set(catalogs.filter { EpisodeClues.normalized($0.title.displayTitle) == normalized }.map { $0.title.id })
            let libraryShows = plexTitles.filter { EpisodeClues.normalized($0.title) == normalized }
            ids.formUnion(libraryShows.compactMap(\.tmdbId))
            ids.formUnion(indexed.filter { EpisodeClues.normalized($0.title) == normalized }.compactMap { $0.ids.tmdb })
            ids.formUnion(catalogs.filter { saved in libraryShows.contains { show in
                show.imdbId != nil && show.imdbId == saved.imdbID || show.tvdbId != nil && show.tvdbId == saved.tvdbID
            } }.map { $0.title.id })
            ids.formUnion((snapshot?.recentIdentities ?? []).filter { EpisodeClues.normalized($0.title) == normalized }.compactMap { $0.tmdbId.map(Int.init) })
            if ids.isEmpty, !token.isEmpty {
                // Stable IMDb/TVDB IDs are preferable to a title search.
                let records = localRecords.filter { EpisodeClues.normalized($0.title) == normalized }
                for record in records {
                    let mapping = catalogs.first { $0.imdbID != nil && $0.imdbID == record.ids.imdb || $0.tvdbID != nil && $0.tvdbID == record.ids.tvdb }
                    if let mapping { ids.insert(mapping.title.id) }
                }
                if ids.isEmpty {
                    let titles: [CatalogTitle]
                    if let saved = searchedShows[normalized] { titles = saved }
                    else {
                        if let imdb = records.first?.ids.imdb ?? libraryShows.first?.imdbId { titles = try await catalog.find(externalID: imdb, source: "imdb_id", kind: "tv", token: token) }
                        else if let tvdb = records.first?.ids.tvdb ?? libraryShows.first?.tvdbId { titles = try await catalog.find(externalID: String(tvdb), source: "tvdb_id", kind: "tv", token: token) }
                        else { titles = try await catalog.search(show, kind: "tv", token: token) }
                        searchedShows[normalized] = titles
                    }
                    ids.formUnion(titles.filter { EpisodeClues.normalized($0.displayTitle) == normalized }.map(\.id))
                }
            }
            // A generic Taskmaster introduction cannot select a regional ID.
            guard ids.count == 1, let id = ids.first else { continue }
            if let season = local.filename.season { plans[id, default: []].insert(season) }
            else if local.show == nil, indexedShows.count == 1, let season = indexed.first?.episode?.season { plans[id, default: []].insert(season) }
            else { fullShows.insert(id) }
        }
        guard !token.isEmpty else { return (catalogs, handled) }
        for id in Set(plans.keys).union(fullShows).sorted() {
            try Task.checkCancellation()
            let old = catalogs.first { $0.title.id == id }
            let seasons: Set<Int>? = fullShows.contains(id) ? nil : plans[id]
            do {
                let value = try await catalog.seriesCatalog(id: id, token: token, seasons: seasons, existing: old)
                cache(value, name: "tv-catalog-\(id).json")
                catalogs.removeAll { $0.title.id == id }; catalogs.append(value)
            } catch is CancellationError { throw CancellationError() }
            catch { discoveryIssues.append("Targeted catalog lookup failed; saved evidence remains available.") }
        }
        return (catalogs, handled)
    }

    func beginCatalogRefresh() {
        guard catalogRefreshTask == nil, !catalogRefreshBusy, !closing else { return }
        catalogRefreshTask = Task { [weak self] in
            guard let self else { return }
            defer { catalogRefreshTask = nil }
            await refreshLocalCatalogs()
        }
    }
    func scheduleCatalogRefreshIfDue() {
        guard !smokeMode, !closing, preferences.bool(forKey: "backgroundCatalogRefresh"), catalogRefreshState.due(), catalogRefreshTask == nil else { return }
        beginCatalogRefresh()
    }
    func refreshLocalCatalogs() async {
        guard !catalogRefreshBusy else { return }
        catalogRefreshBusy = true; defer { catalogRefreshBusy = false }
        catalogRefreshState.server = preferences.string(forKey: "plexURL")
        catalogRefreshState.attemptedAt = Date(); cache(catalogRefreshState, name: "catalog-refresh.json")
        do {
            guard let base = URL(string: preferences.string(forKey: "plexURL") ?? "") else { throw RelayFailure.message("Configure Plex before refreshing the library catalog.") }
            let saved = try await catalog.plexInventory(base: base, token: plexToken())
            try Task.checkCancellation()
            guard preferences.string(forKey: "plexURL") == base.absoluteString else { return }
            plexInventory = saved; plexTitles = saved.shows; plexLoadedAt = saved.fetchedAt
            cache(saved, name: "plex-inventory.json")
            let token = try metadataToken()
            var catalogs = savedCatalogs()
            var mappingRequests = 0
            // Warm at most twelve relevant shows per run; episode pages remain
            // governed by APITransport budgets, pacing and cancellation.
            let incoming = Set(localExplorations.values.compactMap(\.show).map(EpisodeClues.normalized))
            let prioritized = saved.shows.sorted { incoming.contains(EpisodeClues.normalized($0.title)) && !incoming.contains(EpisodeClues.normalized($1.title)) }
            var warmed = 0
            for show in prioritized where !token.isEmpty {
                try Task.checkCancellation()
                let linked = catalogs.first { $0.title.id == show.tmdbId || show.imdbId != nil && $0.imdbID == show.imdbId || show.tvdbId != nil && $0.tvdbID == show.tvdbId }
                let recent = show.addedAt.map { Date().timeIntervalSince($0) < 30 * 86400 } ?? false
                let implicated = incoming.contains(EpisodeClues.normalized(show.title))
                guard implicated || recent || linked?.continuing == true || linked == nil else { continue }
                if let date = linked?.fetchedAt, Date().timeIntervalSince(date) < 21600 { continue }
                guard warmed < 12 else { break }; warmed += 1
                var id = show.tmdbId ?? linked?.title.id
                if id == nil, mappingRequests < 6 {
                    mappingRequests += 1
                    let values: [CatalogTitle]
                    if let imdb = show.imdbId { values = try await catalog.find(externalID: imdb, source: "imdb_id", kind: "tv", token: token) }
                    else if let tvdb = show.tvdbId { values = try await catalog.find(externalID: String(tvdb), source: "tvdb_id", kind: "tv", token: token) }
                    else { continue }
                    if values.count == 1 { id = values[0].id }
                }
                guard let id else { continue }
                // Details-only request finds announced seasons without downloading
                // every historical season. Fetch uncached, current and future seasons.
                let details = try await catalog.seriesCatalog(id: id, token: token, seasons: [], existing: linked)
                let available = details.availableSeasons ?? []
                let latest = available.max()
                var wanted = Set(available.filter { number in
                    details.seasonFetchedAt?[number] == nil || number == latest
                })
                for local in localExplorations.values where EpisodeClues.normalized(local.show ?? "") == EpisodeClues.normalized(show.title) {
                    if let season = local.filename.season { wanted.insert(season) }
                }
                let value = try await catalog.seriesCatalog(id: id, token: token, seasons: wanted, existing: details)
                cache(value, name: "tv-catalog-\(id).json")
                catalogs.removeAll { $0.title.id == id }; catalogs.append(value)
                // Persist stable joins without copying access tokens or provider URLs.
                if let index = plexInventory?.shows.firstIndex(where: { $0.id == show.id }) { plexInventory?.shows[index].tmdbId = id }
            }
            if let inventory = plexInventory { plexTitles = inventory.shows; cache(inventory, name: "plex-inventory.json") }
            folderCatalogs = catalogs; rebuildFolderSuggestions(); rebuildMatchConfidence()
            catalogRefreshState.succeededAt = Date(); catalogRefreshState.failure = nil
            catalogRefreshMessage = "Library inventory refreshed; relevant episode catalogs cached."
        } catch is CancellationError {
            catalogRefreshState.failure = "Catalog refresh cancelled; saved snapshots preserved."
            catalogRefreshMessage = catalogRefreshState.failure!
        }
        catch {
            catalogRefreshState.failure = "Refresh incomplete; saved snapshots preserved."
            catalogRefreshMessage = catalogRefreshState.failure!
        }
        cache(catalogRefreshState, name: "catalog-refresh.json")
    }
}
