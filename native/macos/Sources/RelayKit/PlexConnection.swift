import Foundation

public struct PlexLibrary: Sendable {
    public var titles: [PlexTitle]
    public var televisionLibraries: Int
}

/// Only held in memory. A resource's server token must never enter the catalog cache.
public struct PlexSecureServer: Identifiable, Sendable {
    public var id: String
    public var name: String
    public var connections: [URL]
    public var token: String
}

extension CatalogClient {
    public static func validPlexBase(_ url: URL) -> Bool {
        ["http", "https"].contains(url.scheme?.lowercased() ?? "") && url.host != nil &&
        url.user == nil && url.password == nil && url.query == nil && url.fragment == nil &&
        (url.path.isEmpty || url.path == "/")
    }

    static func plexConnectionError(_ error: Error) -> String {
        guard let error = error as? URLError else { return "Plex connection failed. Check the server address and try Test Connection." }
        switch error.code {
        case .serverCertificateHasBadDate, .serverCertificateUntrusted, .serverCertificateHasUnknownRoot,
             .serverCertificateNotYetValid, .secureConnectionFailed:
            return "Plex HTTPS certificate could not be verified. A .local name or IP address may not match Plex's certificate. Use Find Secure Servers to select the HTTPS address advertised by Plex."
        case .cannotFindHost, .dnsLookupFailed:
            return "Plex server name could not be found. Check the address and network. For a plex.direct address, your router's DNS rebinding protection may need a plex.direct exception."
        case .cannotConnectToHost, .timedOut, .networkConnectionLost, .notConnectedToInternet:
            return "Plex server could not be reached. Check that the server is running, the address and port are correct, and this Mac can reach its network."
        default:
            return "Plex connection failed (network error \(error.code.rawValue)). Check the server address and try Test Connection."
        }
    }

    /// Uses Plex's authenticated resource directory, preserving normal certificate validation.
    public func plexSecureServers(token: String) async throws -> [PlexSecureServer] {
        guard !token.isEmpty else { throw RelayFailure.message("Enter a Plex account token first.") }
        struct Resource: Decodable {
            struct Connection: Decodable { var uri: String; var local: Bool?; var relay: Bool? }
            var name: String; var clientIdentifier: String; var provides: String
            var accessToken: String?; var connections: [Connection]
        }
        let data = try await get(URL(string: "https://plex.tv/api/v2/resources?includeHttps=1&includeRelay=0")!, token: token, plex: true)
        let resources: [Resource]
        do { resources = try JSONDecoder().decode([Resource].self, from: data) }
        catch { throw RelayFailure.message("Plex returned an unexpected server directory. The account could not be checked.") }
        return resources.filter { $0.provides.split(separator: ",").contains("server") }.compactMap { resource in
            var seen = Set<URL>()
            let urls = resource.connections.sorted { ($0.local == true ? 0 : 1) < ($1.local == true ? 0 : 1) }.compactMap { connection -> URL? in
                guard connection.relay != true, let url = URL(string: connection.uri), Self.validPlexBase(url), url.scheme == "https", seen.insert(url).inserted else { return nil }
                return url
            }
            guard !urls.isEmpty else { return nil }
            return PlexSecureServer(id: resource.clientIdentifier, name: resource.name, connections: urls, token: resource.accessToken.flatMap { $0.isEmpty ? nil : $0 } ?? token)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}
