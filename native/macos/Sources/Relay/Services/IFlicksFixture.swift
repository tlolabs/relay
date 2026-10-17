import AppKit
import RelayKit
import IFlicksCapture

extension RelayModel {
    /// Explicit test-only path: one generated clip, an empty queue, no preference
    /// changes. The shell harness removes only the uniquely owned fixture output.
    func runIFlicksFixture(root: URL) async {
        guard let engine else { try? Data((error ?? "Cannot open fixture store").utf8).write(to: root.appendingPathComponent("integration-error.txt")); NSApp.terminate(nil); return }
        do {
            let process = try await runningIFlicks()
            let queue = try await controller.sample(process: process, timeout: 1)
            guard let job = jobs.first, job.filename.hasPrefix("RELAY Integration ") else { throw RelayFailure.message("Expected a uniquely named disposable integration clip") }
            if ["submission_uncertain", "submitted", "processing", "awaiting_output"].contains(job.state) {
                // Explicit re-run of this fixture may recover its one observed
                // object. It never imports an uncertain input again.
                let matches = queue.filter { $0.filePath == job.currentPath }
                guard queue.count == 1, matches.count == 1 else { throw RelayFailure.message("Fixture recovery requires only its exact existing input in the queue") }
                let bound: RelayJob
                if job.state == "submission_uncertain" {
                    bound = try await engine.execute(["command": "bind_submission", "id": job.id, "video_id": matches[0].id, "process_identity": IFlicksController.processIdentity(process), "reported_path": job.currentPath])
                } else {
                    guard job.iflicksId == matches[0].id, job.processIdentity == IFlicksController.processIdentity(process) else { throw RelayFailure.message("The fixture's recorded process/ID does not match") }
                    bound = job
                }
                if !["working", "completed"].contains(matches[0].status) {
                    try await controller.applyMetadata(bound.identity, id: matches[0].id, process: process)
                    await verifyAndStart(bound)
                }
            } else {
                guard queue.isEmpty else { throw RelayFailure.message("Live fixture test skipped: iFlicks already has queued videos. No media was submitted.") }
                selectedIds = [job.id]; loadDraft()
                draft.kind = "tv"; draft.title = root.lastPathComponent; draft.season = 1; draft.episode = 1; draft.episodeTitle = "Disposable Integration Test"
                await saveDraft(); await previewBatch()
                guard preview?.errors.isEmpty == true else { throw RelayFailure.message("The live fixture preview failed: \(preview?.errors.joined(separator: "; ") ?? error ?? "unknown")") }
                presentingPreview = false; await startApprovedBatch()
                guard let prepared = jobs.first(where: { $0.id == job.id }), prepared.state == "prepared" else { throw RelayFailure.message("Fixture preparation failed") }
                await perform { try await self.handoff([prepared]) }
            }
            let initial = try await engine.snapshot()
            guard initial.jobs.first?.iflicksId != nil, ["processing", "awaiting_output"].contains(initial.jobs.first?.state ?? "") else { throw RelayFailure.message(error ?? "Native import/metadata/start validation did not pass") }
            let deadline = ProcessInfo.processInfo.systemUptime + 90
            var completedAt: TimeInterval?
            var autoquit = false
            while ProcessInfo.processInfo.systemUptime < deadline {
                guard let current = IFlicksProcess.running() else { autoquit = true; break }
                guard current == process else { throw RelayFailure.message("iFlicks restarted during the fixture") }
                do {
                    let observed = try await controller.sample(process: current, timeout: 1)
                    let _: RelaySnapshot = try await engine.execute(["command": "iflicks_event", "observation": ["event": "iflicks_snapshot", "process": RelayEngine.object(current), "videos": RelayEngine.object(observed)]])
                    if observed.first(where: { $0.id == initial.jobs.first?.iflicksId })?.status == "completed" {
                        completedAt = completedAt ?? ProcessInfo.processInfo.systemUptime
                        if ProcessInfo.processInfo.systemUptime - completedAt! >= 4 { break }
                    }
                } catch let failure as IFlicksQueryFailure where [-1712, -600].contains(failure.code) {}
                try await Task.sleep(for: .milliseconds(250))
            }
            guard completedAt != nil || autoquit else { throw RelayFailure.message("The fixture did not report Completed or exit within 90 seconds; inspect iFlicks") }
            let evidence: [String: Any] = ["completed_observed": completedAt != nil, "autoquit_observed": autoquit, "resumed_existing_fixture": job.state != "needs_review"]
            try JSONSerialization.data(withJSONObject: evidence).write(to: root.appendingPathComponent("native-evidence.json"))
            try await Task.sleep(for: .seconds(1))
            let config = snapshot!.config!
            let files = try FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: config.outputFolder), includingPropertiesForKeys: nil)
                .filter { $0.lastPathComponent.hasPrefix(root.lastPathComponent) && ["mp4", "m4v", "mkv", "mov"].contains($0.pathExtension.lowercased()) }
            guard files.count == 1 else { throw RelayFailure.message("Expected exactly one output with the unique fixture title; found \(files.count)") }
            let _: RelaySnapshot = try await engine.execute(["command": "confirm_output", "id": job.id, "path": files[0].path])
            let result: RelaySnapshot = try await engine.execute(["command": "reconcile", "id": job.id])
            guard result.jobs.first?.state == "complete" else { throw RelayFailure.message("Native fixture reconciliation failed") }
            try JSONEncoder().encode(result).write(to: root.appendingPathComponent("integration-result.json"))
        } catch {
            if let state = try? await engine.snapshot() { try? JSONEncoder().encode(state).write(to: root.appendingPathComponent("integration-state.json")) }
            try? Data(error.localizedDescription.utf8).write(to: root.appendingPathComponent("integration-error.txt"))
        }
        NSApp.terminate(nil)
    }
}
