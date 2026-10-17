import Foundation
import Darwin

public struct MediaTools: Sendable {
    public let ffmpeg: URL; public let ffprobe: URL; public let mediaInfo: URL
    public init(directory: URL? = nil) throws {
        let root = directory ?? Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers")
        ffmpeg = root.appendingPathComponent("ffmpeg"); ffprobe = root.appendingPathComponent("ffprobe"); mediaInfo = root.appendingPathComponent("mediainfo")
        guard [ffmpeg, ffprobe, mediaInfo].allSatisfy({ FileManager.default.isExecutableFile(atPath: $0.path) }) else {
            throw RelayFailure.message("The source-built media dependencies are missing. Rebuild Relay to compile FFmpeg, ffprobe and MediaInfo.")
        }
    }
}
/// Serializes external media processes; cancellation terminates the running child.
public actor DirectProcessor {
    private var child: Process?
    private var cancelled = false
    public init() {}
    public func cancel() { cancelled = true; if let child, child.isRunning { child.terminate(); Self.forceStop(child) } }
    private nonisolated static func forceStop(_ process: Process) { DispatchQueue.global().asyncAfter(deadline:.now()+1) { if process.isRunning { kill(process.processIdentifier,SIGKILL) } } }
    public func resetCancellation() { cancelled = false }
    public func run(_ tool: URL, _ args: [String], timeout: TimeInterval = 86400) async throws -> Data {
        guard !cancelled else { throw CancellationError() }
        let process = Process(); process.executableURL = tool; process.arguments = args
        process.environment = ProcessInfo.processInfo.environment.merging(["LC_ALL":"en_US.UTF-8","LANG":"en_US.UTF-8"]) { _,new in new }
        let out = Pipe(), err = Pipe(); process.standardOutput = out; process.standardError = err
        child = process
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                let timer = DispatchWorkItem { if process.isRunning { process.terminate(); Self.forceStop(process) } }
                // Drain both pipes concurrently so diagnostics cannot deadlock a full pipe.
                let stdout = Task.detached { out.fileHandleForReading.readDataToEndOfFile() }
                let stderr = Task.detached { err.fileHandleForReading.readDataToEndOfFile() }
                process.terminationHandler = { finished in
                    timer.cancel()
                    Task {
                        let output = await stdout.value, errors = await stderr.value
                        guard finished.terminationStatus == 0 else {
                            continuation.resume(throwing: RelayFailure.message(String(decoding: errors.suffix(12000), as: UTF8.self).isEmpty ? "Media processing stopped" : String(decoding: errors.suffix(12000), as: UTF8.self))); return
                        }
                        continuation.resume(returning: output)
                    }
                }
                do { try process.run(); DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timer) }
                catch { out.fileHandleForWriting.closeFile(); err.fileHandleForWriting.closeFile(); timer.cancel(); continuation.resume(throwing: error) }
            }
        }, onCancel: { if process.isRunning { process.terminate(); Self.forceStop(process) } })
    }
    public func inspect(path: String, tools: MediaTools) async throws -> MediaInspection {
        let raw = try await run(tools.ffprobe, ["-v","error","-show_format","-show_streams","-show_chapters","-of","json",path], timeout: 60)
        let info = try await run(tools.mediaInfo, ["--Output=JSON",path], timeout: 60)
        guard raw.count < 8*1024*1024, info.count < 8*1024*1024 else { throw RelayFailure.message("Media inspection exceeds the size limit") }
        let object = try JSONSerialization.jsonObject(with: raw) as? [String:Any] ?? [:]
        let mi = try JSONSerialization.jsonObject(with: info) as? [String:Any] ?? [:]
        let tracks = ((mi["media"] as? [String:Any])?["track"] as? [[String:Any]] ?? []).filter { $0["@type"] as? String == "Video" }
        func str(_ value: Any?) -> String { value.map { String(describing: $0) } ?? "" }
        func num(_ value: Any?) -> Int { Int(str(value)) ?? 0 }
        let streams = (object["streams"] as? [[String:Any]] ?? []).map { s -> MediaStream in
            let tags = s["tags"] as? [String:Any] ?? [:], flags = s["disposition"] as? [String:Any] ?? [:]
            return MediaStream(index: num(s["index"]), kind: str(s["codec_type"]), codec: str(s["codec_name"]), profile: str(s["profile"]), width: num(s["width"]), height: num(s["height"]), channels: num(s["channels"]), sampleRate: str(s["sample_rate"]), duration: Double(str(s["duration"])) ?? 0, language: str(tags["language"]).isEmpty ? "und" : str(tags["language"]), isDefault: num(flags["default"]) == 1, forced: num(flags["forced"]) == 1, attachedPic: num(flags["attached_pic"]) == 1, frameRate: str(s["r_frame_rate"]), bitrate: str(s["bit_rate"]), codecTag: s["codec_tag_string"] as? String)
        }
        let chapters = (object["chapters"] as? [[String:Any]] ?? []).map { c in MediaChapter(start: Double(str(c["start_time"])) ?? 0, end: Double(str(c["end_time"])) ?? 0, title: str((c["tags"] as? [String:Any])?["title"])) }
        let rules = tracks.map { RuleMedia(format: str($0["Format"]), height: num($0["Height"]), width: num($0["Width"]), profile: str($0["Format_Profile"])) }
        return MediaInspection(streams: streams, chapters: chapters, ruleMedia: rules, duration: Double(str((object["format"] as? [String:Any])?["duration"])) ?? 0)
    }
    public static func selectedStreams(_ input: MediaInspection, choices: [TrackChoice]) throws -> [MediaStream] {
        let selected = input.streams.filter { !$0.attachedPic }.filter { stream in choices.first(where: { $0.index == stream.index })?.enabled ?? true }
        guard selected.filter({ $0.kind == "video" }).count == 1, selected.contains(where: { $0.kind == "video" && ["h264","hevc"].contains($0.codec) }) else { throw RelayFailure.message("Choose one H.264 or HEVC video track") }
        for stream in selected {
            let chapterTrack = stream.kind == "data" && stream.codec == "bin_data" && stream.codecTag == "text" && !input.chapters.isEmpty
            guard stream.kind == "video" || stream.kind == "audio" && ["aac","ac3","eac3"].contains(stream.codec) || stream.kind == "subtitle" && stream.codec == "mov_text" || chapterTrack else { throw RelayFailure.message("Cannot preserve \(stream.kind) track \(stream.index) (\(stream.codec)) in MP4. Disable it explicitly or use another processor.") }
        }
        return selected.filter { $0.kind != "data" } // QuickTime chapter data is recreated by -map_chapters.
    }
    public static func isoLanguage(_ raw: String) -> String {
        let code = String(raw.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ".").first ?? "und").lowercased()
        return ["en":"eng","fr":"fra","de":"deu","es":"spa","it":"ita","ja":"jpn","pt":"por","zh":"zho","nl":"nld","ru":"rus","ko":"kor","ar":"ara","hi":"hin","sv":"swe","no":"nor","da":"dan","fi":"fin","pl":"pol","cs":"ces","tr":"tur","el":"ell","he":"heb"][code] ?? (code.isEmpty ? "und" : code)
    }
    public func process(job: RelayJob, tools: MediaTools, stage: @Sendable (String) async -> Void) async throws -> String {
        guard let temporary = job.options.temporary else { throw RelayFailure.message("Missing owned output stage") }
        let input = try await inspect(path: job.currentPath, tools: tools)
        let streams = try Self.selectedStreams(input, choices: job.options.tracks)
        var args = ["-v","error","-nostdin","-y","-i",job.currentPath]
        let subtitles = job.options.embedSubtitles ? job.subtitles.filter(\.selected) : []
        for sub in subtitles { args += ["-i",sub.retainedPath ?? sub.currentPath] }
        for stream in streams { args += ["-map","0:\(stream.index)"] }
        for index in subtitles.indices { args += ["-map","\(index + 1):s:0"] }
        args += ["-map_chapters","0","-map_metadata","0","-c","copy"]
        let existingSubtitles = streams.filter { $0.kind == "subtitle" }.count
        for (index,sub) in subtitles.enumerated() {
            let iso = Self.isoLanguage(sub.language)
            args += ["-c:s:\(existingSubtitles + index)","mov_text","-metadata:s:s:\(existingSubtitles + index)","language=\(iso)","-disposition:s:\(existingSubtitles + index)",sub.language.contains(".forced") ? "forced" : "0"]
        }
        for (output,stream) in streams.enumerated() {
            if let choice = job.options.tracks.first(where: { $0.index == stream.index }) {
                let iso = Self.isoLanguage(choice.language)
                let disp = [choice.default ? "default" : "",choice.forced ? "forced" : ""].filter { !$0.isEmpty }.joined(separator: "+")
                args += ["-metadata:s:\(output)","language=\(iso)","-disposition:\(output)",disp.isEmpty ? "0" : disp]
            }
        }
        if job.options.streaming { args += ["-movflags","+faststart"] }
        args += ["-f","mp4",temporary]
        await stage("Copying video and audio without re-encoding…")
        _ = try await run(tools.ffmpeg,args)
        return "FFmpeg stream copy completed"
    }
    public func verify(job: RelayJob, tools: MediaTools) async throws -> String {
        guard let path = job.options.temporary else { throw RelayFailure.message("Missing stage") }
        let input = try await inspect(path: job.currentPath, tools: tools), output = try await inspect(path: path, tools: tools)
        let expected = try Self.selectedStreams(input, choices: job.options.tracks)
        let actual = output.streams.filter { !$0.attachedPic && $0.kind != "data" }
        let embeddedSubs = job.options.embedSubtitles ? job.subtitles.filter(\.selected) : []
        guard actual.count == expected.count + embeddedSubs.count, abs(input.duration-output.duration) < 0.2 else { throw RelayFailure.message("Output stream count or duration changed unexpectedly") }
        for (index,source) in expected.enumerated() {
            let result = actual[index]
            guard result.codec == source.codec, result.width == source.width, result.height == source.height, result.channels == source.channels else { throw RelayFailure.message("Output stream properties changed") }
            let a = try await run(tools.ffmpeg,["-v","error","-i",job.currentPath,"-map","0:\(source.index)","-c","copy","-f","hash","-hash","sha256","-"])
            let b = try await run(tools.ffmpeg,["-v","error","-i",path,"-map","0:\(result.index)","-c","copy","-f","hash","-hash","sha256","-"])
            guard a == b else { throw RelayFailure.message("Video/audio/subtitle payload verification failed for track \(source.index)") }
            let choice = job.options.tracks.first { $0.index == source.index }
            guard Self.isoLanguage(result.language) == Self.isoLanguage(choice?.language ?? source.language), result.isDefault == (choice?.default ?? source.isDefault), result.forced == (choice?.forced ?? source.forced) else { throw RelayFailure.message("Track language or playback flags did not match the approved choices") }
        }
        for (offset,sub) in embeddedSubs.enumerated() {
            let result = actual[expected.count + offset]
            guard result.kind == "subtitle", result.codec == "mov_text", Self.isoLanguage(result.language) == Self.isoLanguage(sub.language), result.forced == sub.language.contains(".forced") else {
                throw RelayFailure.message("Embedded external subtitle track properties did not match the approved choices")
            }
        }
        guard input.chapters.count == output.chapters.count, zip(input.chapters,output.chapters).allSatisfy({ abs($0.start-$1.start)<0.002 && $0.title==$1.title }) else { throw RelayFailure.message("Chapter preservation verification failed") }
        if job.identity.kind == "tv", output.streams.contains(where: \.attachedPic) { throw RelayFailure.message("TV cover artwork remains") }
        return "SHA-256 packet payloads, stream properties, languages/flags, duration and chapters verified"
    }
}
