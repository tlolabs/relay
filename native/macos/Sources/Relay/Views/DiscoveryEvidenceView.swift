import SwiftUI
import RelayKit

struct DiscoverySourceLinks: View {
    let evidence: [DiscoveryEvidence]
    var body: some View {
        HStack(spacing: 8) {
            ForEach(Array(Set(evidence.map(\.source))).sorted { $0.rawValue < $1.rawValue }, id: \.self) { source in
                Link(source.rawValue, destination: source.website)
            }
        }.font(.caption)
    }
}
struct DiscoveryEvidenceView: View {
    let match: TVShowMatch
    var body: some View {
        if !match.evidence.isEmpty || !match.disagreements.isEmpty {
            DiscoverySourceLinks(evidence: match.evidence)
            DisclosureGroup("Source evidence\(match.disagreements.isEmpty ? "" : " · differences to review")") {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(match.disagreements.enumerated()), id: \.offset) { _, issue in
                        Text(issue).font(.caption).foregroundStyle(.orange).textSelection(.enabled)
                    }
                    ForEach(Array(match.evidence.sorted { $0.source.rawValue < $1.source.rawValue }.enumerated()), id: \.offset) { _, record in
                        if let episode = record.episode {
                            Text("\(record.source.rawValue): \(episode.title) · S\(episode.season.map(String.init) ?? "?")E\(episode.number.map(String.init) ?? "?")").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Text("Selection applies TMDB metadata. Titles missing from TMDB require manual episode selection.").font(.caption).foregroundStyle(.secondary)
                }.padding(.top, 4)
            }.font(.caption)
        }
    }
}
struct MovieDiscoveryEvidenceView: View {
    let title: CatalogTitle
    let evidence: [DiscoveryEvidence]
    var body: some View {
        DiscoverySourceLinks(evidence: evidence)
        DisclosureGroup("Compare source metadata") {
            VStack(alignment: .leading, spacing: 5) {
                Text("TMDB: \(title.displayTitle) (\(title.year.map(String.init) ?? "year unknown")) — used for this selection")
                ForEach(Array(evidence.enumerated()), id: \.offset) { _, record in
                    let differs = EpisodeClues.normalized(record.title) != EpisodeClues.normalized(title.displayTitle) || (record.year != nil && record.year != title.year)
                    Text("\(record.source.rawValue): \(record.title) (\(record.year.map(String.init) ?? "year unknown"))")
                        .foregroundStyle(differs ? .orange : .secondary)
                }
            }.font(.caption).padding(.top, 4)
        }.font(.caption)
    }
}
struct DiscoveryStatusView: View {
    let statuses: [ProviderStatus]
    let issues: [String]
    var body: some View {
        if !statuses.isEmpty || !issues.isEmpty {
            DisclosureGroup("Sources\(issues.isEmpty ? "" : " · \(issues.count) unresolved checks")") {
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Provider responses may use cached data up to six hours old; IMDb uses your last imported dataset.").foregroundStyle(.secondary)
                        ForEach(statuses) { status in
                            HStack(alignment: .firstTextBaseline) {
                                Link(status.source.rawValue, destination: status.source.website)
                                Text(status.message).foregroundStyle(status.incomplete ? .orange : .secondary)
                            }
                        }
                        ForEach(Array(issues.enumerated()), id: \.offset) { _, issue in
                            Text(issue).foregroundStyle(.orange).textSelection(.enabled)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.frame(maxHeight: 170).padding(.top, 4)
            }.font(.caption)
        }
    }
}
