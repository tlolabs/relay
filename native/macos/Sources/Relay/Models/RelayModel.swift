import AppKit
import Foundation
import Observation
import RelayKit
import IFlicksCapture

@MainActor @Observable
final class RelayModel {
    var snapshot: RelaySnapshot?
    var selectedIds = Set<String>()
    var group = "Review"
    var busy = false
    var error: String?
    var notice: String?
    var preview: BatchPreview?
    var presentingPreview = false
    var outputJob: RelayJob?
    var candidates: [OutputCandidate] = []
    var selectedOutput: String?
    var iflicksStatus = IFlicksCaptureStatus()
    var catalogTitles: [CatalogTitle] = []
    var episodes: [EpisodeCandidate] = []
    var suggestions: [EpisodeSuggestion] = []
    var plexTitles: [PlexTitle] = []
    var catalogBusy = false
    var searchText = ""
    var chosenTitle: CatalogTitle?
    var seriesContext: SeriesContext?
    var seriesContextCached = false
    var season = 1
    var catalogKind = "tv"
    var draft = MediaIdentity()
    var draftSubtitles: [Subtitle] = []
    var editingId: String?
    var draftRevision: UInt64 = 0
    var databaseURL: URL?
    var smokeMode = false
    var engine: RelayEngine?
    let catalog = CatalogClient()
    let controller = IFlicksController()
    private var sampler: IFlicksSampler?
    private var lifecycle: IFlicksLifecycleMonitor?
    private var pollTask: Task<Void, Never>?
    private var previousAttention = Set<String>()
    private var hasLoadedAttention = false
    private let outputInspector = OutputInspector()

    var hasOpenStore: Bool { engine != nil }
    var jobs: [RelayJob] { snapshot?.jobs ?? [] }
    var groups: [String] { Array(Set(jobs.filter(\.editable).map { $0.identity.group })).sorted() }
    var visibleJobs: [RelayJob] {
        jobs.filter { job in
            switch group {
            case "Review": return job.editable
            case "Active": return !job.editable && job.state != "complete"
            case "Completed": return job.state == "complete"
            default: return job.editable && job.identity.group == group
            }
        }.sorted { $0.createdMs < $1.createdMs }
    }
    var selectedJob: RelayJob? { jobs.first { $0.id == selectedIds.sorted().first } }
    var reviewIds: [String] { visibleJobs.filter { $0.editable && $0.included && (selectedIds.isEmpty || selectedIds.contains($0.id)) }.map(\.id) }
    var hasUnsavedChanges: Bool { guard let job = selectedJob, job.id == editingId, job.editable else { return false }; return draft != job.identity || draftSubtitles.map { "\($0.id):\($0.selected):\($0.language)" } != job.subtitles.map { "\($0.id):\($0.selected):\($0.language)" } }
    var attentionCount: Int { jobs.filter { $0.needsAttention || $0.editable && $0.included }.count }

    func initialize(smokeRoot: URL? = nil) async {
        guard engine == nil else { return }
        smokeMode = smokeRoot != nil
        do {
            let root = smokeRoot?.appendingPathComponent("state") ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("RELAY", isDirectory: true)
            databaseURL = root.appendingPathComponent("jobs.sqlite")
            let engine = try RelayEngine(database: databaseURL!)
            self.engine = engine
            snapshot = try await engine.snapshot()
            if snapshot?.config == nil {
                let home = FileManager.default.homeDirectoryForCurrentUser
                let defaults = UserDefaults.standard
                let roots = smokeRoot.map { [$0.appendingPathComponent("intake").path] } ?? defaults.stringArray(forKey: "intakeRoots") ?? [home.appendingPathComponent("Downloads").path]
                let output = smokeRoot?.appendingPathComponent("output").path ?? defaults.string(forKey: "outputFolder") ?? home.appendingPathComponent("Movies/iFlicks 3").path
                snapshot = try await engine.configure(RelayConfig(roots: roots, recursive: defaults.bool(forKey: "recursive"), outputFolder: output))
            }
            try await refresh(discover: true)
            if !smokeMode { await startSampler() }
            pollTask = Task { [weak self] in
                var tick = 0
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(500))
                    guard !Task.isCancelled, let self else { return }
                    tick += 1
                    if !self.busy { do { try await self.refresh(discover: tick % 10 == 0) } catch { self.error = error.localizedDescription } }
                }
            }
        } catch { self.error = error.localizedDescription }
    }
    func refresh(discover: Bool = false) async throws {
        guard let engine else { throw RelayFailure.message("The job store is unavailable") }
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
    }
    func scan() async { await perform { try await self.refresh(discover: true) } }
    func perform(_ work: () async throws -> Void) async {
        guard !busy else { return }; busy = true; error = nil
        defer { busy = false }
        do { try await work() } catch { self.error = error.localizedDescription; try? await refresh() }
    }
    func loadDraft() {
        guard let job = selectedJob else { editingId = nil; return }
        editingId = job.id; draftRevision = job.revision; draft = job.identity; draftSubtitles = job.subtitles
        searchText = job.identity.kind == "movie" ? job.identity.title : job.identity.title.isEmpty ? job.identity.episodeTitle : job.identity.title
        catalogKind = job.identity.kind == "movie" ? "movie" : "tv"; season = job.identity.season ?? 1
        catalogTitles = []; suggestions = []; episodes = []; chosenTitle = nil; seriesContext = nil; seriesContextCached = false
    }
    func saveDraft() async {
        guard let job = selectedJob, job.id == editingId, let engine else { return }
        await perform {
            self.snapshot = try await engine.execute(["command": "edit", "id": job.id, "revision": self.draftRevision,
                "identity": RelayEngine.object(self.draft), "subtitles": self.draftSubtitles.map { ["id": $0.id, "selected": $0.selected, "language": $0.language] }])
            self.loadDraft()
            self.notice = "Identity and subtitle choices saved for review."
        }
    }
    func saveSubtitleChoices() async {
        guard let job = selectedJob, let engine else { return }
        await perform {
            self.snapshot = try await engine.execute(["command": "review_subtitles", "id": job.id,
                "subtitles": self.draftSubtitles.map { ["id": $0.id, "selected": $0.selected, "language": $0.language] }])
            self.loadDraft()
        }
    }
    func toggleIncluded(_ job: RelayJob) async {
        guard let engine else { return }
        await perform { self.snapshot = try await engine.execute(["command": "edit", "id": job.id, "revision": job.revision, "included": !job.included]) }
    }
    func previewBatch() async {
        guard let engine else { return }
        guard !hasUnsavedChanges else { error = "Save the current review before previewing the batch"; return }
        let ids = reviewIds
        await perform { self.preview = try await engine.execute(["command": "preview", "ids": ids]); self.presentingPreview = true }
    }
    func startApprovedBatch() async {
        guard let preview, let engine else { return }
        presentingPreview = false
        await perform {
            self.snapshot = try await engine.execute(["command": "start_batch", "token": preview.token])
            self.group = "Active"
            let prepared = self.jobs.filter { preview.actions.map(\.id).contains($0.id) && $0.state == "prepared" }
            if !self.smokeMode { try await self.handoff(prepared) }
        }
    }
    func restore(_ job: RelayJob) async {
        guard let engine else { return }
        await perform { self.snapshot = try await engine.execute(["command": job.state == "prepared" ? "unprepare" : "recover", "id": job.id]) }
    }
    func attachSubtitle(_ job: RelayJob) async {
        let panel = NSOpenPanel(); panel.title = "Attach an SRT to this job"; panel.allowedContentTypes = [.init(filenameExtension: "srt")!]
        guard panel.runModal() == .OK, let path = panel.url?.path, let engine else { return }
        await perform { self.snapshot = try await engine.execute(["command": "attach_subtitle", "id": job.id, "path": path, "language": "en"]); self.loadDraft() }
    }
    func showOutputs(_ job: RelayJob) async {
        guard let engine else { return }
        await perform { self.candidates = try await engine.execute(["command": "outputs"]); self.outputJob = job; self.selectedOutput = job.outputPath }
    }
    func browseOutput() {
        let panel = NSOpenPanel(); panel.title = "Select the actual finished video for this job"; panel.canChooseFiles = true
        if panel.runModal() == .OK, let url = panel.url { selectedOutput = url.path; if !candidates.contains(where: { $0.path == url.path }) { candidates.append(OutputCandidate(path: url.path, size: 0)) } }
    }
    func confirmOutput() async {
        guard let job = outputJob, let path = selectedOutput, let engine else { return }
        await perform {
            let evidence = try await self.outputInspector.validate(path: path, identity: job.identity)
            self.snapshot = try await engine.execute(["command": "confirm_output", "id": job.id, "path": path, "evidence": evidence])
            self.outputJob = nil
            self.snapshot = try await engine.execute(["command": "reconcile", "id": job.id])
            self.notice = "Finished output confirmed and subtitles reconciled."
        }
    }
    func retrySubtitles(_ job: RelayJob) async {
        guard let engine else { return }
        await perform { self.snapshot = try await engine.execute(["command": "reconcile", "id": job.id]) }
    }
    func reveal(_ path: String) { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
    func applySettings(_ config: RelayConfig) async {
        guard let engine else { return }
        await perform { self.snapshot = try await engine.configure(config); try await self.refresh(discover: true) }
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
    func close() async { pollTask?.cancel(); pollTask = nil; await pauseSampler(); await engine?.close(); engine = nil }
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
    func sendPrepared(_ job: RelayJob) async { await perform { try await self.handoff([job]) } }
    func handoff(_ jobs: [RelayJob]) async throws {
        guard let engine, !jobs.isEmpty else { return }
        await pauseSampler()
        do {
            let process = try await runningIFlicks()
            var ready: [RelayJob] = []
            for job in jobs {
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
            for job in ready {
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
        await perform {
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
        await perform {
            guard let process = IFlicksProcess.running() else { throw RelayFailure.message("Open iFlicks and inspect the existing queue first") }
            let videos = try await self.controller.sample(process: process, timeout: 1)
            let matches = videos.filter { $0.filePath == job.currentPath }
            guard matches.count == 1 else { throw RelayFailure.message("Exactly one queued object must report this job's prepared input path") }
            let _: RelayJob = try await engine.execute(["command": "bind_submission", "id": job.id, "video_id": matches[0].id, "process_identity": IFlicksController.processIdentity(process), "reported_path": job.currentPath])
            try await self.refresh()
        }
    }
}
