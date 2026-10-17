import Foundation

public struct TrackChoice: Codable, Equatable, Identifiable, Sendable {
    public var index: Int; public var enabled: Bool; public var language: String
    public var `default`: Bool; public var forced: Bool
    public var id: Int { index }
    public init(index: Int, enabled: Bool = true, language: String = "und", default value: Bool = false, forced: Bool = false) {
        self.index = index; self.enabled = enabled; self.language = language; self.default = value; self.forced = forced
    }
}
public struct MediaStream: Codable, Equatable, Identifiable, Sendable {
    public var index: Int; public var kind: String; public var codec: String; public var profile: String
    public var width: Int; public var height: Int; public var channels: Int; public var sampleRate: String
    public var duration: Double; public var language: String; public var isDefault: Bool; public var forced: Bool
    public var attachedPic: Bool; public var frameRate: String; public var bitrate: String
    public var codecTag: String? = nil
    public var id: Int { index }
    public var summary: String {
        [codec.uppercased(), profile, duration > 0 ? String(format:"%.3f s",duration) : "", width > 0 ? "\(width)×\(height)" : "", channels > 0 ? "\(channels) channels" : "", kind == "video" ? frameRate + " fps" : "", sampleRate.isEmpty ? "" : sampleRate + " Hz", bitrate.isEmpty ? "" : "\(bitrate) bps"].filter { !$0.isEmpty }.joined(separator: " · ")
    }
}
public struct MediaChapter: Codable, Equatable, Identifiable, Sendable {
    public var start: Double; public var end: Double; public var title: String
    public var id: Double { start }
}
public struct RuleMedia: Codable, Equatable, Sendable { public var format: String; public var height: Int; public var width: Int; public var profile: String }
public struct MediaInspection: Codable, Equatable, Sendable {
    public var streams: [MediaStream]; public var chapters: [MediaChapter]; public var ruleMedia: [RuleMedia]; public var duration: Double
}
public struct DirectDraft: Codable, Equatable, Sendable {
    public var metadata: [String: String] = [:]; public var overrides: Set<String> = []
    public var filename = ""; public var destination = ""; public var streaming = true; public var trashSource = true
    public var artworkFingerprint: FileFingerprint?
    public var embedSubtitles = false; public var artworkPath = ""; public var artworkUrl = ""
    public var tracks: [TrackChoice] = []; public var inspection: MediaInspection?
    public var temporary: String?; public var temporaryIdentity: FileFingerprint?
    public var target: String?; public var receipt: FileFingerprint?; public var trashPath: String?; public var backend = false
    public init() {}
}
public struct NamingSettings: Codable, Equatable, Sendable {
    public var tv = "{show} – s{season:02}e{episode:02} – {name}-{comment}.mp4"
    public var movie = "{name} ({year})-{comment}.mp4"
    public var suffixes: [String: String] = [:]
    public init() { for q in ["SD", "HD 720p", "HD 1080p", "4K"] { for c in ["H.264", "HEVC"] { suffixes["\(q) \(c)"] = "\(q) \(c) DL" } } }
}
public struct MetadataField: Identifiable, Sendable {
    public let id: String; public let label: String; public var multiline = false
    public init(_ id: String, _ label: String, multiline: Bool = false) { self.id = id; self.label = label; self.multiline = multiline }
    public static let sections: [(String, [MetadataField])] = [
        ("General", [.init("tagline", "Tagline"), .init("description", "Description", multiline: true), .init("seasonDescription", "Season Description", multiline: true), .init("releaseDate", "Release Date"), .init("albumRating", "Album Rating"), .init("rating", "Rating"), .init("genre", "Genre"), .init("contentRating", "Content Rating"), .init("advisory", "Advisory Rating (0–4)"), .init("definition", "Definition (0–3)"), .init("comment", "Comment")]),
        ("Cast & Crew", [.init("actors", "Actors", multiline: true), .init("directors", "Directors", multiline: true), .init("coDirectors", "Co-Directors", multiline: true), .init("producers", "Producers", multiline: true), .init("screenwriters", "Screenwriters", multiline: true)]),
        ("Sorting", [.init("album", "Album"), .init("grouping", "Grouping"), .init("artist", "Artist"), .init("albumArtist", "Album Artist"), .init("composer", "Composer"), .init("studio", "Studio"), .init("network", "TV Network"), .init("sortAlbum", "Sort Album"), .init("sortAlbumArtist", "Sort Album Artist"), .init("sortArtist", "Sort Artist"), .init("sortComposer", "Sort Composer"), .init("sortName", "Sort Name"), .init("sortShow", "Sort Show"), .init("discNumber", "Disc Number"), .init("discCount", "Disc Count"), .init("trackNumber", "Track Number"), .init("trackCount", "Track Count"), .init("useDVDOrder", "Use DVD Order"), .init("dvdSeason", "DVD Season Number"), .init("dvdEpisode", "DVD Episode Number"), .init("absoluteEpisode", "Absolute Episode Number")]),
        ("Advanced", [.init("artistID", "Apple Artist ID"), .init("composerID", "Apple Composer ID"), .init("contentID", "Apple Content ID"), .init("episodeID", "Episode ID"), .init("genreID", "Genre ID"), .init("genreType", "Genre Type"), .init("account", "iTunes Account"), .init("country", "iTunes Country ID"), .init("playlistID", "Playlist ID"), .init("purchaseDate", "Purchase Date"), .init("creationDate", "Creation Date"), .init("copyright", "Copyright"), .init("encodedBy", "Encoded by"), .init("encodingTool", "Encoding Tool"), .init("xid", "XID"), .init("tags", "Tags", multiline: true)])]
}
