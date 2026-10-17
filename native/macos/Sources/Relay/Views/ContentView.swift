import SwiftUI
import RelayKit

struct ContentView: View {
    @Bindable var model: RelayModel
    var body: some View {
        NavigationSplitView {
            SidebarView(model: model)
                .navigationSplitViewColumnWidth(min: 170, ideal: 190, max: 240)
        } content: {
            JobListView(model: model)
                .navigationSplitViewColumnWidth(min: 300, ideal: 370, max: 520)
        } detail: {
            if let job = model.selectedJob { JobDetailView(model: model, job: job) }
            else { ContentUnavailableView("Review your next batch", systemImage: "tray.full", description: Text("Select a video to identify it, review subtitles, or follow its processing.")) }
        }
        .frame(minWidth: 1000, minHeight: 700)
        .toolbar {
            ToolbarItemGroup {
                Button { Task { await model.scan() } } label: { Label("Scan", systemImage: "arrow.clockwise") }.disabled(model.busy)
                Button { Task { await model.previewBatch() } } label: { Label("Review Batch", systemImage: "checklist") }.disabled(model.busy || model.reviewIds.isEmpty || model.hasUnsavedChanges)
                SettingsLink { Label("Settings", systemImage: "gearshape") }
                if model.busy || model.catalogBusy { ProgressView().controlSize(.small) }
            }
        }
        .safeAreaInset(edge: .bottom) {
            VStack(alignment: .leading, spacing: 4) {
                if let error = model.error {
                    HStack { Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red).textSelection(.enabled); Spacer(); Button("Dismiss") { model.error = nil } }
                } else if let notice = model.notice {
                    HStack { Text(notice).foregroundStyle(.secondary); Spacer(); Button { model.notice = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain) }
                }
                HStack {
                    Label(model.iflicksStatus.message, systemImage: "film.stack").lineLimit(1)
                    Spacer()
                    Text("\(model.jobs.count) jobs · \(model.attentionCount) to review").foregroundStyle(.secondary)
                }
            }.font(.caption).padding(10).background(.bar)
        }
        .onChange(of: model.selectedIds) { _, _ in model.loadDraft() }
        .sheet(isPresented: $model.presentingPreview) { BatchPreviewView(model: model) }
        .sheet(item: $model.outputJob) { job in OutputReviewView(model: model, job: job) }
    }
}
