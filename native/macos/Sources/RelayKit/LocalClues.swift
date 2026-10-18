import Foundation
import Darwin
import AVFoundation

public struct LocalEvidence: Codable, Sendable, Equatable {
    public var field: String
    public var original: String
    public var normalized: String
    public var source: String
    public var file: String
    public var inferred: Bool
    /// Correlated fields from the same download share a dependency group.
    public var dependency: String
    public var supportingFiles: [String]
    public init(_ field: String, _ value: String, source: String, file: String, inferred: Bool = false, supportingFiles: [String] = []) {
        self.field = field; original = value; normalized = EpisodeClues.normalized(value)
        self.source = source; self.file = file; self.inferred = inferred
        dependency = source == "batch" ? "batch:" + supportingFiles.joined(separator: "|") : source.hasPrefix("subtitle") ? "subtitle:\(file)" : "download:\(file)"
        self.supportingFiles = supportingFiles
    }
}

public struct FilenameClues: Codable, Sendable, Equatable {
    public var original: String
    public var show: String?
    public var season: Int?
    public var episode: Int?
    public var title: String
    public var numberToken: String? {
        guard let season, let episode else { return nil }
        return String(format: "s%02de%02d", season, episode)
    }
    public init(_ stem: String) {
        original = stem; title = Self.display(stem)
        let pattern = #"(?i)(?:\bs(\d+)e(\d+)|\bseason\s+(\d+)\s*,?\s*(?:episode|ep)\s*\.?\s*(\d+))\b"#
        if let regex = try? NSRegularExpression(pattern: pattern), let match = regex.firstMatch(in: stem, range: NSRange(stem.startIndex..., in: stem)), let range = Range(match.range, in: stem) {
            func number(_ index: Int) -> Int? { Range(match.range(at: index), in: stem).flatMap { Int(stem[$0]) } }
            season = number(1) ?? number(3); episode = number(2) ?? number(4)
            let prefix = Self.display(String(stem[..<range.lowerBound]))
            show = prefix.isEmpty ? nil : prefix
            title = Self.display(String(stem[range.upperBound...]))
            // Multi-episode files require a manual choice.
            if title.range(of: #"^(?:e\d+|-\d+)"#, options: .regularExpression) != nil { episode = nil }
        }
    }
    public static func display(_ text: String) -> String {
        var value = text.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "-–—.,")))
        let pairs: [Character: Character] = ["'": "'", "\"": "\"", "‘": "’", "“": "”"]
        if let first = value.first, let end = pairs[first], value.last == end, value.count > 1 {
            value.removeFirst(); value.removeLast()
        }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public enum TitleAgreement: String, Codable, Sendable { case exact, approximate, none }
public extension EpisodeClues {
    static func agreement(_ a: String, _ b: String) -> TitleAgreement {
        guard !normalized(a).isEmpty else { return .none }
        if normalized(a) == normalized(b) { return .exact }
        func expanded(_ s: String) -> String {
            var result = s.lowercased().replacingOccurrences(of: "’", with: "'")
            for word in ["would", "could", "should", "might", "must"] {
                result = result.replacingOccurrences(of: "\(word)'ve", with: "\(word) have")
            }
            return normalized(result)
        }
        return expanded(a) == expanded(b) ? .approximate : .none
    }
}

public struct LocalExploration: Codable, Sendable {
    public var file: String
    public var filename: FilenameClues
    public var evidence: [LocalEvidence]
    public var exploredAt = Date()
    public var show: String? {
        let names = Set(evidence.filter { $0.field == "show" }.map(\.normalized))
        if names.count == 1 { return evidence.first { $0.field == "show" }?.original }
        // An explicit regional name refines a generic programme name only.
        if names.count == 2, names.contains("taskmaster"), let regional = names.subtracting(["taskmaster"]).first,
           ["taskmasteraustralia", "taskmasternewzealand"].contains(regional) {
            return evidence.first { $0.field == "show" && $0.normalized == regional }?.original
        }
        return nil
    }
    public var regions: Set<String> {
        var result = Set(evidence.filter { $0.field == "region" }.map(\.normalized))
        for record in evidence where record.field == "show" {
            if record.normalized == "taskmasteraustralia" { result.insert("australia") }
            if record.normalized == "taskmasternewzealand" { result.insert("newzealand") }
        }
        return result
    }
    public var conflicts: Bool {
        let shows = Set(evidence.filter { $0.field == "show" }.map(\.normalized))
        return regions.count > 1 || (shows.count > 1 && show == nil) ||
            Set(evidence.filter { $0.field == "season" }.map { Int($0.original).map(String.init) ?? $0.normalized }).count > 1 ||
            Set(evidence.filter { $0.field == "episode" }.map { Int($0.original).map(String.init) ?? $0.normalized }).count > 1
    }
    public var sourceHosts: Set<String> {
        Set(evidence.filter { $0.field == "origin" }.compactMap { URL(string: $0.original)?.host?.lowercased() })
    }
    public var provisional: MediaIdentity {
        var identity = MediaIdentity(); identity.kind = "tv"; identity.title = show ?? ""
        identity.season = filename.season; identity.episode = filename.episode; identity.episodeTitle = filename.title
        return identity
    }
}

/// Local files are data only. No URLs found here are fetched or executed.
public enum LocalExplorer {
    static func bounded(_ url: URL, bytes: Int) -> Data? {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]), values.isRegularFile == true, values.isSymbolicLink != true,
              let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        return try? handle.read(upToCount: bytes)
    }
    public static func explore(_ url: URL, subtitleText: String? = nil, origins: [String] = [], tags: [String: String] = [:]) -> LocalExploration {
        let path = url.path, filename = FilenameClues(url.deletingPathExtension().lastPathComponent)
        var evidence: [LocalEvidence] = []
        func add(_ field: String, _ value: String, _ source: String, _ file: String? = nil) {
            guard !value.isEmpty else { return }
            evidence.append(LocalEvidence(field, value, source: source, file: file ?? path))
        }
        add("filename", filename.original, "filename")
        add("folder", url.deletingLastPathComponent().lastPathComponent, "folder")
        add("title", filename.title, "filename")
        if let show = filename.show { add("show", show, "filename") }
        if let season = filename.season { add("season", String(season), "filename") }
        if let episode = filename.episode { add("episode", String(episode), "filename") }
        for origin in origins + whereFroms(url) { add("origin", origin, "download-origin") }
        let stem = url.deletingPathExtension()
        let files = (try? FileManager.default.contentsOfDirectory(at: url.deletingLastPathComponent(), includingPropertiesForKeys: nil)) ?? []
        let subtitles = files.filter {
            let name = $0.deletingPathExtension().lastPathComponent
            let base = stem.lastPathComponent
            return $0.pathExtension.lowercased() == "srt" && (name == base || name.hasPrefix(base + "."))
        }.sorted { $0.path < $1.path }
        let texts: [(URL, String)] = subtitleText.map { [(stem.appendingPathExtension("srt"), $0)] } ?? subtitles.compactMap { file in
            bounded(file, bytes: 2 * 1024 * 1024).map { (file, String(decoding: $0, as: UTF8.self)) }
        }
        for (subtitle, text) in texts {
            // Strip cue indices/timestamps, retaining dialogue order and original quotes.
            let lines = text.components(separatedBy: .newlines).filter { !$0.contains("-->") && Int($0.trimmingCharacters(in: .whitespaces)) == nil && !$0.isEmpty }
            let opening = lines.prefix(180).joined(separator: " ")
            let intro = String(opening.prefix(12000))
            let tail = lines.suffix(100).joined(separator: " ")
            let inspected = intro + " " + tail
            func captures(_ pattern: String, _ input: String) -> [String] {
                guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return [] }
                return regex.matches(in: input, range: NSRange(input.startIndex..., in: input)).compactMap { Range($0.range(at: 1), in: input).map { String(input[$0]) } }
            }
            let introPattern = #"\bwelcome\s+to\s+[\"“']?([\p{L}\p{N}][\p{L}\p{N} '&’:-]{1,65}?)(?:[.,!\"”]|\s+[Tt]he\s+game)"#
            let introRegex = try? NSRegularExpression(pattern: introPattern, options: .caseInsensitive)
            let introductions = introRegex?.matches(in: intro, range: NSRange(intro.startIndex..., in: intro)).compactMap { match -> String? in
                guard let full = Range(match.range, in: intro), let name = Range(match.range(at: 1), in: intro) else { return nil }
                let preceding = String(intro[..<full.lowerBound].suffix(120))
                guard preceding.range(of: #"(?i)(?:next week|promotion|promo|biography|recap|as seen on|appeared on|used to host|guest from|he said|she said)[^.!?]*$"#, options: .regularExpression) == nil else { return nil }
                return String(intro[name])
            } ?? []
            for (index, show) in introductions.enumerated() {
                let name = FilenameClues.display(show)
                let normalized = EpisodeClues.normalized(name)
                // Later "welcome to the stage" and "welcome to my trap" lines
                // introduce guests or tasks, rather than a new programme.
                guard !["the", "my", "our", "try"].contains(name.lowercased().split(separator: " ").first.map(String.init) ?? ""),
                      index == 0 || ["crowdcontrol", "taskmaster", "taskmasteraustralia", "taskmasternewzealand"].contains(normalized) else { continue }
                add("show", name, "subtitle", subtitle.path)
            }
            if evidence.contains(where: { $0.field == "show" && $0.normalized == "taskmaster" }) {
                for region in captures(#"\b(Taskmaster (?:Australia|New Zealand))\s+(?:series|season)\s+(?:[a-z]+|\d+)\s+(?:champion|final|winner)"#, tail) {
                    add("show", region, "subtitle", subtitle.path)
                }
            }
            if evidence.contains(where: { $0.field == "show" && $0.normalized.hasPrefix("taskmaster") }) {
                let hosts = [("Tom Gleeson", "Tom Cashman", "Australia"), ("Greg Davies", "Alex Horne", "United Kingdom"), ("Jeremy Wells", "Paul Williams", "New Zealand")]
                for (host, assistant, region) in hosts where intro.localizedCaseInsensitiveContains(host) && intro.localizedCaseInsensitiveContains(assistant) {
                    add("hosts", host + "; " + assistant, "subtitle", subtitle.path)
                    evidence.append(LocalEvidence("region", region, source: "subtitle-hosts", file: subtitle.path, inferred: true))
                }
            }
            let words = ["one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8, "nine": 9, "ten": 10, "eleven": 11, "twelve": 12]
            for statement in captures(#"\b((?:series|season|episode)\s+(?:\d+|one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve))\b"#, inspected) {
                let parts = statement.lowercased().split(separator: " ").map(String.init)
                if let raw = parts.last, let number = Int(raw) ?? words[raw] {
                    add(parts.first == "episode" ? "episode" : "season", String(number), "subtitle", subtitle.path)
                    add("context", statement, "subtitle", subtitle.path)
                }
            }
            for statement in captures(#"((?:\b(?:series|season)\s+\d+)|(?:\b(?:your host|I'm your host|my name is|I'm Tom|lineup|contestants|joining us|we have|it's Tom Cashman)[^.!?]{0,180}))"#, inspected) {
                add("context", statement, "subtitle", subtitle.path)
                if let regex = try? NSRegularExpression(pattern: #"(?i)^(?:series|season)\s+(\d+)$"#), let match = regex.firstMatch(in: statement, range: NSRange(statement.startIndex..., in: statement)), let range = Range(match.range(at: 1), in: statement) { add("season", String(statement[range]), "subtitle", subtitle.path) }
            }
            if EpisodeClues.normalized(inspected).contains(EpisodeClues.normalized(filename.title)), !filename.title.isEmpty {
                add("dialogue-title", filename.title, "subtitle", subtitle.path)
            } else if !filename.title.isEmpty, EpisodeClues.normalized(text).contains(EpisodeClues.normalized(filename.title)) {
                // Extend beyond the bounded context only to find this specific title phrase.
                add("dialogue-title", filename.title, "subtitle", subtitle.path)
            }
        }
        for (key, value) in tags { add(key == "show" ? "show" : key == "season" || key == "episode" ? key : "embedded-\(key)", value, "embedded") }
        // Unknown JSON fields are retained as evidence, never interpreted as commands.
        let json = url.deletingPathExtension().appendingPathExtension("json")
        if let data = bounded(json, bytes: 1024 * 1024), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            func walk(_ object: [String: Any], prefix: String = "", depth: Int = 0) {
                guard depth < 4 else { return }
                for key in object.keys.sorted().prefix(100) {
                    if let child = object[key] as? [String: Any] { walk(child, prefix: prefix + key + ".", depth: depth + 1) }
                    else if let value = object[key] as? String { add("companion-" + prefix + key, String(value.prefix(2048)), "companion", json.path) }
                    else if let value = object[key], JSONSerialization.isValidJSONObject([value]),
                            let encoded = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .sortedKeys]),
                            let text = String(data: encoded, encoding: .utf8) {
                        add("companion-" + prefix + key, String(text.prefix(2048)), "companion", json.path)
                    }
                }
            }
            walk(object)
        }
        return LocalExploration(file: path, filename: filename, evidence: evidence)
    }
    public static func embeddedTags(_ url: URL) async -> [String: String] {
        let asset = AVURLAsset(url: url)
        guard let formats = try? await asset.load(.availableMetadataFormats) else { return [:] }
        var tags: [String: String] = [:]
        for format in formats {
            guard let items = try? await asset.loadMetadata(for: format) else { continue }
            for item in items {
                let identifier = item.identifier?.rawValue.split(separator: "/").last.map(String.init) ?? ""
                var key = (item.key as? String ?? identifier).lowercased()
                if key.isEmpty, let number = item.key as? NSNumber {
                    let raw = number.uint32Value
                    key = String(bytes: [UInt8((raw >> 24) & 255), UInt8((raw >> 16) & 255), UInt8((raw >> 8) & 255), UInt8(raw & 255)], encoding: .isoLatin1) ?? ""
                }
                let fields = ["tvsh": "show", "tvsn": "season", "tves": "episode", "©nam": "title", "title": "title", "show": "show", "com.apple.quicktime.title": "title"]
                if let field = fields[key] {
                    if let value = try? await item.load(.stringValue) { tags[field] = value }
                    else if let value = try? await item.load(.numberValue) { tags[field] = value.stringValue }
                }
            }
        }
        return tags
    }
    static func whereFroms(_ url: URL) -> [String] {
        let name = "com.apple.metadata:kMDItemWhereFroms"
        let count = getxattr(url.path, name, nil, 0, 0, 0)
        guard count > 0, count < 65536 else { return [] }
        var data = Data(count: count)
        let read = data.withUnsafeMutableBytes { getxattr(url.path, name, $0.baseAddress, count, 0, 0) }
        guard read == count else { return [] }
        return (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String] ?? []
    }
    public static func relate(_ originals: [LocalExploration]) -> [LocalExploration] {
        let originals = originals.map { original in
            var value = original; value.evidence.removeAll { $0.source == "batch" }; return value
        }
        return originals.map { original in
            var value = original
            guard !value.conflicts, let season = value.filename.season, let number = value.filename.episode, !value.sourceHosts.isEmpty else { return value }
            let peers = originals.filter {
                $0.file != value.file && !$0.conflicts && $0.filename.season == season && $0.filename.episode != nil &&
                URL(fileURLWithPath: $0.file).deletingLastPathComponent() == URL(fileURLWithPath: value.file).deletingLastPathComponent() &&
                !$0.sourceHosts.isDisjoint(with: value.sourceHosts) && $0.evidence.contains { $0.field == "show" && !$0.inferred }
            }
            let regionalEvidence = peers.reduce(into: value.regions) { $0.formUnion($1.regions) }
            guard regionalEvidence.count <= 1 else { return value }
            let names = Set(peers.compactMap(\.show).map(EpisodeClues.normalized))
            let regions = names.subtracting(["taskmaster"])
            guard peers.count >= 3, regions.count == 1, let show = peers.compactMap(\.show).first(where: { EpisodeClues.normalized($0) == regions.first }),
                  names.allSatisfy({ $0 == EpisodeClues.normalized(show) || $0 == "taskmaster" && ["taskmasteraustralia", "taskmasternewzealand"].contains(EpisodeClues.normalized(show)) }),
                  value.show == nil || EpisodeClues.normalized(value.show!) == EpisodeClues.normalized(show) || value.show == "Taskmaster" && ["taskmasteraustralia", "taskmasternewzealand"].contains(EpisodeClues.normalized(show)),
                  (peers.contains(where: { ($0.filename.episode ?? number) < number }) && peers.contains(where: { ($0.filename.episode ?? number) > number })) || peers.contains(where: { $0.show == show && $0.evidence.contains { $0.field == "season" && $0.source == "subtitle" } }) else { return value }
            value.evidence.append(LocalEvidence("show", show, source: "batch", file: value.file, inferred: true, supportingFiles: peers.map(\.file).sorted()))
            return value
        }
    }
}
