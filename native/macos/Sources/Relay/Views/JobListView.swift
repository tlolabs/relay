import SwiftUI
import RelayKit

struct JobListView: View {
    @Bindable var model: RelayModel
    var body: some View {
        VStack(spacing: 0) {
            HStack { Text(model.group).font(.headline); Spacer(); Text("\(model.visibleJobs.count)").foregroundStyle(.secondary) }.padding()
            if model.visibleJobs.isEmpty {
                ContentUnavailableView("No videos here", systemImage: "tray", description: Text("Scan your intake folders or choose a different batch."))
            } else {
                List(selection: $model.selectedIds) {
                    ForEach(model.visibleJobs) { job in
                        HStack(alignment: .top, spacing: 10) {
                            if job.editable {
                                Button { Task { await model.toggleIncluded(job) } } label: { Image(systemName: job.included ? "checkmark.square.fill" : "square").foregroundStyle(job.included ? Color.accentColor : .secondary) }
                                    .buttonStyle(.plain).help("Include or exclude this video").disabled(model.busy)
                            } else { Image(systemName: job.state == "complete" ? "checkmark.circle.fill" : job.needsAttention ? "exclamationmark.circle" : "film").foregroundStyle(job.state == "complete" ? .green : .secondary) }
                            VStack(alignment: .leading, spacing: 5) {
                                Text(job.filename).fontWeight(.medium).lineLimit(2)
                                Text(job.identity.display).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                HStack {
                                    Text(job.stateLabel).font(.caption2)
                                    Spacer()
                                    if let progress = job.progress { Text("\(progress)%").font(.caption.monospacedDigit()) }
                                }.foregroundStyle(.secondary)
                                if job.state == "processing", let progress = job.progress { ProgressView(value: Double(progress), total: 100).controlSize(.small) }
                            }
                        }.padding(.vertical, 4).tag(job.id)
                    }
                }.listStyle(.inset)
            }
            Text("Select multiple rows with ⌘ or ⇧ to review a subset together.").font(.caption).foregroundStyle(.secondary).padding(10)
        }
    }
}
