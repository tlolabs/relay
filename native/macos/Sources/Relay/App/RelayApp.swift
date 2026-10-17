import AppKit
import SwiftUI
import RelayKit

@main
struct RelayApp: App {
    @NSApplicationDelegateAdaptor(RelayDelegate.self) private var delegate
    @State private var model = RelayModel()
    var body: some Scene {
        WindowGroup("RELAY", id: "relay") {
            ContentView(model: model)
                .onAppear { delegate.model = model }
                .task {
                    let args = ProcessInfo.processInfo.arguments
                    if let index = args.firstIndex(of: "--check-connections"), args.count > index + 1 {
                        let override = args.firstIndex(of: "--plex-server-url").flatMap { args.count > $0 + 1 ? URL(string: args[$0 + 1]) : nil }
                        let provider = args.firstIndex(of: "--check-provider").flatMap { args.count > $0 + 1 ? APIProvider(rawValue: args[$0 + 1]) : nil }
                        await model.runConnectionAudit(report: URL(fileURLWithPath: args[index + 1]), plexOverride: override, only: provider)
                        return
                    }
                    let mode = args.contains("--direct-smoke-test") ? "--direct-smoke-test" : args.contains("--integration-test") ? "--integration-test" : "--smoke-test"
                    let fixture = args.firstIndex(of: mode).flatMap { index in args.count > index + 1 ? URL(fileURLWithPath: args[index + 1]) : nil }
                    if let fixture { try? Data(String(ProcessInfo.processInfo.processIdentifier).utf8).write(to: fixture.appendingPathComponent("process-id")) }
                    await model.initialize(smokeRoot: fixture)
                    if let fixture {
                        if mode == "--direct-smoke-test" { await model.runDirectSmoke(root: fixture) }
                        else if mode == "--integration-test" { await model.runIFlicksFixture(root: fixture) }
                        else { await model.runSmoke(root: fixture) }
                    }
                }
        }.defaultSize(width: 1180, height: 800)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu("Batch") {
                Button("Scan Intake") { Task { await model.scan() } }.keyboardShortcut("r", modifiers: .command).disabled(model.busy)
                Button("Review Batch") { Task { await model.previewBatch() } }.keyboardShortcut(.return, modifiers: .command).disabled(model.busy || model.reviewIds.isEmpty)
            }
        }
        Settings { ProcessingSettingsView(model: model) }
        MenuBarExtra("RELAY", systemImage: model.attentionCount > 0 ? "tray.full.fill" : "tray") { RelayMenu(model: model) }
    }
}
private struct RelayMenu: View {
    let model: RelayModel
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Text("\(model.attentionCount) items to review")
        Button("Show RELAY") { openWindow(id: "relay"); NSApp.activate(ignoringOtherApps: true) }
        Button("Scan Intake") { Task { await model.scan() } }.disabled(model.busy)
        SettingsLink { Text("Settings…") }
        Divider()
        Button("Quit RELAY") { NSApp.terminate(nil) }
    }
}
@MainActor final class RelayDelegate: NSObject, NSApplicationDelegate {
    weak var model: RelayModel?
    private var terminationSignal: DispatchSourceSignal?
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        if !ProcessInfo.processInfo.arguments.contains("--direct-smoke-test") { NSApp.activate(ignoringOtherApps: true) }
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler { NSApp.terminate(nil) }; source.resume(); terminationSignal = source
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    private var terminationRequested = false
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model, model.hasOpenStore else { return .terminateNow }
        guard !terminationRequested else { return .terminateCancel }
        terminationRequested = true
        Task {
            while model.busy { try? await Task.sleep(for: .milliseconds(100)) }
            await model.close()
            // Cancel this synchronous termination request, finish actor work,
            // then request termination again with a closed store. A nested
            // terminateLater modal loop can starve the current SwiftUI task.
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
        return .terminateCancel
    }
}
