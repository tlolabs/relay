import AppKit
import Foundation
import Observation
import RelayKit
import IFlicksCapture

@MainActor @Observable
final class RelayModel {
    var snapshot: RelaySnapshot?
    var selectedIds = Set<String>()
    var pendingSelection: Set<String>?
    var pendingGroup: String?
    var confirmingNavigation = false
    var group = "Queue"
    var busy = false
    var workMessage: String?
    var scanning = false
    var folderSearchInProgress = false
    var folderSearchSignature: [String]?
    var folderCatalogs: [TVSeriesCatalog] = []
    var folderEvidence: [Int: [DiscoveryEvidence]] = [:]
    var folderSuggestions: [String: MediaIdentity] = [:]
    var folderSearchSummary = "Scan intake folders to find videos."
    var episodeActivity: String?
    var error: String?
    var notice: String?
    var preview: BatchPreview?
    var presentingPreview = false
    var outputJob: RelayJob?
    var candidates: [OutputCandidate] = []
    var selectedOutput: String?
    var iflicksStatus = IFlicksCaptureStatus()
    var catalogTitles: [CatalogTitle] = []
    var showMatches: [TVShowMatch] = []
    var providerStatuses: [ProviderStatus] = []
    var discoveryIssues: [String] = []
    var catalogEvidence: [Int: [DiscoveryEvidence]] = [:]
    var imdbImportTask: Task<Void, Never>?
    var imdbImportMessage = ""
    var imdbImporting = false
    var catalogMessage = ""
    var catalogTask: Task<Void, Never>?
    var catalogRequest = UUID()
    var episodeRequest = UUID()
    var episodes: [EpisodeCandidate] = []
    var suggestions: [EpisodeSuggestion] = []
    var plexTitles: [PlexTitle] = []
    var plexBusy = false
    var plexLoadedAt: Date?
    var plexLastCheckedAt: Date?
    var plexConnectionVerified = false
    var plexMessage = "Not checked. Save and test your Plex connection in Settings."
    var settingsTab = "general"
    var apiUsage: [APIUsageSnapshot] = []
    var apiUsageError = ""
    var checkingConnections = false
    var connectionCheckTask: Task<Void, Never>?
    var catalogBusy = false
    var searchText = ""
    var chosenTitle: CatalogTitle?
    var seriesContext: SeriesContext?
    var seriesContextCached = false
    var season = 1
    var catalogKind = "tv"
    var draft = MediaIdentity()
    var draftDirect = DirectDraft()
    var editedMetadataFields = Set<String>()
    var editedIdentityFields = Set<String>()
    var naming = NamingSettings()
    var pendingCatalogChoice: CatalogChoice?
    var artworkCandidates: [String] = []
    var loadingCatalogDetails = false
    var inspectingIds = Set<String>()
    var savingDraft = false
    var autosaveTask: Task<Void,Never>?
    var processingTask: Task<Void,Never>?
    var processingMessage: String?
    let processor = DirectProcessor()
    let inspectorProcessor = DirectProcessor()
    var posterCache: [String: Data] = [:]
    var draftSubtitles: [Subtitle] = []
    var editingId: String?
    var draftRevision: UInt64 = 0
    var databaseURL: URL?
    var smokeMode = false
    var engine: RelayEngine?
    let catalog = CatalogClient()
    let metadataDiscovery = MetadataDiscoveryClient()
    let imdbIndex = IMDbIndex()
    @ObservationIgnored lazy var discoveryResolver = TMDBDiscoveryResolver(catalog: catalog)
    let episodeWebSearch = EpisodeWebSearch()
    let controller = IFlicksController()
    private var sampler: IFlicksSampler?
    private var lifecycle: IFlicksLifecycleMonitor?
    private var pollTask: Task<Void, Never>?
    private var previousAttention = Set<String>()
    private var hasLoadedAttention = false
    private let outputInspector = OutputInspector()

    var hasOpenStore: Bool { engine != nil }
    var jobs: [RelayJob] { snapshot?.jobs ?? [] }
    var groups: [String] { Array(Set(jobs.filter(\.editable).map { listIdentity(for: $0).group })).sorted() }
    func suggestedIdentity(for job: RelayJob) -> MediaIdentity? {
        guard job.editable, job.identity.title.isEmpty else { return nil }
        return folderSuggestions[job.id]
    }
    func listIdentity(for job: RelayJob) -> MediaIdentity { suggestedIdentity(for: job) ?? job.identity }
    var activityMessages: [String] {
        var messages: [String] = []
        if let processingMessage { messages.append(processingMessage) }
        if scanning { messages.append("Scanning intake folders for videos and subtitles…") }
        else if let workMessage { messages.append(workMessage) }
        if catalogBusy { messages.append(catalogMessage.isEmpty ? "Searching metadata sources…" : catalogMessage) }
        if let episodeActivity { messages.append(episodeActivity) }
        return messages
    }
    var visibleJobs: [RelayJob] {
        jobs.filter { job in
            switch group {
            case "Queue": return true
            case "Review": return job.editable
            case "Active": return !job.editable && job.state != "complete"
            case "Completed": return job.state == "complete"
            default: return job.editable && listIdentity(for: job).group == group
            }
        }.sorted { FolderReview.precedes(identity: listIdentity(for: $0), filename: $0.filename, id: $0.id,
                                         identity: listIdentity(for: $1), filename: $1.filename, id: $1.id) }
    }
    var selectedJob: RelayJob? {
        let visible = visibleJobs
        return visible.first { $0.id == editingId && selectedIds.contains($0.id) } ?? visible.first { selectedIds.contains($0.id) }
    }
    var reviewIds: [String] { visibleJobs.filter { $0.editable && $0.included && (selectedIds.isEmpty || selectedIds.contains($0.id)) }.map(\.id) }
    var hasUnsavedChanges: Bool { guard let job = selectedJob, job.id == editingId, job.editable else { return false }; return !editedMetadataFields.isEmpty || !editedIdentityFields.isEmpty || draft != job.identity || draftDirect != job.options || draftSubtitles.map { "\($0.id):\($0.selected):\($0.language)" } != job.subtitles.map { "\($0.id):\($0.selected):\($0.language)" } }
    var attentionCount: Int { jobs.filter { $0.needsAttention || $0.editable && $0.included }.count }

    func selectJobs(_ ids: Set<String>, in nextGroup: String? = nil) {
        if !smokeMode, hasUnsavedChanges, !savingDraft {
            Task { await persistDraft(); if !hasUnsavedChanges { if let nextGroup { group = nextGroup }; selectedIds = ids; loadDraft() } }; return
        }
        if hasUnsavedChanges && (nextGroup != nil || editingId.map { !ids.contains($0) } == true) {
            pendingSelection = ids; pendingGroup = nextGroup; confirmingNavigation = true
        } else {
            if let nextGroup { group = nextGroup }
            selectedIds = ids
        }
    }
    func finishNavigation(saving: Bool) async {
        guard let ids = pendingSelection else { return }
        let nextGroup = pendingGroup
        pendingSelection = nil; pendingGroup = nil
        if saving {
            await saveDraft()
            guard !hasUnsavedChanges else { return }
        }
        if let nextGroup { group = nextGroup }
        selectedIds = ids
    }

    static func defaultIntakeRoots(home: URL = FileManager.default.homeDirectoryForCurrentUser, defaults: UserDefaults = .standard) -> [String] {
        let fm = FileManager.default
        let saved = (defaults.stringArray(forKey: "intakeRoots") ?? []).filter { fm.fileExists(atPath: $0) }
        if !saved.isEmpty { return saved }
        let downloads = home.appendingPathComponent("Downloads").path
        return [fm.fileExists(atPath: downloads) ? downloads : home.path]
    }
    static func defaultOutputFolder(home: URL = FileManager.default.homeDirectoryForCurrentUser, defaults: UserDefaults = .standard) -> String {
        let fm = FileManager.default
        if let saved = defaults.string(forKey: "outputFolder"), !saved.isEmpty, fm.fileExists(atPath: saved) { return saved }
        let movies = home.appendingPathComponent("Movies").path
        return fm.fileExists(atPath: movies) ? movies : home.path
    }
    func initialize(smokeRoot: URL? = nil) async {
        guard engine == nil else { return }
        busy = true; workMessage = "Opening the job library…"
        defer { busy = false; workMessage = nil }
        smokeMode = smokeRoot != nil
        do {
            let root = smokeRoot?.appendingPathComponent("state") ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("RELAY", isDirectory: true)
            databaseURL = root.appendingPathComponent("jobs.sqlite")
            let engine = try RelayEngine(database: databaseURL!)
            self.engine = engine
            snapshot = try await engine.snapshot()
            do {
                if snapshot?.config == nil {
                    let defaults = UserDefaults.standard
                    let roots = smokeRoot.map { [$0.appendingPathComponent("intake").path] } ?? Self.defaultIntakeRoots(defaults: defaults)
                    let output = smokeRoot?.appendingPathComponent("output").path ?? Self.defaultOutputFolder(defaults: defaults)
                    snapshot = try await engine.configure(RelayConfig(roots: roots, recursive: defaults.bool(forKey: "recursive"), outputFolder: output))
                }
                try await refresh(discover: true)
            } catch { self.error = error.localizedDescription }
            await loadNaming()
            if !smokeMode, jobs.contains(where: { $0.iflicksId != nil && $0.state != "complete" }) { await startSampler() }
            pollTask = Task { [weak self] in
                var tick = 0
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(500))
                    guard !Task.isCancelled, let self else { return }
                    tick += 1
                    if !self.busy { do { try await self.refresh(discover: tick % 10 == 0 && (UserDefaults.standard.object(forKey: "watchFoldersEnabled") as? Bool ?? true)) } catch { self.error = error.localizedDescription } }
                }
            }
        } catch { self.error = error.localizedDescription }
    }
    func refresh(discover: Bool = false) async throws {
        guard let engine else { throw RelayFailure.message("The job store is unavailable") }
        if discover { scanning = true }
        defer { if discover { scanning = false } }
        let hadEdits = hasUnsavedChanges, priorState = selectedJob?.state
        let result: RelaySnapshot = try await engine.execute(["command": discover ? "discover" : "snapshot"])
        snapshot = result
        let attention = Set(result.jobs.filter { $0.needsAttention || $0.editable && $0.included }.map { "\($0.id):\($0.state)" })
        let added = attention.subtracting(previousAttention)
        if !smokeMode {
            NSApp.dockTile.badgeLabel = UserDefaults.standard.object(forKey: "dockBadge") as? Bool ?? true ? (attention.isEmpty ? nil : String(attention.count)) : nil
            if hasLoadedAttention && !added.isEmpty { AttentionService.deliver(count: added.count) }
        }
        previousAttention = attention; hasLoadedAttention = true
        selectedIds.formIntersection(Set(result.jobs.map(\.id)))
        if !hadEdits, !savingDraft, priorState != selectedJob?.state { loadDraft() }
        if discover { beginFolderSearchIfNeeded() }
        if !smokeMode, let job = selectedJob, job.editable, job.options.inspection == nil, !hasUnsavedChanges { Task { await self.inspectSelected() } }
    }
    func scan() async {
        cancelCatalogSearch()
        folderSearchSignature = nil
        await perform("Scanning intake folders…") { try await self.refresh(discover: true) }
    }
    func perform(_ message: String = "Updating jobs…", _ work: () async throws -> Void) async {
        guard !busy else { return }; busy = true; workMessage = message; error = nil
        defer { busy = false; workMessage = nil }
        do { try await work() } catch { self.error = error.localizedDescription; try? await refresh() }
    }
    func loadDraft() {
        editedMetadataFields = []
        editedIdentityFields = []
        if !folderSearchInProgress { cancelCatalogSearch() }
        episodeRequest = UUID(); episodeActivity = nil
        guard let job = selectedJob else { editingId = nil; return }
        editingId = job.id; draftRevision = job.revision; draft = job.identity; draftDirect = job.options; draftSubtitles = job.subtitles
        if !smokeMode { Task { await inspectSelected() } }
        searchText = job.identity.kind == "movie" ? job.identity.title : job.identity.title.isEmpty ? job.identity.episodeTitle : job.identity.title
        catalogKind = job.identity.kind == "movie" ? "movie" : "tv"; season = job.identity.season ?? 1
        suggestions = []; episodes = []; chosenTitle = nil; seriesContext = nil; seriesContextCached = false
        if !folderSearchInProgress {
            catalogTitles = []; providerStatuses = []; discoveryIssues = []; catalogEvidence = folderEvidence
            showMatches = MetadataConsensus.rank(folderCatalogs, clues: episodeSearchClues, evidence: folderEvidence).filter { !$0.supportedTitles.isEmpty }
            catalogMessage = folderSearchSummary
        }
    }
    func saveDraft() async {
        if !smokeMode { await persistDraft(); return }
        guard let job = selectedJob, job.id == editingId, let engine else { return }
        await perform("Saving identity and subtitle choices…") {
            self.snapshot = try await engine.execute(["command": "edit", "id": job.id, "revision": self.draftRevision,
                "identity": RelayEngine.object(self.draft), "subtitles": self.draftSubtitles.map { ["id": $0.id, "selected": $0.selected, "language": $0.language] }])
            self.loadDraft()
            self.notice = "Identity and subtitle choices saved for review."
        }
    }
    func saveSubtitleChoices() async {
        guard let job = selectedJob, let engine else { return }
        await perform("Saving subtitle choices…") {
            self.snapshot = try await engine.execute(["command": "review_subtitles", "id": job.id,
                "subtitles": self.draftSubtitles.map { ["id": $0.id, "selected": $0.selected, "language": $0.language] }])
            self.loadDraft()
        }
    }
    func toggleIncluded(_ job: RelayJob) async {
        guard let engine else { return }
        await perform("Updating batch inclusion…") {
            self.snapshot = try await engine.execute(["command": "edit", "id": job.id, "revision": job.revision, "included": !job.included])
            if self.editingId == job.id, self.draftRevision == job.revision,
               let updated = self.jobs.first(where: { $0.id == job.id }) { self.draftRevision = updated.revision }
        }
    }
    func previewBatch() async {
        if !smokeMode { await directPreview(); return }
        guard let engine else { return }
        guard !hasUnsavedChanges else { error = "Save the current review before previewing the batch"; return }
        let ids = reviewIds
        await perform("Checking filenames and subtitles for batch review…") { self.preview = try await engine.execute(["command": "preview", "ids": ids]); self.presentingPreview = true }
    }
    func startApprovedBatch() async {
        if !smokeMode { await approveDirect(); return }
        guard let preview, let engine else { return }
        presentingPreview = false
        await perform("Preparing approved filenames and sending videos to iFlicks…") {
            self.snapshot = try await engine.execute(["command": "start_batch", "token": preview.token])
            self.group = "Active"
            let prepared = self.jobs.filter { preview.actions.map(\.id).contains($0.id) && $0.state == "prepared" }
            if !self.smokeMode { try await self.handoff(prepared) }
        }
    }
    func restore(_ job: RelayJob) async {
        guard let engine else { return }
        await perform("Restoring original filenames…") { self.snapshot = try await engine.execute(["command": job.state == "prepared" ? "unprepare" : "recover", "id": job.id]) }
    }
    func attachSubtitle(_ job: RelayJob) async {
        let panel = NSOpenPanel(); panel.title = "Attach an SRT to this job"; panel.allowedContentTypes = [.init(filenameExtension: "srt")!]
        guard panel.runModal() == .OK, let path = panel.url?.path, let engine else { return }
        autosaveTask?.cancel(); await persistDraft()
        await perform("Attaching subtitle…") { self.snapshot = try await engine.execute(["command": "attach_subtitle", "id": job.id, "path": path, "language": "en"]); self.loadDraft() }
    }
    func showOutputs(_ job: RelayJob) async {
        guard let engine else { return }
        await perform("Finding finished videos in the output folder…") { self.candidates = try await engine.execute(["command": "outputs"]); self.outputJob = job; self.selectedOutput = job.outputPath }
    }
    func browseOutput() {
        let panel = NSOpenPanel(); panel.title = "Select the actual finished video for this job"; panel.canChooseFiles = true
        if panel.runModal() == .OK, let url = panel.url { selectedOutput = url.path; if !candidates.contains(where: { $0.path == url.path }) { candidates.append(OutputCandidate(path: url.path, size: 0)) } }
    }
    func confirmOutput() async {
        guard let job = outputJob, let path = selectedOutput, let engine else { return }
        await perform("Verifying the finished video and placing subtitles…") {
            let expected: FileFingerprint = try await engine.execute(["command": "check_output", "id": job.id, "path": path])
            let evidence = try await self.outputInspector.prepareConfirmedOutput(path: path, identity: job.identity, expected: expected)
            self.snapshot = try await engine.execute(["command": "confirm_output", "id": job.id, "path": path, "evidence": evidence])
            self.outputJob = nil
            self.snapshot = try await engine.execute(["command": "reconcile", "id": job.id])
            self.notice = job.identity.kind == "tv" ? "Finished TV output confirmed, embedded cover artwork cleared, and subtitles reconciled." : "Finished output confirmed and subtitles reconciled."
        }
    }
    func retrySubtitles(_ job: RelayJob) async {
        guard let engine else { return }
        await perform("Checking and placing subtitles…") { self.snapshot = try await engine.execute(["command": "reconcile", "id": job.id]); if let updated = self.jobs.first(where: { $0.id == job.id }), updated.options.backend, updated.options.trashSource, updated.options.trashPath == nil { try await self.cleanupSource(updated) } }
    }
    func reveal(_ path: String) { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
    func applySettings(_ config: RelayConfig) async {
        guard let engine else { return }
        await perform("Saving intake settings and scanning folders…") {
            self.snapshot = try await engine.configure(config)
            if !self.smokeMode {
                UserDefaults.standard.set(config.roots, forKey: "intakeRoots")
                UserDefaults.standard.set(config.recursive, forKey: "recursive")
                UserDefaults.standard.set(config.outputFolder, forKey: "outputFolder")
            }
            try await self.refresh(discover: true)
        }
    }
    private func startSampler() async {
        guard let engine else { return }
        let sampler = IFlicksSampler(transport: controller, provider: { IFlicksProcess.running() }, sink: { event in
            let _: RelaySnapshot? = try? await engine.execute(["command": "iflicks_event", "observation": RelayEngine.object(event)])
        }, update: { [weak self] status in await self?.setStatus(status) })
        self.sampler = sampler; await sampler.start(); lifecycle = IFlicksLifecycleMonitor(sampler: sampler)
    }
    private func setStatus(_ status: IFlicksCaptureStatus) { iflicksStatus = status }
    func pauseSampler() async { lifecycle?.stop(); lifecycle = nil; await sampler?.stop(); sampler = nil }
    func close() async { autosaveTask?.cancel(); await persistDraft(); cancelProcessing(); if let processingTask { await processingTask.value }; imdbImportTask?.cancel(); if let task = imdbImportTask { await task.value }; catalogTask?.cancel(); catalogRequest = UUID(); pollTask?.cancel(); pollTask = nil; await pauseSampler(); await engine?.close(); engine = nil }
    func runningIFlicks() async throws -> IFlicksProcess {
        if IFlicksProcess.running() == nil {
            let url = URL(fileURLWithPath: "/Applications/iFlicks 3.app")
            guard FileManager.default.fileExists(atPath: url.path) else { throw RelayFailure.message("Install iFlicks 3 in Applications before handoff; approved names are already prepared") }
            let config = NSWorkspace.OpenConfiguration(); config.activates = false
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                NSWorkspace.shared.openApplication(at: url, configuration: config) { _, error in
                    if let error { continuation.resume(throwing: error) } else { continuation.resume() }
                }
            }
        }
        let deadline = ProcessInfo.processInfo.systemUptime + 8
        var lastFailure: Error?
        while ProcessInfo.processInfo.systemUptime < deadline {
            if let running = IFlicksProcess.running() {
                do { _ = try await controller.sample(process: running, timeout: 1); return running }
                catch let failure as IFlicksQueryFailure where [-1712, -600, -609, -1708].contains(failure.code) { lastFailure = failure }
                catch { throw error }
            }
            try await Task.sleep(for: .milliseconds(250))
        }
        throw lastFailure ?? RelayFailure.message("iFlicks did not become available; jobs remain prepared")
    }
    func sendPrepared(_ job: RelayJob) async { await perform("Sending the prepared video to iFlicks…") { try await self.handoff([job]) } }
    func handoff(_ jobs: [RelayJob]) async throws {
        guard let engine, !jobs.isEmpty else { return }
        await pauseSampler()
        do {
            let process = try await runningIFlicks()
            var ready: [RelayJob] = []
            for (index, job) in jobs.enumerated() {
                workMessage = "Sending video \(index + 1) of \(jobs.count) to iFlicks: \(job.filename)"
                do {
                    // Read first; a failure here cannot create an uncertain import.
                    let existing = try await controller.sample(process: process, timeout: 1)
                    let prepared: RelayJob = try await engine.execute(["command": "begin_submission", "id": job.id])
                    let video = try await controller.importVideo(path: prepared.currentPath, process: process, existing: existing)
                    let bound: RelayJob = try await engine.execute(["command": "bind_submission", "id": job.id, "video_id": video.id, "process_identity": IFlicksController.processIdentity(process), "reported_path": video.filePath ?? ""])
                    try await controller.applyMetadata(bound.identity, id: video.id, process: process)
                    try await controller.verifyMetadata(bound.identity, id: video.id, process: process)
                    ready.append(bound)
                } catch {
                    let _: RelaySnapshot? = try? await engine.execute(["command": "integration_error", "id": job.id, "message": error.localizedDescription])
                    self.error = error.localizedDescription
                }
            }
            for (index, job) in ready.enumerated() {
                workMessage = "Verifying and starting video \(index + 1) of \(ready.count): \(job.filename)"
                do {
                    try await controller.verifyMetadata(job.identity, id: job.iflicksId!, process: process)
                    let _: RelayJob = try await engine.execute(["command": "authorize_processing", "id": job.id])
                    try await controller.start(id: job.iflicksId!, process: process)
                } catch {
                    let _: RelaySnapshot? = try? await engine.execute(["command": "integration_error", "id": job.id, "message": error.localizedDescription])
                    self.error = error.localizedDescription
                }
            }
            try await refresh()
        } catch { await startSampler(); throw error }
        await startSampler()
    }
    func verifyAndStart(_ job: RelayJob) async {
        guard let engine, let id = job.iflicksId else { return }
        await perform("Verifying approved metadata in iFlicks…") {
            await self.pauseSampler()
            do {
                guard let process = IFlicksProcess.running(), IFlicksController.processIdentity(process) == job.processIdentity else { throw RelayFailure.message("The bound iFlicks process is unavailable. Confirm output or inspect the queue.") }
                try await self.controller.verifyMetadata(job.identity, id: id, process: process)
                let _: RelayJob = try await engine.execute(["command": "authorize_processing", "id": job.id])
                try await self.controller.start(id: id, process: process)
            } catch { await self.startSampler(); throw error }
            await self.startSampler(); try await self.refresh()
        }
    }
    func bindExisting(_ job: RelayJob) async {
        guard let engine else { return }
        await perform("Finding the existing video in the iFlicks queue…") {
            guard let process = IFlicksProcess.running() else { throw RelayFailure.message("Open iFlicks and inspect the existing queue first") }
            let videos = try await self.controller.sample(process: process, timeout: 1)
            let matches = videos.filter { $0.filePath == job.currentPath }
            guard matches.count == 1 else { throw RelayFailure.message("Exactly one queued object must report this job's prepared input path") }
            let _: RelayJob = try await engine.execute(["command": "bind_submission", "id": job.id, "video_id": matches[0].id, "process_identity": IFlicksController.processIdentity(process), "reported_path": job.currentPath])
            try await self.refresh()
        }
    }
}
