import SwiftUI
import AppKit
import ServiceManagement
import RelayKit

struct ProcessingSettingsView: View {
    @Bindable var model: RelayModel
    @State private var tab = "General"
    @State private var roots: [String] = []
    @State private var output = ""
    @State private var recursive = false
    @State private var token = ""
    @State private var braveToken = ""
    @State private var sourceTab = "TMDB"
    @AppStorage("metadataLanguage") private var language = "en-US"
    @AppStorage("defaultStreaming") private var streaming = true
    @AppStorage("defaultTrash") private var trash = true
    @AppStorage("watchFoldersEnabled") private var watch = true
    @AppStorage("notifications") private var notifications = true
    @AppStorage("attentionSound") private var sound = false
    @AppStorage("dockBadge") private var badge = true
    @AppStorage("dockBounce") private var bounce = true
    @AppStorage("openForAttention") private var openAttention = false
    var body: some View {
        VStack(spacing:0) {
            HStack(spacing:6) { ForEach([("General","gearshape"),("Processing","film"),("Watch Folders","folder.badge.gearshape"),("Naming","arrow.triangle.branch"),("Connections","network"),("Advanced","wrench.and.screwdriver")],id:\.0) { title,icon in
                Button { tab = title } label: { VStack(spacing:5) { Image(systemName:icon).font(.title2);Text(title).font(.caption) }.frame(width:95,height:55).foregroundStyle(tab == title ? Color.accentColor : .secondary).background(tab == title ? Color.accentColor.opacity(0.12) : Color.clear,in:RoundedRectangle(cornerRadius:8)) }.buttonStyle(.plain)
            } }.padding(14).frame(maxWidth:.infinity).background(.bar)
            Divider()
            Group {
                switch tab {
                case "General": general
                case "Processing": processing
                case "Watch Folders": folders
                case "Naming": naming
                case "Connections": connections
                default: advanced
                }
            }.frame(maxWidth:.infinity,maxHeight:.infinity)
        }.frame(width:820,height:680)
            .onAppear { roots = model.snapshot?.config?.roots ?? []; output = model.snapshot?.config?.outputFolder ?? ""; recursive = model.snapshot?.config?.recursive ?? false; syncSettingsTab(); Task { await model.loadNaming() } }
            .onChange(of: model.settingsTab) { _, _ in syncSettingsTab() }
    }
    private func syncSettingsTab() {
        if ["plex","sources","usage","connections"].contains(model.settingsTab) {
            tab = "Connections"
            sourceTab = model.settingsTab == "plex" ? "Plex" : model.settingsTab == "sources" ? "Data Sources" : model.settingsTab == "usage" ? "API Usage" : "TMDB"
        }
    }
    private var general: some View {
        Form {
            Section("Defaults") { Text("Update Metadata and Rename"); Text("Destination: \(model.snapshot?.config?.outputFolder ?? "Choose in Processing")").textSelection(.enabled); Picker("Metadata Language",selection:$language) { Text("English").tag("en-US");Text("French").tag("fr-FR");Text("German").tag("de-DE");Text("Spanish").tag("es-ES") }; Text("Content Ratings: United States"); Text("TV artwork: display only · Movie artwork: embed selected poster").font(.caption).foregroundStyle(.secondary) }
            Section("Attention") { Toggle("Notifications",isOn:$notifications); Button("Enable Notifications…") { Task { _ = try? await AttentionService.requestPermission() } }; Toggle("Sound",isOn:$sound);Toggle("Dock badge",isOn:$badge);Toggle("Dock bounce",isOn:$bounce);Toggle("Open window for attention",isOn:$openAttention) }
            Section("Startup") { Toggle("Open at login",isOn:Binding(get:{ SMAppService.mainApp.status == .enabled },set:{ value in do { if value { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } } catch { model.error = error.localizedDescription } })); Text("Relay stays in the menu bar to monitor watched folders.").font(.caption).foregroundStyle(.secondary) }
        }.formStyle(.grouped)
    }
    private var processing: some View {
        Form {
            Section("Update Metadata and Rename") { Toggle("Optimize for Streaming",isOn:$streaming);Toggle("Move source to Trash after verification",isOn:$trash);Text("Video and audio are copied without re-encoding. Input files remain intact until the finished output and selected subtitles have been verified.").font(.caption).foregroundStyle(.secondary) }
            Section("Destination") { Text(output).textSelection(.enabled);Button("Choose Folder…") { if let path = chooseFolder() { output = path } }; Button("Save Destination") { saveFolders() }.disabled(roots.isEmpty || output.isEmpty) }
            Section("Media Dependencies") { Text(dependencyVersions);Text("Compiled from pinned sources by Rust and bundled with Relay. Version pins and SHA-256 checksums live in media-dependencies.json.").font(.caption).foregroundStyle(.secondary) }
        }.formStyle(.grouped)
    }
    private var folders: some View {
        Form {
            Toggle("Monitor watched folders",isOn:$watch)
            Section("Folders") { ForEach(roots,id:\.self) { root in HStack { Text(root).textSelection(.enabled);Spacer();Button { roots.removeAll { $0 == root } } label:{ Image(systemName:"minus.circle") } } };Button("Add Folder…") { if let path = chooseFolder(), !roots.contains(path) { roots.append(path) } };Toggle("Include subfolders",isOn:$recursive);Button("Save Watch Folders") { saveFolders() }.disabled(roots.isEmpty || output.isEmpty) }
            Text("New videos are identified and added to the queue. Review them and press Start when the downloads are finished.").font(.callout).foregroundStyle(.secondary)
        }.formStyle(.grouped)
    }
    private var naming: some View {
        Form {
            Section("Filename Templates") { TextField("TV Shows",text:$model.naming.tv);TextField("Movies",text:$model.naming.movie);Text("Tokens: {show}, {name}, {year}, {season:02}, {episode:02}, {season}, {episode}, {comment}").font(.caption).textSelection(.enabled) }
            Section("Quality / Codec Suffixes") { ForEach(model.naming.suffixes.keys.sorted(),id:\.self) { key in TextField(key,text:Binding(get:{ model.naming.suffixes[key] ?? "" },set:{ model.naming.suffixes[key] = $0 })) } }
            Button("Save Naming Settings") { Task { await model.saveNaming() } }
            Text("MediaInfo supplies video height and codec. Current iFlicks thresholds are preserved: above 560 → 720p, above 720 → 1080p, above 1080 → 4K. Per-file filename and comment overrides take precedence.").font(.caption).foregroundStyle(.secondary)
        }.formStyle(.grouped).textFieldStyle(.roundedBorder)
    }
    private var connections: some View {
        VStack { Picker("Connection",selection:$sourceTab) { ForEach(["TMDB","Plex","Data Sources","API Usage"],id:\.self) { Text($0) } }.pickerStyle(.segmented).padding()
            switch sourceTab {
            case "Plex": PlexLibrarySettings(model:model)
            case "Data Sources": MetadataSourcesSettings(model:model)
            case "API Usage": APIUsageSettings(model:model)
            default: Form { Section("TMDB") { SecureField("API Read Access Token",text:$token);Button("Save Token") { do { try CredentialStore.save(token,account:"tmdb");token="";model.invalidateAPIConnection(.tmdb) } catch { model.error = error.localizedDescription } }.disabled(token.isEmpty);Button("Remove TMDB Token") { do { try CredentialStore.save("",account:"tmdb");model.invalidateAPIConnection(.tmdb) } catch { model.error = error.localizedDescription } };Link("Get a TMDB Token",destination:URL(string:"https://www.themoviedb.org/settings/api")!);Text("This product uses the TMDB API but is not endorsed or certified by TMDB.").font(.caption) }; Section("Brave Search (optional)") { SecureField("API Key",text:$braveToken);Button("Save Brave Key") { do { try CredentialStore.save(braveToken,account:"brave-search");braveToken="";model.invalidateAPIConnection(.brave) } catch { model.error=error.localizedDescription } }.disabled(braveToken.isEmpty);Button("Remove Brave Key") { do { try CredentialStore.save("",account:"brave-search");model.invalidateAPIConnection(.brave) } catch { model.error=error.localizedDescription } } } }.formStyle(.grouped)
            }
        }
    }
    private var advanced: some View {
        Form { Section("Diagnostics") { Button("Export Relay Journal…") { model.exportLogs() };Button("Clear Public Metadata Cache") { model.clearPublicCache() };Text("Jobs, credentials, retained subtitles and the local IMDb index are preserved.").font(.caption).foregroundStyle(.secondary) };Section("About") { Text("RELAY 0.2.0 · Intel macOS 14+");Text("Direct metadata tagging, naming and stream-preserving processing.");Text("Dependency versions and complete build provenance are included in the app’s Resources folder.").font(.caption).foregroundStyle(.secondary) } }.formStyle(.grouped)
    }
    private func chooseFolder()->String? { let panel=NSOpenPanel();panel.canChooseDirectories=true;panel.canChooseFiles=false;panel.canCreateDirectories=true;return panel.runModal() == .OK ? panel.url?.path : nil }
    private var dependencyVersions: String {
        guard let file=Bundle.main.resourceURL?.appendingPathComponent("media-dependencies.json"),let data=try? Data(contentsOf:file),let manifest=try? JSONSerialization.jsonObject(with:data) as? [String:Any],let sources=manifest["sources"] as? [[String:Any]] else { return "See the bundled dependency manifest for versions." }
        return sources.map { source in
            let name=source["name"] as? String == "ffmpeg" ? "FFmpeg / ffprobe" : "MediaInfo"
            let included=(source["includes"] as? [String] ?? []).joined(separator:", ")
            return "\(name) \(source["version"] as? String ?? "")" + (included.isEmpty ? "" : " (\(included))")
        }.joined(separator:" · ")
    }
    private func saveFolders() { Task { await model.applySettings(RelayConfig(roots:roots,recursive:recursive,outputFolder:output)) } }
}
