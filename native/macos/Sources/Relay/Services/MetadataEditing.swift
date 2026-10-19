import AppKit
import Foundation
import RelayKit

struct CatalogChoice: Identifiable { var title: CatalogTitle; var kind: String; var metadata: FullCatalogMetadata?; var id: Int { title.id } }
extension RelayModel {
    func chooseCatalogTitle(_ title: CatalogTitle) {
        if smokeMode { applyCatalogTitle(title); return }
        pendingCatalogChoice = CatalogChoice(title:title,kind:catalogKind)
        let editing = editingId, kind = catalogKind
        loadingCatalogDetails = true
        Task {
            defer { loadingCatalogDetails = false }
            do {
                if selectedJob.map({ localContext(for: $0) == nil }) ?? false { await prepareLocalEvidence() }
                try Task.checkCancellation()
                let details = try await catalog.fullMetadata(id:title.id,kind:kind,language:preferences.string(forKey:"metadataLanguage") ?? "en-US",token:metadataToken())
                if editingId == editing, pendingCatalogChoice?.id == title.id { pendingCatalogChoice?.metadata = details }
            } catch { self.error = error.localizedDescription }
        }
    }
    func applyPendingCatalog() {
        guard let choice = pendingCatalogChoice else { return }
        pendingCatalogChoice = nil; catalogKind = choice.kind
        applyCatalogTitle(choice.title)
        if let metadata = choice.metadata { mergeMetadata(metadata); artworkCandidates = metadata.artwork }
        startMetadataLoad()
    }
    func mergeMetadata(_ values: FullCatalogMetadata) {
        automaticMetadataFields.formUnion(values.fields.keys)
        for (key,value) in values.fields where !draftDirect.overrides.contains(key) { draftDirect.metadata[key] = value }
        scheduleAutosave()
    }
    func loadEpisodeMetadata() async {
        guard draft.tmdbId != nil else { return }
        let identity = draft, editing = editingId, request = metadataRequest
        metadataActivity = "Loading metadata for \(identity.display)…"
        defer { if metadataRequest == request { metadataActivity = nil } }
        do {
            let values = try await catalogMetadata(for: identity)
            let artwork = try await downloadedCatalogArtwork(values, options: draftDirect)
            try Task.checkCancellation()
            guard editingId == editing, draft.kind == identity.kind, draft.tmdbId == identity.tmdbId,
                  draft.season == identity.season, draft.episode == identity.episode,
                  metadataRequest == request, selectedJob?.editable == true else { return }
            automaticMetadataFields.formUnion(values.fields.keys)
            draftDirect = values.applying(to: draftDirect)
            if !draftDirect.overrides.contains("artwork") {
                automaticArtwork = true
                if draftDirect.artworkUrl != (values.artwork.first ?? "") || draftDirect.artworkPath != (artwork ?? "") { draftDirect.artworkFingerprint = nil }
                draftDirect.artworkUrl = values.artwork.first ?? ""
                draftDirect.artworkPath = artwork ?? ""
            }
            artworkCandidates = values.artwork
            scheduleAutosave()
        } catch is CancellationError { }
        catch { if editingId == editing, metadataRequest == request { self.error = "Metadata is incomplete: \(error.localizedDescription)" } }
    }

    func startMetadataLoad() {
        metadataTask?.cancel(); metadataRequest = UUID(); metadataActivity = nil
        guard !smokeMode, !busy, selectedJob?.editable == true, draft.tmdbId != nil,
              draft.kind == "movie" || (draft.kind == "tv" && draft.season != nil && draft.episode != nil) else { return }
        let request = metadataRequest
        metadataTask = Task {
            if selectedJob.map({ localContext(for: $0) == nil }) ?? false { await prepareLocalEvidence() }
            guard !Task.isCancelled, metadataRequest == request else { return }
            await loadEpisodeMetadata()
        }
    }

    func catalogMetadata(for identity: MediaIdentity) async throws -> FullCatalogMetadata {
        guard let id = identity.tmdbId else { throw RelayFailure.message("Choose a TMDB identity before loading metadata.") }
        if identity.kind == "tv", identity.season == nil || identity.episode == nil {
            throw RelayFailure.message("Choose a season and episode for \(identity.title) before loading metadata.")
        }
        return try await catalog.fullMetadata(id: Int(id), kind: identity.kind, season: identity.season, episode: identity.episode,
                                              language: preferences.string(forKey: "metadataLanguage") ?? "en-US", token: metadataToken())
    }

    func downloadedCatalogArtwork(_ values: FullCatalogMetadata, options: DirectDraft) async throws -> String? {
        guard !options.overrides.contains("artwork"), let text = values.artwork.first else { return nil }
        if options.artworkUrl == text, !options.artworkPath.isEmpty, FileManager.default.fileExists(atPath: options.artworkPath) { return options.artworkPath }
        guard let url = URL(string: text), let databaseURL else { throw RelayFailure.message("The artwork storage folder is unavailable.") }
        let data = try await posterData(for: url)
        let folder = databaseURL.deletingLastPathComponent().appendingPathComponent("artwork", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent(UUID().uuidString + ".jpg")
        try data.write(to: file, options: .atomic)
        return file.path
    }

    /// Complete each row separately, including old drafts created before full TV
    /// imports. Any failed resource stops batch review rather than approving gaps.
    func completeCatalogMetadata(ids: [String]) async throws {
        guard let engine else { throw RelayFailure.message("The job store is unavailable.") }
        for id in ids {
            guard let job = jobs.first(where: { $0.id == id }), job.editable, job.identity.tmdbId != nil else { continue }
            workMessage = "Loading metadata for \(job.identity.display)…"
            do {
                let values = try await catalogMetadata(for: job.identity)
                let artwork = try await downloadedCatalogArtwork(values, options: job.options)
                var direct = values.applying(to: job.options)
                if !direct.overrides.contains("artwork") {
                    direct.artworkUrl = values.artwork.first ?? ""; direct.artworkPath = artwork ?? ""; direct.artworkFingerprint = nil
                }
                let _: RelaySnapshot = try await engine.execute(["command": "edit", "id": id, "revision": job.revision, "direct": RelayEngine.object(direct)])
                try await refresh()
            } catch {
                throw RelayFailure.message("Metadata for \(job.identity.display) could not be completed: \(error.localizedDescription)")
            }
        }
    }
    func loadArtwork() async {
        guard let id = draft.tmdbId else { return }
        let kind = draft.kind, editing = editingId
        do {
            let value = try await catalog.fullMetadata(id:Int(id),kind:kind,language:preferences.string(forKey:"metadataLanguage") ?? "en-US",token:metadataToken())
            if editingId == editing, draft.tmdbId == id { artworkCandidates = value.artwork }
        } catch { self.error = error.localizedDescription }
    }
    func selectArtwork(_ text: String, manual: Bool = true) async {
        guard manual || !draftDirect.overrides.contains("artwork") else { return }
        guard let url = URL(string:text), let databaseURL else { return }
        let request = UUID(); artworkSelection = request
        let editing = editingId, id = draft.tmdbId
        do {
            let data = try await posterData(for: url)
            guard editingId == editing, draft.tmdbId == id, artworkSelection == request else { return }
            let folder = databaseURL.deletingLastPathComponent().appendingPathComponent("artwork",isDirectory:true)
            try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
            let file = folder.appendingPathComponent(UUID().uuidString + ".jpg")
            try data.write(to:file,options:.atomic)
            guard editingId == editing, draft.tmdbId == id else { return }
            draftDirect.artworkUrl = text; draftDirect.artworkPath = file.path
            if manual { draftDirect.overrides.insert("artwork") }
            scheduleAutosave()
        } catch { self.error = error.localizedDescription }
    }
    private func cleanFilenameValue(_ value: String) -> String {
        let safe = String(String.UnicodeScalarView(value.unicodeScalars.map { $0 == "/" || $0 == ":" || CharacterSet.controlCharacters.contains($0) ? UnicodeScalar(" ") : $0 }))
        return safe.split(whereSeparator: { $0.isWhitespace }).joined(separator:" ").trimmingCharacters(in:CharacterSet(charactersIn:".")).trimmingCharacters(in:CharacterSet.whitespaces)
    }
    func plannedOutput(_ job: RelayJob) -> String {
        if let output = job.options.target { return output }
        let options = job.id == editingId ? draftDirect : job.options
        let identity = job.id == editingId ? draft : job.identity
        let dest = options.destination.isEmpty ? snapshot?.config?.outputFolder ?? "" : options.destination
        var name = options.filename
        if name.isEmpty {
            let video = options.inspection?.ruleMedia.first
            let h = video?.height ?? 0, codec = video?.format == "HEVC" ? "HEVC" : "H.264"
            let quality = ["0":"SD","1":"HD 720p","2":"HD 1080p","3":"4K"][options.metadata["definition"] ?? ""] ?? (h > 1080 ? "4K" : h > 720 ? "HD 1080p" : h > 560 ? "HD 720p" : "SD")
            let suffix = naming.suffixes["\(quality) \(codec)"] ?? ""
            let storedComment = options.metadata["comment"] ?? ""
            let comment = options.overrides.contains("comment") ? storedComment : storedComment.isEmpty || storedComment.hasPrefix("Information courtesy of") ? suffix : storedComment
            let show = identity.includeYear && !naming.tv.contains("{year}") ? (identity.year.map { "\(identity.title) (\($0))" } ?? identity.title) : identity.title
            name = identity.kind == "movie" ? naming.movie : naming.tv
            for (key,value) in [("{show}",show),("{name}",identity.kind == "movie" ? identity.title : identity.episodeTitle),("{year}",identity.year.map(String.init) ?? ""),("{season:02}",String(format:"%02d",identity.season ?? 0)),("{episode:02}",String(format:"%02d",identity.episode ?? 0)),("{season}",String(identity.season ?? 0)),("{episode}",String(identity.episode ?? 0)),("{comment}",comment)] { name = name.replacingOccurrences(of:key,with:cleanFilenameValue(value)) }
            name = cleanFilenameValue(URL(fileURLWithPath: name).deletingPathExtension().lastPathComponent) + ".mp4"
        }
        return URL(fileURLWithPath:dest).appendingPathComponent(name).path
    }
    func addVideos() async {
        let panel = NSOpenPanel(); panel.allowsMultipleSelection = true; panel.allowedContentTypes = VideoImport.contentTypes
        guard panel.runModal() == .OK else { return }
        enqueueVideos(panel.urls)
    }
}
