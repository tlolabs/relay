import SwiftUI

struct ObserverView: View {
    @Bindable var model: ObserverModel

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 12) {
                Image(systemName: "waveform.path").font(.system(size: 32, weight: .medium)).foregroundStyle(.teal)
                VStack(alignment: .leading, spacing: 4) {
                    Text("RELAY Observer").font(.largeTitle.weight(.semibold))
                    Text("A timeline of your downloads and processed files.").foregroundStyle(.secondary)
                }
                Spacer()
                Label(model.running ? "Recording" : "Ready", systemImage: model.running ? "record.circle.fill" : "circle")
                    .foregroundStyle(model.running ? .red : .secondary)
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Watched folders").font(.headline)
                        Spacer()
                        Button("Add Folder…", systemImage: "folder.badge.plus", action: model.addFolder)
                            .disabled(!model.canConfigure)
                    }
                    if model.folders.isEmpty {
                        ContentUnavailableView("Choose a folder to begin", systemImage: "folder",
                            description: Text("Choose the folder to monitor and save the log in."))
                            .frame(height: 110)
                        Button("Choose Folder…", action: model.choosePrimaryFolder)
                    } else {
                        ForEach(Array(model.folders.enumerated()), id: \.element) { index, url in
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: index == 0 ? "folder.fill" : "folder").foregroundStyle(.teal).padding(.top, 2)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(url.path).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                                        .lineLimit(2).truncationMode(.middle)
                                    if index == 0 { Text("Primary folder · log saved here").font(.caption).foregroundStyle(.secondary) }
                                }
                                Spacer()
                                if index == 0 {
                                    Button("Change…", action: model.choosePrimaryFolder).disabled(!model.canConfigure)
                                } else {
                                    Button { model.folders.remove(at: index) } label: { Image(systemName: "minus.circle") }
                                        .help("Remove watched folder").disabled(!model.canConfigure)
                                }
                            }
                        }
                    }
                    Divider()
                    Toggle("Include subfolders", isOn: $model.recursive).disabled(!model.canConfigure)
                    Text("Off by default. Observer logs and this app are always excluded. Symlinks are never followed.")
                        .font(.caption).foregroundStyle(.secondary)
                }.padding(8)
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 6) {
                    Toggle("Capture iFlicks activity", isOn: $model.captureIFlicks).disabled(!model.canConfigure)
                    Text(model.iflicksStatus.message).font(.callout)
                    if let time = model.iflicksStatus.lastSuccessfulSampleUnixMs {
                        Text("Latest successful sample: \(Date(timeIntervalSince1970: Double(time) / 1000).formatted(date: .omitted, time: .standard)) · \(model.iflicksStatus.videos.count) video(s)")
                            .font(.caption).foregroundStyle(.secondary)
                        ForEach(model.iflicksStatus.videos.prefix(3), id: \.id) { video in
                            Text("\(video.status) · \(video.progress.map(String.init) ?? "?")% · \(video.filePath ?? "Path unavailable")")
                                .font(.caption).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(6)
            }

            HStack(spacing: 10) {
                Button { Task { await model.start() } } label: { Label("Start", systemImage: "record.circle") }
                    .buttonStyle(.borderedProminent).tint(.teal)
                    .disabled(!model.canConfigure || model.folders.isEmpty)
                Button { Task { await model.stop() } } label: { Label("Stop", systemImage: "stop.fill") }
                    .disabled(!model.running || model.busy)
                Button("Add Marker…", systemImage: "flag") { model.showingMarker = true }
                    .disabled(!model.running || model.busy)
                Button("Reveal Log", systemImage: "doc.text.magnifyingglass", action: model.revealLog)
                    .disabled(model.snapshot == nil)
                Spacer()
                if model.busy { ProgressView().controlSize(.small); Text("Please wait…").foregroundStyle(.secondary) }
            }

            if let snapshot = model.snapshot {
                HStack(spacing: 24) {
                    metric("Files observed", String(snapshot.fileCount))
                    metric("Log records", String(snapshot.eventCount))
                    metric("Warnings / gaps", String(snapshot.warningCount))
                    Spacer()
                    if let time = snapshot.lastScanUnixMs {
                        VStack(alignment: .trailing, spacing: 4) {
                            Text("Last scan").font(.caption).foregroundStyle(.secondary)
                            Text(Date(timeIntervalSince1970: Double(time) / 1000), style: .time).monospacedDigit()
                        }
                    }
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text(model.running ? "Live activity" : snapshot.lastError == nil ? "Capture stopped · log ready to upload" : "Capture stopped · log may be incomplete").font(.headline)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 5) {
                            ForEach(Array(snapshot.recentEvents.enumerated()), id: \.offset) { _, event in
                                Text(event).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }.frame(minHeight: 85, maxHeight: .infinity)
                    Text(URL(fileURLWithPath: snapshot.logPath).lastPathComponent)
                        .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
            } else {
                ContentUnavailableView("Ready to observe", systemImage: "waveform.path",
                    description: Text("Start a capture, use Downie or iFlicks normally, then stop and upload the JSONL log."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            if let warning = model.watcherWarning { Label(warning, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).font(.callout) }
            if let error = model.error {
                HStack(alignment: .top) {
                    Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
                    Spacer()
                    Button("Dismiss") { model.error = nil }
                }.font(.callout)
            }
            Text("Metadata only. No media is opened, hashed, renamed or processed. File events do not prove completion.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(24).frame(minWidth: 720, idealWidth: 820, minHeight: 760, idealHeight: 860)
        .sheet(isPresented: $model.showingMarker) { markerSheet }
        .task {
            if model.needsFolderSelection {
                model.needsFolderSelection = false
                model.choosePrimaryFolder()
            }
        }
    }

    private func metric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title2.monospacedDigit().weight(.medium))
        }
    }

    private var markerSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Add a timeline marker").font(.title2.weight(.semibold))
            Text("Note what happened in Downie or iFlicks. Markers are observations you supply, not automatic completion claims.")
                .foregroundStyle(.secondary)
            TextField("For example: Downie finished", text: $model.markerText).textFieldStyle(.roundedBorder)
            HStack {
                ForEach(["Downie finished", "Started iFlicks", "iFlicks finished"], id: \.self) { text in
                    Button(text) { model.markerText = text }.controlSize(.small)
                }
            }
            HStack {
                Spacer()
                Button("Cancel") { model.showingMarker = false }.keyboardShortcut(.cancelAction)
                Button("Add Marker") { Task { await model.addMarker() } }
                    .keyboardShortcut(.defaultAction).disabled(model.markerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(24).frame(width: 540)
    }
}
