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
    @State private var braveToken = ""
    @State private var credentialNotice = ""
    @AppStorage("notifications") private var notifications = true
    @AppStorage("attentionSound") private var sound = false
    @AppStorage("dockBadge") private var badge = true
    @AppStorage("dockBounce") private var bounce = true
    @AppStorage("openForAttention") private var openWindow = false
    @State private var login = false
    @State private var requestingAutomation = false
    var body: some View {
        TabView(selection: $model.settingsTab) {
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
            }.formStyle(.grouped).tabItem { Label("Folders", systemImage: "folder") }.tag("folders")
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
                        Button("Save TMDB Token") { credential { try CredentialStore.save(tmdbToken, account: "tmdb"); tmdbToken = ""; model.invalidateAPIConnection(.tmdb) } }.disabled(tmdbToken.isEmpty)
                        Button("Remove Token") { credential { try CredentialStore.save("", account: "tmdb"); model.invalidateAPIConnection(.tmdb) } }
                    }
                    Link("Get a TMDB API Read Access Token", destination: URL(string: "https://www.themoviedb.org/settings/api")!)
                    Text("This product uses the TMDB API but is not endorsed or certified by TMDB.").font(.caption).foregroundStyle(.secondary)
                }
                Section("Episode web search (optional)") {
                    SecureField("Brave Search API key", text: $braveToken)
                    HStack {
                        Button("Save Search Key") { credential { try CredentialStore.save(braveToken, account: "brave-search"); braveToken = ""; model.invalidateAPIConnection(.brave) } }.disabled(braveToken.isEmpty)
                        Button("Remove Search Key") { credential { try CredentialStore.save("", account: "brave-search"); model.invalidateAPIConnection(.brave) } }
                    }
                    Link("Get a Brave Search API key", destination: URL(string: "https://api-dashboard.search.brave.com")!)
                    Text("Discovers unfamiliar shows using downloaded episode titles. Sends title clues to Brave Search; TMDB verifies episode names and numbering. Without a key, Relay uses show-title search and saved/recent show catalogs.").font(.caption).foregroundStyle(.secondary)
                }
                if !credentialNotice.isEmpty { Text(credentialNotice).font(.caption).foregroundStyle(.secondary) }
            }.formStyle(.grouped).tabItem { Label("Connections", systemImage: "network") }.tag("connections")
            PlexLibrarySettings(model: model).tabItem { Label("Plex", systemImage: "server.rack") }.tag("plex")
            MetadataSourcesSettings(model: model).tabItem { Label("Data Sources", systemImage: "square.stack.3d.up") }.tag("sources")
            APIUsageSettings(model: model).tabItem { Label("API Usage", systemImage: "chart.bar") }.tag("usage")
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
            }.formStyle(.grouped).tabItem { Label("Attention", systemImage: "bell") }.tag("attention")
            VStack(alignment: .leading, spacing: 18) {
                Text("RELAY 0.2.3").font(.title.weight(.semibold))
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
            }.padding(28).tabItem { Label("About", systemImage: "info.circle") }.tag("about")
        }.frame(width: 760, height: 650)
        .onAppear {
            roots = model.snapshot?.config?.roots ?? []
            output = model.snapshot?.config?.outputFolder ?? ""
            recursive = model.snapshot?.config?.recursive ?? false
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
