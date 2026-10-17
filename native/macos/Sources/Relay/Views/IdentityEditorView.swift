import SwiftUI
import RelayKit

struct IdentityEditorView: View {
    @Bindable var model: RelayModel
    private func number(_ key: WritableKeyPath<MediaIdentity, Int?>) -> Binding<String> {
        Binding(get: { model.draft[keyPath: key].map(String.init) ?? "" }, set: { model.draft[keyPath: key] = Int($0) })
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            GroupBox("Identity") {
                VStack(alignment: .leading, spacing: 10) {
                    Picker("Type", selection: $model.draft.kind) {
                        Text("Choose…").tag(""); Text("TV").tag("tv"); Text("Movie").tag("movie")
                    }
                    TextField(model.draft.kind == "movie" ? "Movie title" : "Show title", text: $model.draft.title)
                    HStack { Text("Year").frame(width: 55, alignment: .leading); TextField("Optional for TV", text: number(\.year)).frame(width: 130) }
                    if model.draft.kind != "movie" {
                        Toggle("Include show year in prepared filename", isOn: $model.draft.includeYear).font(.caption)
                        HStack {
                            Text("Season"); TextField("Season", text: number(\.season))
                            Text("Episode"); TextField("Episode", text: number(\.episode))
                        }
                        TextField("Episode title", text: $model.draft.episodeTitle)
                    }
                    if let recent = model.snapshot?.recentIdentities.filter({ $0.kind == "tv" }), !recent.isEmpty {
                        Menu("Recent shows") { ForEach(Array(recent.enumerated()), id: \.offset) { _, identity in Button("\(identity.title)\(identity.year.map { " (\($0))" } ?? "")") { model.useRecent(identity) } } }
                    }
                }.textFieldStyle(.roundedBorder).padding(6)
            }
            GroupBox("Find with TMDB") {
                VStack(alignment: .leading, spacing: 10) {
                    Picker("Search", selection: $model.catalogKind) { Text("TV shows").tag("tv"); Text("Movies").tag("movie") }.pickerStyle(.segmented)
                    HStack { TextField("Show or movie title", text: $model.searchText).onSubmit { Task { await model.searchCatalog() } }; Button("Search") { Task { await model.searchCatalog() } }.disabled(model.catalogBusy) }
                    if !model.catalogTitles.isEmpty {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 6) {
                                ForEach(model.catalogTitles) { title in
                                    Button("\(title.displayTitle)\(title.year.map { " (\($0))" } ?? "")") { model.chooseCatalogTitle(title) }.buttonStyle(.link)
                                }
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }.frame(maxHeight: 130)
                    }
                    if let context = model.seriesContext {
                        Text("TMDB\(model.seriesContextCached ? " (cached)" : ""): \(context.status ?? "Status unknown") · In production: \(context.inProduction.map { $0 ? "yes" : "no" } ?? "unknown")\(context.nextEpisodeToAir?.airDate.map { " · Next episode \($0)" } ?? "")").font(.caption).foregroundStyle(.secondary)
                    }
                    if model.draft.kind == "tv", model.draft.tmdbId != nil {
                        HStack { Stepper("Season \(model.season)", value: $model.season, in: 0...200); Button("Load Episodes") { Task { await model.loadEpisodes() } }.disabled(model.catalogBusy) }
                        ForEach(Array(model.suggestions.prefix(3).enumerated()), id: \.offset) { _, suggestion in
                            Button("Suggested E\(suggestion.episode.episodeNumber): \(suggestion.episode.name)") { model.chooseEpisode(suggestion.episode) }.buttonStyle(.link).help(suggestion.reason)
                        }
                        if !model.episodes.isEmpty {
                            Menu("Choose episode…") { ForEach(model.episodes) { episode in Button("E\(episode.episodeNumber) — \(episode.name)") { model.chooseEpisode(episode) } } }
                        }
                        if model.selectedIds.count > 1 { Button("Apply Show to Selected Rows") { Task { await model.applyShowToSelection() } } }
                    }
                    Text("Catalog matches are suggestions. Verify specials, bonus content and numbering before approval.").font(.caption).foregroundStyle(.secondary)
                }.textFieldStyle(.roundedBorder).padding(6)
            }
            DisclosureGroup("Plex library context") {
                VStack(alignment: .leading, spacing: 8) {
                    Button("Refresh Plex Shows") { Task { await model.loadPlex() } }.disabled(model.catalogBusy)
                    ForEach(model.plexTitles.filter { model.searchText.isEmpty || $0.title.localizedCaseInsensitiveContains(model.searchText) }.prefix(12)) { title in
                        Button("\(title.title)\(title.year.map { " (\($0))" } ?? "")") { model.searchText = title.title; model.draft.title = title.title; model.draft.year = title.year; model.draft.kind = "tv" }.buttonStyle(.link)
                    }
                    Text("Plex supplies context. Compare your library's episode order; missing information remains unknown.").font(.caption).foregroundStyle(.secondary)
                }.padding(.top, 8)
            }
        }
    }
}
