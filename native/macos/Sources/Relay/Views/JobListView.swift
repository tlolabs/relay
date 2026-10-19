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
    @State private var gridSelection = QueueGridSelection()
    @FocusState private var gridFocused: Bool
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
                Picker("Queue view", selection: $grid) {
                    Image(systemName: "list.bullet").tag(false).accessibilityLabel("List view")
                    Image(systemName: "square.grid.2x2").tag(true).accessibilityLabel("Grid view")
                }.pickerStyle(.segmented).labelsHidden().accessibilityLabel("Queue layout").frame(width: 76)
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
                queueGrid
            } else {
                List(selection: Binding(get: { model.selectedIds }, set: { model.selectJobs($0) })) {
                    ForEach(jobs) { job in
                        HStack(spacing: 9) {
                            QueueThumbnail(job: job).frame(width: 62,height: 46)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(model.listIdentity(for: job).title.isEmpty ? job.filename : model.listIdentity(for: job).kind == "movie" ? model.listIdentity(for: job).display : model.listIdentity(for: job).episodeTitle.isEmpty ? job.filename : model.listIdentity(for: job).episodeTitle).fontWeight(.medium).lineLimit(1)
                                if model.listIdentity(for: job).kind == "tv" { Text("\(model.suggestedIdentity(for: job) != nil ? "Suggested: " : "")\(model.listIdentity(for: job).title) · S\(model.listIdentity(for: job).season.map(String.init) ?? "?") E\(model.listIdentity(for: job).episode.map(String.init) ?? "?")").font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                                queueStatus(job)
                                QueueSearchStatus(model: model, job: job)
                            }
                            Spacer(minLength: 0)
                            if job.state == "direct_processing" { ProgressView().controlSize(.small) }
                            if job.state == "complete" { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green) }
                        }.padding(.vertical,3).tag(job.id)
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel(accessibilityLabel(for: job))
                            .contextMenu { Button("Quick Look") { look([job]) }; Button("Reveal in Finder") { model.reveal(job.outputPath ?? job.currentPath) } }
                    }
                }.listStyle(.plain)
                .onKeyPress(.space, phases: .down) { press in
                    guard press.modifiers.isEmpty, !model.selectedQueueJobs.isEmpty else { return .ignored }
                    look(model.selectedQueueJobs); return .handled
                }
                .onDeleteCommand(perform: model.canRemoveSelectedJobs ? { Task { await model.removeSelectedJobs() } } : nil)
            }
            Divider()
            HStack {
                Button { Task { await model.scan() } } label: { Image(systemName: "arrow.clockwise") }
                    .help("Scan watched folders")
                    .accessibilityLabel("Scan watched folders")
                    .disabled(model.busy)
                Button { Task { await model.removeSelectedJobs() } } label: { Image(systemName: "minus") }
                    .help("Remove selected videos from the queue; keep files on disk")
                    .accessibilityLabel("Remove selected videos")
                    .disabled(!model.canRemoveSelectedJobs)
                Button { Task { await model.addVideos() } } label: { Image(systemName: "plus") }
                    .help("Add videos")
                    .accessibilityLabel("Add videos to queue")
                    .disabled(model.busy)
                if let job = model.selectedJob, job.editable {
                    Button { Task { await model.toggleIncluded(job) } } label: { Image(systemName: job.included ? "checkmark.square" : "square") }
                        .help("Include in processing")
                        .accessibilityLabel(job.included ? "Included in processing" : "Excluded from processing")
                        .accessibilityAddTraits(job.included ? [.isButton, .isSelected] : .isButton)
                }
                Spacer()
                if model.processingTask != nil { Button("Stop") { model.cancelProcessing() }.accessibilityLabel("Stop processing") }
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
        .quickLookPreview($previewURL, in: previewURLs)
    }

    private var queueGrid: some View {
        GeometryReader { geometry in
            // Keep keyboard up/down movement aligned with the actual layout.
            let count = max(1, Int((geometry.size.width - 24 + 18) / (140 + 18)))
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 18), count: count), spacing: 18) {
                        ForEach(jobs) { job in gridCell(job).id(job.id) }
                    }.padding(12)
                }
                .focusable()
                .focused($gridFocused)
                .focusEffectDisabled()
                .overlay {
                    if gridFocused, model.selectedQueueJobs.isEmpty {
                        Rectangle().strokeBorder(Color(nsColor: .keyboardFocusIndicatorColor), lineWidth: 3).allowsHitTesting(false)
                    }
                }
                .accessibilityLabel("Video queue")
                .help("Arrow keys select videos; Shift extends selection, Command-A selects all. Space previews selected videos. Delete removes queue entries and keeps files on disk.")
                .onKeyPress(keys: [.leftArrow, .rightArrow, .upArrow, .downArrow, .home, .end]) { press in
                    guard gridFocused, press.modifiers.intersection([.command, .option, .control]).isEmpty else { return .ignored }
                    let offset: Int
                    switch press.key {
                    case .leftArrow: offset = -1
                    case .rightArrow: offset = 1
                    case .upArrow: offset = -count
                    case .downArrow: offset = count
                    case .home: offset = -jobs.count
                    default: offset = jobs.count
                    }
                    if press.key == .end, model.requestedQueueSelection.isEmpty, let last = jobs.last {
                        model.selectJobs(gridSelection.select(last.id, in: jobs.map(\.id), selected: model.requestedQueueSelection))
                    } else {
                        model.selectJobs(gridSelection.move(by: offset, in: jobs.map(\.id), selected: model.requestedQueueSelection, extending: press.modifiers.contains(.shift)))
                    }
                    return .handled
                }
                .onKeyPress(keys: [.space, .return], phases: .down) { press in
                    guard gridFocused, press.modifiers.isEmpty, !model.selectedQueueJobs.isEmpty else { return .ignored }
                    look(model.selectedQueueJobs); return .handled
                }
                .onKeyPress("a", phases: .down) { press in
                    guard gridFocused, press.modifiers == .command else { return .ignored }
                    model.selectJobs(gridSelection.selectAll(in: jobs.map(\.id), selected: model.requestedQueueSelection))
                    return .handled
                }
                .onDeleteCommand(perform: gridFocused && model.canRemoveSelectedJobs ? { Task { await model.removeSelectedJobs() } } : nil)
                .onChange(of: gridFocused) { _, focused in
                    gridSelection.reconcile(in: jobs.map(\.id), selected: model.requestedQueueSelection)
                    if focused, let cursor = gridSelection.cursor { proxy.scrollTo(cursor) }
                }
                .onChange(of: QueueGridSnapshot(ids: jobs.map(\.id), selected: model.requestedQueueSelection)) { old, next in
                    let replacement = QueueGridSelection.replacement(for: gridSelection.cursor, oldIDs: old.ids, newIDs: next.ids)
                    gridSelection.reconcile(in: next.ids, selected: model.requestedQueueSelection)
                    if gridFocused, next.selected.isDisjoint(with: next.ids), let replacement {
                        model.selectJobs(gridSelection.select(replacement, in: next.ids, selected: []))
                    }
                    if gridFocused, let cursor = gridSelection.cursor { proxy.scrollTo(cursor) }
                }
            }
        }
    }

    private func gridCell(_ job: RelayJob) -> some View {
        VStack(spacing: 6) {
            QueueThumbnail(job: job).frame(height: 110)
            Text((model.suggestedIdentity(for: job) != nil ? "Suggested: " : "") + model.listIdentity(for: job).display).font(.caption).lineLimit(3)
            queueStatus(job)
            QueueSearchStatus(model: model, job: job)
        }.padding(8).frame(maxWidth: .infinity)
            .background(model.selectedIds.contains(job.id) ? Color.accentColor.opacity(0.22) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
            .overlay {
                if model.selectedIds.contains(job.id) {
                    RoundedRectangle(cornerRadius: 6).strokeBorder(gridFocused ? Color(nsColor: .keyboardFocusIndicatorColor) : Color.secondary, lineWidth: gridFocused ? 3 : 1)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 6))
            .onTapGesture {
                let modifiers = NSEvent.modifierFlags
                model.selectJobs(gridSelection.select(job.id, in: jobs.map(\.id), selected: model.requestedQueueSelection,
                    extending: modifiers.contains(.shift), toggling: modifiers.contains(.command)))
                gridFocused = true
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityLabel(for: job))
            .accessibilityAddTraits(model.selectedIds.contains(job.id) ? [.isButton, .isSelected] : [.isButton])
            .accessibilityAction {
                model.selectJobs(gridSelection.select(job.id, in: jobs.map(\.id), selected: model.requestedQueueSelection))
                gridFocused = true
            }
            .accessibilityAction(named: "Quick Look") { look([job]) }
            .accessibilityAction(named: "Reveal in Finder") { model.reveal(job.outputPath ?? job.currentPath) }
            .contextMenu { Button("Quick Look") { look([job]) }; Button("Reveal in Finder") { model.reveal(job.outputPath ?? job.currentPath) } }
    }

    private func queueStatus(_ job: RelayJob) -> some View {
        Label(model.queueStatusLabel(for: job), systemImage: job.needsAttention ? "exclamationmark.triangle" : "")
            .labelStyle(QueueStatusLabelStyle(showIcon: job.needsAttention))
            .font(.caption2).foregroundStyle(.primary)
    }

    private func accessibilityLabel(for job: RelayJob) -> String {
        var details = [job.filename]
        let identity = model.listIdentity(for: job).display
        if !identity.isEmpty, identity != job.filename {
            details.append((model.suggestedIdentity(for: job) != nil ? "Suggested: " : "") + identity)
        }
        if job.needsAttention { details.append("Needs attention") }
        details.append(model.queueStatusLabel(for: job))
        if job.editable, !job.included { details.append("Excluded from processing") }
        let search = QueueSearchStatus.summary(model: model, job: job)
        if !search.isEmpty { details.append(search) }
        return details.joined(separator: ". ")
    }
    private func look(_ jobs: [RelayJob]) { previewURLs = jobs.compactMap { job in [job.outputPath,job.currentPath].compactMap { $0 }.first { FileManager.default.fileExists(atPath: $0) }.map { URL(fileURLWithPath: $0) } }; previewURL = previewURLs.first }
}

private struct QueueStatusLabelStyle: LabelStyle {
    let showIcon: Bool
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) { if showIcon { configuration.icon }; configuration.title }
    }
}
