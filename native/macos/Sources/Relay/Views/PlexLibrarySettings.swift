import SwiftUI
import RelayKit

struct PlexLibrarySettings: View {
    @Bindable var model: RelayModel
    @AppStorage("backgroundCatalogRefresh") private var backgroundRefresh = false
    @State private var filter = ""
    private var shows: [PlexTitle] {
        model.plexTitles.filter { filter.isEmpty || $0.title.localizedCaseInsensitiveContains(filter) }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }
    var body: some View {
        Form {
            PlexSettingsView(model: model)
            Section("Local episode catalog") {
                Toggle("Refresh library and relevant catalogs in the background", isOn: $backgroundRefresh)
                Button("Refresh Episode Catalog") { model.beginCatalogRefresh() }.disabled(model.catalogRefreshBusy)
                if model.catalogRefreshBusy { ProgressView("Refreshing saved library and catalogs…") }
                Text(model.catalogRefreshMessage).font(.caption).foregroundStyle(.secondary)
                if let saved = model.plexInventory {
                    Text("Saved inventory: \(saved.episodes.count) episodes · \(saved.fetchedAt.formatted(date: .abbreviated, time: .shortened))").font(.caption)
                }
                Text("Due checks run in the app every six hours, with a one-hour retry cooldown. Library presence is unknown after a day without a complete refresh. Membership does not indicate watch activity.").font(.caption).foregroundStyle(.secondary)
            }
            Section("TV shows from Plex (\(model.plexTitles.count))") {
                HStack {
                    TextField("Filter Plex shows", text: $filter)
                    Button("Refresh Library") { Task { await model.loadPlex() } }.disabled(model.plexBusy)
                }
                if model.plexTitles.isEmpty { Text("A successful connection loads your visible TV shows here.").font(.caption).foregroundStyle(.secondary) }
                else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 8) {
                            ForEach(shows) { show in
                                HStack {
                                    Text(show.title)
                                    if let year = show.year { Text(String(year)).foregroundStyle(.secondary) }
                                    Spacer()
                                    Button("Search in TMDB") {
                                        model.catalogKind = "tv"; model.searchText = show.title; model.beginCatalogSearch()
                                    }.disabled(model.selectedJob?.editable != true)
                                }.font(.caption)
                            }
                        }.padding(.vertical, 4)
                    }.frame(height: 180)
                }
                Text("Search in TMDB uses the Plex show as a clue for the selected review row. Applied names and episode numbering still come from TMDB.").font(.caption).foregroundStyle(.secondary)
            }
        }.formStyle(.grouped)
        .task {
            if !model.smokeMode, model.plexLastCheckedAt == nil, UserDefaults.standard.string(forKey: "plexURL")?.isEmpty == false { await model.loadPlex() }
        }
    }
}
