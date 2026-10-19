import SwiftUI
import RelayKit

struct JobDetailView: View {
    @Bindable var model: RelayModel
    let job: RelayJob
    var body: some View {
        VStack(spacing: 0) {
            if job.editable {
                CatalogSearchView(model: model).padding(16)
                Divider()
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(job.filename).font(.title2.weight(.semibold)).textSelection(.enabled)
                            Text(job.stateLabel).foregroundStyle(job.needsAttention ? .orange : .secondary)
                        }
                        Spacer()
                        Button { model.reveal(job.outputPath ?? job.currentPath) } label: { Image(systemName: "folder") }.help("Reveal file").accessibilityLabel("Reveal file in Finder")
                    }
                    if !job.message.isEmpty { Text(job.message).font(.callout).foregroundStyle(.secondary).textSelection(.enabled) }
                    if job.editable {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("1. Confirm identity → 2. Save Review → 3. Review Batch").font(.callout.weight(.medium))
                            Text("Select the video in the list and press Space to check it in Quick Look. Saving keeps your choices for the final batch review.").font(.caption).foregroundStyle(.secondary)
                        }
                        if let proposed = model.suggestedIdentity(for: job) {
                            GroupBox("Suggested from folder search") {
                                VStack(alignment: .leading, spacing: 8) {
                                    Text(proposed.display).font(.callout)
                                    Text("Unique exact title match in the checked catalogs. Confirm the show and numbering before saving.").font(.caption).foregroundStyle(.secondary)
                                    Button("Use Suggested Identity") { model.useFolderSuggestion(proposed) }
                                }.frame(maxWidth: .infinity, alignment: .leading).padding(6)
                            }
                        }
                        IdentityEditorView(model: model)
                        SubtitleChoicesView(model: model, editable: true)
                        HStack {
                            Button("Save Review") { Task { await model.saveDraft() } }.buttonStyle(.borderedProminent).disabled(model.busy)
                            Button("Reload") { model.loadDraft() }.disabled(model.busy)
                            if model.hasUnsavedChanges { Text("Unsaved changes").font(.caption).foregroundStyle(.orange) }
                        }
                        if job.revision != model.draftRevision { Text("The source changed while you were reviewing. Reload before saving.").font(.callout).foregroundStyle(.orange) }
                    } else {
                        Text(job.identity.display).font(.headline)
                        if let id = job.iflicksId { LabeledContent("iFlicks ID") { Text(id).font(.caption.monospaced()).textSelection(.enabled) } }
                        if let percent = job.progress {
                            ProgressView(value: Double(percent), total: 100) { Text("\(job.iflicksStatus ?? "Observed") · \(percent)%") }
                        }
                        SubtitleChoicesView(model: model, editable: ["awaiting_output", "output_verified", "reconciliation_failed", "complete"].contains(job.state))
                        actions
                    }
                    DisclosureGroup("Paths & history") {
                        VStack(alignment: .leading, spacing: 8) {
                            path("Original", job.originalPath)
                            path("Current input", job.currentPath)
                            if let output = job.outputPath { path("Confirmed output", output) }
                            ForEach(Array((model.snapshot?.events ?? []).filter { $0.jobId == job.id }.enumerated()), id: \.offset) { _, event in
                                Text("\(Date(timeIntervalSince1970: Double(event.timestampMs) / 1000).formatted(date: .omitted, time: .shortened)) · \(event.event)\n\(event.message)").font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8)
                    }
                }.padding(22).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .onAppear { if model.editingId != job.id { model.loadDraft() } }
        .disabled(model.busy)
    }
    @ViewBuilder private var actions: some View {
        VStack(alignment: .leading, spacing: 10) {
            if job.state == "prepared" {
                HStack {
                    Button("Send to iFlicks") { Task { await model.sendPrepared(job) } }.buttonStyle(.borderedProminent)
                    Button("Restore Original Names") { Task { await model.restore(job) } }
                }
            }
            if job.state == "submitted" || job.state == "awaiting_output" && ["queued", "unknown"].contains(job.iflicksStatus ?? "") { Button("Verify & Start") { Task { await model.verifyAndStart(job) } }.buttonStyle(.borderedProminent) }
            if job.state == "submission_uncertain" { Button("Bind Existing iFlicks Item") { Task { await model.bindExisting(job) } } }
            if job.state == "recovery_needed" { Button("Recover Original Names") { Task { await model.restore(job) } }.buttonStyle(.borderedProminent) }
            if !["recovery_needed", "preparing", "submission_pending"].contains(job.state) {
                Button(job.outputPath == nil ? "Select Finished Output…" : "Review Finished Output…") { Task { await model.showOutputs(job) } }
                if ["output_verified", "reconciliation_failed"].contains(job.state), job.outputPath != nil { Button("Place / Retry Subtitles") { Task { await model.retrySubtitles(job) } } }
            }
        }
    }
    private func path(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) { Text(label).font(.caption.weight(.medium)); Text(value).font(.caption.monospaced()).textSelection(.enabled) }
    }
}

struct SubtitleChoicesView: View {
    @Bindable var model: RelayModel
    let editable: Bool
    var body: some View {
        GroupBox("Subtitles") {
            VStack(alignment: .leading, spacing: 10) {
                if model.draftSubtitles.isEmpty { Text("No associated SRT. This video can proceed without one.").font(.callout).foregroundStyle(.secondary) }
                ForEach($model.draftSubtitles) { $sub in
                    HStack(alignment: .top) {
                        Toggle(isOn: $sub.selected) { Text(URL(fileURLWithPath: sub.currentPath).lastPathComponent).font(.caption).lineLimit(3) }.disabled(!editable)
                        TextField("Language", text: $sub.language).frame(width: 75).disabled(!editable).help("For example en, fr, en.forced or en.sdh")
                    }
                }
                Text("Confirm the language and variant. Ordinary English uses .en.srt. Existing published files are left in place when choices change.").font(.caption).foregroundStyle(.secondary)
                HStack {
                    if let job = model.selectedJob { Button("Add Subtitle…") { Task { await model.attachSubtitle(job) } } }
                    if model.selectedJob?.editable == false, editable { Button("Save Subtitle Choices") { Task { await model.saveSubtitleChoices() } } }
                }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(6)
        }
    }
}
