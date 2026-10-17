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

}
