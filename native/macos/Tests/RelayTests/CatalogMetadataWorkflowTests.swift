import AppKit
import XCTest
@testable import RelayKit
@testable import Relay

private final class CatalogWorkflowHTTP: URLProtocol {
    static var failingEpisode: Int?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let path = request.url!.path
        let number = Int(path.components(separatedBy: "/").last ?? "") ?? 0
        let status = path.contains("/episode/") && number == Self.failingEpisode ? 503 : 200
        let payload: String
        let image = request.url!.host == "image.tmdb.org"
        if image { payload = "" }
        else if path.contains("/episode/") {
            payload = """
            {"id":\(number + 100),"overview":"Episode \(number) plot","air_date":"2025-09-08",
             "credits":{"cast":[{"name":"Host"}],"guest_stars":[{"name":"Guest \(number)"}],"crew":[{"name":"Director","job":"Director"}]}}
            """
        } else if path.contains("/season/") {
            payload = #"{"id":10,"overview":"Season plot","credits":{"crew":[]}}"#
        } else {
            payload = #"{"id":123,"tagline":"Shared tagline","genres":[{"name":"Comedy"}],"production_companies":[{"name":"Studio"}],"networks":[{"name":"Network"}],"poster_path":"/show.png","credits":{"cast":[],"crew":[]},"images":{"posters":[]},"content_ratings":{"results":[{"iso_3166_1":"US","rating":"TV-MA"}]},"keywords":{"results":[]}}"#
        }
        let bytes = image ? Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aXioAAAAASUVORK5CYII=")! : Data(payload.utf8)
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": image ? "image/png" : "application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: bytes)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@MainActor final class CatalogMetadataWorkflowTests: XCTestCase {
    private func sourceBytes(_ number: Int) -> Data {
        // Minimal readable MP4 headers; no codec process is needed to test tags.
        var bytes = Data([0, 0, 0, 8]) + Data("ftyp".utf8) + Data([0, 0, 0, 116]) + Data("moov".utf8) + Data([0, 0, 0, 108]) + Data("mvhd".utf8)
        bytes.append(Data(repeating: 0, count: 100))
        bytes.replaceSubrange(36..<40, with: [0, 0, 0, 1])
        let payload = Data("source \(number)".utf8)
        bytes.append(Data([0, 0, 0, UInt8(payload.count + 8)]) + Data("mdat".utf8) + payload)
        return bytes
    }
    private func fixture() async throws -> (URL, RelayModel, RelayEngine) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let intake = root.appendingPathComponent("intake"), output = root.appendingPathComponent("output")
        try FileManager.default.createDirectory(at: intake, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for number in 1...6 { try sourceBytes(number).write(to: intake.appendingPathComponent("Episode \(number).mp4")) }
        let engine = try RelayEngine(database: root.appendingPathComponent("state/jobs.sqlite"))
        _ = try await engine.configure(RelayConfig(roots: [intake.path], recursive: false, outputFolder: output.path))
        let state: RelaySnapshot = try await engine.execute(["command": "discover"])
        for job in state.jobs {
            let number = Int(job.identity.episodeTitle.components(separatedBy: " ").last!)!
            var identity = job.identity
            identity.kind = "tv"; identity.title = "Show"; identity.year = 2025; identity.tmdbId = 123; identity.season = 1; identity.episode = number
            var direct = DirectDraft(); direct.metadata["artist"] = "Original artist"
            direct.inspection = try JSONDecoder().decode(MediaInspection.self, from: Data(#"{"streams":[],"chapters":[],"ruleMedia":[{"format":"AVC","height":1080,"width":1920,"profile":"High"}],"duration":1}"#.utf8))
            if number == 2 { direct.metadata["tagline"] = ""; direct.metadata["description"] = "My plot"; direct.overrides = ["tagline", "description", "artwork"] }
            let edited: RelaySnapshot = try await engine.execute(["command": "edit", "id": job.id, "revision": job.revision, "identity": RelayEngine.object(identity), "direct": RelayEngine.object(direct)])
            let current = try XCTUnwrap(edited.jobs.first { $0.id == job.id })
            let _: RelayJob = try await engine.execute(["command": "direct_inspect", "id": job.id, "revision": current.revision, "inspection": RelayEngine.object(direct.inspection!)])
        }
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [CatalogWorkflowHTTP.self]
        let client = CatalogClient(session: URLSession(configuration: config), usage: APIUsageStore(fileURL: nil))
        let model = RelayModel(catalog: client, metadataToken: { "fixture" })
        model.smokeMode = true; model.databaseURL = root.appendingPathComponent("state/jobs.sqlite"); model.engine = engine
        model.snapshot = try await engine.snapshot(); model.selectedIds = Set(model.jobs.map(\.id)); model.loadDraft()
        return (root, model, engine)
    }

    func testCompletesAllSixExistingDraftsAndRetainsOverridesAndSourceFiles() async throws {
        let (root, model, engine) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try await model.completeCatalogMetadata(ids: model.jobs.map(\.id))
        let state = try await engine.snapshot()
        for job in state.jobs {
            let number = job.identity.episode!
            XCTAssertEqual(job.options.metadata["description"], number == 2 ? "My plot" : "Episode \(number) plot")
            XCTAssertEqual(job.options.metadata["tagline"], number == 2 ? "" : "Shared tagline")
            XCTAssertEqual(job.options.metadata["actors"], "Host\nGuest \(number)")
            XCTAssertEqual(job.options.metadata["seasonDescription"], "Season plot")
            XCTAssertEqual(job.options.metadata["genre"], "Comedy")
            XCTAssertEqual(job.options.metadata["studio"], "Studio")
            XCTAssertEqual(job.options.metadata["network"], "Network")
            XCTAssertEqual(job.options.metadata["contentRating"], "TV-MA")
            XCTAssertEqual(job.options.metadata["episodeID"], String(format: "S01E%02d", number))
            XCTAssertEqual(job.options.metadata["artist"], "Original artist")
            XCTAssertEqual(job.state, "needs_review")
            XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: job.currentPath)), sourceBytes(number))
            if number == 2 { XCTAssertEqual(job.options.artworkPath, "") }
            else { XCTAssertFalse(job.options.artworkPath.isEmpty); XCTAssertTrue(FileManager.default.fileExists(atPath: job.options.artworkPath)) }
        }
        await engine.close()
        let reopened = try RelayEngine(database: root.appendingPathComponent("state/jobs.sqlite"))
        let restored = try await reopened.snapshot()
        XCTAssertTrue(restored.jobs.allSatisfy { $0.options.metadata["seasonDescription"] == "Season plot" })
        await reopened.close()
    }

    func testAutomaticFieldsDoNotCopyOneEpisodesPlotOrGuestsToOtherSelectedRows() async throws {
        let (root, model, engine) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let editing = try XCTUnwrap(model.editingId)
        model.mergeMetadata(FullCatalogMetadata(fields: ["description": "Fetched plot", "actors": "Fetched guests"]))
        await model.persistDraft()
        let state = try await engine.snapshot()
        XCTAssertEqual(state.jobs.first { $0.id == editing }?.options.metadata["actors"], "Fetched guests")
        XCTAssertTrue(state.jobs.filter { $0.id != editing }.allSatisfy { $0.options.metadata["actors"] == nil })
        model.editMetadataField("actors", value: "Manual cast for selection")
        await model.persistDraft()
        let edited = try await engine.snapshot()
        XCTAssertTrue(edited.jobs.allSatisfy { $0.options.metadata["actors"] == "Manual cast for selection" && $0.options.overrides.contains("actors") })
        await engine.close()
    }

    func testApplyingShowCompletesEverySelectedEpisodeWithoutSharingEpisodeDetails() async throws {
        let (root, model, engine) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = NSApplication.shared
        model.smokeMode = false
        await model.applyShowToSelection()
        XCTAssertNil(model.error)
        let state = try await engine.snapshot()
        for job in state.jobs {
            XCTAssertEqual(job.options.metadata["actors"], "Host\nGuest \(job.identity.episode!)")
            XCTAssertEqual(job.options.metadata["description"], job.identity.episode == 2 ? "My plot" : "Episode \(job.identity.episode!) plot")
        }
        model.smokeMode = true
        await engine.close()
    }

    func testImportedMetadataSurvivesMP4TagWritingAndReadback() async throws {
        let (root, model, engine) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try await model.completeCatalogMetadata(ids: model.jobs.map(\.id))
        let job = try XCTUnwrap(model.jobs.first { $0.identity.episode == 1 })
        let preview: BatchPreview = try await engine.execute(["command": "direct_preview", "ids": [job.id]])
        XCTAssertTrue(preview.errors.isEmpty, preview.errors.joined(separator: "\n"))
        let _: RelaySnapshot = try await engine.execute(["command": "direct_approve", "token": preview.token])
        let active: RelayJob = try await engine.execute(["command": "direct_begin", "id": job.id])
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: XCTUnwrap(active.options.temporary)))
        try handle.write(contentsOf: sourceBytes(1)); try handle.close()
        let _: RelayJob = try await engine.execute(["command": "direct_tag", "id": job.id])
        let readback: [String: String] = try await engine.execute(["command": "direct_readback", "id": job.id])
        for (key, value) in job.options.metadata where !value.isEmpty { XCTAssertEqual(readback[key], value, "Imported field \(key) was lost during MP4 writing") }
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: job.currentPath)), sourceBytes(1))
        await engine.close()
    }

    func testFailedMetadataPreventsBatchReviewAndRetryCompletesIt() async throws {
        let (root, model, engine) = try await fixture()
        defer { CatalogWorkflowHTTP.failingEpisode = nil; try? FileManager.default.removeItem(at: root) }
        _ = NSApplication.shared
        model.selectedIds = []; model.loadDraft(); model.smokeMode = false
        CatalogWorkflowHTTP.failingEpisode = 2
        await model.directPreview()
        XCTAssertFalse(model.presentingPreview)
        XCTAssertNil(model.preview)
        XCTAssertTrue(model.error?.contains("could not be completed") == true, model.error ?? "No error")
        XCTAssertTrue(model.error?.contains("503") == true, model.error ?? "No error")
        CatalogWorkflowHTTP.failingEpisode = nil
        // Verify retry through the same completion path without creating a batch
        // against the deliberately synthetic video payloads.
        try await model.completeCatalogMetadata(ids: model.jobs.map(\.id))
        let state = try await engine.snapshot()
        XCTAssertTrue(state.jobs.allSatisfy { $0.options.metadata["actors"]?.contains("Guest") == true })
        model.smokeMode = true
        await engine.close()
    }
}
