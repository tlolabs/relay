import Foundation

enum CompletedRetention: String, CaseIterable, Identifiable {
    case untilQuit
    case removeImmediately

    var id: String { rawValue }
    var title: String {
        switch self {
        case .untilQuit: return "Keep in Completed until quit"
        case .removeImmediately: return "Remove immediately"
        }
    }
}
