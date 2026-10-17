import SwiftUI
import RelayKit

struct PlexSettingsView: View {
    @Bindable var model: RelayModel
    @State private var address = ""
    @State private var token = ""
    @State private var findingServers = false
    @State private var servers: [PlexSecureServer] = []
    @State private var directoryMessage = ""

    var body: some View {
        Section("Plex library context (optional)") {
            TextField("Server URL", text: $address)
                .help("Plex base URL, for example https://your-server.plex.direct:32400")
                .disabled(model.plexBusy || findingServers || model.checkingConnections)
            SecureField("Plex token", text: $token, prompt: Text("Leave blank to keep the saved token"))
                .disabled(model.plexBusy || findingServers || model.checkingConnections)
            HStack {
                Button("Save & Test Connection") { saveAndTest() }
                Button("Find Secure Servers") { findServers() }
                if model.plexBusy || findingServers { ProgressView().controlSize(.small) }
            }.disabled(model.plexBusy || findingServers || model.checkingConnections)
            if !servers.isEmpty {
                Menu("Choose Secure Server…") {
                    ForEach(servers) { server in
                        Menu(server.name) {
                            ForEach(Array(server.connections.enumerated()), id: \.offset) { index, url in
                                Button("\(index == 0 ? "Preferred" : "Alternate") — \(url.absoluteString)") {
                                    address = url.absoluteString; token = server.token
                                    saveAndTest(serverToken: true)
                                    servers = []; directoryMessage = ""
                                }
                            }
                        }
                    }
                }.disabled(model.plexBusy || findingServers)
            }
            if !directoryMessage.isEmpty { Text(directoryMessage).font(.caption).foregroundStyle(.secondary) }
            Label(model.plexMessage, systemImage: model.plexConnectionVerified ? "checkmark.circle.fill" : "exclamationmark.circle")
                .font(.caption).foregroundStyle(model.plexConnectionVerified ? Color.green : Color.secondary)
                .textSelection(.enabled)
            if let checked = model.plexLastCheckedAt {
                Text("Last checked: \(checked.formatted(date: .abbreviated, time: .shortened))").font(.caption).foregroundStyle(.secondary)
            }
            Button("Remove Plex Connection") {
                do {
                    try CredentialStore.save("", account: "plex")
                    try CredentialStore.save("", account: "plex-account")
                    UserDefaults.standard.removeObject(forKey: "plexURL")
                    address = ""; token = ""; servers = []; directoryMessage = ""
                    model.resetPlexConnection()
                } catch { directoryMessage = error.localizedDescription }
            }.disabled(model.plexBusy || findingServers)
            Text("Find Secure Servers uses your token to ask Plex for its HTTPS server addresses. Choose your server, then check the connection result. A .local hostname usually does not match Plex's HTTPS certificate. Tokens are stored in Keychain.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .onAppear { address = UserDefaults.standard.string(forKey: "plexURL") ?? "" }
    }

    private func saveAndTest(serverToken: Bool = false) {
        do {
            let value = address.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let url = URL(string: value), CatalogClient.validPlexBase(url) else {
                throw RelayFailure.message("Enter the server's base URL without /web, credentials, query parameters or fragments.")
            }
            let input = token.trimmingCharacters(in: .whitespacesAndNewlines)
            let effectiveToken = try input.isEmpty ? CredentialStore.read("plex") ?? "" : input
            guard !effectiveToken.isEmpty else {
                throw RelayFailure.message("Enter a Plex token first.")
            }
            if !input.isEmpty {
                try CredentialStore.save(input, account: "plex")
                if !serverToken { try CredentialStore.save(input, account: "plex-account") }
                token = ""
            }
            UserDefaults.standard.set(url.absoluteString, forKey: "plexURL")
            address = url.absoluteString; directoryMessage = ""
            model.resetPlexConnection()
            model.cancelCatalogSearch()
            Task {
                await model.loadPlex()
                if model.plexConnectionVerified { model.beginCatalogSearch() }
            }
        } catch { directoryMessage = error.localizedDescription }
    }

    private func findServers() {
        findingServers = true; servers = []; directoryMessage = "Finding HTTPS addresses through Plex…"
        Task { @MainActor in
            defer { findingServers = false }
            do {
                let input = token.trimmingCharacters(in: .whitespacesAndNewlines)
                let account = try input.isEmpty ? CredentialStore.read("plex-account") ?? CredentialStore.read("plex") ?? "" : input
                let found = try await model.catalog.plexSecureServers(token: account)
                // Keep the account token separate from any server-specific token returned by Plex.
                try CredentialStore.save(account, account: "plex-account")
                token = ""; servers = found
                directoryMessage = found.isEmpty ? "Plex returned no servers with direct HTTPS addresses for this account. Check server availability and secure connection settings." : "Found \(found.count) servers. Choose yours below; Relay will test the selected address and load its TV libraries."
            } catch { directoryMessage = error.localizedDescription }
        }
    }
}
