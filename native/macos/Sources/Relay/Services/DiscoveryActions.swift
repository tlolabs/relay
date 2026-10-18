import AppKit
import Foundation
import RelayKit

extension RelayModel {
    var imdbIndexURL: URL? { cacheFolder?.appendingPathComponent("imdb.sqlite") }
    func sourceEnabled(_ source: MetadataSource) -> Bool {
        UserDefaults.standard.object(forKey: "metadata-\(source.rawValue)") as? Bool ?? true
    }
    func searchCatalog(automatic: Bool = false, filenamesOnly: Bool = false) async {
        guard !catalogBusy, !Task.isCancelled else { return }
        let request = UUID(); catalogRequest = request; catalogBusy = true
        catalogMessage = "Exploring local file and batch clues…"
        await prepareLocalEvidence()
        guard !Task.isCancelled, catalogRequest == request else {
            if catalogRequest == request { catalogBusy = false; folderSearchInProgress = false }
            return
        }
        let kind = filenamesOnly ? "tv" : catalogKind
        let query = filenamesOnly ? "" : searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let selectedShowID = filenamesOnly ? nil : draft.tmdbId
        let searchJobs = kind == "movie" ? jobs.filter { $0.editable && selectedIds.contains($0.id) } : episodeSearchJobs
        searchJobClues = Dictionary(uniqueKeysWithValues: searchJobs.map { ($0.id, EpisodeClues.normalized(searchClue(for: $0))) })
        searchFileNames = Dictionary(uniqueKeysWithValues: searchJobs.map { ($0.id, $0.filename) })
        activeSearches = [:]; searchedJobIDs = []
        // A manual movie query can differ from the filename/title.
        if kind == "movie" { for job in searchJobs { searchJobClues[job.id] = EpisodeClues.normalized(query) } }
        let activity: DiscoveryActivityHandler = { [weak self] value in
            await self?.updateSearchActivity(value, request: request)
        }
        var finishedSearch = false
        var catalogs = savedCatalogs()
        let downloadedCount = episodeSearchClues.count
        var clues = kind == "movie" ? EpisodeClues.unique([query]) : filenamesOnly ? episodeSearchClues : EpisodeClues.unique([query] + episodeSearchClues)
        catalogMessage = "Searching metadata for \(downloadedCount) downloaded episode titles…"
        defer {
            if catalogRequest == request {
                activeSearches = [:]; catalogBusy = false
                if kind == "tv" {
                    folderCatalogs = catalogs
                    rebuildFolderSuggestions()
                    rebuildMatchConfidence(incomplete: !finishedSearch || searchHasIncompleteChecks)
                }
                if filenamesOnly { folderSearchInProgress = false; folderSearchSummary = catalogMessage }
            }
        }
        providerStatuses = []; discoveryIssues = []; catalogEvidence = [:]; catalogTitles = []
        showMatches = kind == "tv" ? EpisodeClues.rank(catalogs, clues: clues).filter { !$0.matchedTitles.isEmpty } : []
        let useLocalPlan = filenamesOnly || query.isEmpty || searchJobs.contains { job in
            localContext(for: job).map { EpisodeClues.agreement($0.filename.title, query) != .none || EpisodeClues.normalized($0.show ?? "") == EpisodeClues.normalized(query) } ?? false
        }
        if kind == "tv", useLocalPlan, !searchJobs.isEmpty,
           searchJobs.allSatisfy({ job in localContext(for: job).map { LocalMatching.matches($0, catalogs: catalogs).count == 1 } ?? false }) {
            finishedSearch = true
            catalogMessage = "Resolved from saved canonical catalogs and local clues. Review before applying."
            return
        }
        do {
            let tmdb = try metadataToken()
            try Task.checkCancellation(); guard catalogRequest == request else { return }
            var candidates: [CatalogTitle] = []
            var local = DiscoveryReport()
            if sourceEnabled(.imdb), let url = imdbIndexURL {
                catalogMessage = "Searching the local IMDb index…"
                do { local = try await imdbIndex.search(titles: clues, kind: kind, index: url, activity: activity) }
                catch is CancellationError { throw CancellationError() }
                catch { local = DiscoveryReport(statuses: [ProviderStatus(source: .imdb, message: "Local index unavailable; rebuild it in Settings", incomplete: true)]) }
            } else { local = DiscoveryReport(statuses: [ProviderStatus(source: .imdb, message: "Disabled in Settings", incomplete: false)]) }
            await activity(.init(source: "IMDb", clues: [], finished: true))
            try Task.checkCancellation(); guard catalogRequest == request else { return }
            if kind == "tv", useLocalPlan {
                let targeted = try await resolveTargetedCatalogs(catalogs, localRecords: local.evidence, token: tmdb)
                catalogs = targeted.catalogs
                for record in local.evidence {
                    let id = record.ids.tmdb ?? catalogs.first(where: {
                        record.ids.imdb != nil && $0.imdbID == record.ids.imdb || record.ids.tvdb != nil && $0.tvdbID == record.ids.tvdb
                    })?.title.id
                    if let id { catalogEvidence[id, default: []].append(record) }
                }
                folderEvidence.merge(catalogEvidence) { _, new in new }
                try Task.checkCancellation(); guard catalogRequest == request else { return }
                let unresolved = searchJobs.filter { !targeted.handled.contains($0.id) }
                if unresolved.isEmpty {
                    finishedSearch = true; providerStatuses = local.statuses
                    showMatches = MetadataConsensus.rank(catalogs, clues: clues, evidence: catalogEvidence).filter { !$0.matchedTitles.isEmpty }
                    catalogMessage = "Compared local clues with targeted TMDB catalogs. Unverified contextual candidates remain provisional."
                    return
                }
                clues = EpisodeClues.unique(unresolved.map { searchClue(for: $0) })
            }
            if !tmdb.isEmpty, !filenamesOnly, !query.isEmpty {
                await activity(.init(source: "TMDB", clues: kind == "movie" ? [query] : clues, detail: "Searching \(query)"))
                do { candidates = try await catalog.search(query, kind: kind, token: tmdb, language: UserDefaults.standard.string(forKey: "metadataLanguage") ?? "en-US") }
                catch is CancellationError { throw CancellationError() }
                catch { guard catalogRequest == request else { return }; discoveryIssues.append("TMDB title search is unavailable; trying the other sources.") }
            }
            guard catalogRequest == request else { return }
            await activity(.init(source: "TMDB", clues: [], finished: true))
            catalogTitles = candidates
            var seeds = plexTitles.map { DiscoverySeed(title: $0.title, year: $0.year, ids: DiscoveryIDs(tmdb: $0.tmdbId)) }
            seeds += (snapshot?.recentIdentities ?? []).filter { $0.kind == "tv" }.map { DiscoverySeed(title: $0.title, year: $0.year, ids: DiscoveryIDs(tmdb: $0.tmdbId.map(Int.init))) }
            seeds += candidates.map { DiscoverySeed(title: $0.displayTitle, year: $0.year, ids: DiscoveryIDs(tmdb: $0.id)) }
            seeds += local.evidence.map { DiscoverySeed(title: $0.title, year: $0.year, ids: $0.ids) }
            if !query.isEmpty { seeds.append(DiscoverySeed(title: query)) }
            catalogMessage = "Searching episode titles across the enabled sources…"
            let localReport = local
            let credentials = DiscoveryCredentials(trakt: sourceEnabled(.trakt) ? try CredentialStore.read("trakt") ?? "" : "", omdb: sourceEnabled(.omdb) ? try CredentialStore.read("omdb") ?? "" : "", tvdb: sourceEnabled(.tvdb) ? try CredentialStore.read("tvdb") ?? "" : "")
            let report = try await metadataDiscovery.discover(titles: clues, kind: kind, seeds: seeds, credentials: credentials, cache: cacheFolder, enabled: Set(MetadataSource.allCases.filter(sourceEnabled)), progress: { [weak self] progress in
                Task { @MainActor in
                    guard let self, self.catalogRequest == request, self.catalogBusy, self.providerStatuses.isEmpty else { return }
                    self.providerStatuses = localReport.statuses + progress.statuses
                    self.catalogMessage = "Checking candidate shows with TVmaze and TheTVDB…"
                }
            }, activity: activity)
            try Task.checkCancellation(); guard catalogRequest == request else { return }
            providerStatuses = local.statuses + report.statuses
            let evidence = Array(Set(local.evidence + report.evidence))
            guard !tmdb.isEmpty else {
                discoveryIssues += evidence.map { "\($0.source.rawValue): \($0.title)\($0.episode.map { " — \($0.title)" } ?? "")" }
                catalogMessage = "Found \(evidence.count) source records. Add a TMDB token in Settings to verify matches and apply TMDB metadata."
                return
            }
            catalogMessage = "Comparing source identities with TMDB…"
            let resolved = try await discoveryResolver.resolve(evidence, token: tmdb, activity: activity)
            try Task.checkCancellation(); guard catalogRequest == request else { return }
            catalogEvidence = resolved.evidence; discoveryIssues += resolved.unresolved
            if kind == "movie" {
                var seen = Set<Int>()
                catalogTitles = (resolved.titles + candidates).filter { seen.insert($0.id).inserted }.sorted {
                    Set(catalogEvidence[$0.id, default: []].map(\.source)).count > Set(catalogEvidence[$1.id, default: []].map(\.source)).count
                }
                for job in searchJobs {
                    if let best = catalogTitles.first {
                        matchConfidence[job.id] = MatchConfidence.movie(title: best, query: query, candidates: catalogTitles, evidence: catalogEvidence[best.id, default: []], incomplete: searchHasIncompleteChecks)
                    } else { matchConfidence[job.id] = MatchConfidence(score: 0, candidate: nil, reasons: ["No verified movie match found."]) }
                }
                finishedSearch = true
                catalogMessage = "Compared \(evidence.count) source records; selections use TMDB's movie metadata."
                return
            }
            var ids = resolved.titles.map(\.id) + candidates.prefix(5).map(\.id)
            if let id = selectedShowID { ids.append(Int(id)) }
            // Existing web search remains a user-configured fallback.
            let web = try CredentialStore.read("brave-search") ?? ""
            if !web.isEmpty, evidence.isEmpty {
                do { ids += try await episodeWebSearch.showIDs(titles: clues, token: web, activity: activity) }
                catch is CancellationError { throw CancellationError() }
                catch { guard catalogRequest == request else { return }; discoveryIssues.append("Optional web search is unavailable.") }
            }
            var seen = Set<Int>(); let ordered = ids.filter { seen.insert($0).inserted }
            var failures = 0
            catalogMessage = "Checking \(ordered.count) candidate TMDB shows…"
            for (index, id) in ordered.enumerated() {
                try Task.checkCancellation(); guard catalogRequest == request else { return }
                if !(catalogs.first(where: { $0.title.id == id })?.fetchedAt.map({ Date().timeIntervalSince($0) < 21600 }) ?? false) {
                    catalogMessage = "Checking TMDB show \(index + 1) of \(ordered.count)…"
                    await activity(.init(source: "TMDB", clues: clues, detail: "Checking candidate show \(index + 1) of \(ordered.count)"))
                    do {
                        let value = try await catalog.seriesCatalog(id: id, token: tmdb)
                        cache(value, name: "tv-catalog-\(id).json")
                        catalogs.removeAll { $0.title.id == id }; catalogs.append(value)
                    } catch is CancellationError { throw CancellationError() }
                    catch { failures += 1 }
                }
                guard catalogRequest == request else { return }
                showMatches = MetadataConsensus.rank(catalogs, clues: clues, evidence: catalogEvidence).filter { match in
                    !match.matchedTitles.isEmpty || !match.evidence.isEmpty || candidates.contains { $0.id == match.id }
                }
                catalogTitles = candidates.filter { title in !showMatches.contains { $0.id == title.id } }
            }
            folderCatalogs = catalogs
            if filenamesOnly { folderEvidence = resolved.evidence }
            else { folderEvidence.merge(resolved.evidence) { _, new in new } }
            finishedSearch = true
            rebuildFolderSuggestions()
            catalogMessage = "Compared \(downloadedCount) downloaded titles and \(evidence.count) source records. Applied names and numbering come from TMDB."
            if failures > 0 { discoveryIssues.append("\(failures) TMDB catalogs could not refresh; saved catalogs remain available.") }
            if showMatches.isEmpty && catalogTitles.isEmpty { catalogMessage += " No verified matches found. Configure free source keys in Settings or try a show title." }
        } catch is CancellationError { }
        catch {
            if catalogRequest == request { catalogMessage = error.localizedDescription; if !automatic { self.error = error.localizedDescription } }
        }
    }
    func importIMDbDatasets() {
        let panel = NSOpenPanel(); panel.title = "Select IMDb title.basics.tsv(.gz) and title.episode.tsv(.gz)"; panel.allowsMultipleSelection = true; panel.canChooseDirectories = false
        guard panel.runModal() == .OK else { return }
        guard let basics = panel.urls.first(where: { ["title.basics.tsv", "title.basics.tsv.gz"].contains($0.lastPathComponent) }), let episodes = panel.urls.first(where: { ["title.episode.tsv", "title.episode.tsv.gz"].contains($0.lastPathComponent) }), let destination = imdbIndexURL else {
            error = "Select both official IMDb datasets: title.basics.tsv(.gz) and title.episode.tsv(.gz)."; return
        }
        guard !imdbImporting else { return }
        imdbImporting = true; imdbImportMessage = "Importing IMDb datasets…"
        imdbImportTask = Task {
            defer { imdbImporting = false; imdbImportTask = nil }
            do {
                let rows = try await imdbIndex.importFiles(basics: basics, episodes: episodes, destination: destination) { [weak self] count in
                    Task { @MainActor in if self?.imdbImporting == true { self?.imdbImportMessage = "Imported \(count.formatted()) IMDb records…" } }
                }
                imdbImportMessage = "IMDb local index ready: \(rows.formatted()) records."
            } catch is CancellationError { imdbImportMessage = "Import cancelled; the previous index was preserved." }
            catch { imdbImportMessage = error.localizedDescription }
        }
    }
}
