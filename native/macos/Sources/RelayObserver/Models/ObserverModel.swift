import AppKit
import Foundation
import Observation
import IFlicksCapture

@MainActor @Observable
final class ObserverModel {
    var folders: [URL] = []
    var recursive = false
    var captureIFlicks = true
    var iflicksStatus = IFlicksCaptureStatus()
    private var sampler: IFlicksSampler?
    private var lifecycleMonitor: IFlicksLifecycleMonitor?
    var snapshot: ObserverSnapshot?
    var busy = false
    var error: String?
    var showingMarker = false
    var markerText = ""
    var needsFolderSelection = false
    var watcherWarning: String?
    private let engine = ObserverEngine()
    private var watcher: FolderWatcher?
    private var pollTask: Task<Void, Never>?

    var running: Bool { snapshot?.running == true }
    var canConfigure: Bool { !running && !busy }

    init() {
        let bundle = Bundle.main.bundleURL.resolvingSymlinksInPath()
        let parent = bundle.deletingLastPathComponent()
        if bundle.path.contains("/AppTranslocation/") || !FileManager.default.isWritableFile(atPath: parent.path) {
            needsFolderSelection = true
        } else { folders = [parent] }
    }

    func choosePrimaryFolder() {
        guard canConfigure else { return }
        if let url = chooseFolder(prompt: "Choose Watch & Log Folder") {
            folders.removeAll { $0 == url }
            if !folders.isEmpty { folders.removeFirst() }
            folders.insert(url, at: 0)
            needsFolderSelection = false
        }
    }

    func addFolder() {
        guard canConfigure, let url = chooseFolder(prompt: "Add Watched Folder") else { return }
        guard !folders.contains(url) else { error = "That folder is already being monitored."; return }
        folders.append(url)
    }

    private func chooseFolder(prompt: String) -> URL? {
        let panel = NSOpenPanel()
        panel.title = prompt
        panel.message = "RELAY only observes metadata. The log is written in the first watched folder."
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose Folder"
        return panel.runModal() == .OK ? panel.url?.resolvingSymlinksInPath().standardizedFileURL : nil
    }

    func start() async {
        guard canConfigure, !folders.isEmpty else { return }
        busy = true; error = nil; watcherWarning = nil
        do {
            // Reap a worker that previously stopped because its log became
            // unwritable before attempting another session.
            lifecycleMonitor?.stop(); lifecycleMonitor = nil
            await sampler?.stop(); sampler = nil
            _ = try await engine.stop()
            snapshot = try await engine.start(folders: folders, recursive: recursive, captureIFlicks: captureIFlicks, bundle: Bundle.main.bundleURL.resolvingSymlinksInPath())
            let engine = engine
            let watcher = FolderWatcher { notices in Task { await engine.notice(notices) } }
            self.watcher = watcher
            do { try watcher.start(folders: folders) }
            catch {
                watcherWarning = error.localizedDescription
                await engine.notice([NativeNotice(path: folders[0].path, flags: 0, eventId: "0",
                    receivedUnixMs: UInt64(Date().timeIntervalSince1970 * 1000), gap: true, error: error.localizedDescription)])
            }
            if captureIFlicks {
                let sampler = IFlicksSampler(transport: AppleEventTransport(), provider: { IFlicksProcess.running() },
                    sink: { event in await engine.iflicks(event) },
                    update: { [weak self] status in await self?.updateIFlicks(status) })
                self.sampler = sampler
                await sampler.start()
                lifecycleMonitor = IFlicksLifecycleMonitor(sampler: sampler)
            } else { iflicksStatus.message = "iFlicks capture disabled" }
            pollTask?.cancel()
            pollTask = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(500))
                    guard !Task.isCancelled, let self else { return }
                    do {
                        self.snapshot = try await self.engine.snapshot()
                        if let failure = self.snapshot?.lastError { self.error = failure }
                        if !self.running { self.watcher?.stop(); self.lifecycleMonitor?.stop(); self.lifecycleMonitor = nil; await self.sampler?.stop(); self.sampler = nil; return }
                    } catch { self.error = error.localizedDescription; return }
                }
            }
        } catch { self.error = error.localizedDescription }
        busy = false
    }

    func stop() async {
        guard !busy else { return }
        busy = true
        watcher?.stop(); watcher = nil
        pollTask?.cancel(); pollTask = nil
        lifecycleMonitor?.stop(); lifecycleMonitor = nil
        await sampler?.stop(); sampler = nil
        do {
            if let result = try await engine.stop() { snapshot = result }
            if let failure = snapshot?.lastError { error = failure }
        } catch { self.error = error.localizedDescription }
        busy = false
    }

    private func updateIFlicks(_ status: IFlicksCaptureStatus) { iflicksStatus = status }

    func addMarker() async {
        do { try await engine.marker(markerText); markerText = ""; showingMarker = false }
        catch { self.error = error.localizedDescription }
    }

    func revealLog() {
        guard let path = snapshot?.logPath else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }
}
