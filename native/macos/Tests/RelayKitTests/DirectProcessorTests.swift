import XCTest
import Foundation
@testable import RelayKit

final class DirectProcessorTests: XCTestCase {
    private var project: URL { var url = URL(fileURLWithPath:#filePath); for _ in 0..<5 { url.deleteLastPathComponent() }; return url }
    private func fixture(_ root: URL, hevc: Bool = false) throws -> URL {
        let input = root.appendingPathComponent("intake/Original.mp4")
        let chapters = root.appendingPathComponent("chapters.txt")
        try Data(";FFMETADATA1\n[CHAPTER]\nTIMEBASE=1/1000\nSTART=0\nEND=1000\ntitle=Opening\n[CHAPTER]\nTIMEBASE=1/1000\nSTART=1000\nEND=2000\ntitle=Ending\n".utf8).write(to:chapters)
        // Fixture synthesis alone uses the pre-existing encoder. Production processing
        // and all inspection/verification below use Relay's source-built tools.
        let p=Process();p.executableURL=URL(fileURLWithPath:"/usr/local/bin/ffmpeg")
        p.arguments=["-v","error","-f","lavfi","-i","color=c=blue:s=160x90:r=24:d=2","-f","lavfi","-i","sine=frequency=440:duration=2","-f","lavfi","-i","sine=frequency=880:duration=2","-i",chapters.path,"-map","0:v","-map","1:a","-map","2:a","-map_chapters","3","-c:v",hevc ? "libx265" : "libx264","-c:a:0","aac","-c:a:1","ac3","-metadata:s:a:0","language=eng","-metadata:s:a:1","language=fra","-disposition:a:0","default","-disposition:a:1","0","-movflags","+faststart",input.path]
        p.standardError=FileHandle.nullDevice;try p.run();p.waitUntilExit();XCTAssertEqual(p.terminationStatus,0)
        let cover = root.appendingPathComponent("existing-poster.png")
        try Data(base64Encoded:"iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aX1sAAAAASUVORK5CYII=")!.write(to:cover)
        let covered = root.appendingPathComponent("covered.mp4")
        let art = Process(); art.executableURL = URL(fileURLWithPath:"/usr/local/bin/ffmpeg")
        art.arguments = ["-v","error","-i",input.path,"-i",cover.path,"-map","0","-map","1:v","-c","copy","-disposition:v:1","attached_pic",covered.path]
        art.standardError=FileHandle.nullDevice; try art.run(); art.waitUntilExit(); XCTAssertEqual(art.terminationStatus,0)
        try FileManager.default.removeItem(at:input); try FileManager.default.moveItem(at:covered,to:input)
        return input
    }
    func testDirectTVAndMovieEndToEndWithoutIFlicks() async throws {
        let tools=try MediaTools(directory:project.appendingPathComponent("build/media/install/bin"))
        for kind in ["tv","movie"] {
            let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at:root.appendingPathComponent("intake"),withIntermediateDirectories:true)
            try FileManager.default.createDirectory(at:root.appendingPathComponent("output"),withIntermediateDirectories:true)
            defer { try? FileManager.default.removeItem(at:root) }
            let input=try fixture(root,hevc:kind == "movie")
            let subtitleSuffix = kind == "movie" ? "en.forced.srt" : "srt"
            try Data("1\n00:00:00,100 --> 00:00:01,000\nHello\n".utf8).write(to:input.deletingPathExtension().appendingPathExtension(subtitleSuffix))
            let engine=try RelayEngine(database:root.appendingPathComponent("state/jobs.sqlite"))
            _ = try await engine.configure(RelayConfig(roots:[root.appendingPathComponent("intake").path],recursive:false,outputFolder:root.appendingPathComponent("output").path))
            let initial:RelaySnapshot=try await engine.execute(["command":"discover"])
            let job=try XCTUnwrap(initial.jobs.first)
            var identity=MediaIdentity();identity.kind=kind;identity.title="Fixture & Friends";identity.year=2025;identity.season=1;identity.episode=2;identity.episodeTitle="A reviewed episode"
            let processor=DirectProcessor()
            let inspection=try await processor.inspect(path:input.path,tools:tools)
            XCTAssertEqual(inspection.ruleMedia.first?.format,kind == "movie" ? "HEVC" : "AVC");XCTAssertEqual(inspection.chapters.count,2)
            let inspected:RelayJob=try await engine.execute(["command":"direct_inspect","id":job.id,"revision":job.revision,"inspection":RelayEngine.object(inspection)])
            var draft=inspected.options;draft.trashSource=false;draft.embedSubtitles=true
            draft.metadata=["description":"Description & <details>","tagline":"A tagline","genre":"Comedy","contentRating":kind == "tv" ? "TV-PG" : "PG-13","actors":"Actor One\nActor Two","directors":"Director","producers":"Producer","screenwriters":"Writer","studio":"Studio","sortName":"Sort title","trackNumber":"2","trackCount":"5","contentID":"1234","dvdSeason":"1"]
            let integers: Set<String> = ["artistID","composerID","contentID","country","playlistID","genreID","advisory","definition","trackNumber","trackCount","discNumber","discCount"]
            for field in MetadataField.sections.flatMap({ $0.1 }) where draft.metadata[field.id] == nil {
                draft.metadata[field.id] = integers.contains(field.id) ? "1" : "Fixture \(field.id)"
            }
            draft.overrides = Set(draft.metadata.keys)
            draft.tracks=[TrackChoice(index:1,language:"en",default:true),TrackChoice(index:2,enabled:kind == "movie",language:"fr",default:false)]
            if kind == "movie" {
                let image=root.appendingPathComponent("poster.png")
                try Data(base64Encoded:"iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aX1sAAAAASUVORK5CYII=")!.write(to:image)
                draft.artworkPath=image.path
                draft.metadata["studio"] = ""
                draft.metadata["directors"] = ""
                draft.metadata["trackNumber"] = ""
                draft.metadata["trackCount"] = ""
            }
            let _:RelaySnapshot=try await engine.execute(["command":"edit","id":job.id,"revision":inspected.revision,"identity":RelayEngine.object(identity),"direct":RelayEngine.object(draft)])
            let preview:BatchPreview=try await engine.execute(["command":"direct_preview","ids":[job.id]])
            XCTAssertTrue(preview.errors.isEmpty,preview.errors.joined(separator:"\n"))
            let _:RelaySnapshot=try await engine.execute(["command":"direct_approve","token":preview.token])
            let active:RelayJob=try await engine.execute(["command":"direct_begin","id":job.id])
            _ = try await processor.process(job:active,tools:tools,stage:{ _ in })
            let tagged:RelayJob=try await engine.execute(["command":"direct_tag","id":job.id])
            let evidence=try await processor.verify(job:tagged,tools:tools)
            let published:RelayJob=try await engine.execute(["command":"direct_publish","id":job.id,"evidence":evidence])
            XCTAssertEqual(published.state,"complete");XCTAssertNil(published.iflicksId)
            let readback: [String:String] = try await engine.execute(["command":"direct_readback","id":job.id])
            for (key,value) in draft.metadata {
                if value.isEmpty { XCTAssertNil(readback[key], "Explicitly cleared field \(key) must be removed on readback") }
                else { XCTAssertEqual(readback[key],value,"Metadata field \(key) must survive the file write") }
            }
            XCTAssertTrue(FileManager.default.fileExists(atPath:input.path))
            let path=try XCTUnwrap(published.outputPath)
            XCTAssertTrue(FileManager.default.fileExists(atPath:URL(fileURLWithPath:path).deletingPathExtension().appendingPathExtension(kind == "movie" ? "en.forced.srt" : "en.srt").path))
            let final=try await processor.inspect(path:path,tools:tools)
            XCTAssertEqual(final.streams.filter(\.attachedPic).count,kind == "movie" ? 1 : 0)
            XCTAssertEqual(final.streams.filter { $0.kind == "audio" }.count,kind == "movie" ? 2 : 1)
            XCTAssertEqual(final.chapters.count,2)
            XCTAssertEqual(final.streams.first { $0.kind == "subtitle" }?.language,"eng")
            XCTAssertEqual(final.streams.first { $0.kind == "subtitle" }?.forced,kind == "movie")
            let packets = try await processor.run(tools.ffprobe,["-v","error","-select_streams","s:0","-show_packets","-show_entries","packet=pts_time,duration_time","-of","json",path])
            let packetObject = try XCTUnwrap(JSONSerialization.jsonObject(with:packets) as? [String:Any])
            let timings = try XCTUnwrap(packetObject["packets"] as? [[String:String]])
            XCTAssertTrue(timings.contains { abs((Double($0["pts_time"] ?? "") ?? -1) - 0.1) < 0.002 && abs((Double($0["duration_time"] ?? "") ?? -1) - 0.9) < 0.002 },"Embedded subtitle timing must survive publication")
            let metadata=try await processor.run(tools.ffprobe,["-v","error","-show_format","-of","json",path])
            XCTAssertTrue(String(decoding:metadata,as:UTF8.self).contains("Description & <details>"))
            let noRepeat:RelaySnapshot=try await engine.execute(["command":"discover"])
            XCTAssertEqual(noRepeat.jobs.count,1)
            await engine.close()
        }
    }
    func testDisabledTrackAndCancellation() async throws {
        let tools=try MediaTools(directory:project.appendingPathComponent("build/media/install/bin")), processor=DirectProcessor()
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root.appendingPathComponent("intake"),withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:root) }
        let input=try fixture(root), info=try await processor.inspect(path:input.path,tools:tools)
        let streams=try DirectProcessor.selectedStreams(info,choices:[TrackChoice(index:2,enabled:false)])
        XCTAssertEqual(streams.filter { $0.kind == "audio" }.count,1)
        var unsupported = info
        var data = info.streams[0]; data.index=99; data.kind="data";data.codec="bin_data";data.codecTag="gpmd"
        unsupported.streams.append(data)
        XCTAssertThrowsError(try DirectProcessor.selectedStreams(unsupported,choices:[]))
        await processor.cancel()
        do { _ = try await processor.run(tools.ffprobe,[input.path]);XCTFail("Cancelled process must not start") } catch {}
    }
}
