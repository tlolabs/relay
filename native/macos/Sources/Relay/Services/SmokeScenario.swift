import AppKit
import RelayKit

extension RelayModel {
    func runSmoke(root: URL) async {
        guard let engine else { try? Data((error ?? "Cannot open fixture store").utf8).write(to: root.appendingPathComponent("error.txt")); NSApp.terminate(nil); return }
        do {
            guard let original = jobs.first else { throw RelayFailure.message("No fixture video discovered") }
            selectedIds = [original.id]; loadDraft()
            draft.kind = "tv"; draft.title = "RELAY Fixture"; draft.season = 1; draft.episode = 1; draft.episodeTitle = "A reviewed episode"
            await saveDraft()
            try? await Task.sleep(for: .milliseconds(500))
            try captureFixtureWindow(root.appendingPathComponent("review.png"))
            await previewBatch()
            guard preview?.errors.isEmpty == true else { throw RelayFailure.message("Fixture batch preview failed") }
            try? await Task.sleep(for: .milliseconds(500))
            try captureFixtureWindow(root.appendingPathComponent("preview.png"))
            presentingPreview = false
            await startApprovedBatch() // smokeMode prevents all real iFlicks access.
            let output = root.appendingPathComponent("output/RELAY Fixture – s01e01 – Actual Final-HD.m4v")
            try Data("finished fixture".utf8).write(to: output)
            let _: RelaySnapshot = try await engine.execute(["command": "confirm_output", "id": original.id, "path": output.path])
            let final: RelaySnapshot = try await engine.execute(["command": "reconcile", "id": original.id])
            snapshot = final; group = "Completed"; selectedIds = [original.id]; loadDraft()
            guard final.jobs.first?.state == "complete" else { throw RelayFailure.message("Fixture job did not complete") }
            try JSONEncoder().encode(final).write(to: root.appendingPathComponent("result.json"))
            try? await Task.sleep(for: .seconds(1))
            try captureFixtureWindow(root.appendingPathComponent("relay.png"))
        } catch { try? Data(error.localizedDescription.utf8).write(to: root.appendingPathComponent("error.txt")) }
        NSApp.terminate(nil)
    }
    private func captureFixtureWindow(_ destination: URL) throws {
        if let parent = NSApp.windows.first(where: { $0.title == "RELAY" }),
           let image = CGWindowListCreateImage(.null, .optionIncludingWindow, CGWindowID((parent.attachedSheet ?? parent).windowNumber), [.boundsIgnoreFraming, .bestResolution]),
           let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) { try png.write(to: destination) }
    }
}
