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
        return CatalogClient(session: URLSession(configuration: configuration))
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
