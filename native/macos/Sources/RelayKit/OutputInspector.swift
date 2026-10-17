import Foundation
import Darwin

/// A bounded metadata probe; video bytes are never hashed or copied. Explicit
/// user output selection remains the association evidence, with tags as checks.
public actor OutputInspector {
    private let executable: URL?
    public init(executable: URL? = nil) {
        self.executable = executable ?? [Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/ffprobe").path].first(where: FileManager.default.isExecutableFile(atPath:)).map(URL.init(fileURLWithPath:))
    }
    public func validate(path: String, identity: MediaIdentity) throws -> String {
        try Self.validateMetadata(probe(path: path), identity: identity)
    }
    public func prepareConfirmedOutput(path: String, identity: MediaIdentity, expected: FileFingerprint? = nil) throws -> String {
        let data = try probe(path: path)
        let evidence = try Self.validateMetadata(data, identity: identity)
        if let expected {
            var file = stat()
            guard lstat(path, &file) == 0, Self.matches(file, expected) else { throw RelayFailure.message("The finished output changed during validation. Select it again.") }
        }
        guard identity.kind == "tv", try Self.hasArtwork(data) else { return evidence }
        guard ["mp4", "m4v", "mov"].contains(URL(fileURLWithPath: path).pathExtension.lowercased()) else {
            throw RelayFailure.message("Automatic TV artwork removal supports MP4/M4V/MOV outputs. Remove this file's artwork manually before confirming it.")
        }
        let count = try MP4Artwork.remove(path: path, expected: expected) {
            let result = try probe(path: path)
            _ = try Self.validateMetadata(result, identity: identity)
            guard try !Self.hasArtwork(result) else { throw RelayFailure.message("Embedded TV artwork remains; output confirmation stopped") }
        }
        return evidence + "; removed \(count) embedded TV cover-art atoms without re-encoding"
    }
    static func matches(_ file: stat, _ expected: FileFingerprint) -> Bool {
        let modified = String(file.st_mtimespec.tv_sec) + String(format: "%09ld", file.st_mtimespec.tv_nsec)
        return UInt64(file.st_dev) == expected.device && UInt64(file.st_ino) == expected.inode && UInt64(file.st_size) == expected.size && modified == expected.modifiedNs
    }
    static func hasArtwork(_ data: Data) throws -> Bool {
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return (object?["streams"] as? [[String: Any]] ?? []).contains {
            (($0["disposition"] as? [String: Any])?["attached_pic"] as? Int ?? 0) == 1
        }
    }
    private func probe(path: String) throws -> Data {
        guard let executable else { throw RelayFailure.message("ffprobe is required to check finished media. Rebuild Relay to compile its bundled media dependencies, then confirm the output again.") }
        let process = Process(); process.executableURL = executable
        process.arguments = ["-v", "error", "-probesize", "5000000", "-analyzeduration", "5000000", "-show_format", "-show_streams", "-of", "json", path]
        let output = Pipe(); process.standardOutput = output; process.standardError = FileHandle.nullDevice
        try process.run()
        let timeout = DispatchWorkItem {
            if process.isRunning {
                process.terminate()
                DispatchQueue.global().asyncAfter(deadline: .now() + 1) { if process.isRunning { kill(process.processIdentifier, SIGKILL) } }
            }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 8, execute: timeout)
        let data = output.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit(); timeout.cancel()
        guard process.terminationStatus == 0, data.count < 8 * 1024 * 1024 else { throw RelayFailure.message("The selected output could not be probed. Wait for processing to finish and choose the actual finished video.") }
        return data
    }
    static func validateMetadata(_ data: Data, identity: MediaIdentity) throws -> String {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any], let streams = object["streams"] as? [[String: Any]],
              streams.contains(where: { ($0["codec_type"] as? String) == "video" && (($0["disposition"] as? [String: Any])?["attached_pic"] as? Int ?? 0) == 0 }) else { throw RelayFailure.message("The selected file has no readable video stream") }
        let tags = (object["format"] as? [String: Any])?["tags"] as? [String: Any] ?? [:]
        func normalized(_ value: String) -> String { value.lowercased().filter { $0.isLetter || $0.isNumber } }
        func conflict(_ field: String, actual: String, approved: String) -> RelayFailure {
            .message("The selected output's \(field) tag is \"\(actual)\", but the approved value is \"\(approved)\" for \(identity.display). Select this job's matching finished video, or correct its metadata before confirming again.")
        }
        if identity.kind == "tv" {
            if let show = tags["show"] as? String, !show.isEmpty, normalized(show) != normalized(identity.title) { throw conflict("show", actual: show, approved: identity.title) }
            if let season = (tags["season_number"] as? String).flatMap(Int.init), season != identity.season { throw conflict("season", actual: String(season), approved: identity.season.map(String.init) ?? "unspecified") }
            if let episode = (tags["episode_sort"] as? String).flatMap(Int.init), episode != identity.episode { throw conflict("episode", actual: String(episode), approved: identity.episode.map(String.init) ?? "unspecified") }
        } else if identity.kind == "movie" {
            if let title = tags["title"] as? String, !title.isEmpty, normalized(title) != normalized(identity.title) { throw conflict("movie title", actual: title, approved: identity.title) }
            if let date = tags["date"] as? String, let year = Int(date.prefix(4)), year != identity.year { throw conflict("movie year", actual: String(year), approved: identity.year.map(String.init) ?? "unspecified") }
        }
        return "Explicit user output selection; ffprobe found a readable video stream and no conflicting inspected identity tags"
    }
}
