import SwiftUI
import RelayKit

/// Keep search visible while the identity and subtitle editor scrolls.
struct CatalogSearchView: View {
    @Bindable var model: RelayModel
    @Environment(\.openSettings) private var openSettings
    @State private var resultsHeight: CGFloat = 70
    @AppStorage("metadataLanguage") private var language = "en-US"
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Picker("Language",selection:$language) { Text("English").tag("en-US");Text("French").tag("fr-FR");Text("German").tag("de-DE");Text("Spanish").tag("es-ES") }.frame(maxWidth:240)
            Picker("Catalog", selection: Binding(get: { model.catalogKind }, set: { value in
                model.cancelCatalogSearch()
                model.catalogKind = value; model.showMatches = []; model.catalogTitles = []; model.catalogMessage = ""
            })) {
                Text("TV shows & episodes").tag("tv")
                Text("Movies").tag("movie")
            }.pickerStyle(.segmented)
            HStack {
                TextField(model.catalogKind == "tv" ? "Search show or episode title" : "Search movie title", text: $model.searchText)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { model.beginCatalogSearch() }
                Button("Search") { model.beginCatalogSearch() }
                if model.catalogBusy {
                    ProgressView().controlSize(.small)
                    Button { model.cancelCatalogSearch(); model.catalogMessage = "Search stopped. Matches already found remain available." } label: { Image(systemName: "xmark.circle") }.help("Stop searching").accessibilityLabel("Stop searching")
                }
            }
            if model.catalogKind == "tv" {
                HStack {
                    Button("Find Show from Downloaded Episodes") { model.beginCatalogSearch(filenamesOnly: true) }
                        .disabled(model.episodeSearchClues.isEmpty)
                    Text("\(model.episodeSearchClues.count) title clues").font(.caption).foregroundStyle(.secondary)
                }
                if let recent = model.snapshot?.recentIdentities.filter({ $0.kind == "tv" }), !recent.isEmpty {
                    HStack(alignment: .firstTextBaseline) {
                        Text("Recent").font(.caption).foregroundStyle(.secondary)
                        ScrollView(.horizontal) {
                            HStack {
                                ForEach(Array(recent.enumerated()), id: \.offset) { _, identity in
                                    Button("\(identity.title)\(identity.year.map { " (\($0))" } ?? "")") { model.useRecent(identity) }
                                }
                            }
                        }.scrollIndicators(.hidden)
                    }
                }
            }
            if !model.showMatches.isEmpty || !model.catalogTitles.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        if model.catalogKind == "tv" {
                            ForEach(model.showMatches) { match in
                                VStack(alignment: .leading, spacing: 5) {
                                HStack(alignment: .firstTextBaseline) {
                                    CatalogArtworkView(model:model,url:match.catalog.title.posterURL).frame(width:38,height:52)
                                    Button(label(match.catalog.title)) { model.chooseShowMatch(match) }.buttonStyle(.link)
                                    if !match.matchedTitles.isEmpty {
                                        Text(match.supportedTitles.count > match.matchedTitles.count ? "\(match.supportedTitles.count) clues · \(match.matchedTitles.count) TMDB matches" : "\(match.matchedTitles.count) titles match TMDB").font(.caption).foregroundStyle(.secondary)
                                            .help(match.matchedTitles.joined(separator: "\n"))
                                    }
                                }
                                if let job = model.selectedJob {
                                    if let local = model.localContext(for: job) {
                                        ConfidenceLabel(confidence: MatchConfidence.local(local, catalogs: model.showMatches.map(\.catalog), inventory: model.plexInventory, providerEvidence: model.catalogEvidence, evaluatingShowID: match.id))
                                    } else {
                                        ConfidenceLabel(confidence: MatchConfidence.tv(clue: model.searchClue(for: job), catalogs: model.showMatches.map(\.catalog), evidence: model.catalogEvidence, incomplete: model.searchHasIncompleteChecks, showID: match.id))
                                    }
                                }
                                DiscoveryEvidenceView(match: match)
                                }
                            }
                        }
                        ForEach(model.catalogTitles) { title in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack { CatalogArtworkView(model:model,url:title.posterURL).frame(width:38,height:52); Button(label(title)) { model.chooseCatalogTitle(title) }.buttonStyle(.link) }
                                if let evidence = model.catalogEvidence[title.id] { MovieDiscoveryEvidenceView(title: title, evidence: evidence) }
                                if model.catalogKind == "movie" {
                                    ConfidenceLabel(confidence: MatchConfidence.movie(title: title, query: model.searchText, candidates: model.catalogTitles, evidence: model.catalogEvidence[title.id, default: []], incomplete: model.searchHasIncompleteChecks))
                                }
                            }
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                        .background(GeometryReader { geometry in
                            Color.clear.preference(key: CatalogResultsHeight.self, value: geometry.size.height)
                        })
                }.frame(height: min(190, max(40, resultsHeight)))
                    .onPreferenceChange(CatalogResultsHeight.self) { resultsHeight = $0 }
            }
            DiscoveryStatusView(statuses: model.providerStatuses, issues: model.discoveryIssues)
            if model.catalogKind == "tv", UserDefaults.standard.string(forKey: "plexURL")?.isEmpty == false {
                HStack {
                    Button { model.settingsTab = "plex"; openSettings() } label: {
                        Label(model.plexConnectionVerified ? "Plex: \(model.plexTitles.count) shows" : "Plex needs attention", systemImage: model.plexConnectionVerified ? "checkmark.circle" : "exclamationmark.circle")
                    }.help(model.plexMessage)
                    Button("Refresh") { Task { await model.loadPlex() } }.disabled(model.plexBusy)
                }.font(.caption)
            }
            if !model.catalogMessage.isEmpty { Text(model.catalogMessage).font(.caption).foregroundStyle(.secondary) }
        }

    }
    private func label(_ title: CatalogTitle) -> String {
        "\(title.displayTitle)\(title.year.map { " (\($0))" } ?? "")"
    }
}
private struct CatalogResultsHeight: PreferenceKey {
    static var defaultValue: CGFloat = 70
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}
