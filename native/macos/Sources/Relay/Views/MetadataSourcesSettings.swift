import SwiftUI
import RelayKit

struct MetadataSourcesSettings: View {
    @Bindable var model: RelayModel
    var body: some View {
        Form {
            Section("Collective discovery, TMDB metadata") {
                Text("Enabled sources help identify movies and shows from the entire set of episode filenames. Relay compares their evidence with TMDB and applies TMDB names and numbering. Differences remain visible for review.").font(.callout)
                Text("TVmaze works without a key. Add free keys for Trakt, OMDb and TheTVDB to enable those sources. Sources may share upstream data; agreement is evidence, not a guarantee.").font(.caption).foregroundStyle(.secondary)
            }
            MetadataSourceKeyView(model: model, source: .trakt, account: "trakt", label: "Client ID / API key", details: "Free public API. Register an application; episode-title search does not need access to your watch history.", link: "https://developer.trakt.tv/apps")
            MetadataSourceKeyView(model: model, source: .omdb, account: "omdb", label: "API key", details: "Free key: 1,000 requests/day. Relay stops at 900 per UTC day and rolling 24 hours. See API Usage for counters; other apps may also consume your allowance.", link: "https://www.omdbapi.com/apikey.aspx")
            Section("TVmaze") {
                sourceToggle(.tvmaze)
                Text("Free, no key. Checks candidate shows' complete episode lists, including specials. TVmaze does not provide global episode-title search.").font(.caption).foregroundStyle(.secondary)
                Link("TVmaze data · CC BY-SA", destination: URL(string: "https://www.tvmaze.com/api")!)
            }
            MetadataSourceKeyView(model: model, source: .tvdb, account: "tvdb", label: "Free project API key", details: "Register Relay for the free project tier if eligible. Attribution is required. A paid user subscription or PIN is not used by Relay. Checks show catalogs and movie identities.", link: "https://www.thetvdb.com/api-information")
            Section("IMDb local search") {
                sourceToggle(.imdb)
                Text("IMDb's free option is its personal/non-commercial datasets. Download title.basics.tsv.gz and title.episode.tsv.gz, then select both files below. Import can take time and several GB of disk space. No subscription or paid IMDb API is used.").font(.caption).foregroundStyle(.secondary)
                Link("Get IMDb's non-commercial datasets and terms", destination: URL(string: "https://datasets.imdbws.com/")!)
                HStack {
                    Button("Import IMDb Datasets…") { model.importIMDbDatasets() }.disabled(model.imdbImporting)
                    if model.imdbImporting {
                        ProgressView().controlSize(.small)
                        Button("Cancel Import") { model.imdbImportTask?.cancel() }
                    }
                }
                Text(model.imdbImportMessage.isEmpty ? "The completed index stays on this Mac. Reimport newer datasets to update it." : model.imdbImportMessage).font(.caption).foregroundStyle(.secondary)
                Link("IMDb dataset documentation", destination: URL(string: "https://data.imdb.com/non-commercial-datasets/")!)
            }
        }.formStyle(.grouped)
    }
    private func sourceToggle(_ source: MetadataSource) -> some View {
        MetadataSourceToggle(model: model, source: source)
    }

}
private struct MetadataSourceKeyView: View {
    @Bindable var model: RelayModel
    let source: MetadataSource
    let account: String
    let label: String
    let details: String
    let link: String
    @State private var key = ""
    @State private var status = ""
    var body: some View {
        Section(source.rawValue) {
            MetadataSourceToggle(model: model, source: source)
            SecureField(label, text: $key)
            HStack {
                Button("Save Key") { save(key) }.disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("Remove Key") { save("") }
                if let provider = source.apiProvider { Button("Test Connection") { model.beginConnectionChecks(only: provider) }.disabled(model.checkingConnections) }
                Link("Get a free \(source.rawValue) key", destination: URL(string: link)!)
            }
            Text(details).font(.caption).foregroundStyle(.secondary)
            if !status.isEmpty { Text(status).font(.caption).foregroundStyle(.secondary) }
        }
    }
    private func save(_ value: String) {
        do {
            try CredentialStore.save(value.trimmingCharacters(in: .whitespacesAndNewlines), account: account)
            key = ""; status = value.isEmpty ? "Key removed." : "Key saved in Keychain."
            model.cancelCatalogSearch()
            if let provider = source.apiProvider { model.invalidateAPIConnection(provider) }
        } catch { status = error.localizedDescription }
    }
}

private struct MetadataSourceToggle: View {
    let model: RelayModel
    let source: MetadataSource
    @AppStorage private var enabled: Bool
    init(model: RelayModel, source: MetadataSource) {
        self.model = model; self.source = source
        _enabled = AppStorage(wrappedValue: true, "metadata-\(source.rawValue)")
    }
    var body: some View {
        Toggle("Use \(source.rawValue)", isOn: $enabled)
            .onChange(of: enabled) { _, _ in model.cancelCatalogSearch() }
    }
}
