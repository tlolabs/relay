import AppKit
import SwiftUI
import RelayKit

extension RelayModel {
    func runDirectSmoke(root: URL) async {
        let priorTab = UserDefaults.standard.object(forKey: "inspectorTab")
        let priorGrid = UserDefaults.standard.object(forKey: "queueGrid")
        let priorRetention = UserDefaults.standard.object(forKey: "completedRetention")
        UserDefaults.standard.set(CompletedRetention.untilQuit.rawValue, forKey: "completedRetention")
        defer { if let priorRetention { UserDefaults.standard.set(priorRetention, forKey: "completedRetention") } else { UserDefaults.standard.removeObject(forKey: "completedRetention") } }
        defer { if let priorTab { UserDefaults.standard.set(priorTab, forKey: "inspectorTab") } else { UserDefaults.standard.removeObject(forKey: "inspectorTab") }; if let priorGrid { UserDefaults.standard.set(priorGrid, forKey:"queueGrid") } else { UserDefaults.standard.removeObject(forKey:"queueGrid") } }
        do {
            guard let engine else { throw RelayFailure.message(error ?? "No fixture store") }
            guard jobs.count == 2 else { throw RelayFailure.message("Two disposable video fixtures are required") }
            for job in jobs {
                let info = try await processor.inspect(path:job.currentPath,tools:mediaTools())
                let _: RelayJob = try await engine.execute(["command":"direct_inspect","id":job.id,"revision":job.revision,"inspection":RelayEngine.object(info)])
            }
            try await refresh()
            let ids = jobs.map(\.id)
            for id in ids {
                selectedIds = [id];loadDraft()
                draft.kind = jobFor(id).filename.hasPrefix("Movie") ? "movie" : "tv"
                draft.title = draft.kind == "movie" ? "RELAY Movie Fixture" : "RELAY TV Fixture"
                draft.year=2025;draft.season=draft.kind == "tv" ? 1 : nil;draft.episode=draft.kind == "tv" ? 1 : nil
                draft.episodeTitle=draft.kind == "tv" ? "A reviewed episode" : ""
                draftDirect.metadata=["description":"A disposable fixture verifies the complete replacement workflow.","genre":"Comedy","actors":"Actor One\nActor Two","directors":"Director","studio":"Fixture Studio"]
                draftDirect.overrides=["description"];draftDirect.trashSource=true;draftDirect.embedSubtitles=true
                if draft.kind == "movie" { draftDirect.artworkPath=root.appendingPathComponent("poster.png").path }
                await persistDraft()
            }
            try await refresh()
            // Exercise the search presentation with deterministic local evidence;
            // the packaged smoke test never calls live metadata providers.
            if let tv = jobs.first(where: { $0.identity.kind == "tv" }) {
                let data = Data(#"{"title":{"id":123,"name":"RELAY TV Fixture"},"episodes":[{"id":1,"name":"A reviewed episode","seasonNumber":1,"episodeNumber":1}]}"#.utf8)
                let value = try JSONDecoder().decode(TVSeriesCatalog.self, from: data)
                let evidence = [DiscoveryEvidence(source: .trakt, recordID: "fixture", title: "RELAY TV Fixture", episode: DiscoveredEpisode(title: "A reviewed episode", season: 1, number: 1)), DiscoveryEvidence(source: .tvmaze, recordID: "fixture", title: "RELAY TV Fixture", episode: DiscoveredEpisode(title: "A reviewed episode", season: 1, number: 1))]
                matchConfidence[tv.id] = MatchConfidence.tv(clue: "A reviewed episode", catalogs: [value], evidence: [123: evidence])
            }
            selectedIds = [ids[0]];loadDraft()
            UserDefaults.standard.set(false,forKey:"queueGrid")
            for appearance in ["dark","light"] {
                NSApp.appearance=NSAppearance(named:appearance == "dark" ? .darkAqua : .aqua)
                for tab in ["Metadata","Details","Tracks","Chapters"] {
                    UserDefaults.standard.set(tab,forKey:"inspectorTab")
                    try await Task.sleep(for:.milliseconds(250))
                    try captureDirectView(root.appendingPathComponent("\(appearance)-\(tab).png"))
                }
                for id in ids {
                    selectedIds = [id];loadDraft();UserDefaults.standard.set("Metadata",forKey:"inspectorTab")
                    try await Task.sleep(for:.milliseconds(200))
                    try captureDirectView(root.appendingPathComponent("\(appearance)-\(draft.kind)-Metadata.png"))
                }
                selectedIds=Set(ids);loadDraft()
                try await Task.sleep(for:.milliseconds(200))
                try captureDirectView(root.appendingPathComponent("\(appearance)-Multiple.png"))
                selectedIds=[ids[0]];loadDraft()
                for fraction in [0.5,1.0] {
                    scrollInspector(fraction)
                    try await Task.sleep(for:.milliseconds(150))
                    try captureDirectView(root.appendingPathComponent("\(appearance)-Metadata-\(fraction == 1 ? "Bottom" : "Middle").png"))
                }
                scrollInspector(0)
                UserDefaults.standard.set(true,forKey:"queueGrid")
                try await Task.sleep(for:.milliseconds(200))
                try captureDirectView(root.appendingPathComponent("\(appearance)-Grid.png"))
                UserDefaults.standard.set(false,forKey:"queueGrid")
                searchJobClues = Dictionary(uniqueKeysWithValues: jobs.map { ($0.id, EpisodeClues.normalized(searchClue(for: $0))) })
                searchFileNames = Dictionary(uniqueKeysWithValues: jobs.map { ($0.id, $0.filename) })
                catalogBusy = true; folderSearchInProgress = true
                catalogMessage = "Comparing episode titles with Trakt and TMDB…"
                updateSearchActivity(.init(source: "Trakt", clues: jobs.map { searchClue(for: $0) }), request: catalogRequest)
                try await Task.sleep(for: .milliseconds(200))
                try captureDirectView(root.appendingPathComponent("\(appearance)-SearchActivity.png"))
                cancelCatalogSearch()
                settingsTab="general"
                let settings=NSWindow(contentRect:NSRect(x:100,y:100,width:820,height:680),styleMask:[.titled,.closable],backing:.buffered,defer:false)
                settings.title="RELAY Settings Fixture";settings.isReleasedWhenClosed=false
                settings.contentView=NSHostingView(rootView:ProcessingSettingsView(model:self))
                settings.order(.below,relativeTo:NSApp.windows.first(where:{ $0.title == "RELAY" })?.windowNumber ?? 0)
                try await Task.sleep(for:.milliseconds(250))
                try captureDirectView(root.appendingPathComponent("\(appearance)-Settings.png"),window:settings)
                settings.close()
            }
            selectedIds = []
            await directPreview()
            guard preview?.errors.isEmpty == true else { throw RelayFailure.message(preview?.errors.joined(separator:"\n") ?? "No preview") }
            try await Task.sleep(for:.milliseconds(200))
            try captureDirectView(root.appendingPathComponent("approved-preview.png"))
            await approveDirect()
            if let task=processingTask { await task.value }
            guard jobs.allSatisfy({ $0.state == "complete" && $0.options.trashPath != nil }), jobs.allSatisfy({ $0.iflicksId == nil }) else { throw RelayFailure.message(error ?? jobs.map(\.message).joined(separator:"\n")) }
            guard jobCount(in: .queue) == 0, jobCount(in: .processing) == 0, jobCount(in: .completed) == 2 else { throw RelayFailure.message("Completed jobs did not leave Queue and Processing") }
            group = "Completed"; selectedIds = []; loadDraft()
            try await Task.sleep(for: .milliseconds(200))
            try captureDirectView(root.appendingPathComponent("Completed.png"))
            try JSONEncoder().encode(snapshot).write(to:root.appendingPathComponent("direct-result.json"))
        } catch { try? Data(error.localizedDescription.utf8).write(to:root.appendingPathComponent("error.txt")) }
        NSApp.terminate(nil)
    }
    private func jobFor(_ id:String)->RelayJob { jobs.first { $0.id == id }! }
    private func scrollInspector(_ fraction: Double) {
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        guard let content=NSApp.windows.first(where:{ $0.title == "RELAY" })?.contentView else { return }
        for scroll in descendants(content).compactMap({ $0 as? NSScrollView }) where scroll.bounds.width > 550 {
            if let document=scroll.documentView { scroll.contentView.scroll(to:NSPoint(x:0,y:max(0,document.bounds.height-scroll.contentView.bounds.height)*fraction));scroll.reflectScrolledClipView(scroll.contentView) }
        }
    }
    private func captureDirectView(_ destination: URL, window requested: NSWindow? = nil) throws {
        guard let window=requested ?? NSApp.windows.first(where: { $0.title == "RELAY" }),let content=(window.attachedSheet ?? window).contentView,
              let bitmap=content.bitmapImageRepForCachingDisplay(in:content.bounds) else { throw RelayFailure.message("Fixture window could not be rendered") }
        window.displayIfNeeded()
        if let image = CGWindowListCreateImage(.null,.optionIncludingWindow,CGWindowID((window.attachedSheet ?? window).windowNumber),[.boundsIgnoreFraming,.bestResolution]),let png = NSBitmapImageRep(cgImage:image).representation(using:.png,properties:[:]) { try png.write(to:destination);return }
        content.cacheDisplay(in:content.bounds,to:bitmap)
        guard let png=bitmap.representation(using:.png,properties:[:]) else { throw RelayFailure.message("Fixture PNG encoding failed") }
        try png.write(to:destination)
    }
}
