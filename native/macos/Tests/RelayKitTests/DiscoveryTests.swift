import XCTest
import Foundation
@testable import RelayKit

private final class DiscoveryHTTPStub: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, [String: String], Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (status, headers, data) = try Self.handler!(request)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
final class DiscoveryTests: XCTestCase {
    private func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [DiscoveryHTTPStub.self]
        return URLSession(configuration: configuration)
    }
    private func response(_ value: Any, headers: [String: String] = [:]) throws -> (Int, [String: String], Data) { (200, headers, try JSONSerialization.data(withJSONObject: value)) }
    private func parameters(_ request: URLRequest) -> [String: String] {
        Dictionary(uniqueKeysWithValues: (URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
    }
    func testAllAPIProvidersFindEpisodeAndRetainNumberingDifferences() async throws {
        DiscoveryHTTPStub.handler = { request in
            let url = request.url!, q = self.parameters(request)
            switch url.host! {
            case "api.trakt.tv":
                XCTAssertEqual(request.value(forHTTPHeaderField: "trakt-api-key"), "trakt-key")
                XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
                XCTAssertEqual(url.path, "/search/episode"); XCTAssertEqual(q["fields"], "title")
                XCTAssertEqual(q["query"], "Can I Have Your Leg\\?")
                return try self.response([["show": ["title": "Crowd Control", "year": 2025, "ids": ["tmdb": 123, "tvdb": 42, "imdb": "tt123"]], "episode": ["title": "Can I Have Your Leg?", "season": 1, "number": 3, "ids": ["trakt": 7]]]])
            case "www.omdbapi.com":
                XCTAssertEqual(q["apikey"], "omdb-key")
                if q["s"] != nil { return try self.response(["Response": "True", "totalResults": "1", "Search": [["Title": "Can I Have Your Leg?", "imdbID": "tt7", "Type": "episode"]]]) }
                if q["i"] == "tt7" { return try self.response(["Response": "True", "seriesID": "tt123", "Season": "1", "Episode": "3"]) }
                return try self.response(["Response": "True", "Title": "Crowd Control", "Year": "2025–"])
            case "api.tvmaze.com":
                if url.path == "/lookup/shows" { return try self.response(["id": 9, "name": "Crowd Control", "premiered": "2025-01-01", "externals": ["imdb": "tt123", "thetvdb": 42]]) }
                if url.path == "/search/shows" { return try self.response([["show": ["id": 9, "name": "Crowd Control", "premiered": "2025-01-01", "externals": ["imdb": "tt123", "thetvdb": 42]]]]) }
                XCTAssertEqual(q["specials"], "1")
                return try self.response([["id": 90, "name": "Can I Have Your Leg?", "season": 1, "number": 3, "airdate": "2025-01-05"]])
            case "api4.thetvdb.com":
                if url.path == "/v4/login" {
                    XCTAssertEqual(request.httpMethod, "POST")
                    return try self.response(["data": ["token": "tvdb-bearer"]])
                }
                XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer tvdb-bearer")
                if url.path == "/v4/search" { return try self.response(["data": [["tvdb_id": "42", "name": "Crowd Control", "year": "2025"]]]) }
                return try self.response(["data": ["series": ["name": "Crowd Control", "remoteIds": [["id": "tt123", "sourceName": "IMDB"]]], "episodes": [["id": 60, "name": "Can I Have Your Leg?", "seasonNumber": 1, "number": 4]]], "links": ["next": NSNull()]])
            default: XCTFail("Unexpected provider"); return (500, [:], Data())
            }
        }
        let client = MetadataDiscoveryClient(session: session(), usage: testAPIUsage())
        let report = try await client.discover(titles: ["Can I Have Your Leg?"], kind: "tv", seeds: [], credentials: DiscoveryCredentials(trakt: "trakt-key", omdb: "omdb-key", tvdb: "tvdb-key"), cache: nil)
        XCTAssertEqual(Set(report.evidence.map(\.source)), [.trakt, .omdb, .tvmaze, .tvdb])
        XCTAssertTrue(report.statuses.allSatisfy { !$0.incomplete })
        let episode = EpisodeCandidate(id: 7, name: "Can I Have Your Leg?", seasonNumber: 2, episodeNumber: 8)
        let catalog = TVSeriesCatalog(title: CatalogTitle(id: 123, name: "Crowd Control"), episodes: [episode])
        let ranked = MetadataConsensus.rank([catalog], clues: [episode.name], evidence: [123: report.evidence])
        XCTAssertEqual(ranked[0].matchedTitles.count, 1)
        XCTAssertEqual(ranked[0].disagreements.count, 4)
        XCTAssertEqual(ranked[0].catalog.episodes[0].seasonNumber, 2)
    }
    func testProviderOutageAndNoKeyLeaveOtherProviderEvidenceAvailable() async throws {
        DiscoveryHTTPStub.handler = { request in
            if request.url!.host == "api.trakt.tv" { return (429, ["Retry-After": "60"], Data("private-body".utf8)) }
            if self.parameters(request)["s"] != nil { return try self.response(["Response": "True", "totalResults": "1", "Search": [["Title": "Movie", "Year": "2020", "imdbID": "tt20"]]]) }
            XCTFail("Unexpected request"); return (500, [:], Data())
        }
        let client = MetadataDiscoveryClient(session: session(), usage: testAPIUsage())
        let report = try await client.discover(titles: ["Movie"], kind: "movie", seeds: [], credentials: DiscoveryCredentials(trakt: "secret", omdb: "secret"), cache: nil)
        XCTAssertEqual(report.evidence.map(\.source), [.omdb])
        XCTAssertTrue(report.statuses.first { $0.source == .trakt }!.incomplete)
        XCTAssertFalse(report.statuses.map(\.message).joined().contains("secret"))
        XCTAssertFalse(report.statuses.map(\.message).joined().contains("private-body"))
        XCTAssertTrue(report.statuses.first { $0.source == .tvdb }!.message.contains("free API key"))
    }
    func testQuotaAndPersistentCacheDoNotStoreAPIKeys() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let day = ISO8601DateFormatter().string(from: Date()).prefix(10)
        try JSONEncoder().encode(899).write(to: folder.appendingPathComponent("omdb-budget-\(day).json"))
        var requests = 0
        DiscoveryHTTPStub.handler = { _ in requests += 1; return try self.response(["Response": "True", "Search": [], "totalResults": "0"]) }
        let budget = testAPIUsage()
        let http = ProviderHTTP(session: session(), usage: budget), query = [URLQueryItem(name: "s", value: "First")]
        _ = try await http.request(.omdb, path: "/", query: query, token: "never-store-this", cache: folder)
        let reopened = ProviderHTTP(session: session(), usage: budget)
        _ = try await reopened.request(.omdb, path: "/", query: query, token: "another-secret", cache: folder)
        do { _ = try await reopened.request(.omdb, path: "/", query: [URLQueryItem(name: "s", value: "Second")], token: "never-store-this", cache: folder); XCTFail("Budget must hold") } catch {}
        XCTAssertEqual(requests, 1)
        for file in try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) {
            let data = try Data(contentsOf: file)
            XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("never-store-this"))
        }
    }
    func testTraktAndTVDBPaginationKeepAllExactMatches() async throws {
        DiscoveryHTTPStub.handler = { request in
            let q = self.parameters(request), page = Int(q["page"] ?? "0")!
            if request.url!.host == "api.trakt.tv" {
                return try self.response([["show": ["title": "Show", "year": 2020, "ids": ["tmdb": page]], "episode": ["title": "Pilot", "season": 1, "number": 1, "ids": ["trakt": page]]]], headers: ["X-Pagination-Page-Count": "2"])
            }
            if request.url!.path == "/v4/login" { return try self.response(["data": ["token": "bearer"]]) }
            return try self.response(["data": ["series": ["name": "Show"], "episodes": [["id": page + 50, "name": "Pilot", "seasonNumber": page + 1, "number": 1]]], "links": ["next": page == 0 ? "https://api4.thetvdb.com/v4/series/4/episodes/official?page=1" as Any : NSNull()]])
        }
        let client = MetadataDiscoveryClient(session: session(), usage: testAPIUsage())
        let report = try await client.discover(titles: ["Pilot"], kind: "tv", seeds: [DiscoverySeed(title: "Show", year: 2020, ids: DiscoveryIDs(tvdb: 4))], credentials: DiscoveryCredentials(trakt: "key", tvdb: "key"), cache: nil, enabled: [.trakt, .tvdb])
        XCTAssertEqual(report.evidence.filter { $0.source == .trakt }.count, 2)
        XCTAssertEqual(report.evidence.filter { $0.source == .tvdb }.count, 2)
    }
    func testResolverRejectsConflictingIDsAndAmbiguousNameMatches() async throws {
        DiscoveryHTTPStub.handler = { request in
            let url = request.url!
            if url.path == "/3/tv/123" { return try self.response(["id": 123, "name": "Show", "first_air_date": "2020-01-01"]) }
            if url.path.hasPrefix("/3/find/") { return try self.response(["tv_results": [["id": 456, "name": "Another Show"]], "movie_results": []]) }
            return try self.response(["results": [["id": 1, "name": "Shared Name"], ["id": 2, "name": "Shared Name"]]])
        }
        let resolver = TMDBDiscoveryResolver(catalog: CatalogClient(session: session(), usage: testAPIUsage()))
        let report = try await resolver.resolve([
            DiscoveryEvidence(source: .trakt, recordID: "1", title: "Show", ids: DiscoveryIDs(tmdb: 123, imdb: "tt456")),
            DiscoveryEvidence(source: .tvmaze, recordID: "2", title: "Shared Name")
        ], token: "fixture")
        XCTAssertTrue(report.titles.isEmpty); XCTAssertEqual(report.unresolved.count, 2)
        XCTAssertTrue(report.unresolved.joined().contains("identifiers disagree"))
    }
    func testResolverOnlyAppliesTMDBMovieMetadata() async throws {
        DiscoveryHTTPStub.handler = { request in
            XCTAssertEqual(self.parameters(request)["external_source"], "imdb_id")
            return try self.response(["movie_results": [["id": 20, "title": "TMDB Title", "release_date": "2021-02-03"]], "tv_results": []])
        }
        let resolver = TMDBDiscoveryResolver(catalog: CatalogClient(session: session(), usage: testAPIUsage()))
        let report = try await resolver.resolve([DiscoveryEvidence(source: .omdb, recordID: "tt20", kind: "movie", title: "Provider Title", year: 2020, ids: DiscoveryIDs(imdb: "tt20"))], token: "fixture")
        XCTAssertEqual(report.titles[0].displayTitle, "TMDB Title"); XCTAssertEqual(report.titles[0].year, 2021)
        XCTAssertEqual(report.titles[0].releaseDate, "2021-02-03")
        XCTAssertEqual(report.evidence[20]?[0].title, "Provider Title")
    }
    func testDuplicateEvidenceDoesNotInflateVotesAndMissingTMDBTitlesStayUnfilled() {
        let record = DiscoveryEvidence(source: .trakt, recordID: "one", title: "Show", episode: DiscoveredEpisode(title: "External Title", season: 1, number: 2))
        let catalog = TVSeriesCatalog(title: CatalogTitle(id: 1, name: "Show"), episodes: [EpisodeCandidate(id: 2, name: "Different TMDB Title", seasonNumber: 1, episodeNumber: 2)])
        let matches = MetadataConsensus.rank([catalog], clues: ["External Title"], evidence: [1: [record, record, record]])
        XCTAssertEqual(matches[0].evidence.count, 1); XCTAssertEqual(matches[0].matchedTitles.count, 0)
        XCTAssertEqual(matches[0].disagreements.count, 2)
        XCTAssertNil(EpisodeClues.exactMatch("External Title", episodes: catalog.episodes))
    }
}

extension DiscoveryTests {
    func testAllMovieProvidersResolveCollectivelyToTMDB() async throws {
        DiscoveryHTTPStub.handler = { request in
            let host = request.url!.host!, path = request.url!.path
            if host == "api.trakt.tv" {
                XCTAssertEqual(path, "/search/movie")
                return try self.response([["movie": ["title": "Provider Movie", "year": 2020, "ids": ["trakt": 20, "tmdb": 20, "imdb": "tt20"]]]])
            }
            if host == "www.omdbapi.com" {
                XCTAssertEqual(self.parameters(request)["type"], "movie")
                return try self.response(["Response": "True", "totalResults": "1", "Search": [["Title": "Provider Movie", "Year": "2020", "imdbID": "tt20"]]])
            }
            if host == "api4.thetvdb.com" {
                if path == "/v4/login" { return try self.response(["data": ["token": "bearer"]]) }
                if path == "/v4/search" {
                    XCTAssertEqual(self.parameters(request)["type"], "movie")
                    return try self.response(["data": [["tvdb_id": "8", "name": "Provider Movie", "year": "2020"]]])
                }
                return try self.response(["data": ["id": 8, "remoteIds": [["id": "tt20", "sourceName": "IMDB"]]]])
            }
            if path == "/3/movie/20" { return try self.response(["id": 20, "title": "Canonical Movie", "release_date": "2021-01-01"]) }
            return try self.response(["movie_results": [["id": 20, "title": "Canonical Movie", "release_date": "2021-01-01"]], "tv_results": []])
        }
        let urlSession = session(), client = MetadataDiscoveryClient(session: urlSession, usage: testAPIUsage())
        let report = try await client.discover(titles: ["Provider Movie"], kind: "movie", seeds: [], credentials: DiscoveryCredentials(trakt: "key", omdb: "key", tvdb: "key"), cache: nil)
        XCTAssertEqual(Set(report.evidence.map(\.source)), [.trakt, .omdb, .tvdb])
        let resolved = try await TMDBDiscoveryResolver(catalog: CatalogClient(session: urlSession, usage: testAPIUsage())).resolve(report.evidence, token: "key")
        XCTAssertTrue(resolved.unresolved.isEmpty)
        XCTAssertEqual(resolved.titles.count, 1); XCTAssertEqual(resolved.evidence[20]?.count, 3)
        XCTAssertEqual(resolved.titles.first?.displayTitle, "Canonical Movie"); XCTAssertEqual(resolved.titles.first?.year, 2021)
    }
}

extension DiscoveryTests {
    func testCollectiveCluesRankIncompleteTMDBCatalogAndAliasUsesCanonicalNumber() {
        let canonical = EpisodeCandidate(id: 10, name: "Canonical Episode Title", seasonNumber: 2, episodeNumber: 8)
        let records = [
            DiscoveryEvidence(source: .imdb, recordID: "1", title: "Show", episode: DiscoveredEpisode(title: canonical.name, season: 1, number: 3), matchedClue: "Downloaded Alias"),
            DiscoveryEvidence(source: .trakt, recordID: "2", title: "Show", episode: DiscoveredEpisode(title: "Missing Title", season: 1, number: 4))
        ]
        let catalog = TVSeriesCatalog(title: CatalogTitle(id: 1, name: "Show"), episodes: [canonical])
        let other = TVSeriesCatalog(title: CatalogTitle(id: 2, name: "Other"), episodes: [EpisodeCandidate(id: 20, name: "Missing Title", seasonNumber: 1, episodeNumber: 1)])
        let ranked = MetadataConsensus.rank([other, catalog], clues: ["Downloaded Alias", "Missing Title"], evidence: [1: records])
        XCTAssertEqual(ranked[0].id, 1); XCTAssertEqual(ranked[0].supportedTitles.count, 2)
        let filled = MetadataConsensus.episode(for: "Downloaded Alias", episodes: catalog.episodes, evidence: records)
        XCTAssertEqual(filled?.seasonNumber, 2); XCTAssertEqual(filled?.episodeNumber, 8); XCTAssertEqual(filled?.name, canonical.name)
        XCTAssertNil(MetadataConsensus.episode(for: "Missing Title", episodes: catalog.episodes, evidence: records))
    }
    func testConflictingAliasesNeverPickFirstCanonicalEpisode() {
        let episodes = [EpisodeCandidate(id: 1, name: "One", seasonNumber: 1, episodeNumber: 1), EpisodeCandidate(id: 2, name: "Two", seasonNumber: 1, episodeNumber: 2)]
        let evidence = [DiscoveryEvidence(source: .imdb, recordID: "1", title: "Show", episode: DiscoveredEpisode(title: "One"), matchedClue: "Alias"), DiscoveryEvidence(source: .trakt, recordID: "2", title: "Show", episode: DiscoveredEpisode(title: "Two"), matchedClue: "Alias")]
        XCTAssertNil(MetadataConsensus.episode(for: "Alias", episodes: episodes, evidence: evidence))
    }
}
