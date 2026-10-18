import Foundation
import RelayKit

enum QueueFilter: String, CaseIterable, Identifiable {
    case queue = "Queue"
    case unidentified = "Unidentified"
    case suggested = "Suggested"
    case matched = "Matched"
    case processing = "Active"
    case completed = "Completed"

    var id: String { rawValue }
    var title: String { self == .processing ? "Processing" : rawValue }
    var description: String {
        switch self {
        case .queue: return "Videos awaiting review. Approved videos move to Processing."
        case .unidentified: return "Videos that still need an identity or a suggested match."
        case .suggested: return "Proposed or partial identities awaiting a complete saved match."
        case .matched: return "Complete saved identities, ready for your processing review."
        case .processing: return "Approved jobs, processing, and work needing recovery."
        case .completed: return "Finished videos from this session. Cleared when RELAY quits."
        }
    }

    func includes(_ job: RelayJob, suggestion: MediaIdentity?) -> Bool {
        switch self {
        case .queue: return job.editable
        case .processing: return !job.editable && (job.state != "complete" || job.needsAttention)
        case .completed: return job.state == "complete" && !job.needsAttention
        case .unidentified, .suggested, .matched:
            return job.editable && Self.identityFilter(for: job, suggestion: suggestion) == self
        }
    }

    static func identityFilter(for job: RelayJob, suggestion: MediaIdentity?) -> QueueFilter {
        let identity = job.identity
        let title = identity.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let validYear = identity.year.map { (1880...2200).contains($0) } ?? true
        let complete: Bool
        switch identity.kind {
        case "movie": complete = identity.year != nil
        case "tv": complete = identity.season.map { (0...10000).contains($0) } == true
            && identity.episode.map { (1...100000).contains($0) } == true
        default: complete = false
        }
        if !title.isEmpty && validYear && complete { return .matched }
        return !title.isEmpty || suggestion != nil ? .suggested : .unidentified
    }
}
