import SwiftUI
import RelayKit

struct OutputReviewView: View {
    @Bindable var model: RelayModel
    let job: RelayJob
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Confirm the finished output").font(.title2.weight(.semibold))
            Text(job.identity.display).font(.headline)
            Text("Choose this job's actual finished video. iFlicks reports the original input path, so RELAY needs your confirmation of the output association.").foregroundStyle(.secondary)
            if job.identity.kind == "tv" {
                Text("RELAY will remove embedded cover artwork from this TV output so Plex can choose an episode-specific thumbnail. Video and audio are preserved.").font(.callout).foregroundStyle(.secondary)
            }
            List(selection: $model.selectedOutput) {
                ForEach(model.candidates) { candidate in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(URL(fileURLWithPath: candidate.path).lastPathComponent)
                        Text(candidate.path).font(.caption).foregroundStyle(.secondary)
                    }.tag(candidate.path)
                }
            }.frame(minHeight: 180).disabled(model.busy)
            if let error = model.error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout).foregroundStyle(.red).textSelection(.enabled)
            }
            if let path = model.selectedOutput {
                let url = URL(fileURLWithPath: path)
                VStack(alignment: .leading, spacing: 5) {
                    Text("Subtitle destinations").font(.headline)
                    ForEach(job.subtitles.filter(\.selected)) { sub in
                        Text(url.deletingPathExtension().path + ".\(sub.language).srt").font(.caption.monospaced()).textSelection(.enabled)
                    }
                    if !job.subtitles.contains(where: \.selected) { Text("No selected subtitles; confirm the video only.").font(.caption).foregroundStyle(.secondary) }
                }
            }
            HStack {
                Button("Browse…", action: model.browseOutput).disabled(model.busy)
                Spacer()
                Button("Cancel") { model.outputJob = nil }.keyboardShortcut(.cancelAction).disabled(model.busy)
                Button("Confirm Output & Place Subtitles") { Task { await model.confirmOutput() } }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent).disabled(model.selectedOutput == nil || model.busy)
            }
        }.padding(24).frame(width: 760, height: 620)
            .interactiveDismissDisabled(model.busy)
            .onChange(of: model.selectedOutput) { _, _ in model.error = nil }
    }
}
