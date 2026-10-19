import AppKit
import Foundation
import RelayKit

extension RelayModel {
    func markIdentityFieldEdited(_ key: String) { editedIdentityFields.insert(key); scheduleAutosave() }
    func editMetadataField(_ key: String, value: String) {
        editedMetadataFields.insert(key)
        draftDirect.metadata[key] = value
        draftDirect.overrides.insert(key)
        scheduleAutosave()
    }
    func metadataFieldIsMixed(_ key: String) -> Bool {
        !editedMetadataFields.contains(key) && Set(jobs.filter { selectedIds.contains($0.id) }.map { $0.options.metadata[key] ?? "" }).count > 1
    }
    func mediaTools() throws -> MediaTools {
        if let path = ProcessInfo.processInfo.environment["RELAY_MEDIA_TOOLS"] { return try MediaTools(directory: URL(fileURLWithPath: path)) }
        return try MediaTools()
    }
    private func directInspectPayload(id: String, revision: UInt64, inspection: MediaInspection) -> [String: Any] {
        var payload: [String: Any] = ["command": "direct_inspect", "id": id, "revision": revision, "inspection": RelayEngine.object(inspection)]
        if UserDefaults.standard.object(forKey: "defaultStreaming") != nil { payload["default_streaming"] = UserDefaults.standard.bool(forKey: "defaultStreaming") }
        if UserDefaults.standard.object(forKey: "defaultTrash") != nil { payload["default_trash"] = UserDefaults.standard.bool(forKey: "defaultTrash") }
        return payload
    }
    func inspectSelected() async {
        guard !smokeMode, let job = selectedJob, job.editable, job.options.inspection == nil,
              let engine, !inspectingIds.contains(job.id) else { return }
        inspectingIds.insert(job.id); defer { inspectingIds.remove(job.id) }
        do {
            if hasUnsavedChanges { autosaveTask?.cancel(); await persistDraft() }
            let inspection = try await inspectorProcessor.inspect(path: job.currentPath, tools: mediaTools())
            if selectedJob?.id == job.id, hasUnsavedChanges { autosaveTask?.cancel(); await persistDraft() }
            guard let latest = jobs.first(where: { $0.id == job.id }), latest.editable else { return }
            let _: RelayJob = try await engine.execute(directInspectPayload(id: latest.id, revision: latest.revision, inspection: inspection))
            try await refresh()
            if selectedJob?.id == job.id, let current = jobs.first(where: { $0.id == job.id }) {
                draftRevision = current.revision
                draftDirect.inspection = current.options.inspection
                if draftDirect.tracks.isEmpty { draftDirect.tracks = current.options.tracks }
                for (k, v) in current.options.metadata where !draftDirect.overrides.contains(k) && (draftDirect.metadata[k]?.isEmpty ?? true) {
                    draftDirect.metadata[k] = v
                }
                if !draftDirect.overrides.contains("streaming") { draftDirect.streaming = current.options.streaming }
                if !draftDirect.overrides.contains("trash_source") { draftDirect.trashSource = current.options.trashSource }
            }
        } catch { if selectedJob?.id == job.id { self.error = error.localizedDescription } }
    }
    func ensureInspected(ids: [String]) async throws {
        guard !smokeMode, let engine else { return }
        let uninspected = jobs.filter { ids.contains($0.id) && $0.editable && $0.options.inspection == nil }
        guard !uninspected.isEmpty else { return }
        let tools = try mediaTools()
        for item in uninspected {
            let inspection = try await inspectorProcessor.inspect(path: item.currentPath, tools: tools)
            let revision = jobs.first(where: { $0.id == item.id })?.revision ?? item.revision
            let _: RelayJob = try await engine.execute(directInspectPayload(id: item.id, revision: revision, inspection: inspection))
        }
        try await refresh()
        if let job = selectedJob, job.id == editingId {
            draftRevision = job.revision
            draftDirect.inspection = job.options.inspection
            if draftDirect.tracks.isEmpty { draftDirect.tracks = job.options.tracks }
            for (k, v) in job.options.metadata where !draftDirect.overrides.contains(k) && (draftDirect.metadata[k]?.isEmpty ?? true) {
                draftDirect.metadata[k] = v
            }
            if !draftDirect.overrides.contains("streaming") { draftDirect.streaming = job.options.streaming }
            if !draftDirect.overrides.contains("trash_source") { draftDirect.trashSource = job.options.trashSource }
        }
    }
    func scheduleAutosave() {
        guard !smokeMode, hasUnsavedChanges else { return }
        if draft.kind == "tv", !draftDirect.overrides.contains("episodeID") {
            draftDirect.metadata["episodeID"] = String(format:"S%02dE%02d",draft.season ?? 0,draft.episode ?? 0)
            automaticMetadataFields.insert("episodeID")
        }
        autosaveTask?.cancel()
        autosaveTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(400)); try Task.checkCancellation(); await self?.persistDraft() } catch {}
        }
    }
    @discardableResult func persistDraft() async -> Bool {
        // Selection changes and explicit saves must wait for the current write,
        // rather than switching editors while its snapshot is still in flight.
        while savingDraft { await withCheckedContinuation { draftSaveWaiters.append($0) } }
        guard hasUnsavedChanges else { return true }
        guard let job = selectedJob, job.editable, job.id == editingId, let engine else { return false }
        savingDraft = true
        defer {
            savingDraft = false
            let waiters = draftSaveWaiters; draftSaveWaiters = []
            for waiter in waiters { waiter.resume() }
        }
        let identity = draft, direct = draftDirect, subtitles = draftSubtitles, revision = draftRevision
        let selected = jobs.filter { $0.editable && selectedIds.contains($0.id) }
        let before = RelayEngine.object(job.identity) as? [String:Any] ?? [:]
        let after = RelayEngine.object(identity) as? [String:Any] ?? [:]
        let explicitIdentity = editedIdentityFields
        let identityKeys = Set(before.keys).union(after.keys).union(explicitIdentity).filter { explicitIdentity.contains($0) || String(describing: before[$0]) != String(describing: after[$0]) }
        let explicitFields = editedMetadataFields
        let fields = Set(job.options.metadata.keys).union(direct.metadata.keys).filter {
            explicitFields.contains($0) || (!automaticMetadataFields.contains($0) && (job.options.metadata[$0] != direct.metadata[$0] || job.options.overrides.contains($0) != direct.overrides.contains($0)))
        }
        let propagateArtwork = !automaticArtwork || direct.overrides.contains("artwork")
        do {
            for item in selected {
                var nextIdentity = item.identity, nextDirect = item.options
                if item.id == job.id { nextIdentity = identity; nextDirect = direct }
                else {
                    var object = RelayEngine.object(item.identity) as? [String:Any] ?? [:]
                    for key in identityKeys { object[key] = after[key] ?? NSNull() }
                    let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
                    nextIdentity = try decoder.decode(MediaIdentity.self, from: JSONSerialization.data(withJSONObject: object))
                    for key in fields { nextDirect.metadata[key] = direct.metadata[key] ?? ""; nextDirect.overrides.insert(key) }
                    if direct.streaming != job.options.streaming { nextDirect.streaming = direct.streaming; nextDirect.overrides.insert("streaming") }
                    if direct.trashSource != job.options.trashSource { nextDirect.trashSource = direct.trashSource; nextDirect.overrides.insert("trash_source") }
                    if direct.embedSubtitles != job.options.embedSubtitles { nextDirect.embedSubtitles = direct.embedSubtitles }
                    if direct.destination != job.options.destination { nextDirect.destination = direct.destination }
                    if propagateArtwork && (direct.artworkPath != job.options.artworkPath || direct.artworkUrl != job.options.artworkUrl) {
                        nextDirect.artworkPath = direct.artworkPath; nextDirect.artworkUrl = direct.artworkUrl
                        if direct.overrides.contains("artwork") { nextDirect.overrides.insert("artwork") }
                    }
                }
                let changes = item.id == job.id ? subtitles : item.subtitles
                let _: RelaySnapshot = try await engine.execute(["command":"edit","id":item.id,"revision": item.id == job.id ? revision : item.revision,"identity":RelayEngine.object(nextIdentity),"direct":RelayEngine.object(nextDirect),"subtitles":changes.map { ["id":$0.id,"selected":$0.selected,"language":$0.language] }])
            }
            for key in explicitFields where draftDirect.metadata[key] == direct.metadata[key] { editedMetadataFields.remove(key) }
            let currentIdentity = RelayEngine.object(draft) as? [String:Any] ?? [:]
            for key in explicitIdentity where String(describing:currentIdentity[key]) == String(describing:after[key]) { editedIdentityFields.remove(key) }
            try await refresh()
            if editingId == job.id, let saved = jobs.first(where: { $0.id == job.id }) { draftRevision = saved.revision; if draftDirect.artworkPath == direct.artworkPath { draftDirect.artworkFingerprint = saved.options.artworkFingerprint } }
            if draft != identity || draftDirect != direct || draftSubtitles != subtitles { scheduleAutosave() }
            return true
        } catch { self.error = "Draft was not saved: \(error.localizedDescription)"; return false }
    }
    func directPreview() async {
        preview = nil; presentingPreview = false
        await metadataTask?.value
        autosaveTask?.cancel(); await persistDraft()
        guard !hasUnsavedChanges, let engine else { return }
        let ids = reviewIds
        await perform("Checking the exact output names and processing choices…") {
            try await self.ensureInspected(ids: ids)
            if !self.smokeMode { try await self.completeCatalogMetadata(ids: ids); self.loadDraft() }
            self.preview = try await engine.execute(["command":"direct_preview","ids":ids])
            self.presentingPreview = true
        }
    }
    func approveDirect() async {
        guard let engine, let preview, processingTask == nil else { return }
        await perform("Approving the reviewed queue…") {
            self.snapshot = try await engine.execute(["command":"direct_approve","token":preview.token])
            self.presentingPreview = false; self.group = "Active"
        }
        guard error == nil else { return }
        processingTask = Task { [weak self] in
            guard let self else { return }
            await processor.resetCancellation()
            for job in jobs.filter({ $0.state == "direct_queued" }) {
                if Task.isCancelled { break }
                do {
                    let active: RelayJob = try await engine.execute(["command":"direct_begin","id":job.id])
                    try await refresh(); processingMessage = "\(job.identity.display): copying streams…"
                    _ = try await processor.process(job: active, tools: mediaTools(), stage: { text in await self.updateProcessingMessage(text) })
                    try Task.checkCancellation()
                    let tagged: RelayJob = try await engine.execute(["command":"direct_tag","id":job.id])
                    processingMessage = "Verifying media payloads and chapter preservation…"
                    let evidence = try await processor.verify(job: tagged, tools: mediaTools())
                    try Task.checkCancellation()
                    let published: RelayJob = try await engine.execute(["command":"direct_publish","id":job.id,"evidence":evidence])
                    try await refresh()
                    if published.options.trashSource { try Task.checkCancellation(); try await cleanupSource(published) }
                } catch {
                    let _: RelaySnapshot? = try? await engine.execute(["command":"direct_error","id":job.id,"message":error.localizedDescription])
                    self.error = error.localizedDescription
                }
                try? await refresh()
            }
            if Task.isCancelled { for job in jobs.filter({ $0.state == "direct_queued" }) { let _: RelaySnapshot? = try? await engine.execute(["command":"direct_error","id":job.id,"message":"Queue stopped before this job began. Return to review to restart."]) } }; try? await refresh()
            processingMessage = nil; processingTask = nil
        }
    }
    func cleanupSource(_ job: RelayJob) async throws {
        guard let engine else { return }
        let checked: RelayJob = try await engine.execute(["command":"direct_cleanup_check","id":job.id])
        // FileManager uses recoverable, volume-appropriate macOS Trash semantics.
        let source = URL(fileURLWithPath: checked.currentPath)
        var result: NSURL?
        try FileManager.default.trashItem(at: source, resultingItemURL: &result)
        snapshot = try await engine.execute(["command":"direct_cleanup_done","id":job.id,"path":result?.path ?? "macOS Trash"])
    }
    func retryDirect(_ job: RelayJob) async {
        guard let engine else { return }
        await perform("Returning the interrupted job to review…") { self.snapshot = try await engine.execute(["command":"direct_retry","id":job.id]); self.loadDraft() }
    }
    func updateProcessingMessage(_ message: String) { processingMessage = message }
    func cancelProcessing() { processingTask?.cancel(); Task { await processor.cancel() } }
    func retryDirectCleanup(_ job: RelayJob) async {
        await perform("Retrying verified source cleanup…") { try await self.cleanupSource(job) }
    }
    func chooseDestination() {
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.canCreateDirectories = true
        if panel.runModal() == .OK, let url = panel.url { draftDirect.destination = url.path; scheduleAutosave() }
    }
    func chooseLocalPoster() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.jpeg,.png]
        if panel.runModal() == .OK, let url = panel.url { importLocalArtwork(url) }
    }
    func loadNaming() async {
        guard let engine else { return }
        do { naming = try await engine.execute(["command":"direct_naming"]) } catch { self.error = error.localizedDescription }
    }
    func saveNaming() async {
        guard let engine else { return }
        do { naming = try await engine.execute(["command":"direct_naming","settings":RelayEngine.object(naming)]); notice = "Naming settings saved." } catch { self.error = error.localizedDescription }
    }
    func exportLogs() {
        let panel = NSSavePanel(); panel.nameFieldStringValue = "RELAY-journal.json"
        guard panel.runModal() == .OK, let url = panel.url, let snapshot else { return }
        do { try JSONEncoder().encode(snapshot.events).write(to: url, options: .atomic) } catch { self.error = error.localizedDescription }
    }
    func clearPublicCache() {
        clearPosterCache()
        guard let folder = cacheFolder, let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else { return }
        do { for url in files where url.pathExtension == "json" { try FileManager.default.removeItem(at: url) }; notice = "Public JSON metadata cache cleared. Jobs, credentials and IMDb index retained." } catch { self.error = error.localizedDescription }
    }
}
