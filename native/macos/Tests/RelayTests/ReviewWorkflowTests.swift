import XCTest
import RelayKit
@testable import Relay

@MainActor
final class ReviewWorkflowTests: XCTestCase {
    private func model() throws -> RelayModel {
        let jobs: [[String: Any]] = ["a", "b"].enumerated().map { index, id in
            ["id": id, "originalPath": "/tmp/\(id).mp4", "currentPath": "/tmp/\(id).mp4",
             "fingerprint": ["device": 1, "inode": index + 1, "size": 1, "modifiedNs": "1"],
             "identity": ["episodeTitle": id], "subtitles": [], "included": true,
             "revision": 1, "state": "needs_review", "message": "", "createdMs": 1, "updatedMs": 1]
        }
        let data = try JSONSerialization.data(withJSONObject: ["version": "0.1.0", "jobs": jobs, "events": [], "recentIdentities": []])
        let model = RelayModel()
        model.smokeMode = true
        model.snapshot = try JSONDecoder().decode(RelaySnapshot.self, from: data)
        model.selectedIds = ["a"]; model.loadDraft()
        return model
    }
    func testSwitchingRowsProtectsUnsavedReview() async throws {
        let model = try model()
        model.draft.title = "Unsaved show"
        model.selectJobs(["b"])
        XCTAssertEqual(model.selectedIds, ["a"])
        XCTAssertEqual(model.pendingSelection, ["b"])
        XCTAssertTrue(model.confirmingNavigation)
        XCTAssertEqual(model.draft.title, "Unsaved show")
        await model.finishNavigation(saving: false)
        XCTAssertEqual(model.selectedIds, ["b"])
    }
    func testAddingSelectionRetainsCurrentEditorAndDraft() async throws {
        let model = try model()
        model.draft.title = "Unsaved show"
        model.selectJobs(["a", "b"])
        XCTAssertEqual(model.selectedJob?.id, "a")
        XCTAssertFalse(model.confirmingNavigation)
        XCTAssertTrue(model.hasUnsavedChanges)
    }
    func testSwitchingGroupsProtectsUnsavedReview() async throws {
        let model = try model()
        model.draft.title = "Unsaved show"
        model.selectJobs([], in: "Completed")
        XCTAssertEqual(model.group, "Queue")
        XCTAssertEqual(model.pendingGroup, "Completed")
        XCTAssertEqual(model.selectedIds, ["a"])
    }
    func testFolderSearchSurvivesRowSelection() async throws {
        let model = try model()
        model.folderSearchInProgress = true; model.catalogBusy = true
        let request = model.catalogRequest
        model.catalogMessage = "Searching every downloaded title…"
        model.selectJobs(["b"]); model.loadDraft()
        XCTAssertEqual(model.catalogRequest, request)
        XCTAssertTrue(model.catalogBusy)
        XCTAssertTrue(model.folderSearchInProgress)
        XCTAssertEqual(model.catalogMessage, "Searching every downloaded title…")
        model.cancelCatalogSearch()
        XCTAssertFalse(model.catalogBusy)
        XCTAssertFalse(model.folderSearchInProgress)
        XCTAssertNotEqual(model.catalogRequest, request)
    }
    func testInitialFolderSearchIncludesExcludedRowsAndNeedsNoSelection() async throws {
        let model = try model()
        model.selectedIds = []; model.loadDraft()
        model.snapshot?.jobs[1].included = false
        model.smokeMode = false
        model.beginFolderSearchIfNeeded()
        XCTAssertTrue(model.folderSearchInProgress)
        XCTAssertEqual(model.folderSearchSignature?.count, 2)
        let task = try XCTUnwrap(model.catalogTask)
        model.cancelCatalogSearch()
        await task.value // Cancel before the task starts: no live API or Keychain access.
        XCTAssertFalse(model.catalogBusy)
    }
    func testEmptyInventoryReportsCompletionWithoutStartingLookup() async throws {
        let model = try model()
        model.snapshot?.jobs = []
        model.smokeMode = false
        model.beginFolderSearchIfNeeded()
        XCTAssertTrue(model.folderSearchSummary.contains("Found 0 videos"))
        XCTAssertFalse(model.folderSearchInProgress)
        XCTAssertNil(model.catalogTask)
    }
    func testQueueEmptyStateDistinguishesScanAndFilters() throws {
        let model = try model()
        model.snapshot?.jobs = []
        XCTAssertEqual(model.queueEmptyTitle, "Your queue is empty")
        model.scanning = true
        XCTAssertEqual(model.queueEmptyTitle, "Scanning folders…")
        model.scanning = false
        model.snapshot = try JSONDecoder().decode(RelaySnapshot.self, from: Data(#"{"version":"0.2.0","jobs":[],"events":[],"recentIdentities":[],"scan":{"videoCount":0,"completedMs":1}}"#.utf8))
        XCTAssertEqual(model.queueEmptyTitle, "No videos found")
        model.group = "Completed"
        XCTAssertEqual(model.queueEmptyTitle, "No completed videos")
        model.group = "Active"
        XCTAssertEqual(model.queueEmptyTitle, "No videos processing")
        model.group = "Suggested"
        XCTAssertEqual(model.queueEmptyTitle, "No suggested matches")
        model.group = "Matched"
        XCTAssertEqual(model.queueEmptyTitle, "No matched videos")
        model.group = "Unidentified"
        XCTAssertEqual(model.queueEmptyTitle, "No unidentified videos")
    }
    func testQueueFiltersSeparateSuggestionsSavedMatchesAndFinishedVideos() throws {
        let model = try model()
        var unknown = model.jobs[0]; unknown.id = "unknown"
        var partial = unknown; partial.id = "partial"; partial.identity.kind = "movie"; partial.identity.title = "Movie"
        var matched = partial; matched.id = "matched"; matched.identity.year = 2024
        var proposed = unknown; proposed.id = "proposed"
        var active = matched; active.id = "active"; active.state = "direct_processing"
        var completed = matched; completed.id = "completed"; completed.state = "complete"
        var failed = matched; failed.id = "failed"; failed.state = "direct_failed"
        model.snapshot?.jobs = [unknown, partial, matched, proposed, active, completed, failed]
        model.folderSuggestions[proposed.id] = matched.identity
        model.selectedIds = []; model.loadDraft()
        let expected: [QueueFilter: Set<String>] = [
            .queue: ["unknown", "partial", "matched", "proposed"],
            .unidentified: ["unknown"], .suggested: ["partial", "proposed"],
            .matched: ["matched"], .processing: ["active", "failed"], .completed: ["completed"]
        ]
        for filter in QueueFilter.allCases {
            model.selectJobs([], in: filter.rawValue)
            XCTAssertEqual(Set(model.visibleJobs.map(\.id)), expected[filter])
            XCTAssertEqual(model.jobCount(in: filter), expected[filter]?.count)
        }
        model.selectJobs([], in: "Suggested")
        XCTAssertTrue(model.queueStatusLabel(for: proposed).hasPrefix("Suggested"))
        XCTAssertEqual(model.jobs.first { $0.id == proposed.id }?.identity.title, "", "Suggestions must not save an identity")
        model.snapshot?.jobs[3].identity = matched.identity
        XCTAssertEqual(Set(model.visibleJobs.map(\.id)), ["partial"])
        model.selectJobs([], in: "Matched")
        XCTAssertEqual(Set(model.visibleJobs.map(\.id)), ["matched", "proposed"])
        model.snapshot?.jobs[2].state = "complete"
        model.selectJobs([], in: "Queue")
        XCTAssertFalse(model.visibleJobs.contains { $0.id == "matched" })
        model.selectJobs([], in: "Completed")
        XCTAssertEqual(Set(model.visibleJobs.map(\.id)), ["matched", "completed"])
        XCTAssertTrue(model.reviewIds.isEmpty)
    }
    func testMatchedFilterRequiresCompleteMovieOrTVIdentity() throws {
        let model = try model()
        var job = model.jobs[0]
        job.identity.kind = "tv"; job.identity.title = "Show"; job.identity.season = 0
        XCTAssertEqual(QueueFilter.identityFilter(for: job, suggestion: nil), .suggested)
        job.identity.episode = 0
        XCTAssertEqual(QueueFilter.identityFilter(for: job, suggestion: nil), .suggested)
        job.identity.episode = 1
        XCTAssertEqual(QueueFilter.identityFilter(for: job, suggestion: nil), .matched)
        job.identity.kind = "movie"
        XCTAssertEqual(QueueFilter.identityFilter(for: job, suggestion: nil), .suggested)
        job.identity.year = 2025
        XCTAssertEqual(QueueFilter.identityFilter(for: job, suggestion: nil), .matched)
        job.identity.year = 0
        XCTAssertEqual(QueueFilter.identityFilter(for: job, suggestion: nil), .suggested)
        job.identity.title = "  "
        XCTAssertEqual(QueueFilter.identityFilter(for: job, suggestion: nil), .unidentified)
    }
    func testSwitchingQueueFilterProtectsUnsavedIdentity() async throws {
        let model = try model()
        model.draft.title = "Unsaved title"
        model.selectJobs([], in: QueueFilter.suggested.rawValue)
        XCTAssertEqual(model.queueFilter, .queue)
        XCTAssertEqual(model.pendingGroup, "Suggested")
        XCTAssertEqual(model.selectedIds, ["a"])
        await model.finishNavigation(saving: false)
        XCTAssertEqual(model.queueFilter, .suggested)
        XCTAssertTrue(model.selectedIds.isEmpty)
    }
    func testRemovalRequiresAVisibleSelectionWithNoApprovedWork() throws {
        let model = try model()
        XCTAssertTrue(model.canRemoveSelectedJobs)
        model.selectedIds = []
        XCTAssertFalse(model.canRemoveSelectedJobs)
        model.selectedIds = ["a", "b"]
        model.snapshot?.jobs[1].state = "direct_processing"
        XCTAssertTrue(model.canRemoveSelectedJobs, "Processing rows have left Queue; only visible reviews are removed")
        model.group = "Active"
        XCTAssertFalse(model.canRemoveSelectedJobs)
        model.group = "Review"
        XCTAssertTrue(model.canRemoveSelectedJobs, "Only visible selected rows are removed")
        model.busy = true
        XCTAssertFalse(model.canRemoveSelectedJobs)
    }
    func testRemoveSelectionSavesDraftAndKeepsSourceFiles() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let intake = root.appendingPathComponent("intake")
        let output = root.appendingPathComponent("output")
        try FileManager.default.createDirectory(at: intake, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["First", "Second"] {
            try Data("fixture".utf8).write(to: intake.appendingPathComponent("\(name).mp4"))
        }
        let engine = try RelayEngine(database: root.appendingPathComponent("state/jobs.sqlite"))
        _ = try await engine.configure(RelayConfig(roots: [intake.path], recursive: false, outputFolder: output.path))
        let model = RelayModel(); model.smokeMode = true; model.engine = engine
        try await model.refresh(discover: true)
        model.group = "Unidentified"
        model.selectedIds = Set(model.jobs.map(\.id)); model.loadDraft()
        let selectedPath = try XCTUnwrap(model.selectedJob?.currentPath)
        model.draft.title = "Saved before removal"
        await model.removeSelectedJobs()
        XCTAssertNil(model.error)
        XCTAssertTrue(model.jobs.isEmpty)
        XCTAssertTrue(model.selectedIds.isEmpty)
        XCTAssertNil(model.editingId)
        XCTAssertFalse(model.canRemoveSelectedJobs)
        try await model.refresh(discover: true)
        XCTAssertTrue(model.jobs.isEmpty, "A watched-folder scan must not re-add removed files")
        XCTAssertEqual(model.snapshot?.scan?.videoCount, 2)
        let restored: RelaySnapshot = try await engine.execute(["command": "direct_add", "path": selectedPath])
        XCTAssertEqual(restored.jobs.first?.identity.title, "Saved before removal")
        XCTAssertTrue(FileManager.default.fileExists(atPath: intake.appendingPathComponent("First.mp4").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: intake.appendingPathComponent("Second.mp4").path))
        await engine.close()
    }
    func testSavingAMatchMovesItOutOfUnidentifiedAndClearsSelection() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let intake = root.appendingPathComponent("intake")
        let output = root.appendingPathComponent("output")
        try FileManager.default.createDirectory(at: intake, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("fixture".utf8).write(to: intake.appendingPathComponent("Unknown.mp4"))
        let engine = try RelayEngine(database: root.appendingPathComponent("state/jobs.sqlite"))
        _ = try await engine.configure(RelayConfig(roots: [intake.path], recursive: false, outputFolder: output.path))
        let model = RelayModel(); model.smokeMode = true; model.engine = engine; model.group = "Unidentified"
        try await model.refresh(discover: true)
        model.selectedIds = Set(model.jobs.map(\.id)); model.loadDraft()
        model.draft.kind = "movie"; model.draft.title = "Saved match"; model.draft.year = 2025
        await model.persistDraft()
        XCTAssertNil(model.error)
        XCTAssertTrue(model.visibleJobs.isEmpty)
        XCTAssertTrue(model.selectedIds.isEmpty)
        XCTAssertEqual(model.jobCount(in: .matched), 1)
        model.selectJobs([], in: "Matched")
        XCTAssertEqual(model.visibleJobs.first?.identity.title, "Saved match")
        XCTAssertEqual(model.reviewIds.count, 1, "The departed selection must not block processing other rows")
        await engine.close()
    }
    func testFolderSuggestionsSortWithoutEditingStoredIdentity() async throws {
        let model = try model()
        let data = Data(#"{"title":{"id":1,"name":"Show"},"episodes":[{"id":1,"name":"a","seasonNumber":1,"episodeNumber":10},{"id":2,"name":"b","seasonNumber":1,"episodeNumber":2}]}"#.utf8)
        model.folderCatalogs = [try JSONDecoder().decode(TVSeriesCatalog.self, from: data)]
        model.rebuildFolderSuggestions()
        XCTAssertEqual(model.visibleJobs.map(\.id), ["b", "a"])
        XCTAssertEqual(model.jobs.first?.identity.title, "")
        XCTAssertEqual(model.selectedJob?.id, "a", "Background sorting must not change the current editor")
        XCTAssertFalse(model.hasUnsavedChanges)
        let proposed = try XCTUnwrap(model.suggestedIdentity(for: model.jobs[0]))
        model.useFolderSuggestion(proposed)
        XCTAssertEqual(model.draft.episode, 10)
        XCTAssertEqual(model.jobs[0].identity.title, "")
        XCTAssertTrue(model.hasUnsavedChanges)
    }

    func testSearchActivityFollowsFilesAcrossSelectionAndRejectsOldCallbacks() throws {
        let model = try model()
        model.catalogBusy = true; model.folderSearchInProgress = true
        model.searchJobClues = ["a": "a", "b": "b"]
        model.searchFileNames = ["a": "a.mp4", "b": "b.mp4"]
        let request = model.catalogRequest
        model.updateSearchActivity(.init(source: "Trakt", clues: ["a"]), request: request)
        model.updateSearchActivity(.init(source: "OMDb", clues: ["b"]), request: request)
        XCTAssertEqual(model.searchingFiles, ["a.mp4", "b.mp4"])
        XCTAssertEqual(model.searchSources(for: model.jobs[0]), ["Trakt"])
        model.selectJobs(["b"]); model.loadDraft()
        XCTAssertEqual(model.searchSources(for: model.jobs[0]), ["Trakt"])
        model.updateSearchActivity(.init(source: "Trakt", clues: ["b"]), request: request)
        XCTAssertEqual(model.searchSources(for: model.jobs[0]), [])
        XCTAssertEqual(model.searchSources(for: model.jobs[1]), ["OMDb", "Trakt"])
        model.cancelCatalogSearch()
        model.updateSearchActivity(.init(source: "Trakt", clues: ["a"]), request: request)
        XCTAssertTrue(model.activeSearches.isEmpty)
        XCTAssertTrue(model.searchingFiles.isEmpty)
    }
    func testPendingSourceCleanupStaysInProcessingInsteadOfCompleted() throws {
        let model = try model()
        var job = model.jobs[0]
        job.state = "complete"
        var direct = DirectDraft(); direct.backend = true; direct.trashSource = true
        job.direct = direct
        XCTAssertTrue(job.needsAttention)
        XCTAssertFalse(QueueFilter.completed.includes(job, suggestion: nil))
        XCTAssertTrue(QueueFilter.processing.includes(job, suggestion: nil))
        XCTAssertFalse(QueueFilter.queue.includes(job, suggestion: nil))
        direct.trashPath = "macOS Trash"; job.direct = direct
        XCTAssertTrue(QueueFilter.completed.includes(job, suggestion: nil))
        XCTAssertFalse(QueueFilter.processing.includes(job, suggestion: nil))
    }

    func testManualIdentityChangeCannotInheritAutomaticConfidence() throws {
        let model = try model()
        var identity = MediaIdentity()
        identity.kind = "tv"; identity.title = "Automatic show"; identity.season = 1; identity.episode = 2
        model.matchConfidence["a"] = MatchConfidence(score: 95, candidate: identity.display, reasons: ["Sources agree"], identity: identity)
        XCTAssertEqual(model.confidence(for: model.jobs[0])?.score, 95)
        model.draft = identity
        XCTAssertEqual(model.confidence(for: model.jobs[0])?.score, 95)
        model.draft.episode = 3
        XCTAssertEqual(model.confidence(for: model.jobs[0])?.score, 0)
        XCTAssertTrue(model.confidence(for: model.jobs[0])?.explanation.contains("current identity differs") == true)
    }

}
