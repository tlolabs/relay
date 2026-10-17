import XCTest
import Foundation
@testable import RelayKit

private final class PlexHTTPStub: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (status, data) = try Self.handler!(request)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

final class PlexConnectionTests: XCTestCase {
    private func client() -> CatalogClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PlexHTTPStub.self]
        return CatalogClient(session: URLSession(configuration: configuration), usage: testAPIUsage())
    }
    func testSecureDirectoryKeepsServerTokensInMemoryAndPrefersLocalHTTPS() async throws {
        PlexHTTPStub.handler = { request in
            XCTAssertEqual(request.url!.host, "plex.tv")
            XCTAssertEqual(request.url!.path, "/api/v2/resources")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Plex-Token"), "account-secret")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Plex-Client-Identifier"), "com.tlolabs.relay")
            XCTAssertFalse(request.url!.absoluteString.contains("account-secret"))
            let data = #"[{"name":"My Server","clientIdentifier":"one","provides":"server","accessToken":"server-secret","connections":[{"uri":"https://remote.plex.direct:32400","local":false},{"uri":"http://192.168.1.2:32400","local":true},{"uri":"https://local.plex.direct:32400","local":true},{"uri":"https://local.plex.direct:32400","local":true},{"uri":"https://relay.plex.direct:443","relay":true},{"uri":"https://user:secret@invalid.example","local":true},{"uri":"https://invalid.example/?X-Plex-Token=secret"}]},{"name":"Player","clientIdentifier":"two","provides":"player","connections":[{"uri":"https://player.example"}]}]"#
            return (200, Data(data.utf8))
        }
        let servers = try await client().plexSecureServers(token: "account-secret")
        XCTAssertEqual(servers.count, 1)
        XCTAssertEqual(servers[0].token, "server-secret")
        XCTAssertEqual(servers[0].connections.map(\.host), ["local.plex.direct", "remote.plex.direct"])
    }
    func testCertificateFailureDoesNotRetryOverHTTPOrClaimConnection() async throws {
        var count = 0
        PlexHTTPStub.handler = { request in
            count += 1
            XCTAssertEqual(request.url!.scheme, "https")
            throw URLError(.serverCertificateUntrusted, userInfo: [NSLocalizedDescriptionKey: "private diagnostic token=secret"])
        }
        do {
            _ = try await client().plexLibrary(base: URL(string: "https://tkplex.local:32400")!, token: "secret")
            XCTFail("The certificate failure must propagate")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Find Secure Servers"))
            XCTAssertFalse(error.localizedDescription.contains("secret"))
        }
        XCTAssertEqual(count, 1)
    }
    func testRejectedTokenAndUnavailableHostHaveDistinctActionableErrors() async throws {
        PlexHTTPStub.handler = { _ in (401, Data("secret-body".utf8)) }
        do { _ = try await client().plexSecureServers(token: "secret"); XCTFail("Must reject") }
        catch { XCTAssertTrue(error.localizedDescription.contains("rejected the token")); XCTAssertFalse(error.localizedDescription.contains("secret")) }
        PlexHTTPStub.handler = { _ in throw URLError(.timedOut) }
        do { _ = try await client().plexLibrary(base: URL(string: "https://server.example")!, token: "secret"); XCTFail("Must reject") }
        catch { XCTAssertTrue(error.localizedDescription.contains("could not be reached")) }
    }
    func testEmptyLibraryIsAuthenticatedButNotAnUnexpectedResponse() async throws {
        PlexHTTPStub.handler = { _ in (200, Data(#"{"MediaContainer":{"size":0}}"#.utf8)) }
        let result = try await client().plexLibrary(base: URL(string: "https://server.example")!, token: "secret")
        XCTAssertEqual(result.televisionLibraries, 0); XCTAssertTrue(result.titles.isEmpty)
        PlexHTTPStub.handler = { _ in (200, Data(#"{"MediaContainer":{"unrelated":"payload"}}"#.utf8)) }
        do { _ = try await client().plexLibrary(base: URL(string: "https://server.example")!, token: "secret"); XCTFail("Must reject") }
        catch { XCTAssertTrue(error.localizedDescription.contains("unexpected library list")) }
    }
    func testIncompleteLibraryDoesNotReturnASuccessfulPartialCount() async throws {
        PlexHTTPStub.handler = { request in
            if request.url!.path == "/library/sections" { return (200, Data(#"{"MediaContainer":{"Directory":[{"key":"1","type":"show"}]}}"#.utf8)) }
            return (200, Data(#"{"MediaContainer":{"size":0,"totalSize":4,"Metadata":[]}}"#.utf8))
        }
        do { _ = try await client().plexLibrary(base: URL(string: "https://server.example")!, token: "secret"); XCTFail("Must reject") }
        catch { XCTAssertTrue(error.localizedDescription.contains("fully loaded")) }
    }
    func testBaseURLValidationRejectsWebPathsAndEmbeddedTokens() {
        XCTAssertTrue(CatalogClient.validPlexBase(URL(string: "https://server.plex.direct:32400/")!))
        for value in ["https://server/web", "https://server/?X-Plex-Token=secret", "https://server/#fragment", "https://user:secret@server", "file:///tmp/server"] {
            XCTAssertFalse(CatalogClient.validPlexBase(URL(string: value)!))
        }
    }
}
