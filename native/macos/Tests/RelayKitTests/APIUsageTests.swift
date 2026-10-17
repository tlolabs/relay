import XCTest
import Foundation
@testable import RelayKit

func testAPIUsage(file: URL? = nil) -> APIUsageStore {
    var policies = Dictionary(uniqueKeysWithValues: APIProvider.allCases.map { ($0, $0.policy) })
    for source in APIProvider.allCases { policies[source]!.interval = 0 }
    return APIUsageStore(testFile: file, policies: policies)
}
private final class UsageClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date: Date
    init(_ value: String = "2026-10-31T23:59:00Z") { date = ISO8601DateFormatter().date(from: value)! }
    func now() -> Date { lock.lock(); defer { lock.unlock() }; return date }
    func advance(_ seconds: TimeInterval) { lock.lock(); date += seconds; lock.unlock() }
}
private final class UsageHTTPStub: URLProtocol {
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

final class APIUsageTests: XCTestCase {
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true); return url
    }
    private func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [UsageHTTPStub.self]
        return URLSession(configuration: config)
    }
    private func policy(daily: Int = 7, monthly: Int = 20, interval: Double = 0) -> APIUsagePolicy {
        APIUsagePolicy(daily: daily, monthly: monthly, interval: interval, published: "Fixture", documentation: "https://example.com")
    }
    func testConcurrentStoresReserveOnlyTheExactDurableBudget() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("usage.json"), clock = UsageClock()
        let first = APIUsageStore(testFile: file, policies: [.omdb: policy()], clock: clock.now)
        let second = APIUsageStore(testFile: file, policies: [.omdb: policy()], clock: clock.now)
        let sent = await withTaskGroup(of: Bool.self) { group in
            for index in 0..<30 { group.addTask { do { try await (index % 2 == 0 ? first : second).reserve(.omdb); return true } catch { return false } } }
            var successes = 0; for await success in group { if success { successes += 1 } }; return successes
        }
        XCTAssertEqual(sent, 7)
        let reopened = APIUsageStore(testFile: file, policies: [.omdb: policy()], clock: clock.now)
        let stats = try await reopened.snapshots().first { $0.provider == .omdb }!
        XCTAssertEqual(stats.today.requests, 7); XCTAssertEqual(stats.today.blocked, 23)
        do { try await reopened.reserve(.omdb); XCTFail("Restart must not replenish the budget") } catch {}
    }
    func testRollingCapsSurviveUTCDayAndMonthReset() async throws {
        let clock = UsageClock(), usage = APIUsageStore(testFile: nil, policies: [.brave: policy(daily: 1, monthly: 1)], clock: clock.now)
        try await usage.reserve(.brave)
        clock.advance(120)
        do { try await usage.reserve(.brave); XCTFail("Crossing midnight must not replenish a rolling cap") } catch {}
        clock.advance(86400 + 3600)
        do { try await usage.reserve(.brave); XCTFail("Brave must retain its rolling monthly cap") } catch {}
        clock.advance(31 * 86400 + 3600)
        try await usage.reserve(.brave)
    }
    func testFailureCacheAndBlockedCountersDoNotRefundRequests() async throws {
        let usage = APIUsageStore(testFile: nil, policies: [.tvmaze: policy(daily: 1)])
        UsageHTTPStub.handler = { _ in throw URLError(.timedOut) }
        do { _ = try await APITransport.send(URLRequest(url: URL(string: "https://api.tvmaze.com/shows/1")!), provider: .tvmaze, session: session(), usage: usage); XCTFail("Must fail") } catch {}
        try await usage.cacheHit(.tvmaze)
        do { try await usage.reserve(.tvmaze); XCTFail("Failed request still counts") } catch {}
        let stats = try await usage.snapshots().first { $0.provider == .tvmaze }!
        XCTAssertEqual(stats.today.requests, 1); XCTAssertEqual(stats.today.failures, 1)
        XCTAssertEqual(stats.today.cacheHits, 1); XCTAssertEqual(stats.today.blocked, 1)
    }
    func testCorruptOrUnwritableLedgerStopsBeforeNetworking() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("usage.json")
        try Data("broken ledger".utf8).write(to: file)
        var requests = 0
        UsageHTTPStub.handler = { _ in requests += 1; return (200, [:], Data()) }
        for url in [file, file.appendingPathComponent("cannot-create.json")] {
            do { _ = try await APITransport.send(URLRequest(url: URL(string: "https://api.tvmaze.com/shows/1")!), provider: .tvmaze, session: session(), usage: testAPIUsage(file: url)); XCTFail("Must stop") }
            catch { XCTAssertTrue(error.localizedDescription.contains("stopped to protect your limits")) }
        }
        XCTAssertEqual(requests, 0)
    }
    func testRetryAfterAndTraktHeadersPauseAcrossRestartWithoutTruncatingLongCooldown() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("usage.json"), clock = UsageClock()
        let usage = APIUsageStore(testFile: file, policies: [.trakt: policy()], clock: clock.now)
        try await usage.reserve(.trakt)
        let response = HTTPURLResponse(url: URL(string: "https://api.trakt.tv")!, statusCode: 429, httpVersion: nil, headerFields: ["Retry-After": "7200"])!
        try await usage.completed(.trakt, response: response)
        let reopened = APIUsageStore(testFile: file, policies: [.trakt: policy()], clock: clock.now)
        clock.advance(3601)
        do { try await reopened.reserve(.trakt); XCTFail("Cooldown must not be shortened to one hour") } catch {}
        clock.advance(3600); try await reopened.reserve(.trakt)
        let reset = ISO8601DateFormatter().string(from: clock.now().addingTimeInterval(600))
        let headers = ["X-Ratelimit": "{\"remaining\":0,\"until\":\"\(reset)\"}"]
        try await reopened.completed(.trakt, response: HTTPURLResponse(url: URL(string: "https://api.trakt.tv")!, statusCode: 200, httpVersion: nil, headerFields: headers)!)
        do { try await reopened.reserve(.trakt); XCTFail("Zero server remaining must stop even after HTTP 200") } catch {}
    }
    func testRedirectsAreCountedAndCrossProviderRedirectsAreNotFollowed() async throws {
        var requests = 0
        UsageHTTPStub.handler = { request in
            requests += 1
            if request.url!.path == "/lookup/shows" { return (301, ["Location": "/shows/1"], Data()) }
            return (200, [:], Data(#"{"id":1}"#.utf8))
        }
        let usage = testAPIUsage()
        _ = try await APITransport.send(URLRequest(url: URL(string: "https://api.tvmaze.com/lookup/shows")!), provider: .tvmaze, session: session(), usage: usage)
        XCTAssertEqual(requests, 2)
        let stats = try await usage.snapshots().first { $0.provider == .tvmaze }!
        XCTAssertEqual(stats.today.requests, 2)
        UsageHTTPStub.handler = { _ in requests += 1; return (302, ["Location": "https://untrusted.example/secret"], Data()) }
        do { _ = try await APITransport.send(URLRequest(url: URL(string: "https://api.tvmaze.com/lookup/shows")!), provider: .tvmaze, session: session(), usage: usage); XCTFail("Must refuse redirect") } catch {}
        XCTAssertEqual(requests, 3)
    }
    func testPacingRechecksAfterSuspensionForConcurrentCalls() async throws {
        let usage = APIUsageStore(testFile: nil, policies: [.tmdb: policy(interval: 0.03)])
        let started = Date()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<4 { group.addTask { try await usage.reserve(.tmdb) } }
            try await group.waitForAll()
        }
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(started), 0.085)
    }
    func testStoredStatsNeverContainAPIKeysOrRequestURLs() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("usage.json"), usage = testAPIUsage(file: file)
        UsageHTTPStub.handler = { _ in (200, [:], Data(#"{"images":{}}"#.utf8)) }
        try await CatalogClient(session: session(), usage: usage).checkTMDB(token: "private-api-key")
        let text = try String(contentsOf: file)
        XCTAssertFalse(text.contains("private-api-key")); XCTAssertFalse(text.contains("http")); XCTAssertFalse(text.contains("configuration"))
    }
    func testMonthlyCapAndBackwardsClockCannotReplenishAllowance() async throws {
        let clock = UsageClock("2026-10-01T12:00:00Z")
        let usage = APIUsageStore(testFile: nil, policies: [.tmdb: policy(daily: 1, monthly: 2)], clock: { clock.now() })
        try await usage.reserve(.tmdb)
        clock.advance(-3600)
        do { try await usage.reserve(.tmdb); XCTFail("Backwards clock must stop requests") } catch {}
        clock.advance(86400 + 7200); try await usage.reserve(.tmdb)
        clock.advance(86400 + 3600)
        do { try await usage.reserve(.tmdb); XCTFail("Monthly cap must persist across daily resets") } catch {}
    }
    func testConnectionChecksExerciseEpisodeSearchAndDoNotAcceptCachedOMDbEvidence() async throws {
        var calls = 0
        UsageHTTPStub.handler = { request in
            calls += 1
            if request.url!.host == "api.trakt.tv" {
                XCTAssertEqual(request.url!.path, "/search/episode")
                XCTAssertEqual(request.value(forHTTPHeaderField: "trakt-api-key"), "secret")
                return (200, [:], Data("[]".utf8))
            }
            return (401, [:], Data(#"{"Response":"False","Error":"Request limit reached!"}"#.utf8))
        }
        let usage = testAPIUsage(), client = MetadataDiscoveryClient(session: session(), usage: usage)
        try await client.checkConnection(.trakt, key: "secret")
        do { try await client.checkConnection(.omdb, key: "secret"); XCTFail("Exhausted quota must fail the check") } catch {}
        do { try await client.checkConnection(.omdb, key: "secret"); XCTFail("Cooldown must stop the next check before sending") } catch {}
        XCTAssertEqual(calls, 2)
        let stats = try await usage.snapshots().first { $0.provider == .omdb }!
        XCTAssertNotNil(stats.cooldownUntil); XCTAssertEqual(stats.today.requests, 1)
    }
    func testBraveZeroUnlimitedLimitDoesNotCreateAMonthLongPause() async throws {
        let usage = testAPIUsage()
        let response = HTTPURLResponse(url: URL(string: "https://api.search.brave.com")!, statusCode: 200, httpVersion: nil,
            headerFields: ["X-RateLimit-Limit": "50, 0", "X-RateLimit-Remaining": "49, 0", "X-RateLimit-Reset": "1, 1200000", "X-RateLimit-Policy": "50;w=1, 0;w=2592000"])!
        try await usage.completed(.brave, response: response)
        try await usage.reserve(.brave)
        let stats = try await usage.snapshots().first { $0.provider == .brave }!
        XCTAssertNil(stats.cooldownUntil); XCTAssertEqual(stats.remoteWindows?.last?.limit, 0)
        XCTAssertEqual(stats.remoteRemaining, 49)
        let finite = HTTPURLResponse(url: response.url!, statusCode: 200, httpVersion: nil,
            headerFields: ["X-RateLimit-Limit": "50, 1000", "X-RateLimit-Remaining": "49, 0", "X-RateLimit-Reset": "1, 1200000"])!
        try await usage.completed(.brave, response: finite)
        do { try await usage.reserve(.brave); XCTFail("Finite monthly quota at zero must pause") } catch {}
    }
}
