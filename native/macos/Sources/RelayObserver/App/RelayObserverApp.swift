import AppKit
import SwiftUI

@main
struct RelayObserverApp: App {
    @NSApplicationDelegateAdaptor(ObserverAppDelegate.self) private var delegate
    @State private var model = ObserverModel()

    var body: some Scene {
        WindowGroup("RELAY Observer", id: "observer") {
            ObserverView(model: model)
                .onAppear { delegate.model = model }
        }
        .defaultSize(width: 820, height: 860)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu("Capture") {
                Button("Start Capture") { Task { await model.start() } }
                    .keyboardShortcut("r", modifiers: [.command]).disabled(!model.canConfigure || model.folders.isEmpty)
                Button("Stop Capture") { Task { await model.stop() } }
                    .keyboardShortcut(".", modifiers: [.command]).disabled(!model.running || model.busy)
                Button("Add Marker…") { model.showingMarker = true }.disabled(!model.running)
                Button("Reveal Log", action: model.revealLog).disabled(model.snapshot == nil)
            }
        }
        MenuBarExtra("RELAY Observer", systemImage: model.running ? "record.circle" : "waveform.path") {
            ObserverMenu(model: model)
        }
    }
}

private struct ObserverMenu: View {
    let model: ObserverModel
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Text(model.running ? "Recording folder activity" : "Observer is idle")
        Button("Show Observer") {
            openWindow(id: "observer")
            NSApp.activate(ignoringOtherApps: true)
        }
        if model.running { Button("Stop Capture") { Task { await model.stop() } } }
        Button("Reveal Log", action: model.revealLog).disabled(model.snapshot == nil)
        Divider()
        Button("Quit RELAY Observer") { NSApp.terminate(nil) }
    }
}

@MainActor
final class ObserverAppDelegate: NSObject, NSApplicationDelegate {
    weak var model: ObserverModel?
    private var terminationSignal: DispatchSourceSignal?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler { NSApp.terminate(nil) }
        source.resume()
        terminationSignal = source
        // Test-only launch path uses a disposable fixture folder. It exercises
        // the packaged native watcher and bridge without touching real media.
        let args = ProcessInfo.processInfo.arguments
        if let index = args.firstIndex(of: "--smoke-test"), args.count > index + 1 {
            let root = URL(fileURLWithPath: args[index + 1], isDirectory: true)
            Task {
                try? await Task.sleep(for: .seconds(1))
                guard let model else { NSApp.terminate(nil); return }
                model.captureIFlicks = false
                model.folders = [root]
                await model.start()
                if let snapIndex = args.firstIndex(of: "--snapshot"), args.count > snapIndex + 1 {
                    try? await Task.sleep(for: .seconds(1))
                    // Test-only capture of this process's own window. Caching
                    // SwiftUI's NSView misses compositor-backed native surfaces.
                    if let window = NSApp.windows.first(where: { $0.title == "RELAY Observer" }),
                       let image = CGWindowListCreateImage(.null, .optionIncludingWindow, CGWindowID(window.windowNumber), [.boundsIgnoreFraming, .bestResolution]) {
                        let bitmap = NSBitmapImageRep(cgImage: image)
                        if let png = bitmap.representation(using: .png, properties: [:]) { try? png.write(to: URL(fileURLWithPath: args[snapIndex + 1])) }
                    }
                }
                model.markerText = "Packaged app smoke test"
                await model.addMarker()
                try? await Task.sleep(for: .seconds(10))
                await model.stop()
                NSApp.terminate(nil)
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model, model.running || model.busy else { return .terminateNow }
        Task {
            // A Start/Stop already in flight must finish before the final join.
            while model.busy { try? await Task.sleep(for: .milliseconds(100)) }
            await model.stop()
            if let error = model.snapshot?.lastError {
                let alert = NSAlert()
                alert.messageText = "The diagnostic log may be incomplete"
                alert.informativeText = error
                alert.addButton(withTitle: "Keep Open")
                alert.addButton(withTitle: "Quit Anyway")
                NSApp.reply(toApplicationShouldTerminate: alert.runModal() == .alertSecondButtonReturn)
            } else { NSApp.reply(toApplicationShouldTerminate: true) }
        }
        return .terminateLater
    }
}
