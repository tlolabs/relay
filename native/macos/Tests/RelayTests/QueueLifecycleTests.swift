import XCTest
import RelayKit
@testable import Relay

@MainActor
final class QueueLifecycleTests: XCTestCase {
    private func completedFixture(_ root: URL, policy: CompletedRetention) async throws -> RelayModel {
        let intake = root.appendingPathComponent("intake"), output = root.appendingPathComponent("output")
        try FileManager.default.createDirectory(at: intake, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try Data("input".utf8).write(to: intake.appendingPathComponent("Show - S01E01 - Episode.mp4"))
        let engine = try RelayEngine(database: root.appendingPathComponent("state/jobs.sqlite"))
        _ = try await engine.configure(RelayConfig(roots: [intake.path], recursive: false, outputFolder: output.path))
        let found: RelaySnapshot = try await engine.execute(["command": "discover"])
        let id = try XCTUnwrap(found.jobs.first?.id)
        let preview: BatchPreview = try await engine.execute(["command": "preview", "ids": [id]])
        let _: RelaySnapshot = try await engine.execute(["command": "start_batch", "token": preview.token])
        let finished = output.appendingPathComponent("Finished.mp4")
        try Data("output".utf8).write(to: finished)
        let _: RelaySnapshot = try await engine.execute(["command": "confirm_output", "id": id, "path": finished.path])
        let snapshot: RelaySnapshot = try await engine.execute(["command": "reconcile", "id": id])
        XCTAssertEqual(snapshot.jobs.first?.state, "complete")
        let preferences = try XCTUnwrap(UserDefaults(suiteName: "relay-queue-test-\(UUID().uuidString)"))
        preferences.set(policy.rawValue, forKey: "completedRetention")
        let model = RelayModel(preferences: preferences)
        model.smokeMode = true; model.engine = engine; model.snapshot = snapshot
        return model
    }

    func testKeepUntilQuitThenClearWithoutDeletingFilesOrReaddingOnScan() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = try await completedFixture(root, policy: .untilQuit)
        try await model.refresh()
        XCTAssertTrue(model.visibleJobs.isEmpty)
        model.group = "Completed"
        XCTAssertEqual(model.visibleJobs.count, 1)
        let input = try XCTUnwrap(model.jobs.first?.currentPath)
        let output = try XCTUnwrap(model.jobs.first?.outputPath)
        await model.close()
        XCTAssertNil(model.error)
        let reopened = try RelayEngine(database: root.appendingPathComponent("state/jobs.sqlite"))
        let snapshot: RelaySnapshot = try await reopened.execute(["command": "discover"])
        XCTAssertTrue(snapshot.jobs.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: input))
        XCTAssertTrue(FileManager.default.fileExists(atPath: output))
        await reopened.close()
    }

    func testRemoveImmediatelyAndPreferenceChangeClearFinishedEntries() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = try await completedFixture(root, policy: .untilQuit)
        model.group = "Completed"; model.selectedIds = Set(model.jobs.map(\.id)); model.loadDraft()
        XCTAssertEqual(model.visibleJobs.count, 1)
        model.preferences.set(CompletedRetention.removeImmediately.rawValue, forKey: "completedRetention")
        try await model.refresh()
        XCTAssertTrue(model.jobs.isEmpty)
        XCTAssertTrue(model.selectedIds.isEmpty)
        try await model.refresh(discover: true)
        XCTAssertTrue(model.jobs.isEmpty)
        await model.close()
    }

    func testNewSessionClearsPreviousCompletedEntriesAfterUncleanExit() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let previous = try await completedFixture(root, policy: .untilQuit)
        await previous.engine?.close(); previous.engine = nil // Simulated abrupt shutdown.
        let next = RelayModel(); await next.initialize(smokeRoot: root)
        XCTAssertNil(next.error)
        XCTAssertTrue(next.jobs.isEmpty)
        await next.close()
    }

    private func addUnfinishedEntries(to model: RelayModel, root: URL) async throws {
        let engine = try XCTUnwrap(model.engine)
        for name in ["Review", "Approved", "Failed"] {
            let path = root.appendingPathComponent("intake/\(name).mp4")
            try Data(name.utf8).write(to: path)
            let added: RelaySnapshot = try await engine.execute(["command": "direct_add", "path": path.path])
            let job = try XCTUnwrap(added.jobs.first { URL(fileURLWithPath: $0.currentPath).lastPathComponent == path.lastPathComponent }, "Expected \(path.path), got \(added.jobs.map(\.currentPath))")
            if name == "Failed" {
                let _: RelaySnapshot = try await engine.execute(["command": "direct_error", "id": job.id, "message": "Subtitle verification failed"])
            } else if name == "Approved" {
                var identity = MediaIdentity(); identity.kind = "tv"; identity.title = "Show"
                identity.season = 1; identity.episode = 2; identity.episodeTitle = "Approved"
                let _: RelaySnapshot = try await engine.execute(["command": "edit", "id": job.id, "revision": job.revision, "identity": RelayEngine.object(identity)])
                let preview: BatchPreview = try await engine.execute(["command": "preview", "ids": [job.id]])
                let _: RelaySnapshot = try await engine.execute(["command": "start_batch", "token": preview.token])
            }
        }
        model.snapshot = try await engine.snapshot()
        XCTAssertEqual(model.jobs.count, 4)
        XCTAssertEqual(model.jobCount(in: .processing), 2)
    }

    func testQuitClearsReviewApprovedFailedAndCompletedEntries() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = try await completedFixture(root, policy: .untilQuit)
        try await addUnfinishedEntries(to: model, root: root)
        let sources = model.jobs.map(\.currentPath)
        model.group = "Active"; model.selectedIds = Set(model.visibleJobs.map(\.id))
        // Simulate in-flight processing finishing its cancellation before close archives the queue.
        let engine = try XCTUnwrap(model.engine), id = try XCTUnwrap(model.visibleJobs.first?.id)
        model.processingTask = Task {
            do { try await Task.sleep(for: .seconds(10)) } catch {}
            let _: RelaySnapshot? = try? await engine.execute(["command": "direct_error", "id": id, "message": "Cancelled"])
        }
        await model.close()
        XCTAssertNil(model.error)
        XCTAssertTrue(model.jobs.isEmpty)
        XCTAssertTrue(model.selectedIds.isEmpty)
        XCTAssertFalse(model.hasOpenStore)
        XCTAssertFalse(model.enqueueVideos([URL(fileURLWithPath: sources[0])]))
        let reopened = try RelayEngine(database: root.appendingPathComponent("state/jobs.sqlite"))
        let snapshot: RelaySnapshot = try await reopened.execute(["command": "discover"])
        XCTAssertTrue(snapshot.jobs.isEmpty)
        XCTAssertTrue(snapshot.events.contains { $0.event == "queue_cleared" })
        for source in sources { XCTAssertTrue(FileManager.default.fileExists(atPath: source)) }
        await reopened.close()
    }

    func testNewSessionClearsEveryPreviousQueueStateAfterUncleanExit() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let previous = try await completedFixture(root, policy: .untilQuit)
        try await addUnfinishedEntries(to: previous, root: root)
        await previous.engine?.close(); previous.engine = nil
        let next = RelayModel(); await next.initialize(smokeRoot: root)
        XCTAssertNil(next.error)
        XCTAssertTrue(next.jobs.isEmpty)
        XCTAssertEqual(next.jobCount(in: .processing), 0)
        await next.close()
    }
}
