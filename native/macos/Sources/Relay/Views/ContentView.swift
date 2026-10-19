import SwiftUI
import RelayKit

struct ContentView: View {
    @Bindable var model: RelayModel
    var body: some View {
        VStack(spacing: 0) {
        NavigationSplitView {
            JobListView(model: model).navigationSplitViewColumnWidth(min: 280, ideal: 360, max: 600)
        } detail: {
            if let job = model.selectedJob { InspectorView(model: model,job: job) }
            else { ContentUnavailableView("Your video queue", systemImage: "film.stack", description: Text("Select a video to inspect its details, edit metadata, chapters or tracks.")) }
        }
        .frame(minWidth: 1000,minHeight: 700)
        .toolbar {
            ToolbarItem { Text("RELAY").font(.headline) }
            ToolbarItem(placement: .primaryAction) { SettingsLink { Label("Settings",systemImage: "gearshape") } }
        }
        Divider()
            VStack(alignment: .leading,spacing: 5) {
                if let error = model.error { HStack { Label(error,systemImage: "exclamationmark.triangle").foregroundStyle(.primary).textSelection(.enabled); Spacer(); Button("Dismiss") { model.error = nil } } }
                if let activity = model.activityMessages.first { HStack { ProgressView().controlSize(.small); Text(activity).lineLimit(2) } }
                else { Text(model.savingDraft ? "Saving changes…" : "\(model.jobs.count) videos · \(model.attentionCount) to review").foregroundStyle(.secondary) }
            }.font(.caption).padding(8).frame(maxWidth: .infinity,alignment: .leading).background(.bar)
        }
        .modifier(DraftAutosaveObservation(model: model))
        .sheet(isPresented: $model.presentingPreview) { BatchPreviewView(model: model) }
        .sheet(item: $model.outputJob) { job in OutputReviewView(model: model,job: job) }
        .confirmationDialog("Save changes before switching videos?",isPresented: $model.confirmingNavigation) {
            Button("Save and Continue") { Task { await model.finishNavigation(saving: true) } }
            Button("Discard Changes",role: .destructive) { Task { await model.finishNavigation(saving: false) } }
            Button("Keep Editing",role: .cancel) {}
        }
    }
}
