import SwiftUI
import RelayKit

struct BatchPreviewView: View {
    @Bindable var model: RelayModel
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Review the approved batch").font(.title2.weight(.semibold))
            Text("Start Approved Batch confirms that these downloads are finished and the identities, subtitle associations and exact actions below are correct. Relay will write the approved output files directly without re-encoding video or audio.").foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(model.preview?.actions ?? []) { action in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(action.identity.display).font(.headline)
                            path(action.source, action.target)
                            ForEach(Array(action.subtitles.enumerated()), id: \.offset) { _, subtitle in path(subtitle.source, subtitle.target) }
                            if let job = model.jobs.first(where: { $0.id == action.id }) {
                                Text("\(job.options.streaming ? "Streaming optimized" : "Streaming optimization off") · \(job.identity.kind == "tv" ? "No embedded artwork" : "Selected movie poster") · \(job.options.trashSource ? "Move source to Trash after verification" : "Keep source")").font(.caption).foregroundStyle(.secondary)
                                ForEach(job.options.inspection?.streams.filter { !$0.attachedPic && $0.kind != "data" } ?? []) { stream in
                                    let track = job.options.tracks.first { $0.index == stream.index } ?? TrackChoice(index:stream.index,language:stream.language,default:stream.isDefault,forced:stream.forced)
                                    Text("\(stream.kind.capitalized) \(track.index) (\(stream.codec)): \(track.enabled ? "Include" : "Exclude") · \(track.language) · default \(track.default ? "yes" : "no") · forced \(track.forced ? "yes" : "no")").font(.caption)
                                }
                            }
                            if action.subtitles.isEmpty { Text("No selected subtitle").font(.caption).foregroundStyle(.secondary) }
                        }
                        Divider()
                    }
                    ForEach(Array((model.preview?.errors ?? []).enumerated()), id: \.offset) { _, error in Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red) }
                }
            }
            Text("TV cover artwork is removed; movies embed the selected poster. Streaming optimization and track choices follow each reviewed job. Inputs configured for cleanup move to macOS Trash only after verified output and subtitle publication.").font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Back to Review") { model.presentingPreview = false }.keyboardShortcut(.cancelAction)
                Button("Start Approved Batch") { Task { await model.startApprovedBatch() } }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
                    .disabled(model.busy || (model.preview?.actions.isEmpty ?? true) || !(model.preview?.errors.isEmpty ?? false))
            }
        }.padding(24).frame(width: 760, height: 620)
    }
    private func path(_ source: String, _ target: String) -> some View {
        VStack(alignment: .leading, spacing: 2) { Text(source).foregroundStyle(.secondary); Text("→ \(target)") }.font(.caption.monospaced()).textSelection(.enabled)
    }
}
