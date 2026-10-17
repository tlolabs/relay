import Foundation

private final class StopAutomaticRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

enum APITransport {
    /// Count redirects as separate attempts too. Never forward credentials to
    /// another provider or silently downgrade an HTTPS connection.
    static func send(_ initial: URLRequest, provider: APIProvider, session: URLSession, usage: APIUsageStore) async throws -> (Data, HTTPURLResponse) {
        var request = initial
        request.cachePolicy = .reloadIgnoringLocalCacheData
        for hop in 0...3 {
            try await usage.reserve(provider)
            let data: Data, response: URLResponse
            do { (data, response) = try await session.data(for: request, delegate: StopAutomaticRedirects()) }
            catch {
                try await usage.completed(provider, response: nil)
                if Task.isCancelled || (error as? URLError)?.code == .cancelled { throw CancellationError() }
                if provider == .plex { throw RelayFailure.message(CatalogClient.plexConnectionError(error)) }
                throw RelayFailure.message("\(provider.rawValue) connection failed. Check network access and connection settings.")
            }
            guard let http = response as? HTTPURLResponse else {
                try await usage.completed(provider, response: nil)
                throw RelayFailure.message("\(provider.rawValue) returned an unexpected response.")
            }
            try await usage.completed(provider, response: http)
            try Task.checkCancellation()
            if [301, 302, 303, 307, 308].contains(http.statusCode), let location = http.value(forHTTPHeaderField: "Location"), let current = request.url,
               let url = URL(string: location, relativeTo: current)?.absoluteURL {
                let sameHost = url.host?.lowercased() == current.host?.lowercased()
                let plexDirectory = provider == .plex && ["plex.tv", "clients.plex.tv"].contains(current.host?.lowercased() ?? "") && ["plex.tv", "clients.plex.tv"].contains(url.host?.lowercased() ?? "")
                guard hop < 3, sameHost || plexDirectory, url.scheme == current.scheme, url.user == nil, url.password == nil else {
                    throw RelayFailure.message("\(provider.rawValue) requested an unsupported redirect. Check its connection address.")
                }
                request.url = url
                if http.statusCode == 303 { request.httpMethod = "GET"; request.httpBody = nil }
                continue
            }
            if http.statusCode == 429 { throw RelayFailure.message("\(provider.rawValue) rate limit reached. Relay has paused further requests; see API Usage in Settings.") }
            return (data, http)
        }
        throw RelayFailure.message("\(provider.rawValue) returned too many redirects.")
    }
}
