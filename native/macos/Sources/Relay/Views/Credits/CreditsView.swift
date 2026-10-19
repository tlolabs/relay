import AppKit
import SwiftUI

struct CreditsView: View {
    var resourceDirectory: URL? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var voiceOver = NSWorkspace.shared.isVoiceOverEnabled
    @State private var inventory: CreditsInventory?
    @State private var loadError = ""
    @State private var playback = CreditsPlayback()
    @State private var maximum = 0.0
    @State private var hovering = false
    @State private var linkFocused = false
    @State private var visible = false
    @State private var active = NSApp.isActive
    @State private var showingNotices = false

    private var directory: URL {
        resourceDirectory ?? (Bundle.main.resourceURL ?? Bundle.main.bundleURL).appendingPathComponent("Credits", isDirectory: true)
    }
    private var staticMode: Bool { reduceMotion || voiceOver }
    private var running: Bool {
        inventory != nil && playback.shouldRun(visible: visible, active: active, staticMode: staticMode,
                                               interacting: hovering || linkFocused || showingNotices, maximum: maximum)
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 5) {
                Text("The people and projects behind RELAY").font(.title2.weight(.semibold))
                Text("RELAY integration lines · largest first · shared code counted once")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(.vertical, 16)
            Divider()
            if let inventory {
                CreditsScrollView(
                    inventory: inventory, directory: directory, position: playback.position,
                    onManualScroll: { playback.manualScroll(to: $0) },
                    onMaximum: { maximum = $0 },
                    onFocus: { linkFocused = $0 },
                    onVisibility: { shown in
                        if shown && !visible { playback.replay(staticMode: staticMode) }
                        visible = shown
                    }
                )
                .onHover { hovering = $0 }
                .accessibilityLabel("Technology credits")
            } else {
                ContentUnavailableView("Credits unavailable", systemImage: "film",
                                       description: Text(loadError.isEmpty ? "Loading bundled credits…" : loadError))
            }
            Divider()
            HStack(spacing: 12) {
                Button(playback.paused || playback.completed ? "Play" : "Pause",
                       systemImage: playback.paused || playback.completed ? "play.fill" : "pause.fill") {
                    if playback.completed { playback.replay(staticMode: staticMode) }
                    else { playback.paused.toggle() }
                }.disabled(staticMode || inventory == nil)
                Button("Replay", systemImage: "backward.end.fill") {
                    playback.replay(staticMode: staticMode)
                }.disabled(inventory == nil)
                Text(status).font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityLabel(status)
                Button("Licenses & Notices…") {
                    playback.paused = true
                    showingNotices = true
                }
            }.padding(14)
        }
        .onAppear {
            do { inventory = try CreditsInventory.load(directory: directory) }
            catch { loadError = "The bundled credits inventory is missing or unreadable. Licenses & Notices includes the available attribution." }
            playback.replay(staticMode: staticMode)
        }
        .onDisappear { visible = false }
        .onChange(of: staticMode) { _, enabled in
            if enabled { playback.paused = true }
        }
        .onReceive(NSWorkspace.shared.publisher(for: \.isVoiceOverEnabled)) { voiceOver = $0 }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in active = true }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in active = false }
        .sheet(isPresented: $showingNotices) {
            CreditsNoticesView(notices: inventory?.notices ?? fallbackNotices)
        }
        .task(id: running) {
            guard running else { return }
            let clock = ContinuousClock()
            var previous = clock.now
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(33)) }
                catch { return }
                guard running else { return }
                let now = clock.now
                let delta = previous.duration(to: now).components
                previous = now
                playback.advance(seconds: Double(delta.seconds) + Double(delta.attoseconds) / 1e18, maximum: maximum)
            }
        }
    }

    private var status: String {
        if staticMode { return "Manual scrolling · accessibility motion settings" }
        if playback.completed { return "That’s a wrap. Replay anytime." }
        if playback.paused { return "Paused · scroll freely, then choose Play" }
        if hovering || linkFocused { return "Paused while you explore" }
        return playback.delay > 0 ? "The credits are about to roll…" : "18 points per second · enjoy the credits"
    }

    private var fallbackNotices: [CreditNotice] {
        let url = Bundle.main.url(forResource: "Attribution", withExtension: "txt")
        let text = url.flatMap { try? String(contentsOf: $0, encoding: .utf8) }
        return [.init(id: "fallback", name: "Available attribution", text: text ?? "No bundled notices were found. Rebuild RELAY using its standard packaging workflow.", source: "Attribution.txt")]
    }
}

/// Content stays in SwiftUI. The small AppKit bridge only supplies pixel-based
/// scrolling and native scroll/window lifecycle events on macOS 14.
struct CreditsRollContent: View {
    let inventory: CreditsInventory
    let directory: URL
    let onFocus: (Bool) -> Void
    @FocusState private var focusedLink: String?

    var body: some View {
        VStack(spacing: 60) {
            Text("BUILT WITH A LITTLE HELP FROM…")
                .font(.caption.weight(.semibold)).tracking(2).foregroundStyle(.secondary)
                .padding(.top, 52)
            ForEach(inventory.entries) { entry in
                VStack(spacing: 12) {
                    if !entry.notice.isEmpty {
                        Text(entry.notice).font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                    }
                    if let logo = entry.logo,
                       let image = NSImage(contentsOf: directory.appendingPathComponent(logo.file)) {
                        Image(nsImage: image).resizable().scaledToFit().frame(width: 96, height: 64)
                            .padding(8)
                            .background(logo.backdrop == "dark" ? Color(white: 0.12) : .clear,
                                        in: RoundedRectangle(cornerRadius: 8))
                            .accessibilityHidden(true)
                    }
                    Text(entry.line).font(.title3.weight(.medium)).fixedSize(horizontal: false, vertical: true)
                    Text(entry.indirect == nil ? "\(entry.integrationLines.formatted()) RELAY integration lines" : "0 direct RELAY integration lines")
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    Link(entry.name, destination: entry.url).font(.headline)
                        .focused($focusedLink, equals: entry.id)
                    Text(entry.domain).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    if let version = entry.version {
                        Text(version).font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(Array(entry.components.enumerated()), id: \.offset) { index, component in
                        Link(component.name, destination: component.url).font(.callout)
                            .focused($focusedLink, equals: "\(entry.id)-\(index)")
                    }
                }.frame(maxWidth: 540)
            }
            VStack(spacing: 16) {
                Text("SPECIAL THANKS").font(.caption.weight(.semibold)).tracking(2).foregroundStyle(.secondary)
                Text(inventory.inspiration.text).font(.title3)
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                Link(inventory.inspiration.name, destination: inventory.inspiration.url)
                    .font(.headline).focused($focusedLink, equals: "inspiration")
                Text(inventory.inspiration.url.host() ?? "").font(.caption).foregroundStyle(.secondary)
                Text("Thank you for being part of the story.").foregroundStyle(.secondary)
            }.frame(maxWidth: 540).padding(.top, 18).padding(.bottom, 72)
        }
        .frame(maxWidth: .infinity)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 32)
        .multilineTextAlignment(.center)
        .onChange(of: focusedLink) { _, value in onFocus(value != nil) }
    }
}
