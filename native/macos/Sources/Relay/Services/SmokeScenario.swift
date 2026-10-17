import AppKit
import SwiftUI
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
            let fixtureCatalog = try JSONDecoder().decode(TVSeriesCatalog.self, from: Data(#"{"title":{"id":700,"name":"RELAY Fixture"},"episodes":[{"id":701,"name":"A reviewed episode","seasonNumber":1,"episodeNumber":1}]}"#.utf8))
            let records = [
                DiscoveryEvidence(source: .trakt, recordID: "fixture", title: "RELAY Fixture", episode: DiscoveredEpisode(title: "A reviewed episode", season: 1, number: 2)),
                DiscoveryEvidence(source: .tvmaze, recordID: "fixture", title: "RELAY Fixture", episode: DiscoveredEpisode(title: "A reviewed episode", season: 1, number: 1))
            ]
            showMatches = MetadataConsensus.rank([fixtureCatalog], clues: ["A reviewed episode"], evidence: [700: records])
            providerStatuses = [.init(source: .trakt, message: "1 fixture record", incomplete: false), .init(source: .tvmaze, message: "1 fixture record", incomplete: false)]
            try? await Task.sleep(for: .milliseconds(300))
            try captureFixtureWindow(root.appendingPathComponent("search.png"))
            let sourceWindow = NSWindow(contentRect: NSRect(x: 150, y: 150, width: 650, height: 570), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            sourceWindow.title = "RELAY Data Sources — Fixture"
            sourceWindow.contentView = NSHostingView(rootView: MetadataSourcesSettings(model: self).frame(width: 650, height: 570))
            sourceWindow.isReleasedWhenClosed = false; sourceWindow.makeKeyAndOrderFront(nil)
            try? await Task.sleep(for: .milliseconds(400))
            try captureFixtureWindow(root.appendingPathComponent("sources.png"), window: sourceWindow)
            sourceWindow.close()
            let connectionWindow = NSWindow(contentRect: NSRect(x: 150, y: 150, width: 650, height: 570), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            connectionWindow.title = "RELAY Plex Connection — Fixture"
            plexMessage = "Plex HTTPS certificate could not be verified. A .local name or IP address may not match Plex's certificate. Use Find Secure Servers to select the HTTPS address advertised by Plex. Using 123 cached TV shows; the live connection is not verified."
            plexLastCheckedAt = Date()
            connectionWindow.contentView = NSHostingView(rootView: Form { PlexSettingsView(model: self) }.formStyle(.grouped).frame(width: 650, height: 570))
            connectionWindow.isReleasedWhenClosed = false; connectionWindow.makeKeyAndOrderFront(nil)
            try? await Task.sleep(for: .milliseconds(400))
            try captureFixtureWindow(root.appendingPathComponent("plex-error.png"), window: connectionWindow)
            plexMessage = "Connected over HTTPS: 123 TV shows in 2 TV libraries."; plexConnectionVerified = true
            try? await Task.sleep(for: .milliseconds(300))
            try captureFixtureWindow(root.appendingPathComponent("plex-connected.png"), window: connectionWindow)
            connectionWindow.close()
            resetPlexConnection()
            let usageFixture = APIUsageStore(fileURL: nil)
            for source in APIProvider.allCases {
                try await usageFixture.reserve(source)
                try await usageFixture.checked(source, result: APIConnectionCheck(passed: true, message: "Fixture connection verified — no network request made."))
            }
            apiUsage = try await usageFixture.snapshots()
            let usageWindow = NSWindow(contentRect: NSRect(x: 150, y: 150, width: 760, height: 650), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            usageWindow.title = "RELAY API Usage — Fixture"
            usageWindow.contentView = NSHostingView(rootView: APIUsageSettings(model: self).frame(width: 760, height: 650))
            usageWindow.isReleasedWhenClosed = false; usageWindow.makeKeyAndOrderFront(nil)
            try? await Task.sleep(for: .milliseconds(400))
            try captureFixtureWindow(root.appendingPathComponent("api-usage.png"), window: usageWindow)
            usageWindow.close()
            showMatches = []; providerStatuses = []
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
    private func captureFixtureWindow(_ destination: URL, window: NSWindow? = nil) throws {
        if let parent = window ?? NSApp.windows.first(where: { $0.title == "RELAY" }),
           let image = CGWindowListCreateImage(.null, .optionIncludingWindow, CGWindowID((parent.attachedSheet ?? parent).windowNumber), [.boundsIgnoreFraming, .bestResolution]),
           let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) { try png.write(to: destination) }
    }
}
