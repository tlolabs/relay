import Foundation

/// Providers may search different files concurrently; catalog-wide requests
/// explicitly carry every participating clue instead of implying one file.
public struct DiscoverySearchActivity: Sendable {
    public var source: String
    public var clues: [String]
    public var detail: String
    public var finished: Bool

    public init(source: String, clues: [String], detail: String = "", finished: Bool = false) {
        self.source = source; self.clues = clues; self.detail = detail; self.finished = finished
    }
}

public typealias DiscoveryActivityHandler = @Sendable (DiscoverySearchActivity) async -> Void
