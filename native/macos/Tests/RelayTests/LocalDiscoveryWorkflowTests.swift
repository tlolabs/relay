import XCTest
@testable import Relay
@testable import RelayKit

private final class LocalDiscoveryHTTP: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, String))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (code, json) = try Self.handler!(request)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: [:])!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(json.utf8)); client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
@MainActor final class LocalDiscoveryWorkflowTests: XCTestCase {
    func fixture(onIdentificationToken: @escaping () -> Void = {}) async throws -> (URL, RelayModel, RelayEngine) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let intake = root.appendingPathComponent("intake")
        try FileManager.default.createDirectory(at: intake, withIntermediateDirectories: true)
        for (number, title) in [(8, "Eight"), (9, "Coming out lunging")] {
            let stem = "Season 5 Episode \(number) - '\(title)'"
            try Data("fixture".utf8).write(to: intake.appendingPathComponent(stem + ".mp4"))
            try Data("Welcome to Taskmaster Australia.".utf8).write(to: intake.appendingPathComponent(stem + ".srt"))
        }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("out"), withIntermediateDirectories: true)
        let database = root.appendingPathComponent("state/jobs.sqlite")
        let engine = try RelayEngine(database: database)
        _ = try await engine.configure(RelayConfig(roots: [intake.path], recursive: false, outputFolder: root.appendingPathComponent("out").path))
        let session = URLSessionConfiguration.ephemeral; session.protocolClasses = [LocalDiscoveryHTTP.self]
        let catalog = CatalogClient(session: URLSession(configuration: session), usage: APIUsageStore(fileURL: nil))
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        defaults.set("https://plex.example", forKey: "plexURL")
        let model = RelayModel(preferences: defaults, catalog: catalog, metadataToken: { onIdentificationToken(); return "fixture" }, plexToken: { "plex-fixture-secret" })
        model.smokeMode = true; model.databaseURL = database; model.engine = engine
        model.snapshot = try await engine.execute(["command": "discover"])
        model.plexTitles = [PlexTitle(id: "7", title: "Taskmaster Australia", tmdbId: 123)]
        return (root, model, engine)
    }
    func savedCatalog() -> TVSeriesCatalog {
        TVSeriesCatalog(title: CatalogTitle(id: 123, name: "Taskmaster Australia"), episodes: [
            EpisodeCandidate(id: 8, name: "Eight", seasonNumber: 5, episodeNumber: 8),
            EpisodeCandidate(id: 9, name: "Coming out lunging", seasonNumber: 5, episodeNumber: 9)])
    }
    func testFullyCachedOfflineIdentificationMakesZeroRequestsAndPreservesReview() async throws {
        let (root, model, engine) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        var requests = 0
        LocalDiscoveryHTTP.handler = { _ in requests += 1; throw URLError(.notConnectedToInternet) }
        model.cache(savedCatalog(), name: "tv-catalog-123.json")
        let before = model.jobs.map(\.identity)
        await model.searchCatalog(filenamesOnly: true)
        XCTAssertEqual(requests, 0)
        XCTAssertEqual(model.localExplorations.count, 2)
        XCTAssertEqual(model.folderSuggestions.count, 2)
        XCTAssertTrue(model.matchConfidence.values.allSatisfy(\.canonicalAgreement))
        XCTAssertEqual(model.jobs.map(\.identity), before)
        XCTAssertTrue(model.jobs.allSatisfy { $0.state == "needs_review" && $0.approvedRevision == nil })
        await engine.close()
    }
    func testLocalStagePrecedesRequestsAndBatchSharesOneShowAndSeasonLookup() async throws {
        var observedModel: RelayModel?
        var checkedOrder = false
        let (root, model, engine) = try await fixture(onIdentificationToken: {
            XCTAssertEqual(observedModel?.localExplorations.count, 2)
            checkedOrder = true
        })
        observedModel = model
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertTrue(model.localExplorations.isEmpty)
        var paths: [String] = []
        LocalDiscoveryHTTP.handler = { request in
            let path = request.url!.path; paths.append(path)
            switch path {
            case "/3/tv/123": return (200, #"{"id":123,"name":"Taskmaster Australia","seasons":[{"season_number":5}],"status":"Returning Series","in_production":true,"external_ids":{"imdb_id":"tt123","tvdb_id":456}}"#)
            case "/3/tv/123/season/5": return (200, #"{"episodes":[{"id":8,"name":"Eight","season_number":5,"episode_number":8},{"id":9,"name":"Coming out lunging","season_number":5,"episode_number":9}]}"#)
            default: XCTFail("Broad or duplicate discovery request: \(path)"); return (500, "{}")
            }
        }
        await model.searchCatalog(filenamesOnly: true)
        XCTAssertTrue(checkedOrder)
        XCTAssertEqual(paths, ["/3/tv/123", "/3/tv/123/season/5"])
        XCTAssertEqual(model.folderSuggestions.count, 2)
        XCTAssertEqual(model.savedCatalogs().first?.imdbID, "tt123")
        XCTAssertEqual(model.savedCatalogs().first?.tvdbID, 456)
        XCTAssertTrue(model.providerStatuses.allSatisfy { $0.source == .imdb })
        await engine.close()
    }
    func testStableIMDbMappingReusesCachedIDDespiteLocalizedCatalogName() async throws {
        let (root, model, engine) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        var saved = savedCatalog(); saved.title = CatalogTitle(id: 123, name: "Localized Show Name"); saved.imdbID = "tt123"
        var library = PlexTitle(id: "7", title: "Taskmaster Australia", tmdbId: nil); library.imdbId = "tt123"
        model.plexTitles = [library]
        await model.prepareLocalEvidence()
        var paths: [String] = []
        LocalDiscoveryHTTP.handler = { request in
            let path = request.url!.path; paths.append(path)
            if path == "/3/tv/123" { return (200, #"{"id":123,"name":"Taskmaster Australia","seasons":[{"season_number":5}],"external_ids":{"imdb_id":"tt123"}}"#) }
            if path == "/3/tv/123/season/5" { return (200, #"{"episodes":[{"id":8,"name":"Eight","season_number":5,"episode_number":8},{"id":9,"name":"Coming out lunging","season_number":5,"episode_number":9}]}"#) }
            XCTFail("Stable ID should avoid search: \(path)"); return (500, "{}")
        }
        let resolved = try await model.resolveTargetedCatalogs([saved], localRecords: [], token: "fixture")
        XCTAssertEqual(resolved.handled.count, 2)
        XCTAssertEqual(paths, ["/3/tv/123", "/3/tv/123/season/5"])
        XCTAssertEqual(resolved.catalogs.first?.title.id, 123)
        await engine.close()
    }
    func testContinuingShowRefreshAddsAnnouncedSeasonWithoutRefetchingHistory() async throws {
        let (root, model, engine) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        var saved = savedCatalog(); saved.status = "Returning Series"
        saved.fetchedAt = Date(timeIntervalSince1970: 1); saved.availableSeasons = [5]
        saved.seasonFetchedAt = [5: Date(timeIntervalSince1970: 1)]
        model.cache(saved, name: "tv-catalog-123.json")
        var paths: [String] = []
        LocalDiscoveryHTTP.handler = { request in
            let path = request.url!.path; paths.append(path)
            switch path {
            case "/library/sections": return (200, #"{"MediaContainer":{"Directory":[{"key":"1","type":"show"}]}}"#)
            case "/library/sections/1/all": return (200, #"{"MediaContainer":{"size":1,"totalSize":1,"Metadata":[{"ratingKey":"7","title":"Taskmaster Australia","Guid":[{"id":"tmdb://123"}]}]}}"#)
            case "/library/metadata/7/allLeaves": return (200, #"{"MediaContainer":{"size":0}}"#)
            case "/3/tv/123": return (200, #"{"id":123,"name":"Taskmaster Australia","status":"Returning Series","in_production":true,"seasons":[{"season_number":5},{"season_number":6}]}"#)
            case "/3/tv/123/season/6": return (200, #"{"episodes":[{"id":61,"name":"Announced","season_number":6,"episode_number":1,"air_date":"2099-01-01"}]}"#)
            default: XCTFail("Historical seasons should be reused: \(path)"); return (500, "{}")
            }
        }
        await model.refreshLocalCatalogs()
        XCTAssertNil(model.catalogRefreshState.failure)
        let updated = try XCTUnwrap(model.savedCatalogs().first)
        XCTAssertEqual(updated.episodes.count, 3)
        XCTAssertEqual(updated.episodes.last?.release(), .upcoming)
        XCTAssertEqual(paths.filter { $0.contains("/season/") }, ["/3/tv/123/season/6"])
        await engine.close()
    }
    func testFailedIncompleteRefreshPreservesInventoryAndCatalogBytesAcrossRestart() async throws {
        let (root, model, engine) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let old = PlexInventory(server: "https://plex.example", fetchedAt: Date(timeIntervalSince1970: 1), shows: model.plexTitles, episodes: [.init(showID: "7", season: 5, episode: 8, title: "Eight")])
        model.plexInventory = old; model.cache(old, name: "plex-inventory.json"); model.cache(savedCatalog(), name: "tv-catalog-123.json")
        let oldBytes = try Data(contentsOf: model.cacheFolder!.appendingPathComponent("plex-inventory.json"))
        LocalDiscoveryHTTP.handler = { request in
            switch request.url!.path {
            case "/library/sections": return (200, #"{"MediaContainer":{"Directory":[{"key":"1","type":"show"}]}}"#)
            case "/library/sections/1/all": return (200, #"{"MediaContainer":{"size":1,"totalSize":1,"Metadata":[{"ratingKey":"7","title":"Taskmaster Australia","Guid":[{"id":"tmdb://123"}]}]}}"#)
            default: return (200, #"{"MediaContainer":{"totalSize":2,"size":0}}"#)
            }
        }
        await model.refreshLocalCatalogs()
        XCTAssertNotNil(model.catalogRefreshState.failure)
        XCTAssertNil(model.catalogRefreshState.succeededAt)
        XCTAssertFalse(model.catalogRefreshState.due())
        XCTAssertEqual(try Data(contentsOf: model.cacheFolder!.appendingPathComponent("plex-inventory.json")), oldBytes)
        model.plexInventory = nil; model.restoreLocalContext()
        XCTAssertEqual(model.plexInventory?.episodes.count, 1)
        XCTAssertEqual(model.plexInventory?.fetchedAt, old.fetchedAt)
        XCTAssertEqual(model.plexInventory?.presence(tmdb: 123, season: 5, episode: 9), .unknown)
        XCTAssertEqual(model.savedCatalogs().count, 1)
        await engine.close()
    }
    func testSuccessfulEmptyInventoryIsPersistedAndDistinctFromFailure() async throws {
        let (root, model, engine) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        LocalDiscoveryHTTP.handler = { _ in (200, #"{"MediaContainer":{"size":0}}"#) }
        await model.refreshLocalCatalogs()
        XCTAssertNotNil(model.catalogRefreshState.succeededAt)
        XCTAssertNil(model.catalogRefreshState.failure)
        XCTAssertEqual(model.plexInventory?.shows.count, 0)
        XCTAssertTrue(model.plexInventory?.complete == true)
        let bytes = try Data(contentsOf: model.cacheFolder!.appendingPathComponent("plex-inventory.json"))
        XCTAssertFalse(String(decoding: bytes, as: UTF8.self).contains("secret"))
        await engine.close()
    }
}
