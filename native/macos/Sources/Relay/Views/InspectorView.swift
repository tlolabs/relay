import SwiftUI
import AppKit
import RelayKit
import UniformTypeIdentifiers

struct InspectorView: View {
    @Bindable var model: RelayModel
    let job: RelayJob
    @AppStorage("inspectorTab") private var tab = "Metadata"
    @State private var search: String?
    @State private var showArtwork = false
    @State private var artworkDropTargeted = false
    var body: some View {
        VStack(spacing: 0) {
            Picker("Inspector",selection: $tab) {
                Label("Details",systemImage: "slider.horizontal.3").tag("Details")
                Label("Metadata",systemImage: "tag").tag("Metadata")
                Label("Chapters",systemImage: "list.bullet.rectangle").tag("Chapters")
                Label("Tracks",systemImage: "film").tag("Tracks")
            }.pickerStyle(.segmented).labelsHidden().accessibilityLabel("Inspector section").padding(12)
            Divider()
            if model.selectedIds.count > 1 { Text("\(model.selectedIds.count) selected · Only fields you change apply to all selected editable videos.").font(.caption).foregroundStyle(.secondary).padding(8) }
            ScrollView {
                VStack(alignment: .leading,spacing: 24) {
                    switch tab {
                    case "Details": details
                    case "Chapters": chapters
                    case "Tracks": tracks
                    default: metadata
                    }
                }.padding(22).frame(maxWidth: .infinity,alignment: .leading)
            }
        }
        .onAppear { if model.editingId != job.id { model.loadDraft() } }
        .sheet(item: $model.pendingCatalogChoice) { choice in
            VStack(alignment: .leading,spacing: 14) {
                Text("Use \(choice.title.displayTitle)?").font(.title2)
                Text("\(choice.title.year.map(String.init) ?? "Year unknown") · TMDB \(choice.title.id)").foregroundStyle(.secondary)
                Text("The chosen catalog identity and unedited metadata fields will be updated. Your manual metadata overrides, including cleared fields, remain in place.")
                if let poster = choice.metadata?.artwork.first { CatalogArtworkView(model:model,url:poster).frame(height:140) }
                Text("Identity: title, type, year and catalog ID. TV episode numbering will be cleared if the show changes.").font(.callout)
                if model.loadingCatalogDetails { ProgressView("Loading metadata preview…") }
                if let values = choice.metadata { ScrollView { VStack(alignment: .leading) { ForEach(values.fields.keys.sorted(),id: \.self) { key in if !model.draftDirect.overrides.contains(key) { Text("\(key): \(values.fields[key] ?? "")").font(.caption).lineLimit(3) } } } }.frame(maxHeight:220) }
                HStack { Spacer(); Button("Cancel") { model.pendingCatalogChoice = nil }.keyboardShortcut(.cancelAction); Button("Apply Match") { model.applyPendingCatalog() }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent).disabled(model.loadingCatalogDetails) }
            }.padding(24).frame(width: 520)
        }
    }
    private var metadata: some View {
        VStack(alignment: .leading,spacing: 20) {
            if let confidence = model.confidence(for: job) {
                VStack(alignment: .leading, spacing: 6) {
                    ConfidenceLabel(confidence: confidence)
                    DisclosureGroup("Why this score?") {
                        ForEach(confidence.dimensions.keys.sorted(), id: \.self) { key in
                            Text("\(key): \(confidence.dimensions[key] ?? 0)/100").font(.caption)
                        }
                        Text(confidence.canonicalAgreement ? "Canonical catalog agreement · still needs review" : "Provisional contextual candidate").font(.caption)
                        Text(confidence.explanation).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    }.font(.caption)
                }
            }
            section("General") {
                identityRow("Name",key: model.draft.kind == "movie" ? \.title : \.episodeTitle, searchKind: "name")
                identityRow("Show",key: \.title, searchKind: "show", disabled: model.draft.kind == "movie")
                row("Video Kind") { Picker("Video Kind",selection: Binding(get:{ kindMixed ? "" : model.draft.kind },set:{ next in if next == "movie", model.draft.title.isEmpty, !model.draft.episodeTitle.isEmpty { model.draft.title = model.draft.episodeTitle; model.markIdentityFieldEdited("title") }; model.draft.kind=next; model.markIdentityFieldEdited("kind") })) { Text(kindMixed ? "Multiple Values" : "Choose…").tag("");Text("TV Show").tag("tv");Text("Movie").tag("movie") }.labelsHidden() }
                if kindMixed { Text("Choose a common video kind, or select individual videos to edit their title and episode identity.").font(.caption).foregroundStyle(.secondary) }
                row("Year") { TextField(numberMixed(\.year,"year") ? "Multiple Values" : "Year",text: number(\.year,"year")).labelsHidden() }
                if model.draft.kind != "movie" { row("Show Year") { Toggle("Include series year in show filename",isOn: Binding(get:{ model.draft.includeYear },set:{ model.draft.includeYear=$0;model.markIdentityFieldEdited("include_year") })).disabled(kindMixed) } }
                row("Season Number") { TextField(numberMixed(\.season,"season") ? "Multiple Values" : "Season",text: number(\.season,"season")).labelsHidden().disabled(kindMixed || model.draft.kind == "movie") }
                row("Episode Number") { TextField(numberMixed(\.episode,"episode") ? "Multiple Values" : "Episode",text: number(\.episode,"episode")).labelsHidden().disabled(kindMixed || model.draft.kind == "movie") }
                if let suggestion = model.suggestedIdentity(for: job) { row("Suggested") { Button(suggestion.display) { model.useFolderSuggestion(suggestion) }.buttonStyle(.link) } }
                ForEach(MetadataField.sections[0].1.filter { $0.id != "comment" }) { field in fieldRow(field) }
                row("Artwork") {
                    VStack(alignment: .leading,spacing: 8) {
                        if !model.draftDirect.artworkPath.isEmpty, let image = NSImage(contentsOfFile: model.draftDirect.artworkPath) { Image(nsImage: image).resizable().scaledToFit().frame(maxHeight: 230) }
                        else if !model.draftDirect.artworkUrl.isEmpty { CatalogArtworkView(model:model,url:model.draftDirect.artworkUrl).frame(maxHeight:230) }
                        else { Image(systemName: model.draft.kind == "movie" ? "photo" : "tv").font(.system(size: 42)).foregroundStyle(.secondary).frame(height: 90) }
                        HStack {
                            Button("Choose Artwork…") { showArtwork = true }.popover(isPresented: $showArtwork) { ArtworkPicker(model: model) }
                            Button("Choose File…") { model.chooseLocalPoster() }
                        }
                        Text(model.draft.kind == "tv" ? "For identification only · No artwork will be embedded in TV outputs." : "Selected poster will be embedded in the finished movie.").font(.caption).foregroundStyle(.secondary)
                        Text("Drop an image here to use as artwork.").font(.caption).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .contentShape(Rectangle())
                    .background(artworkDropTargeted ? Color.accentColor.opacity(0.08) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
                    .overlay { if artworkDropTargeted { RoundedRectangle(cornerRadius: 8).strokeBorder(Color.accentColor, lineWidth: 2).allowsHitTesting(false) } }
                    .onDrop(of: [UTType.fileURL, UTType.image], isTargeted: $artworkDropTargeted) { model.acceptArtworkDrop($0) }
                }
                fieldRow(MetadataField("comment", "Comment", multiline: true))
            }
            ForEach(Array(MetadataField.sections.dropFirst().enumerated()),id: \.offset) { _,section in
                self.section(section.0) { ForEach(section.1) { field in fieldRow(field) } }
            }
            Text("Credits: one name per line. DVD order, rating, creation-date and season-description values are retained as extended tags. Provider IDs remain separate from Apple IDs.").font(.caption).foregroundStyle(.secondary)
            if let id = model.draft.tmdbId { row("TMDB ID") { Text(String(id)).foregroundStyle(.secondary).textSelection(.enabled) } }
        }.disabled(!job.editable || model.busy)
    }
    private func identityRow(_ title: String,key: WritableKeyPath<MediaIdentity,String>, searchKind: String, disabled: Bool = false) -> some View {
        row(title) {
            HStack {
                TextField(title,text: Binding(get: { disabled || identityMixed(key) ? "" : model.draft[keyPath:key] },set: { model.draft[keyPath:key] = $0;model.markIdentityFieldEdited(key == \.episodeTitle ? "episode_title" : "title") }),prompt: Text(identityMixed(key) ? "Multiple Values" : "")).labelsHidden()
                Button { model.catalogKind = searchKind == "show" ? "tv" : model.draft.kind == "movie" ? "movie" : "tv"; model.searchText = model.draft[keyPath:key]; search = searchKind } label: { Image(systemName: "magnifyingglass.circle.fill") }.buttonStyle(.plain).help("Search catalog for \(title)").accessibilityLabel("Search catalog for \(title)")
                    .popover(isPresented: Binding(get: { search == searchKind },set: { if !$0 { search = nil } })) {
                        VStack(alignment: .leading,spacing: 12) {
                            CatalogSearchView(model: model)
                            if searchKind == "name", model.draft.kind != "movie", !model.episodes.isEmpty {
                                Text("Episodes in \(model.draft.title)").font(.headline)
                                ScrollView { VStack(alignment: .leading) { ForEach(model.episodes.filter { model.searchText.isEmpty || $0.name.localizedCaseInsensitiveContains(model.searchText) || model.searchText == model.draft.episodeTitle }) { episode in Button("S\(episode.seasonNumber) E\(episode.episodeNumber) · \(episode.name)") { model.chooseEpisode(episode); search = nil }.buttonStyle(.link) } } }.frame(maxHeight: 240)
                            }
                        }.padding(16).frame(width: 530)
                    }
            }.disabled(disabled || kindMixed)
        }
    }
    private func fieldRow(_ field: MetadataField) -> some View {
        row(field.label) {
            let binding = Binding<String>(get: { mixed(field.id) ? "" : model.draftDirect.metadata[field.id] ?? "" }, set: { model.editMetadataField(field.id, value: $0) })
            if field.id == "definition" {
                Picker("Definition",selection:binding) { Text(mixed(field.id) ? "Multiple Values" : "Unspecified").tag(""); Text("SD").tag("0"); Text("HD 720p").tag("1"); Text("HD 1080p").tag("2"); Text("4K").tag("3") }.labelsHidden()
            } else if field.id == "advisory" {
                Picker("Advisory Rating",selection:binding) { Text(mixed(field.id) ? "Multiple Values" : "Unspecified").tag(""); Text("None").tag("0"); Text("Clean").tag("2"); Text("Explicit").tag("4") }.labelsHidden()
            } else if field.multiline { TextField(field.label,text: binding,prompt: Text(mixed(field.id) ? "Multiple Values" : ""),axis: .vertical).lineLimit(3...6).labelsHidden() }
            else { TextField(field.label,text: binding,prompt: Text(mixed(field.id) ? "Multiple Values" : "")).labelsHidden() }
        }.contextMenu { Button(model.selectedIds.count > 1 ? "Clear Field for Selected Videos" : "Clear Field") { model.editMetadataField(field.id,value:"") } }
    }
    private func mixed(_ key: String) -> Bool { model.metadataFieldIsMixed(key) }
    private var kindMixed: Bool { !model.editedIdentityFields.contains("kind") && model.draft.kind == job.identity.kind && Set(model.jobs.filter { model.selectedIds.contains($0.id) }.map { $0.identity.kind }).count > 1 }
    private func identityMixed(_ key: WritableKeyPath<MediaIdentity,String>) -> Bool { !model.editedIdentityFields.contains(key == \.episodeTitle ? "episode_title" : "title") && model.draft[keyPath:key] == job.identity[keyPath:key] && Set(model.jobs.filter { model.selectedIds.contains($0.id) }.map { $0.identity[keyPath:key] }).count > 1 }
    private func numberMixed(_ key: WritableKeyPath<MediaIdentity,Int?>,_ name: String) -> Bool { !model.editedIdentityFields.contains(name) && model.draft[keyPath:key] == job.identity[keyPath:key] && Set(model.jobs.filter { model.selectedIds.contains($0.id) }.map { $0.identity[keyPath:key] }).count > 1 }
    private func number(_ key: WritableKeyPath<MediaIdentity,Int?>,_ name: String) -> Binding<String> { Binding(get: { numberMixed(key,name) ? "" : model.draft[keyPath:key].map(String.init) ?? "" },set: { model.draft[keyPath:key] = Int($0);model.markIdentityFieldEdited(name) }) }
    private var details: some View {
        VStack(alignment: .leading,spacing: 24) {
            section("General") {
                row("Preset") { Text("Update Metadata and Rename").frame(maxWidth: .infinity,alignment: .leading) }
                row("Destination") { HStack { Text(model.draftDirect.destination.isEmpty ? model.snapshot?.config?.outputFolder ?? "Choose a folder" : model.draftDirect.destination).lineLimit(2).textSelection(.enabled); Spacer(); Button("Choose…") { model.chooseDestination() }.disabled(!job.editable) } }
                row("Filename") { HStack { TextField("Filename",text: Binding(get:{ model.draftDirect.filename },set:{ model.draftDirect.filename=$0;model.scheduleAutosave() }),prompt: Text(URL(fileURLWithPath:model.plannedOutput(job)).lastPathComponent)).labelsHidden(); Button("Reset") { model.draftDirect.filename = ""; model.scheduleAutosave() } }.disabled(!job.editable || model.selectedIds.count > 1).help("Select one video to override its final filename. Reset restores the naming template.") }
                row("Source") { Toggle("Move to Trash after verified output and subtitles",isOn: Binding(get:{ model.draftDirect.trashSource },set:{ model.draftDirect.trashSource=$0;model.draftDirect.overrides.insert("trash_source");model.scheduleAutosave() })).disabled(!job.editable) }
            }
            section("Details") {
                path("Input",job.currentPath)
                path(job.outputPath == nil ? "Planned Output" : "Output",job.outputPath ?? model.plannedOutput(job))
                if let trash = job.options.trashPath { path("Source in Trash",trash) }
                row("Status") { Text(job.stateLabel) }
                if !job.message.isEmpty { Text(job.message).font(.callout).foregroundStyle(.secondary).textSelection(.enabled) }
                if ["direct_failed","direct_interrupted"].contains(job.state) { Button("Return to Review") { Task { await model.retryDirect(job) } } }
                if job.state == "output_verified" || job.state == "reconciliation_failed" { Button("Retry Subtitles") { Task { await model.retrySubtitles(job) } } }
                if job.state == "complete", job.options.backend, job.options.trashSource, job.options.trashPath == nil { Button("Retry Source Trash") { Task { await model.retryDirectCleanup(job) } } }
                if !job.options.backend && (!job.editable || job.iflicksId != nil) { DisclosureGroup("Legacy iFlicks Job") { JobDetailView(model:model,job:job) } }
            }
        }
    }
    private var chapters: some View {
        VStack(alignment: .leading,spacing: 12) {
            Text("Chapters").font(.headline)
            if let chapters = model.draftDirect.inspection?.chapters, !chapters.isEmpty {
                ForEach(chapters) { chapter in HStack { Text(time(chapter.start)).monospacedDigit().frame(width: 100,alignment: .leading); Text(chapter.title.isEmpty ? "Chapter" : chapter.title); Spacer() }.padding(.vertical,3) }
                Text("Existing chapter names and timestamps are preserved.").font(.caption).foregroundStyle(.secondary)
            } else { Text("No chapters in this video.").foregroundStyle(.secondary) }
        }
    }
    private var tracks: some View {
        VStack(alignment: .leading,spacing: 24) {
            section("General") {
                Toggle("Optimize for Web Streaming",isOn: Binding(get:{ model.draftDirect.streaming },set:{ model.draftDirect.streaming=$0;model.draftDirect.overrides.insert("streaming");model.scheduleAutosave() }))
                Toggle("Embed selected external subtitles",isOn: Binding(get:{ model.draftDirect.embedSubtitles },set:{ model.draftDirect.embedSubtitles=$0;model.scheduleAutosave() }))
                Text("Video and audio pass through without re-encoding. External subtitles remain available beside the finished file.").font(.caption).foregroundStyle(.secondary)
            }.disabled(!job.editable)
            if let streams = model.draftDirect.inspection?.streams {
                ForEach(streams.filter { !$0.attachedPic && $0.kind != "data" }) { stream in
                    section("\(stream.kind.capitalized) Track \(stream.index)") {
                        row("Input") { Text(stream.summary).textSelection(.enabled) }
                        row("Output") { Text(choice(stream).wrappedValue.enabled ? stream.summary : "Excluded") }
                        if stream.kind != "video" {
                            Toggle("Enabled",isOn: choice(stream).enabled)
                            row("Language") { TextField("ISO language code",text: choice(stream).language) }
                            HStack { Toggle("Default",isOn: choice(stream).default); Toggle("Forced",isOn: choice(stream).forced) }
                        }
                    }.disabled(!job.editable || model.selectedIds.count > 1)
                }
            }
            SubtitleChoicesView(model:model,editable:job.editable)
        }
    }
    private func choice(_ stream: MediaStream) -> Binding<TrackChoice> {
        Binding(get: { model.draftDirect.tracks.first { $0.index == stream.index } ?? TrackChoice(index:stream.index,language:stream.language,default:stream.isDefault,forced:stream.forced) },set: { value in model.draftDirect.tracks.removeAll { $0.index == stream.index }; model.draftDirect.tracks.append(value); model.draftDirect.tracks.sort { $0.index < $1.index }; model.scheduleAutosave() })
    }
    private func path(_ label: String,_ value: String) -> some View {
        row(label) { HStack { Text(value).font(.callout).textSelection(.enabled).frame(maxWidth: .infinity,alignment: .leading); Button { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(value,forType:.string) } label: { Image(systemName:"doc.on.doc") }.help("Copy path to clipboard").accessibilityLabel("Copy \(label) path"); Button { model.reveal(value) } label: { Image(systemName:"folder") }.help("Reveal in Finder").accessibilityLabel("Reveal \(label) in Finder") } }
    }
    private func row<Content:View>(_ title: String,@ViewBuilder content: ()->Content) -> some View { HStack(alignment:.firstTextBaseline,spacing:10) { Text(title).foregroundStyle(.secondary).frame(width:145,alignment:.trailing); content().frame(maxWidth:.infinity,alignment:.leading) }.textFieldStyle(.roundedBorder).font(.callout) }
    private func section<Content:View>(_ title:String,@ViewBuilder content:()->Content) -> some View { VStack(alignment:.leading,spacing:10) { Text(title).font(.headline).foregroundStyle(.secondary); content() } }
    private func time(_ seconds: Double)->String { let ms=Int(seconds*1000);return String(format:"%02d:%02d:%02d.%03d",ms/3600000,(ms/60000)%60,(ms/1000)%60,ms%1000) }
}

private struct ArtworkPicker: View {
    @Bindable var model: RelayModel
    var body: some View {
        VStack(alignment:.leading,spacing:12) {
            Text(model.draft.kind == "tv" ? "Show artwork · Display only" : "Movie posters").font(.headline)
            ScrollView { LazyVGrid(columns:[GridItem(.adaptive(minimum:100))],spacing:12) { ForEach(model.artworkCandidates,id:\.self) { url in
                Button { Task { await model.selectArtwork(url) } } label: { CatalogArtworkView(model:model,url:url).frame(width:105,height:145) }.buttonStyle(.plain).accessibilityLabel("Select artwork candidate")
            } } }.frame(height:340)
            Button("Choose Local Image…") { model.chooseLocalPoster() }
        }.padding(16).frame(width:390).task { await model.loadArtwork() }
    }
}
