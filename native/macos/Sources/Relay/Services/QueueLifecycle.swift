import Foundation
import RelayKit

extension RelayModel {
    var completedRetention: CompletedRetention {
        CompletedRetention(rawValue: preferences.string(forKey: "completedRetention") ?? "") ?? .untilQuit
    }

    func clearCompletedEntries() async throws {
        guard let engine else { return }
        snapshot = try await engine.execute(["command": "clear_completed"])
        selectedIds.formIntersection(Set(visibleJobs.map(\.id)))
        if selectedJob?.id != editingId { loadDraft() }
    }

    func clearQueueEntries() async throws {
        guard let engine else { return }
        snapshot = try await engine.execute(["command": "clear_queue"])
        selectedIds = []; editingId = nil
        preview = nil; presentingPreview = false
        folderSuggestions = [:]; matchConfidence = [:]
    }
}
