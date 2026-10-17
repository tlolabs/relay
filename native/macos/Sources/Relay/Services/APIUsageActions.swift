import AppKit
import Foundation
import RelayKit

extension RelayModel {
    func invalidateAPIConnection(_ provider: APIProvider) {
        Task {
            try? await APIUsageStore.shared.checked(provider, result: APIConnectionCheck(passed: false, message: "Settings changed. Test this connection again."))
            await refreshAPIUsage()
        }
    }
    func refreshAPIUsage() async {
        do { apiUsage = try await APIUsageStore.shared.snapshots(); apiUsageError = "" }
        catch { apiUsageError = error.localizedDescription }
    }
    func beginConnectionChecks(only: APIProvider? = nil) {
        guard !checkingConnections else { return }
        cancelCatalogSearch()
        connectionCheckTask = Task { await checkAPIConnections(only: only) }
    }
    func checkAPIConnections(only: APIProvider? = nil, plexOverride: URL? = nil) async {
        guard !checkingConnections else { return }
        checkingConnections = true
        defer { checkingConnections = false }
        for provider in APIProvider.allCases where only == nil || provider == only {
            guard !Task.isCancelled else { break }
            let result: APIConnectionCheck
            do {
                switch provider {
                case .tmdb:
                    let token = try CredentialStore.read("tmdb") ?? ""
                    guard !token.isEmpty else { throw RelayFailure.message("Not configured: add a TMDB API Read Access Token.") }
                    try await catalog.checkTMDB(token: token)
                case .trakt, .omdb, .tvdb, .tvmaze:
                    let source: MetadataSource = provider == .trakt ? .trakt : provider == .omdb ? .omdb : provider == .tvdb ? .tvdb : .tvmaze
                    guard sourceEnabled(source) else { throw RelayFailure.message("Disabled in Data Sources; no test request sent.") }
                    let account = provider == .trakt ? "trakt" : provider == .omdb ? "omdb" : "tvdb"
                    let key = try provider == .tvmaze ? "" : CredentialStore.read(account) ?? ""
                    guard provider == .tvmaze || !key.isEmpty else { throw RelayFailure.message("Not configured: no API key saved.") }
                    try await metadataDiscovery.checkConnection(source, key: key)
                case .brave:
                    let token = try CredentialStore.read("brave-search") ?? ""
                    guard !token.isEmpty else { throw RelayFailure.message("Not configured: no Brave Search key saved.") }
                    _ = try await episodeWebSearch.showIDs(titles: ["Crowd Control"], token: token)
                case .plex:
                    let token = try CredentialStore.read("plex") ?? ""
                    guard !token.isEmpty else { throw RelayFailure.message("Not configured: no Plex token saved.") }
                    if let plexOverride {
                        guard plexOverride.scheme == "https", CatalogClient.validPlexBase(plexOverride) else { throw RelayFailure.message("The replacement Plex URL must be a valid HTTPS base URL.") }
                        // Only replace the saved address after a complete authenticated library read.
                        let library = try await catalog.plexLibrary(base: plexOverride, token: token)
                        UserDefaults.standard.set(plexOverride.absoluteString, forKey: "plexURL")
                        resetPlexConnection()
                        acceptPlexLibrary(library, base: plexOverride)
                    } else { await loadPlex() }
                    guard plexConnectionVerified else { throw RelayFailure.message(plexMessage) }
                }
                result = APIConnectionCheck(passed: true, message: provider == .plex ? plexMessage : "Connected. API credentials and data access verified.")
            } catch is CancellationError { break }
            catch {
                result = APIConnectionCheck(passed: false, message: (error as? RelayFailure)?.localizedDescription ?? "Connection could not be checked. Review the network and saved credentials.")
            }
            do { try await APIUsageStore.shared.checked(provider, result: result) }
            catch { apiUsageError = error.localizedDescription }
            await refreshAPIUsage()
        }
    }
    func runConnectionAudit(report: URL, plexOverride: URL?, only: APIProvider? = nil) async {
        databaseURL = APIUsageStore.defaultFile.deletingLastPathComponent().appendingPathComponent("jobs.sqlite")
        await checkAPIConnections(only: only, plexOverride: plexOverride)
        let rows: [[String: Any]] = apiUsage.map { value in
            ["provider": value.provider.rawValue, "passed": value.check?.passed ?? false,
             "message": value.check?.message ?? "Not checked", "requestsToday": value.today.requests,
             "lastHTTPStatus": value.lastHTTPStatus.map { String($0) } ?? "none"]
        }
        do { try JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys]).write(to: report, options: .atomic) }
        catch { NSLog("RELAY connection audit could not save its report") }
        NSApp.terminate(nil)
    }
}
