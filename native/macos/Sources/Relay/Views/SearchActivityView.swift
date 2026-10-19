import SwiftUI
import RelayKit

struct SearchActivityView: View {
    let model: RelayModel
    var body: some View {
        if model.catalogBusy {
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    ProgressView().controlSize(.small)
                    Text(model.searchingFiles.isEmpty ? "Preparing search…" : "Searching \(model.searchingFiles.count) file(s)").fontWeight(.medium)
                    Spacer()
                    Button { model.cancelCatalogSearch() } label: { Image(systemName: "xmark.circle") }
                        .buttonStyle(.plain).help("Stop searching").accessibilityLabel("Stop searching")
                }
                ForEach(Array(model.searchingFiles.prefix(3).enumerated()), id: \.offset) { _, name in
                    Text(name).lineLimit(1).truncationMode(.middle).help(name)
                }
                if model.searchingFiles.count > 3 {
                    Text("and \(model.searchingFiles.count - 3) more files").foregroundStyle(.secondary)
                        .help(model.searchingFiles.joined(separator: "\n"))
                }
                Text(model.catalogMessage).foregroundStyle(.primary).lineLimit(2).help(model.catalogMessage)
            }.font(.caption).padding(12).frame(maxWidth: .infinity, alignment: .leading).background(.quaternary)
            Divider()
        }
    }
}

struct QueueSearchStatus: View {
    let model: RelayModel
    let job: RelayJob
    var body: some View {
        let sources = model.searchSources(for: job)
        if !sources.isEmpty {
            HStack(spacing: 4) {
                ProgressView().controlSize(.mini)
                Text("Searching · \(sources.joined(separator: ", "))").lineLimit(1)
            }.font(.caption2).foregroundStyle(.primary)
                .help("Searching \(job.filename)\n" + sources.joined(separator: ", "))
        } else if let confidence = model.confidence(for: job) {
            ConfidenceLabel(confidence: confidence)
        } else if model.catalogBusy, model.searchJobClues[job.id] != nil {
            Text(model.searchedJobIDs.contains(job.id) ? "Comparing search results…" : "Waiting for search…").font(.caption2).foregroundStyle(.secondary)
        }
    }

    @MainActor static func summary(model: RelayModel, job: RelayJob) -> String {
        let sources = model.searchSources(for: job)
        if !sources.isEmpty { return "Searching: " + sources.joined(separator: ", ") }
        if let confidence = model.confidence(for: job) { return confidence.label + ". " + confidence.explanation }
        if model.catalogBusy, model.searchJobClues[job.id] != nil {
            return model.searchedJobIDs.contains(job.id) ? "Comparing search results" : "Waiting for search"
        }
        return ""
    }
}

struct ConfidenceLabel: View {
    let confidence: MatchConfidence
    var body: some View {
        Label(confidence.label, systemImage: confidence.score >= 80 ? "checkmark.seal" : confidence.score < 50 ? "exclamationmark.triangle" : "info.circle")
            .font(.caption2).foregroundStyle(.primary)
            .help(confidence.explanation)
            .accessibilityLabel(confidence.label + ". " + confidence.explanation)
    }
}
