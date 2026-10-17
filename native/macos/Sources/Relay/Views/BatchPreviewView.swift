import SwiftUI
import RelayKit

struct BatchPreviewView: View {
    @Bindable var model: RelayModel
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Review the approved batch").font(.title2.weight(.semibold))
            Text("Start Approved Batch confirms that these downloads are finished and the identities, subtitle associations and exact actions below are correct. RELAY will prepare these names and submit the prepared videos to iFlicks.").foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(model.preview?.actions ?? []) { action in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(action.identity.display).font(.headline)
                            path(action.source, action.target)
                            ForEach(Array(action.subtitles.enumerated()), id: \.offset) { _, subtitle in path(subtitle.source, subtitle.target) }
                            if action.subtitles.isEmpty { Text("No selected subtitle").font(.caption).foregroundStyle(.secondary) }
                        }
                        Divider()
                    }
                    ForEach(Array((model.preview?.errors ?? []).enumerated()), id: \.offset) { _, error in Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red) }
                }
            }
            Text("iFlicks keeps its existing rules and presets. You will confirm exact finished output paths before subtitle publication. Original subtitle bytes are retained for recovery; video bytes are not copied.").font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Back to Review") { model.presentingPreview = false }.keyboardShortcut(.cancelAction)
                Button("Start Approved Batch") { Task { await model.startApprovedBatch() } }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
                    .disabled(model.busy || !(model.preview?.errors.isEmpty ?? false))
            }
        }.padding(24).frame(width: 760, height: 620)
    }
    private func path(_ source: String, _ target: String) -> some View {
        VStack(alignment: .leading, spacing: 2) { Text(source).foregroundStyle(.secondary); Text("→ \(target)") }.font(.caption.monospaced()).textSelection(.enabled)
    }
}
