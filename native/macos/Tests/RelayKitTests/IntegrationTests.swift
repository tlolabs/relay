import XCTest
import Foundation
import Carbon
import IFlicksCapture
@testable import RelayKit

private final class HTTPStub: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (status, data) = try Self.handler!(request)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
private final class EventStub: IFlicksEventSending, @unchecked Sendable {
    struct Call { var suite: String; var command: String; var direct: NSAppleEventDescriptor }
    var values: [String: NSAppleEventDescriptor] = [:]
    var calls: [Call] = []
    var importTimeout = false
    func send(process: IFlicksProcess, suite: String, command: String, direct: NSAppleEventDescriptor, data: NSAppleEventDescriptor?) throws -> NSAppleEventDescriptor {
        calls.append(Call(suite: suite, command: command, direct: direct))
        if command == "odoc", importTimeout { throw IFlicksCommandFailure(code: -1712, message: "Fixture delayed import acknowledgement") }
        let raw = direct.forKeyword(AEKeyword(keyAEKeyData))?.typeCodeValue ?? 0
        let key = String(bytes: [UInt8((raw >> 24) & 255), UInt8((raw >> 16) & 255), UInt8((raw >> 8) & 255), UInt8(raw & 255)], encoding: .macOSRoman) ?? ""
        if command == "setd" { values[key] = data }
        return values[key] ?? .null()
    }
}
private actor QueueStub: IFlicksTransport {
    var videos: [IFlicksVideo]
    init(_ videos: [IFlicksVideo]) { self.videos = videos }
    func sample(process: IFlicksProcess, timeout: TimeInterval) async throws -> [IFlicksVideo] { videos }
}
final class IntegrationTests: XCTestCase {
    func testCoreBridgeDiscoveryAndPersistentStore() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let intake = folder.appendingPathComponent("intake"), output = folder.appendingPathComponent("output")
        try FileManager.default.createDirectory(at: intake, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try Data("fixture".utf8).write(to: intake.appendingPathComponent("Show - S01E01 - Café.mp4"))
        let engine = try RelayEngine(database: folder.appendingPathComponent("state/jobs.sqlite"))
        _ = try await engine.configure(RelayConfig(roots: [intake.path], recursive: false, outputFolder: output.path))
        let discovered: RelaySnapshot = try await engine.execute(["command": "discover"])
        XCTAssertEqual(discovered.jobs.count, 1)
        XCTAssertEqual(discovered.jobs[0].identity.episode, 1)
        let preview: BatchPreview = try await engine.execute(["command": "preview", "ids": [discovered.jobs[0].id]])
        XCTAssertTrue(preview.errors.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: discovered.jobs[0].originalPath))
        await engine.close()
        let reopened = try RelayEngine(database: folder.appendingPathComponent("state/jobs.sqlite"))
        let snapshot = try await reopened.snapshot()
        XCTAssertEqual(snapshot.jobs[0].id, discovered.jobs[0].id)
        await reopened.close()
    }
    private func client() -> CatalogClient {
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [HTTPStub.self]
        return CatalogClient(session: URLSession(configuration: configuration), usage: testAPIUsage())
    }
    func testTMDBEncodesQueriesAndDecodesCatalog() async throws {
        HTTPStub.handler = { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fixture-token")
            XCTAssertEqual(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "query" }?.value, "Café & Friends")
            return (200, Data(#"{"results":[{"id":12,"name":"Café & Friends","first_air_date":"2020-01-01"}]}"#.utf8))
        }
        let titles = try await client().search("Café & Friends", kind: "tv", token: "fixture-token")
        XCTAssertEqual(titles[0].year, 2020)
        XCTAssertEqual(titles[0].displayTitle, "Café & Friends")
    }
    func testCatalogErrorsDoNotEchoTokensOrResponseBodies() async {
        HTTPStub.handler = { _ in (401, Data("private-response-fixture-token".utf8)) }
        do { _ = try await client().search("Title", kind: "movie", token: "fixture-token"); XCTFail("Expected unauthorized error") }
        catch { XCTAssertFalse(error.localizedDescription.contains("fixture-token")); XCTAssertTrue(error.localizedDescription.contains("401")) }
    }
    func testPlexReadOnlyPagination() async throws {
        var pages = 0
        HTTPStub.handler = { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Plex-Token"), "fixture-plex")
            if request.url!.path == "/library/sections" { return (200, Data(#"{"MediaContainer":{"Directory":[{"key":"1","type":"show"}]}}"#.utf8)) }
            pages += 1
            let start = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!.first { $0.name == "X-Plex-Container-Start" }!.value!
            return (200, Data("{\"MediaContainer\":{\"totalSize\":2,\"Metadata\":[{\"ratingKey\":\"\(start)\",\"title\":\"Show \(start)\",\"year\":2020}]}}".utf8))
        }
        let titles = try await client().plexTitles(base: URL(string: "http://127.0.0.1:32400")!, token: "fixture-plex")
        XCTAssertEqual(titles.count, 2); XCTAssertEqual(pages, 2)
    }
    func testApprovedMetadataTargetsExactIDAndReadbackMatches() async throws {
        let transport = EventStub(); transport.values["pSts"] = NSAppleEventDescriptor(enumCode: code("kQue"))
        let controller = IFlicksController(sender: transport)
        var identity = MediaIdentity(); identity.kind = "tv"; identity.title = "Show"; identity.season = 0; identity.episode = 10; identity.episodeTitle = "Bonus"
        let process = IFlicksProcess(pid: 42, launchUnixMs: 1)
        try await controller.applyMetadata(identity, id: "exact-video", process: process)
        try await controller.verifyMetadata(identity, id: "exact-video", process: process)
        let writes = transport.calls.filter { $0.command == "setd" }
        XCTAssertEqual(writes.count, 6)
        for call in writes {
            let object = call.direct.forKeyword(AEKeyword(keyAEContainer))!
            XCTAssertEqual(object.forKeyword(AEKeyword(keyAEKeyForm))?.enumCodeValue, OSType(formUniqueID))
            XCTAssertEqual(object.forKeyword(AEKeyword(keyAEKeyData))?.stringValue, "exact-video")
        }
        XCTAssertEqual(transport.values["pEpD"]?.stringValue, "S00E10")
    }
    func testMetadataConflictIsHeldBeforeStart() async throws {
        let transport = EventStub()
        transport.values["pShw"] = NSAppleEventDescriptor(string: "Wrong show")
        var identity = MediaIdentity(); identity.kind = "tv"; identity.title = "Approved show"; identity.season = 1; identity.episode = 2
        let controller = IFlicksController(sender: transport)
        do { try await controller.verifyMetadata(identity, id: "exact-id", process: IFlicksProcess(pid: 42)); XCTFail("Conflicting readback must hold") } catch {}
        XCTAssertFalse(transport.calls.contains { $0.command == "Strt" })
    }
    func testMovieReleaseDateReadbackUsesApprovedYear() async throws {
        let transport = EventStub(); transport.values["pSts"] = NSAppleEventDescriptor(enumCode: code("kQue"))
        var identity = MediaIdentity(); identity.kind = "movie"; identity.title = "Fixture Movie"; identity.year = 2020; identity.releaseDate = "2020-01-01"
        let controller = IFlicksController(sender: transport)
        try await controller.applyMetadata(identity, id: "movie-id", process: IFlicksProcess(pid: 42))
        try await controller.verifyMetadata(identity, id: "movie-id", process: IFlicksProcess(pid: 42))
        XCTAssertEqual(transport.calls.filter { $0.command == "setd" }.count, 3)
    }
    func testSeriesContextDecodesProductionAndUpcomingEpisode() async throws {
        HTTPStub.handler = { request in
            XCTAssertEqual(request.url!.path, "/3/tv/12")
            return (200, Data(#"{"id":12,"status":"Returning Series","in_production":true,"next_episode_to_air":{"air_date":"2026-10-20"}}"#.utf8))
        }
        let context = try await client().seriesContext(id: 12, token: "fixture-token")
        XCTAssertEqual(context.inProduction, true)
        XCTAssertEqual(context.nextEpisodeToAir?.airDate, "2026-10-20")
    }
    func testWorkingVideoCannotReceiveMetadataWrites() async {
        let transport = EventStub(); transport.values["pSts"] = NSAppleEventDescriptor(enumCode: code("kWrk"))
        let controller = IFlicksController(sender: transport)
        do { try await controller.applyMetadata(MediaIdentity(), id: "x", process: IFlicksProcess(pid: 42)); XCTFail("Expected hold") } catch {}
        XCTAssertFalse(transport.calls.contains { $0.command == "setd" })
    }
    func testImportBindsNewExactPathAndNeverReimportsExistingInput() async throws {
        let transport = EventStub()
        let video = IFlicksVideo(id: "new", status: "queued", statusCode: "kQue", progress: 0, filePath: "/fixture.mp4")
        let controller = IFlicksController(sender: transport, reader: QueueStub([video]), pollAttempts: 2, pollDelay: .milliseconds(1))
        let result = try await controller.importVideo(path: "/fixture.mp4", process: IFlicksProcess(pid: 42), existing: [])
        XCTAssertEqual(result.id, "new")
        XCTAssertEqual(transport.calls.filter { $0.command == "odoc" }.count, 1)
        do { _ = try await controller.importVideo(path: "/fixture.mp4", process: IFlicksProcess(pid: 42), existing: [video]); XCTFail("Expected duplicate hold") } catch {}
        XCTAssertEqual(transport.calls.filter { $0.command == "odoc" }.count, 1)
    }
    func testImportTimeoutStillBindsAcceptedInputWithoutResubmission() async throws {
        let transport = EventStub(); transport.importTimeout = true
        let video = IFlicksVideo(id: "accepted", status: "queued", statusCode: "kQue", progress: 0, filePath: "/fixture.mp4")
        let controller = IFlicksController(sender: transport, reader: QueueStub([video]), pollAttempts: 2, pollDelay: .milliseconds(1))
        let bound = try await controller.importVideo(path: "/fixture.mp4", process: IFlicksProcess(pid: 42), existing: [])
        XCTAssertEqual(bound.id, "accepted")
        XCTAssertEqual(transport.calls.filter { $0.command == "odoc" }.count, 1)
    }
    func testUncertainImportIsNotRepeatedByPolling() async {
        let transport = EventStub()
        let controller = IFlicksController(sender: transport, reader: QueueStub([]), pollAttempts: 2, pollDelay: .milliseconds(1))
        do { _ = try await controller.importVideo(path: "/fixture.mp4", process: IFlicksProcess(pid: 42), existing: []); XCTFail("Expected uncertain import") } catch {}
        XCTAssertEqual(transport.calls.filter { $0.command == "odoc" }.count, 1)
    }
    private func code(_ text: String) -> UInt32 { text.utf8.reduce(0) { ($0 << 8) | UInt32($1) } }
}

final class OutputValidationTests: XCTestCase {
    func testAttachedArtDoesNotCountAsVideo() throws {
        let data = Data(#"{"streams":[{"codec_type":"video","disposition":{"attached_pic":1}}]}"#.utf8)
        XCTAssertThrowsError(try OutputInspector.validateMetadata(data, identity: MediaIdentity()))
    }
    func testConflictingEpisodeMetadataIsHeld() throws {
        var identity = MediaIdentity(); identity.kind = "tv"; identity.title = "Show"; identity.season = 1; identity.episode = 2
        let data = Data(#"{"streams":[{"codec_type":"video"}],"format":{"tags":{"show":"Show","season_number":"1","episode_sort":"3"}}}"#.utf8)
        XCTAssertThrowsError(try OutputInspector.validateMetadata(data, identity: identity)) { error in
            XCTAssertTrue(error.localizedDescription.contains("episode tag is \"3\""))
            XCTAssertTrue(error.localizedDescription.contains("approved value is \"2\""))
            XCTAssertTrue(error.localizedDescription.contains(identity.display))
        }
    }
    func testConflictingMovieMetadataIsHeld() throws {
        var identity = MediaIdentity(); identity.kind = "movie"; identity.title = "Approved"; identity.year = 2020
        let data = Data(#"{"streams":[{"codec_type":"video"}],"format":{"tags":{"title":"Another movie","date":"2020"}}}"#.utf8)
        XCTAssertThrowsError(try OutputInspector.validateMetadata(data, identity: identity))
    }
    func testMatchingOutputMetadataSupportsExplicitAttestation() throws {
        var identity = MediaIdentity(); identity.kind = "tv"; identity.title = "Show"; identity.season = 1; identity.episode = 2
        let data = Data(#"{"streams":[{"codec_type":"video"}],"format":{"tags":{"show":"Show","season_number":"1","episode_sort":"2"}}}"#.utf8)
        XCTAssertTrue(try OutputInspector.validateMetadata(data, identity: identity).contains("Explicit user"))
    }
}

extension IntegrationTests {
    func testEpisodeWebSearchUsesEveryClueAndAcceptsOnlyTMDBShowURLs() async throws {
        let clues = ["A Witch Hunt", "Everybody Pregnant", "Can I Have Your Leg?", "Lesbian Applause Break", "Kids Are Trash", "Have You Been Bad?", "Hal Rose Said to Watch This Episode"]
        var queries = ""
        HTTPStub.handler = { request in
            XCTAssertEqual(request.url!.host, "api.search.brave.com")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Subscription-Token"), "web-fixture")
            queries += URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!.first { $0.name == "q" }!.value!
            return (200, Data(#"{"web":{"results":[{"url":"https://www.themoviedb.org/tv/123-crowd-control/season/2"},{"url":"https://www.themoviedb.org.evil.invalid/tv/999"},{"url":"https://www.themoviedb.org/movie/456"}]}}"#.utf8))
        }
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [HTTPStub.self]
        let ids = try await EpisodeWebSearch(session: URLSession(configuration: config), usage: testAPIUsage()).showIDs(titles: clues, token: "web-fixture")
        XCTAssertEqual(ids, [123])
        for clue in clues { XCTAssertTrue(queries.contains(clue), "Missing clue: \(clue)") }
    }
    func testSeriesCatalogLoadsSpecialsAndEverySeason() async throws {
        var requested = Set<String>()
        HTTPStub.handler = { request in
            let path = request.url!.path; requested.insert(path)
            if path == "/3/tv/123" {
                return (200, Data(#"{"id":123,"name":"Crowd Control","first_air_date":"2025-01-01","seasons":[{"season_number":0},{"season_number":1},{"season_number":2}]}"#.utf8))
            }
            let season = Int(path.split(separator: "/").last!)!
            return (200, Data("{\"episodes\":[{\"id\":\(100 + season),\"name\":\"Episode \(season)\",\"season_number\":\(season),\"episode_number\":1}]}".utf8))
        }
        let value = try await client().seriesCatalog(id: 123, token: "fixture-token")
        XCTAssertEqual(Set(value.episodes.map(\.seasonNumber)), [0, 1, 2])
        XCTAssertEqual(requested.count, 4)
    }
}

final class EpisodeClueTests: XCTestCase {
    private func episode(_ id: Int, _ name: String, _ season: Int = 1) -> EpisodeCandidate {
        EpisodeCandidate(id: id, name: name, seasonNumber: season, episodeNumber: id)
    }
    func testWholeCrowdControlBatchOutranksSingleCoincidentalTitle() {
        let titles = ["A Witch Hunt", "Everybody Pregnant", "Can I Have Your Leg?", "Lesbian Applause Break", "Kids Are Trash", "Have You Been Bad?", "Hal Rose Said to Watch This Episode"]
        let crowd = TVSeriesCatalog(title: CatalogTitle(id: 2, name: "Crowd Control"), episodes: titles.enumerated().map { episode($0.offset + 1, $0.element, $0.offset < 3 ? 1 : 2) })
        let other = TVSeriesCatalog(title: CatalogTitle(id: 1, name: "Another Show"), episodes: [episode(1, "A Witch Hunt")])
        let ranked = EpisodeClues.rank([other, crowd], clues: titles + ["can i have your leg", "Unrelated download"])
        XCTAssertEqual(ranked.first?.catalog.title.displayTitle, "Crowd Control")
        XCTAssertEqual(ranked.first?.matchedTitles.count, 7)
        XCTAssertEqual(ranked.last?.matchedTitles.count, 1)
    }
    func testAmbiguousTitlesAcrossSeasonsAreNeverFilledAutomatically() {
        let episodes = [episode(1, "Pilot", 1), episode(2, "Pilot", 2), episode(3, "Have You Been Bad?", 2)]
        XCTAssertNil(EpisodeClues.exactMatch("Pilot", episodes: episodes))
        XCTAssertNil(EpisodeClues.exactMatch("Have You", episodes: episodes))
        XCTAssertEqual(EpisodeClues.exactMatch("have you been bad", episodes: episodes)?.seasonNumber, 2)
    }
}

final class ArtworkTests: XCTestCase {
    private func atom(_ kind: String, _ payload: Data) -> Data {
        var size = UInt32(payload.count + 8).bigEndian
        return withUnsafeBytes(of: &size) { Data($0) } + Data(kind.utf8) + payload
    }
    private func fixture() -> Data {
        atom("ftyp", Data("isom0000".utf8)) + atom("moov", atom("udta", atom("meta", Data(repeating: 0, count: 4) + atom("ilst", atom("covr", Data("art".utf8)) + atom("test", Data("other metadata".utf8)))))) + atom("mdat", Data("video bytes".utf8))
    }
    func testArtworkFailureRestoresAtomAndMalformedInputIsUnchanged() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("fixture.mp4"), original = fixture()
        try original.write(to: file)
        XCTAssertThrowsError(try MP4Artwork.remove(path: file.path) { throw RelayFailure.message("probe failed") })
        XCTAssertEqual(try Data(contentsOf: file), original)
        let broken = original + Data([0, 0, 0, 255, 98, 97, 100, 33])
        try broken.write(to: file)
        XCTAssertThrowsError(try MP4Artwork.remove(path: file.path) {})
        XCTAssertEqual(try Data(contentsOf: file), broken)
    }
    func testRealTVArtworkRemovedWithoutChangingMediaBytesAndMovieArtworkPreserved() async throws {
        guard FileManager.default.isExecutableFile(atPath: "/usr/local/bin/ffmpeg"), FileManager.default.isExecutableFile(atPath: "/usr/local/bin/ffprobe") else { throw XCTSkip("ffmpeg/ffprobe fixture tools are unavailable") }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("fixture.mp4")
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/local/bin/ffmpeg")
        let base = folder.appendingPathComponent("base.mp4")
        process.arguments = ["-v", "error", "-f", "lavfi", "-i", "color=c=black:s=64x64:r=5:d=1", "-c:v", "libx264", base.path]
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run(); process.waitUntilExit(); XCTAssertEqual(process.terminationStatus, 0)
        let cover = Process(); cover.executableURL = process.executableURL
        cover.arguments = ["-v", "error", "-i", base.path, "-f", "lavfi", "-i", "color=c=red:s=32x32:d=1", "-map", "0:v", "-map", "1:v", "-c:v:0", "copy", "-c:v:1", "mjpeg", "-frames:v:1", "1", "-disposition:v:1", "attached_pic", "-metadata", "show=Fixture Show", "-metadata", "season_number=1", "-metadata", "episode_sort=2", file.path]
        cover.standardOutput = FileHandle.nullDevice; cover.standardError = FileHandle.nullDevice
        try cover.run(); cover.waitUntilExit(); XCTAssertEqual(cover.terminationStatus, 0)
        let before = try Data(contentsOf: file)
        let inode = try FileManager.default.attributesOfItem(atPath: file.path)[.systemFileNumber] as! NSNumber
        var project = URL(fileURLWithPath: #filePath); for _ in 0..<5 { project.deleteLastPathComponent() }
        let inspector = OutputInspector(executable: project.appendingPathComponent("build/media/install/bin/ffprobe"))
        var movie = MediaIdentity(); movie.kind = "movie"
        _ = try await inspector.prepareConfirmedOutput(path: file.path, identity: movie)
        XCTAssertEqual(try Data(contentsOf: file), before)
        var tv = MediaIdentity(); tv.kind = "tv"; tv.title = "Fixture Show"; tv.season = 1; tv.episode = 2
        let evidence = try await inspector.prepareConfirmedOutput(path: file.path, identity: tv)
        XCTAssertTrue(evidence.contains("removed 1"))
        let after = try Data(contentsOf: file)
        XCTAssertEqual(before.count, after.count)
        XCTAssertEqual(zip(before, after).filter { $0 != $1 }.count, 4)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: file.path)[.systemFileNumber] as? NSNumber, inode)
        _ = try await inspector.validate(path: file.path, identity: tv)
        // A second confirmation is a no-op once cover art is absent.
        _ = try await inspector.prepareConfirmedOutput(path: file.path, identity: tv)
        XCTAssertEqual(try Data(contentsOf: file), after)
    }
}

extension IntegrationTests {
    func testPlexShowIDFindsNewDownloadedEpisodesThroughTMDBWithoutWebSearch() async throws {
        HTTPStub.handler = { request in
            switch request.url!.path {
            case "/library/sections":
                return (200, Data(#"{"MediaContainer":{"Directory":[{"key":"1","type":"show"}]}}"#.utf8))
            case "/library/sections/1/all":
                let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
                XCTAssertEqual(items.first { $0.name == "includeGuids" }?.value, "1")
                return (200, Data(#"{"MediaContainer":{"totalSize":1,"Metadata":[{"ratingKey":"500","title":"Crowd Control","year":2025,"guid":"plex://show/fixture","Guid":[{"id":"tmdb://123"}],"showOrdering":"aired"}]}}"#.utf8))
            case "/3/tv/123":
                return (200, Data(#"{"id":123,"name":"Crowd Control","first_air_date":"2025-01-01","seasons":[{"season_number":2}]}"#.utf8))
            case "/3/tv/123/season/2":
                return (200, Data(#"{"episodes":[{"id":1,"name":"Everybody Pregnant","season_number":2,"episode_number":1},{"id":2,"name":"A Witch Hunt","season_number":2,"episode_number":4}]}"#.utf8))
            default: XCTFail("Unexpected request (web search should not be needed)"); return (404, Data())
            }
        }
        let client = client()
        let library = try await client.plexTitles(base: URL(string: "http://127.0.0.1:32400")!, token: "plex-fixture")
        XCTAssertEqual(library.first?.tmdbId, 123)
        let show = try await client.seriesCatalog(id: library[0].tmdbId!, token: "tmdb-fixture")
        let result = EpisodeClues.rank([show], clues: ["Everybody Pregnant", "A Witch Hunt"])
        XCTAssertEqual(result.first?.catalog.title.displayTitle, "Crowd Control")
        XCTAssertEqual(result.first?.matchedTitles.count, 2)
    }
}

final class FullMetadataTests: XCTestCase {
    func testMovieCreditsRatingsAndPostersUseCanonicalDetailResponse() async throws {
        let configuration=URLSessionConfiguration.ephemeral;configuration.protocolClasses=[HTTPStub.self]
        HTTPStub.handler = { request in
            XCTAssertTrue(request.url!.path.hasSuffix("/movie/123"))
            XCTAssertTrue(request.url!.query!.contains("language=fr-FR"))
            return (200,Data(#"{"id":123,"overview":"Plot","tagline":"Tagline","release_date":"2025-01-02","poster_path":"/one.jpg","genres":[{"name":"Drama"}],"production_companies":[{"name":"Studio"}],"credits":{"cast":[{"name":"Actor"}],"crew":[{"name":"Director","job":"Director"},{"name":"Producer","job":"Producer"},{"name":"Writer","job":"Screenplay"}]},"release_dates":{"results":[{"iso_3166_1":"US","release_dates":[{"certification":"PG-13"}]}]},"images":{"posters":[{"file_path":"/one.jpg"},{"file_path":"/two.jpg"}]}}"#.utf8))
        }
        defer { HTTPStub.handler = nil }
        let client=CatalogClient(session:URLSession(configuration:configuration),usage:testAPIUsage())
        let value=try await client.fullMetadata(id:123,kind:"movie",language:"fr-FR",token:"fixture")
        XCTAssertEqual(value.fields["actors"],"Actor");XCTAssertEqual(value.fields["directors"],"Director")
        XCTAssertEqual(value.fields["contentRating"],"PG-13");XCTAssertEqual(value.artwork.count,2)
        XCTAssertNil(value.fields["contentID"],"TMDB IDs must not become Apple content IDs")
    }
}
