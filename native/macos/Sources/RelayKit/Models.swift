import Foundation

public struct MediaIdentity: Codable, Equatable, Sendable {
    public var kind = ""
    public var title = ""
    public var year: Int?
    public var season: Int?
    public var episode: Int?
    public var episodeTitle = ""
    public var tmdbId: UInt64?
    public var releaseDate: String?
    public var includeYear = false
    public init() {}
    enum CodingKeys: String, CodingKey { case kind, title, year, season, episode, episodeTitle, tmdbId, releaseDate, includeYear }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        kind = try values.decodeIfPresent(String.self, forKey: .kind) ?? ""
        title = try values.decodeIfPresent(String.self, forKey: .title) ?? ""
        year = try values.decodeIfPresent(Int.self, forKey: .year)
        season = try values.decodeIfPresent(Int.self, forKey: .season)
        episode = try values.decodeIfPresent(Int.self, forKey: .episode)
        episodeTitle = try values.decodeIfPresent(String.self, forKey: .episodeTitle) ?? ""
        tmdbId = try values.decodeIfPresent(UInt64.self, forKey: .tmdbId)
        releaseDate = try values.decodeIfPresent(String.self, forKey: .releaseDate)
        includeYear = try values.decodeIfPresent(Bool.self, forKey: .includeYear) ?? false
    }
    public var display: String {
        if kind == "movie" { return "\(title) (\(year.map(String.init) ?? "Year?"))" }
        if kind == "tv" { return "\(title)\(year.map { " (\($0))" } ?? "") · S\(season.map(String.init) ?? "?")E\(episode.map(String.init) ?? "?") · \(episodeTitle)" }
        return "Identity needs review"
    }
    public var group: String { kind == "movie" ? "Movies" : title.isEmpty ? "Needs identity" : "\(title)\(year.map { " (\($0))" } ?? "")" }
}
public struct FileFingerprint: Codable, Equatable, Sendable {
    public var device: UInt64; public var inode: UInt64; public var size: UInt64; public var modifiedNs: String
}
public struct Subtitle: Codable, Identifiable, Equatable, Sendable {
    public var id: String; public var originalPath: String; public var currentPath: String
    public var fingerprint: FileFingerprint; public var language: String; public var selected: Bool
    public var retainedPath: String?; public var targetPath: String?; public var publishedPath: String?
}
public struct RelayJob: Codable, Identifiable, Sendable {
    public var direct: DirectDraft?
    public var options: DirectDraft { direct ?? DirectDraft() }
    public var id: String; public var originalPath: String; public var currentPath: String
    public var fingerprint: FileFingerprint; public var identity: MediaIdentity; public var subtitles: [Subtitle]
    public var included: Bool; public var revision: UInt64; public var state: String; public var message: String
    public var createdMs: UInt64; public var updatedMs: UInt64; public var preparedPath: String?
    public var batchId: String?; public var approvedRevision: UInt64?; public var iflicksId: String?
    public var processIdentity: String?; public var progress: Int?; public var iflicksStatus: String?
    public var outputPath: String?; public var outputFingerprint: FileFingerprint?; public var outputAttestedMs: UInt64?
    public var editable: Bool { ["needs_review", "excluded", "source_changed"].contains(state) }
    public var filename: String { URL(fileURLWithPath: currentPath).lastPathComponent }
    public var stateLabel: String { state.replacingOccurrences(of: "_", with: " ").capitalized }
    public var needsAttention: Bool { if options.backend && options.trashSource && state == "complete" && options.trashPath == nil { return true }; return ["direct_failed", "direct_interrupted", "source_changed", "recovery_needed", "submission_uncertain", "processing_failed", "awaiting_output", "output_verified", "reconciliation_failed"].contains(state) }
}
public struct RelayConfig: Codable, Sendable {
    public var roots: [String]; public var recursive: Bool; public var outputFolder: String
    public init(roots: [String], recursive: Bool, outputFolder: String) { self.roots = roots; self.recursive = recursive; self.outputFolder = outputFolder }
}
public struct RelayEvent: Codable, Identifiable, Sendable {
    public var event: String; public var jobId: String?; public var timestampMs: UInt64; public var message: String
    public var id: String { "\(timestampMs)-\(event)-\(jobId ?? "")" }
}
public struct RelaySnapshot: Codable, Sendable {
    public var version: String; public var jobs: [RelayJob]; public var events: [RelayEvent]
    public var recentIdentities: [MediaIdentity]; public var config: RelayConfig?
}
public struct BatchPreview: Codable, Sendable {
    public struct Action: Codable, Identifiable, Sendable {
        public struct SubtitleAction: Codable, Sendable { public var source: String; public var target: String; public var language: String }
        public var id: String; public var source: String; public var target: String; public var subtitles: [SubtitleAction]; public var identity: MediaIdentity
    }
    public var token: String; public var actions: [Action]; public var errors: [String]
}
public struct OutputCandidate: Codable, Identifiable, Sendable {
    public init(path: String, size: UInt64) { self.path = path; self.size = size }
    public var path: String; public var size: UInt64; public var id: String { path }
}
public struct EpisodeCandidate: Codable, Identifiable, Sendable {
    public var id: Int; public var name: String; public var seasonNumber: Int; public var episodeNumber: Int
    public var airDate: String?
}
public struct EpisodeSuggestion: Codable, Sendable { public var episode: EpisodeCandidate; public var score: Double; public var reason: String }
public enum RelayFailure: LocalizedError { case message(String)
    public var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}
