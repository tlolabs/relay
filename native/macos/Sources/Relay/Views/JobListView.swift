import SwiftUI
import AppKit
import QuickLook
import RelayKit

struct JobListView: View {
    @Bindable var model: RelayModel
    @AppStorage("queueGrid") private var grid = false
    @State private var previewURL: URL?
    @State private var previewURLs: [URL] = []
    @State private var videoDropTargeted = false
    private var jobs: [RelayJob] { model.visibleJobs }
    private var filterBinding: Binding<QueueFilter> {
        Binding(
            get: { model.queueFilter },
            set: { next in model.selectJobs([], in: next.rawValue) }
        )
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("Queue contents", selection: filterBinding) {
                    ForEach(QueueFilter.allCases) { filter in
                        Text("\(filter.title) (\(model.jobCount(in: filter)))").tag(filter)
                    }
                }.pickerStyle(.menu).labelsHidden().font(.headline)
                    .accessibilityLabel("Queue contents")
                Spacer()
                Picker("Queue view", selection: $grid) { Image(systemName: "list.bullet").tag(false); Image(systemName: "square.grid.2x2").tag(true) }.pickerStyle(.segmented).labelsHidden().frame(width: 76)
            }.padding(12)
            Text(model.queueFilter.description).font(.caption).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal,12).padding(.bottom,8)
            Divider()
            SearchActivityView(model: model)
            if !model.scanning, model.snapshot?.scan?.videoCount == 0, !jobs.isEmpty {
                Label("No videos found in watched folders", systemImage: "folder")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(12)
            }
            if jobs.isEmpty {
                ContentUnavailableView(model.queueEmptyTitle, systemImage: "folder", description: Text(model.queueEmptyDescription))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if grid {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 140))], spacing: 18) {
                        ForEach(jobs) { job in
                            VStack(spacing: 6) {
                                QueueThumbnail(job: job).frame(height: 110)
                                Text((model.suggestedIdentity(for: job) != nil ? "Suggested: " : "") + model.listIdentity(for: job).display).font(.caption).lineLimit(3)
                                Text(model.queueStatusLabel(for: job)).font(.caption2).foregroundStyle(.secondary)
                                QueueSearchStatus(model: model, job: job)
                            }.padding(8).frame(maxWidth: .infinity)
                                .background(model.selectedIds.contains(job.id) ? Color.accentColor.opacity(0.22) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
                                .onTapGesture {
                                    if NSEvent.modifierFlags.contains(.command) {
                                        var ids = model.selectedIds
                                        if !ids.insert(job.id).inserted { ids.remove(job.id) }
                                        model.selectJobs(ids)
                                    } else { model.selectJobs([job.id]) }
                                }
                                .contextMenu { Button("Quick Look") { look([job]) }; Button("Reveal in Finder") { model.reveal(job.outputPath ?? job.currentPath) } }
                        }
                    }.padding(12)
                }
            } else {
                List(selection: Binding(get: { model.selectedIds }, set: { model.selectJobs($0) })) {
                    ForEach(jobs) { job in
                        HStack(spacing: 9) {
                            QueueThumbnail(job: job).frame(width: 62,height: 46)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(model.listIdentity(for: job).title.isEmpty ? job.filename : model.listIdentity(for: job).kind == "movie" ? model.listIdentity(for: job).display : model.listIdentity(for: job).episodeTitle.isEmpty ? job.filename : model.listIdentity(for: job).episodeTitle).fontWeight(.medium).lineLimit(1)
                                if model.listIdentity(for: job).kind == "tv" { Text("\(model.suggestedIdentity(for: job) != nil ? "Suggested: " : "")\(model.listIdentity(for: job).title) · S\(model.listIdentity(for: job).season.map(String.init) ?? "?") E\(model.listIdentity(for: job).episode.map(String.init) ?? "?")").font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                                Text(model.queueStatusLabel(for: job)).font(.caption2).foregroundStyle(job.needsAttention ? .orange : .secondary)
                                QueueSearchStatus(model: model, job: job)
                            }
                            Spacer(minLength: 0)
                            if job.state == "direct_processing" { ProgressView().controlSize(.small) }
                            if job.state == "complete" { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green) }
                        }.padding(.vertical,3).tag(job.id)
                            .contextMenu { Button("Quick Look") { look([job]) }; Button("Reveal in Finder") { model.reveal(job.outputPath ?? job.currentPath) } }
                    }
                }.listStyle(.plain)
            }
            Divider()
            HStack {
                Button { Task { await model.scan() } } label: { Image(systemName: "arrow.clockwise") }.help("Scan watched folders").disabled(model.busy)
                Button { Task { await model.removeSelectedJobs() } } label: { Image(systemName: "minus") }
                    .help("Remove selected videos from the queue; keep files on disk")
                    .accessibilityLabel("Remove selected videos")
                    .disabled(!model.canRemoveSelectedJobs)
                Button { Task { await model.addVideos() } } label: { Image(systemName: "plus") }.help("Add videos").disabled(model.busy)
                if let job = model.selectedJob, job.editable { Button { Task { await model.toggleIncluded(job) } } label: { Image(systemName: job.included ? "checkmark.square" : "square") }.help("Include in processing") }
                Spacer()
                if model.processingTask != nil { Button("Stop") { model.cancelProcessing() } }
                else { Button("Review…") { Task { await model.previewBatch() } }.help("Review output paths and choices before approving processing").buttonStyle(.borderedProminent).disabled(model.busy || model.reviewIds.isEmpty) }
            }.padding(10)
        }
        .contentShape(Rectangle())
        .dropDestination(for: URL.self) { urls, _ in model.enqueueVideos(urls) } isTargeted: { videoDropTargeted = $0 }
        .overlay {
            if videoDropTargeted {
                RoundedRectangle(cornerRadius: 8).strokeBorder(Color.accentColor, lineWidth: 3)
                    .background(Color.accentColor.opacity(0.08))
                    .overlay(alignment: .top) { Label("Drop videos to add to queue", systemImage: "plus.circle.fill").padding(10).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8)).padding(12) }
                    .allowsHitTesting(false)
            }
        }
        .onKeyPress(.space) { look(jobs.filter { model.selectedIds.contains($0.id) }); return .handled }
        .quickLookPreview($previewURL, in: previewURLs)
    }
    private func look(_ jobs: [RelayJob]) { previewURLs = jobs.compactMap { job in [job.outputPath,job.currentPath].compactMap { $0 }.first { FileManager.default.fileExists(atPath: $0) }.map { URL(fileURLWithPath: $0) } }; previewURL = previewURLs.first }
}
