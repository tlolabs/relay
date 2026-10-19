import AppKit
import Observation
import SwiftUI
import XCTest
import RelayKit
@testable import Relay

@MainActor final class AutosaveObservationTests: XCTestCase {
    private func fixture() async throws -> (URL, RelayModel, RelayEngine) {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let intake = root.appendingPathComponent("intake"), output = root.appendingPathComponent("output")
        try FileManager.default.createDirectory(at: intake, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        // Minimal readable MP4 headers, matching the metadata workflow fixtures.
        var bytes = Data([0, 0, 0, 8]) + Data("ftyp".utf8) + Data([0, 0, 0, 116]) + Data("moov".utf8) + Data([0, 0, 0, 108]) + Data("mvhd".utf8)
        bytes.append(Data(repeating: 0, count: 100))
        bytes.replaceSubrange(36..<40, with: [0, 0, 0, 1])
        bytes.append(Data([0, 0, 0, 9]) + Data("mdat".utf8) + Data([0]))
        for index in 1...3 { try bytes.write(to: intake.appendingPathComponent("Movie \(index).mp4")) }
        let engine = try RelayEngine(database: root.appendingPathComponent("state/jobs.sqlite"))
        _ = try await engine.configure(RelayConfig(roots: [intake.path], recursive: false, outputFolder: output.path))
        let discovered: RelaySnapshot = try await engine.execute(["command": "discover"])
        let inspection = try JSONDecoder().decode(MediaInspection.self, from: Data(#"{"streams":[],"chapters":[],"ruleMedia":[],"duration":1}"#.utf8))
        for (index, job) in discovered.jobs.enumerated() {
            var identity = job.identity; identity.kind = "movie"; identity.title = "Title \(index)"
            var options = job.options; options.metadata = ["description": "Plot \(index)", "studio": "Studio \(index)"]
            let state: RelaySnapshot = try await engine.execute(["command": "edit", "id": job.id, "revision": job.revision,
                "identity": RelayEngine.object(identity), "direct": RelayEngine.object(options)])
            let edited = try XCTUnwrap(state.jobs.first { $0.id == job.id })
            let _: RelayJob = try await engine.execute(["command": "direct_inspect", "id": job.id, "revision": edited.revision,
                "inspection": RelayEngine.object(inspection)])
        }
        let model = RelayModel(metadataToken: { "" }, plexToken: { "" })
        model.engine = engine; model.databaseURL = root.appendingPathComponent("state/jobs.sqlite")
        model.snapshot = try await engine.snapshot()
        return (root, model, engine)
    }

    private func host(_ model: RelayModel) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: Color.clear.modifier(DraftAutosaveObservation(model: model)))
        window.orderBack(nil)
        return window
    }

    private func waitUntil(_ condition: () async throws -> Bool) async throws {
        let deadline = Date().addingTimeInterval(4)
        while !(try await condition()) {
            guard Date() < deadline else { XCTFail("Timed out waiting for real autosave/selection"); return }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    func testDeferredSwiftUIChangesDoNotSaveLoadedDraftsButDoSaveUserEdits() async throws {
        let (root, model, engine) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let window = host(model); defer { window.close() }
        try await Task.sleep(for: .milliseconds(80))
        let ids = model.visibleJobs.map(\.id)
        let original = Dictionary(uniqueKeysWithValues: model.jobs.map { ($0.id, $0.revision) })
        model.selectJobs([ids[0]])
        try await waitUntil { model.editingId == ids[0] }
        model.selectJobs([ids[1]])
        try await waitUntil { model.editingId == ids[1] }
        try await Task.sleep(for: .milliseconds(650))
        let unchanged = try await engine.snapshot()
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: unchanged.jobs.map { ($0.id, $0.revision) }), original)
        XCTAssertNil(model.autosaveTask, "Loading a stable draft must not schedule a write")
        model.draft.title = "Typed through the observed editor"
        try await waitUntil {
            guard !model.savingDraft, !model.hasUnsavedChanges else { return false }
            return try await engine.snapshot().jobs.first { $0.id == ids[1] }?.identity.title == "Typed through the observed editor"
        }
        XCTAssertFalse(model.hasUnsavedChanges)
        model.autosaveTask?.cancel()
        await engine.close()
    }

    func testSelectionDuringWriteKeepsLateEditsAndHonorsLatestRequestedRow() async throws {
        let (root, model, engine) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let ids = model.visibleJobs.map(\.id)
        model.selectedIds = [ids[0]]; model.loadDraft()
        model.draft.title = "Saved before leaving"
        var sawInFlightWrite = false
        withObservationTracking { _ = model.savingDraft } onChange: {
            Task { @MainActor in
                sawInFlightWrite = model.savingDraft
                model.editMetadataField("description", value: "Late edit during write")
                var navigation = QueueGridSelection()
                navigation.reconcile(in: ids, selected: model.requestedQueueSelection)
                model.selectJobs(navigation.move(by: 1, in: ids, selected: model.requestedQueueSelection, extending: false))
                model.selectJobs(navigation.move(by: 1, in: ids, selected: model.requestedQueueSelection, extending: false))
                XCTAssertEqual(model.requestedQueueSelection, [ids[2]])
            }
        }
        await model.persistDraft()
        try await waitUntil { model.editingId == ids[2] && model.selectionTask == nil }
        XCTAssertTrue(sawInFlightWrite)
        let state = try await engine.snapshot()
        let saved = try XCTUnwrap(state.jobs.first { $0.id == ids[0] })
        XCTAssertEqual(saved.identity.title, "Saved before leaving")
        XCTAssertEqual(saved.options.metadata["description"], "Late edit during write")
        XCTAssertEqual(model.selectedIds, [ids[2]])
        XCTAssertFalse(model.confirmingNavigation)
        model.autosaveTask?.cancel()
        await engine.close()
    }

    func testObservedExplicitClearAndAutomaticMetadataPreserveOtherRows() async throws {
        let (root, model, engine) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let window = host(model); defer { window.close() }
        try await Task.sleep(for: .milliseconds(80)) // Install SwiftUI's initial observation first.
        model.selectJobs(Set(model.jobs.map(\.id)))
        try await waitUntil { model.editingId != nil }
        let studios = Set(model.jobs.compactMap { $0.options.metadata["studio"] })
        let editing = try XCTUnwrap(model.editingId)
        model.editMetadataField("description", value: "")
        model.mergeMetadata(FullCatalogMetadata(fields: ["actors": "Fetched for this movie"]))
        try await waitUntil {
            guard !model.savingDraft, !model.hasUnsavedChanges else { return false }
            return try await engine.snapshot().jobs.allSatisfy { $0.options.metadata["description"] == "" }
        }
        let saved = try await engine.snapshot()
        XCTAssertEqual(Set(saved.jobs.compactMap { $0.options.metadata["studio"] }), studios)
        XCTAssertEqual(saved.jobs.first { $0.id == editing }?.options.metadata["actors"], "Fetched for this movie")
        XCTAssertTrue(saved.jobs.filter { $0.id != editing }.allSatisfy { $0.options.metadata["actors"] == nil })
        XCTAssertTrue(saved.jobs.allSatisfy { $0.options.overrides.contains("description") && $0.approvedRevision == nil })
        model.autosaveTask?.cancel()
        await engine.close()
    }
}
