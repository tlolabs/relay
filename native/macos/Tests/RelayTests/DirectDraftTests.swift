import XCTest
import RelayKit
@testable import Relay

@MainActor final class DirectDraftTests: XCTestCase {
    func testDraftsClearAndOnlyChangedFieldsPropagateAcrossSelection() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root.appendingPathComponent("intake"),withIntermediateDirectories:true)
        try FileManager.default.createDirectory(at:root.appendingPathComponent("output"),withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:root) }
        for name in ["First","Second"] { try Data("fixture".utf8).write(to:root.appendingPathComponent("intake/\(name).mp4")) }
        let engine=try RelayEngine(database:root.appendingPathComponent("state/jobs.sqlite"))
        _ = try await engine.configure(RelayConfig(roots:[root.appendingPathComponent("intake").path],recursive:false,outputFolder:root.appendingPathComponent("output").path))
        let state: RelaySnapshot=try await engine.execute(["command":"discover"])
        for (index,job) in state.jobs.enumerated() {
            var direct=DirectDraft();direct.metadata=["description":"Keep \(index)","studio":"Studio \(index)"]
            let _: RelaySnapshot=try await engine.execute(["command":"edit","id":job.id,"revision":job.revision,"direct":RelayEngine.object(direct)])
        }
        let model=RelayModel();model.smokeMode=true;model.engine=engine;model.snapshot=try await engine.snapshot()
        model.selectedIds=Set(model.jobs.map(\.id));model.loadDraft()
        model.draftDirect.metadata["description"]="";model.draftDirect.overrides.insert("description")
        await model.persistDraft()
        let saved=try await engine.snapshot()
        XCTAssertTrue(saved.jobs.allSatisfy { $0.options.metadata["description"] == "" && $0.options.overrides.contains("description") })
        XCTAssertEqual(Set(saved.jobs.compactMap { $0.options.metadata["studio"] }),["Studio 0","Studio 1"])
        XCTAssertFalse(model.hasUnsavedChanges)
        // An explicit clear must propagate even when the first selected value
        // is already empty and already has a saved manual override.
        let other = saved.jobs.first { $0.id != model.editingId }!
        var otherDraft = other.options; otherDraft.metadata["description"] = "Different"
        let _: RelaySnapshot = try await engine.execute(["command":"edit","id":other.id,"revision":other.revision,"direct":RelayEngine.object(otherDraft)])
        model.snapshot = try await engine.snapshot(); model.loadDraft()
        XCTAssertTrue(model.metadataFieldIsMixed("description"))
        model.editMetadataField("description", value: "")
        model.draftDirect.streaming = false
        XCTAssertTrue(model.hasUnsavedChanges)
        XCTAssertFalse(model.metadataFieldIsMixed("description"))
        await model.persistDraft()
        let cleared = try await engine.snapshot()
        XCTAssertTrue(cleared.jobs.allSatisfy { $0.options.metadata["description"] == "" && !$0.options.streaming })
        XCTAssertEqual(Set(cleared.jobs.compactMap { $0.options.metadata["studio"] }),["Studio 0","Studio 1"])
        XCTAssertFalse(model.hasUnsavedChanges)
        let yearJob = cleared.jobs.first { $0.id != model.editingId }!
        var withYear = yearJob.identity; withYear.year=2024
        let _: RelaySnapshot = try await engine.execute(["command":"edit","id":yearJob.id,"revision":yearJob.revision,"identity":RelayEngine.object(withYear)])
        model.snapshot = try await engine.snapshot(); model.loadDraft()
        model.draft.year=nil; model.markIdentityFieldEdited("year")
        await model.persistDraft()
        let years = try await engine.snapshot()
        XCTAssertTrue(years.jobs.allSatisfy { $0.identity.year == nil })
        XCTAssertFalse(model.hasUnsavedChanges)
        // Details and the final approval must use the same naming semantics,
        // including an intentionally empty suffix and a reset filename.
        let previewJob = try XCTUnwrap(model.selectedJob)
        model.draft.kind="movie";model.draft.title="Example";model.draft.year=2025
        model.draftDirect.filename="";model.draftDirect.metadata["comment"]="";model.draftDirect.overrides.insert("comment")
        XCTAssertEqual(URL(fileURLWithPath:model.plannedOutput(previewJob)).lastPathComponent,"Example (2025)-.mp4")
        model.draftDirect.filename="Exact Name.mp4"
        XCTAssertEqual(URL(fileURLWithPath:model.plannedOutput(previewJob)).lastPathComponent,"Exact Name.mp4")
        model.draftDirect.filename="";model.draftDirect.overrides.remove("comment");model.draftDirect.metadata["comment"]="Information courtesy of a provider"
        XCTAssertEqual(URL(fileURLWithPath:model.plannedOutput(previewJob)).lastPathComponent,"Example (2025)-SD H.264 DL.mp4")
        model.draft.kind="tv";model.draft.title="Series";model.draft.year=2019;model.draft.includeYear=false;model.draft.season=0;model.draft.episode=7;model.draft.episodeTitle="First: Part/Two"
        XCTAssertEqual(URL(fileURLWithPath:model.plannedOutput(previewJob)).lastPathComponent,"Series – s00e07 – First Part Two-SD H.264 DL.mp4")
        model.draft.includeYear=true
        XCTAssertEqual(URL(fileURLWithPath:model.plannedOutput(previewJob)).lastPathComponent,"Series (2019) – s00e07 – First Part Two-SD H.264 DL.mp4")
        await engine.close()
        let reopened=try RelayEngine(database:root.appendingPathComponent("state/jobs.sqlite"))
        let restored=try await reopened.snapshot()
        XCTAssertTrue(restored.jobs.allSatisfy { $0.options.metadata["description"] == "" && $0.options.overrides.contains("description") })
        await reopened.close()
    }
    func testStandaloneDefaultFoldersDoNotRequireIFlicksDirectory() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let downloads = home.appendingPathComponent("Downloads", isDirectory: true)
        let movies = home.appendingPathComponent("Movies", isDirectory: true)
        try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: movies, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let suiteName = "com.tlolabs.relay.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        // Even without ~/Movies/iFlicks 3, standalone defaults resolve to ~/Downloads and ~/Movies.
        XCTAssertEqual(RelayModel.defaultIntakeRoots(home: home, defaults: defaults), [downloads.path])
        XCTAssertEqual(RelayModel.defaultOutputFolder(home: home, defaults: defaults), movies.path)

        // Missing saved directories fall back cleanly to existing standalone directories.
        defaults.set([home.appendingPathComponent("MissingIntake").path], forKey: "intakeRoots")
        defaults.set(home.appendingPathComponent("Movies/iFlicks 3").path, forKey: "outputFolder")
        XCTAssertEqual(RelayModel.defaultIntakeRoots(home: home, defaults: defaults), [downloads.path])
        XCTAssertEqual(RelayModel.defaultOutputFolder(home: home, defaults: defaults), movies.path)
    }

    func testPosterCacheCapacityAndEviction() {
        let model = RelayModel()
        for i in 0..<60 {
            model.cachePoster(Data("data-\(i)".utf8), for: "https://example.com/poster-\(i).jpg")
        }
        XCTAssertEqual(model.cachedPosterCount, 50)
        XCTAssertNil(model.cachedPoster(for: "https://example.com/poster-0.jpg"))
        XCTAssertNil(model.cachedPoster(for: "https://example.com/poster-9.jpg"))
        XCTAssertNotNil(model.cachedPoster(for: "https://example.com/poster-10.jpg"))
        XCTAssertNotNil(model.cachedPoster(for: "https://example.com/poster-59.jpg"))

        model.clearPosterCache()
        XCTAssertEqual(model.cachedPosterCount, 0)
        XCTAssertEqual(model.cachedPosterBytes, 0)
    }

}
