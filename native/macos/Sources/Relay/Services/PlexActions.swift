import Foundation
import RelayKit

private struct PlexCachedContext: Codable {
    var serverURL: String
    var fetchedAt: Date
    var titles: [PlexTitle]
}

extension RelayModel {
    func acceptPlexLibrary(_ result: PlexLibrary, base: URL) {
        let now = Date()
        plexTitles = result.titles; plexLoadedAt = now; plexLastCheckedAt = now; plexConnectionVerified = true
        cache(PlexCachedContext(serverURL: base.absoluteString, fetchedAt: now, titles: result.titles), name: "plex-context.json")
        let transport = base.scheme == "https" ? "HTTPS" : "HTTP (unencrypted)"
        plexMessage = "Connected over \(transport): \(result.titles.count) TV shows in \(result.televisionLibraries) TV libraries."
        if result.televisionLibraries == 0 { plexMessage += " This account has no visible TV libraries on this server." }
        notice = plexMessage
    }
    func resetPlexConnection() {
        catalogRefreshTask?.cancel(); catalogRefreshState = CatalogRefreshState()
        cache(catalogRefreshState, name: "catalog-refresh.json")
        plexInventory = nil; plexTitles = []; plexLoadedAt = nil; plexLastCheckedAt = nil; plexConnectionVerified = false
        plexMessage = "Not checked. Save and test your Plex connection."
        if let url = cacheFolder?.appendingPathComponent("plex-inventory.json") { try? FileManager.default.removeItem(at: url) }
        if let url = cacheFolder?.appendingPathComponent("plex-context.json") { try? FileManager.default.removeItem(at: url) }
    }

    func loadPlex() async {
        guard !plexBusy else { return }
        plexBusy = true; plexConnectionVerified = false; plexMessage = "Connecting and loading TV libraries…"
        defer { plexBusy = false }
        let address = UserDefaults.standard.string(forKey: "plexURL") ?? ""
        do {
            guard let base = URL(string: address) else { throw RelayFailure.message("Enter a Plex server URL in Settings") }
            let result = try await catalog.plexLibrary(base: base, token: CredentialStore.read("plex") ?? "")
            try Task.checkCancellation()
            guard UserDefaults.standard.string(forKey: "plexURL") == address else { return }
            acceptPlexLibrary(result, base: base)
            try? await APIUsageStore.shared.checked(.plex, result: APIConnectionCheck(passed: true, message: plexMessage))
        } catch is CancellationError {
            plexMessage = "Plex check cancelled. Connection has not been verified."
        } catch {
            guard UserDefaults.standard.string(forKey: "plexURL") == address else { return }
            plexLoadedAt = nil; plexLastCheckedAt = Date(); plexTitles = []
            plexMessage = error.localizedDescription
            if let existing = cached("plex-context.json", as: PlexCachedContext.self), existing.serverURL == address {
                plexTitles = existing.titles; plexLoadedAt = existing.fetchedAt
                plexMessage += " Using \(existing.titles.count) cached TV shows from \(existing.fetchedAt.formatted(date: .abbreviated, time: .shortened)); the live connection is not verified."
            } else if let saved = plexInventory, saved.server == address {
                plexTitles = saved.shows; plexLoadedAt = saved.fetchedAt
                plexMessage += " Using the saved episode inventory; the live connection is not verified."
            }
            try? await APIUsageStore.shared.checked(.plex, result: APIConnectionCheck(passed: false, message: plexMessage))
        }
    }
}
