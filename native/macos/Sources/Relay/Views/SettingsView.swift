import SwiftUI
import AppKit
import ServiceManagement
import RelayKit

struct SettingsView: View {
    @Bindable var model: RelayModel
    @State private var roots: [String] = []
    @State private var output = ""
    @State private var recursive = false
    @State private var tmdbToken = ""
    @State private var plexToken = ""
    @State private var plexURL = ""
    @State private var credentialNotice = ""
    @AppStorage("notifications") private var notifications = true
    @AppStorage("attentionSound") private var sound = false
    @AppStorage("dockBadge") private var badge = true
    @AppStorage("dockBounce") private var bounce = true
    @AppStorage("openForAttention") private var openWindow = false
    @State private var login = false
    @State private var requestingAutomation = false
    var body: some View {
        TabView {
            Form {
                Section("Intake") {
                    ForEach(Array(roots.enumerated()), id: \.offset) { index, root in
                        HStack { Text(root).font(.caption.monospaced()).textSelection(.enabled); Spacer(); Button { roots.remove(at: index) } label: { Image(systemName: "minus.circle") } }
                    }
                    Button("Add Intake Folder…") { if let folder = folder("Choose an intake folder"), !roots.contains(folder) { roots.append(folder) } }
                    Toggle("Include subfolders", isOn: $recursive)
                }
                Section("iFlicks output") {
                    Text(output).font(.caption.monospaced()).textSelection(.enabled)
                    Button("Choose Output Folder…") { if let folder = folder("Choose iFlicks' existing output folder") { output = folder } }
                    Text("Select the folder used by your existing iFlicks rules. RELAY does not change those rules or destinations.").font(.caption).foregroundStyle(.secondary)
                }
                Button("Save Folders") { Task { await model.applySettings(RelayConfig(roots: roots, recursive: recursive, outputFolder: output)) } }.disabled(model.busy || roots.isEmpty || output.isEmpty)
            }.formStyle(.grouped).tabItem { Label("Folders", systemImage: "folder") }
            Form {
                Section("iFlicks Automation") {
                    Text("RELAY imports approved inputs, applies approved identity fields and reads progress. Existing rules and presets remain unchanged.").font(.caption).foregroundStyle(.secondary)
                    Button(requestingAutomation ? "Waiting for macOS permission…" : "Open iFlicks & Enable Automation…") {
                        requestingAutomation = true
                        Task {
                            do { credentialNotice = try await AutomationPermission.request() }
                            catch { credentialNotice = error.localizedDescription }
                            requestingAutomation = false
                        }
                    }.disabled(requestingAutomation)
                }
                Section("TMDB") {
                    SecureField("API Read Access Token", text: $tmdbToken)
                    HStack {
                        Button("Save TMDB Token") { credential { try CredentialStore.save(tmdbToken, account: "tmdb"); tmdbToken = "" } }.disabled(tmdbToken.isEmpty)
                        Button("Remove Token") { credential { try CredentialStore.save("", account: "tmdb") } }
                    }
                    Link("Get a TMDB API Read Access Token", destination: URL(string: "https://www.themoviedb.org/settings/api")!)
                    Text("This product uses the TMDB API but is not endorsed or certified by TMDB.").font(.caption).foregroundStyle(.secondary)
                }
                Section("Plex library context (optional)") {
                    TextField("Server URL, e.g. http://192.168.1.2:32400", text: $plexURL)
                    SecureField("Plex token", text: $plexToken)
                    HStack {
                        Button("Save Plex Connection") {
                            credential {
                                guard let url = URL(string: plexURL), ["http", "https"].contains(url.scheme ?? ""), url.host != nil, url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else { throw RelayFailure.message("Enter a server URL without credentials or query parameters") }
                                UserDefaults.standard.set(plexURL, forKey: "plexURL")
                                if !plexToken.isEmpty { try CredentialStore.save(plexToken, account: "plex"); plexToken = "" }
                            }
                        }
                        Button("Remove Plex Token") { credential { try CredentialStore.save("", account: "plex") } }
                    }
                    Text("Credentials are stored in Keychain. Catalog and Plex context are suggestions; manual identity fields remain available offline.").font(.caption).foregroundStyle(.secondary)
                }
                if !credentialNotice.isEmpty { Text(credentialNotice).font(.caption).foregroundStyle(.secondary) }
            }.formStyle(.grouped).tabItem { Label("Connections", systemImage: "network") }
            Form {
                Section("When work needs review") {
                    Toggle("System notifications", isOn: $notifications)
                    Button("Enable Notification Permission…") { Task { do { let enabled = try await AttentionService.requestPermission(); credentialNotice = enabled ? "Notifications enabled" : "Notifications are disabled in System Settings" } catch { model.error = error.localizedDescription } } }
                    Toggle("Sound", isOn: $sound)
                    Toggle("Dock badge", isOn: $badge)
                    Toggle("Brief Dock bounce", isOn: $bounce)
                    Toggle("Open the review window", isOn: $openWindow)
                }
                Section("Startup") {
                    Toggle("Open at login", isOn: Binding(get: { login }, set: { value in
                        do { if value { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }; login = value }
                        catch { model.error = error.localizedDescription; login = SMAppService.mainApp.status == .enabled }
                    }))
                    Text("Closing the main window leaves RELAY in the menu bar. Quitting waits for in-flight operations and closes the job store.").font(.caption).foregroundStyle(.secondary)
                }
            }.formStyle(.grouped).tabItem { Label("Attention", systemImage: "bell") }
            VStack(alignment: .leading, spacing: 18) {
                Text("RELAY 0.1.0").font(.title.weight(.semibold))
                Text("Your reviewed downloads, prepared and tracked through iFlicks.").foregroundStyle(.secondary)
                Divider()
                if let url = Bundle.main.url(forResource: "TMDB", withExtension: "svg"), let image = NSImage(contentsOf: url) {
                    Image(nsImage: image).resizable().scaledToFit().frame(width: 100, height: 74)
                }
                Text("This product uses the TMDB API but is not endorsed or certified by TMDB.")
                Link("The Movie Database", destination: URL(string: "https://www.themoviedb.org")!)
                Text("TMDB logo by Travis Bell, unchanged. CC BY-SA 4.0; official source mirrored on Wikimedia Commons.").font(.caption).foregroundStyle(.secondary)
                Link("Logo attribution & license", destination: URL(string: "https://commons.wikimedia.org/wiki/File:Tmdb.new.logo.svg")!)
                Spacer()
            }.padding(28).tabItem { Label("About", systemImage: "info.circle") }
        }.frame(width: 650, height: 570)
        .onAppear {
            roots = model.snapshot?.config?.roots ?? []
            output = model.snapshot?.config?.outputFolder ?? ""
            recursive = model.snapshot?.config?.recursive ?? false
            plexURL = UserDefaults.standard.string(forKey: "plexURL") ?? ""
            login = SMAppService.mainApp.status == .enabled
        }
    }
    private func credential(_ work: () throws -> Void) {
        do { try work(); credentialNotice = "Connection settings saved. Tokens are stored in Keychain." }
        catch { model.error = error.localizedDescription; credentialNotice = error.localizedDescription }
    }
    private func folder(_ title: String) -> String? {
        let panel = NSOpenPanel(); panel.title = title; panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
        return panel.runModal() == .OK ? panel.url?.resolvingSymlinksInPath().path : nil
    }
}
