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
                let details = try await catalog.fullMetadata(id:title.id,kind:kind,language:UserDefaults.standard.string(forKey:"metadataLanguage") ?? "en-US",token:CredentialStore.read("tmdb") ?? "")
                if editingId == editing, pendingCatalogChoice?.id == title.id { pendingCatalogChoice?.metadata = details }
            } catch { self.error = error.localizedDescription }
        }
    }
    func applyPendingCatalog() {
        guard let choice = pendingCatalogChoice else { return }
        pendingCatalogChoice = nil; catalogKind = choice.kind
        applyCatalogTitle(choice.title)
        if let metadata = choice.metadata { mergeMetadata(metadata); artworkCandidates = metadata.artwork }
    }
    func mergeMetadata(_ values: FullCatalogMetadata) {
        for (key,value) in values.fields where !draftDirect.overrides.contains(key) { draftDirect.metadata[key] = value }
        if !draftDirect.overrides.contains("artwork"), let url = values.artwork.first {
            draftDirect.artworkUrl = url
            Task { await selectArtwork(url,manual:false) }
        }
        scheduleAutosave()
    }
    func loadEpisodeMetadata() async {
        guard let id = draft.tmdbId, let season = draft.season, let episode = draft.episode else { return }
        let editing = editingId
        do {
            let values = try await catalog.fullMetadata(id:Int(id),kind:"tv",season:season,episode:episode,language:UserDefaults.standard.string(forKey:"metadataLanguage") ?? "en-US",token:CredentialStore.read("tmdb") ?? "")
            guard editingId == editing, draft.tmdbId == id, draft.season == season, draft.episode == episode else { return }
            // A show poster remains the display artwork; episode metadata does not clear it.
            for (key,value) in values.fields where !draftDirect.overrides.contains(key) { draftDirect.metadata[key] = value }
            scheduleAutosave()
        } catch { self.error = error.localizedDescription }
    }
    func loadArtwork() async {
        guard let id = draft.tmdbId else { return }
        let kind = draft.kind, editing = editingId
        do {
            let value = try await catalog.fullMetadata(id:Int(id),kind:kind,language:UserDefaults.standard.string(forKey:"metadataLanguage") ?? "en-US",token:CredentialStore.read("tmdb") ?? "")
            if editingId == editing, draft.tmdbId == id { artworkCandidates = value.artwork }
        } catch { self.error = error.localizedDescription }
    }
    func selectArtwork(_ text: String, manual: Bool = true) async {
        guard let url = URL(string:text), let databaseURL else { return }
        let editing = editingId, id = draft.tmdbId
        do {
            let data = try await catalog.poster(url:url)
            guard editingId == editing, draft.tmdbId == id else { return }
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
        let panel = NSOpenPanel(); panel.allowsMultipleSelection = true; panel.allowedContentTypes = [.mpeg4Movie]
        guard panel.runModal() == .OK, let engine else { return }
        await perform("Adding selected videos to the queue…") { for url in panel.urls { self.snapshot = try await engine.execute(["command":"direct_add","path":url.path]) } }
    }
}
