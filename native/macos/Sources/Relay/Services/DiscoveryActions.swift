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
        let kind = filenamesOnly ? "tv" : catalogKind
        let query = filenamesOnly ? "" : searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let selectedShowID = filenamesOnly ? nil : draft.tmdbId
        let downloadedCount = episodeSearchClues.count
        let clues = kind == "movie" ? EpisodeClues.unique([query]) : filenamesOnly ? episodeSearchClues : EpisodeClues.unique([query] + episodeSearchClues)
        catalogMessage = "Searching metadata for \(downloadedCount) downloaded episode titles…"
        defer {
            if catalogRequest == request {
                catalogBusy = false
                if filenamesOnly { folderSearchInProgress = false; folderSearchSummary = catalogMessage }
            }
        }
        providerStatuses = []; discoveryIssues = []; catalogEvidence = [:]; catalogTitles = []
        var catalogs = savedCatalogs()
        showMatches = kind == "tv" ? EpisodeClues.rank(catalogs, clues: clues).filter { !$0.matchedTitles.isEmpty } : []
        do {
            let tmdb = try CredentialStore.read("tmdb") ?? ""
            let credentials = DiscoveryCredentials(trakt: sourceEnabled(.trakt) ? try CredentialStore.read("trakt") ?? "" : "", omdb: sourceEnabled(.omdb) ? try CredentialStore.read("omdb") ?? "" : "", tvdb: sourceEnabled(.tvdb) ? try CredentialStore.read("tvdb") ?? "" : "")
            if kind == "tv", plexLoadedAt.map({ Date().timeIntervalSince($0) > 21600 }) ?? true {
                if UserDefaults.standard.string(forKey: "plexURL")?.isEmpty == false,
                   plexLastCheckedAt.map({ Date().timeIntervalSince($0) > 60 }) ?? true {
                    catalogMessage = "Reading Plex shows to help identify this folder…"
                    await loadPlex()
                }
            }
            try Task.checkCancellation(); guard catalogRequest == request else { return }
            var candidates: [CatalogTitle] = []
            if !tmdb.isEmpty, !filenamesOnly, !query.isEmpty {
                do { candidates = try await catalog.search(query, kind: kind, token: tmdb, language: UserDefaults.standard.string(forKey: "metadataLanguage") ?? "en-US") }
                catch is CancellationError { throw CancellationError() }
                catch { guard catalogRequest == request else { return }; discoveryIssues.append("TMDB title search is unavailable; trying the other sources.") }
            }
            guard catalogRequest == request else { return }
            catalogTitles = candidates
            var local = DiscoveryReport()
            if sourceEnabled(.imdb), let url = imdbIndexURL {
                catalogMessage = "Searching the local IMDb index…"
                do { local = try await imdbIndex.search(titles: clues, kind: kind, index: url) }
                catch is CancellationError { throw CancellationError() }
                catch { local = DiscoveryReport(statuses: [ProviderStatus(source: .imdb, message: "Local index unavailable; rebuild it in Settings", incomplete: true)]) }
            } else { local = DiscoveryReport(statuses: [ProviderStatus(source: .imdb, message: "Disabled in Settings", incomplete: false)]) }
            try Task.checkCancellation(); guard catalogRequest == request else { return }
            var seeds = plexTitles.map { DiscoverySeed(title: $0.title, year: $0.year, ids: DiscoveryIDs(tmdb: $0.tmdbId)) }
            seeds += (snapshot?.recentIdentities ?? []).filter { $0.kind == "tv" }.map { DiscoverySeed(title: $0.title, year: $0.year, ids: DiscoveryIDs(tmdb: $0.tmdbId.map(Int.init))) }
            seeds += candidates.map { DiscoverySeed(title: $0.displayTitle, year: $0.year, ids: DiscoveryIDs(tmdb: $0.id)) }
            seeds += local.evidence.map { DiscoverySeed(title: $0.title, year: $0.year, ids: $0.ids) }
            if !query.isEmpty { seeds.append(DiscoverySeed(title: query)) }
            catalogMessage = "Searching episode titles across the enabled sources…"
            let localReport = local
            let report = try await metadataDiscovery.discover(titles: clues, kind: kind, seeds: seeds, credentials: credentials, cache: cacheFolder, enabled: Set(MetadataSource.allCases.filter(sourceEnabled))) { [weak self] progress in
                Task { @MainActor in
                    guard let self, self.catalogRequest == request, self.catalogBusy, self.providerStatuses.isEmpty else { return }
                    self.providerStatuses = localReport.statuses + progress.statuses
                    self.catalogMessage = "Checking candidate shows with TVmaze and TheTVDB…"
                }
            }
            try Task.checkCancellation(); guard catalogRequest == request else { return }
            providerStatuses = local.statuses + report.statuses
            let evidence = Array(Set(local.evidence + report.evidence))
            guard !tmdb.isEmpty else {
                discoveryIssues += evidence.map { "\($0.source.rawValue): \($0.title)\($0.episode.map { " — \($0.title)" } ?? "")" }
                catalogMessage = "Found \(evidence.count) source records. Add a TMDB token in Settings to verify matches and apply TMDB metadata."
                return
            }
            catalogMessage = "Comparing source identities with TMDB…"
            let resolved = try await discoveryResolver.resolve(evidence, token: tmdb)
            try Task.checkCancellation(); guard catalogRequest == request else { return }
            catalogEvidence = resolved.evidence; discoveryIssues += resolved.unresolved
            if kind == "movie" {
                var seen = Set<Int>()
                catalogTitles = (resolved.titles + candidates).filter { seen.insert($0.id).inserted }.sorted {
                    Set(catalogEvidence[$0.id, default: []].map(\.source)).count > Set(catalogEvidence[$1.id, default: []].map(\.source)).count
                }
                catalogMessage = "Compared \(evidence.count) source records; selections use TMDB's movie metadata."
                return
            }
            var ids = resolved.titles.map(\.id) + candidates.prefix(5).map(\.id)
            ids += plexTitles.compactMap(\.tmdbId)
            ids += (snapshot?.recentIdentities ?? []).filter { $0.kind == "tv" }.compactMap { $0.tmdbId.map(Int.init) }
            if let id = selectedShowID { ids.append(Int(id)) }
            // Legacy Plex agents sometimes expose no provider IDs.
            for title in plexTitles where title.tmdbId == nil {
                try Task.checkCancellation(); guard catalogRequest == request else { return }
                if let saved = catalogs.first(where: { EpisodeClues.normalized($0.title.displayTitle) == EpisodeClues.normalized(title.title) && (title.year == nil || $0.title.year == title.year) }) { ids.append(saved.title.id) }
                else {
                    do { ids += try await catalog.search(title.title, kind: "tv", token: tmdb).filter { EpisodeClues.normalized($0.displayTitle) == EpisodeClues.normalized(title.title) && (title.year == nil || $0.year == title.year) }.map(\.id) }
                    catch is CancellationError { throw CancellationError() }
                    catch { guard catalogRequest == request else { return }; discoveryIssues.append("Plex show “\(title.title)” could not be checked with TMDB.") }
                }
            }
            // Existing web search remains a user-configured fallback.
            let web = try CredentialStore.read("brave-search") ?? ""
            if !web.isEmpty, evidence.isEmpty {
                do { ids += try await episodeWebSearch.showIDs(titles: clues, token: web) }
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
            folderEvidence.merge(resolved.evidence) { _, new in new }
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
