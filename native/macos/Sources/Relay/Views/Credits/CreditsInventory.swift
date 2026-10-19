import Foundation

struct CreditsInventory: Decodable {
    let schemaVersion: Int
    let entries: [CreditEntry]
    let notices: [CreditNotice]
    let inspiration: CreditInspiration

    static func load(directory: URL) throws -> Self {
        let value = try JSONDecoder().decode(Self.self, from: Data(contentsOf: directory.appendingPathComponent("inventory.json")))
        guard value.schemaVersion == 1, !value.entries.isEmpty, !value.notices.isEmpty else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return value
    }
}

struct CreditEntry: Decodable, Identifiable {
    let id: String
    let name: String
    let url: URL
    let stat: String
    let notice: String
    let integrationLines: Int
    let indirect: String?
    let version: String?
    let components: [CreditLink]
    let logo: CreditLogo?

    var line: String {
        if let indirect {
            return "No extra integration lines—\(indirect) brings this helper along."
        }
        return stat.replacingOccurrences(of: "{count}", with: integrationLines.formatted())
    }
    var domain: String { url.host() ?? url.absoluteString }
}

struct CreditLink: Decodable {
    let name: String
    let url: URL
}

struct CreditLogo: Decodable {
    let file: String
    let source: String
    let terms: String
    let sha256: String
    let backdrop: String?
}

struct CreditNotice: Decodable, Identifiable {
    let id: String
    let name: String
    let text: String
    let source: String
}

struct CreditInspiration: Decodable {
    let name: String
    let url: URL
    let text: String
}

/// Pure playback state. The view supplies monotonic elapsed time only while
/// visible, active and free from pointer/keyboard interaction.
struct CreditsPlayback {
    private(set) var position: Double = 0
    private(set) var delay: Double = 2
    private(set) var completed = false
    var paused = false

    func shouldRun(visible: Bool, active: Bool, staticMode: Bool, interacting: Bool, maximum: Double) -> Bool {
        maximum > 0 && visible && active && !staticMode && !interacting && !paused && !completed
    }

    mutating func replay(staticMode: Bool) {
        position = 0
        delay = 2
        completed = false
        paused = staticMode
    }

    mutating func manualScroll(to position: Double) {
        self.position = max(0, position)
        paused = true
        completed = false
    }

    mutating func advance(seconds: Double, maximum: Double) {
        guard !paused, !completed, seconds.isFinite, seconds > 0, maximum > 0 else { return }
        let waiting = min(delay, seconds)
        delay -= waiting
        position = min(maximum, position + (seconds - waiting) * 18)
        if position >= maximum { completed = true }
    }
}
