import AppKit
import RelayKit

extension RelayModel {
    /// Runs only inside the disposable packaged workflow, with its isolated store.
    func verifyMainWindowSmoke(delegate: RelayDelegate, root: URL) async throws {
        let originalEngine = engine
        let ids = Set(jobs.map(\.id))
        func mainWindow() -> NSWindow? {
            NSApp.windows.first { $0.identifier == RelayDelegate.mainWindowIdentifier }
        }
        func waitForMain(_ phase: String) async throws {
            let deadline = Date().addingTimeInterval(5)
            while mainWindow()?.isVisible != true || mainWindow()?.isMiniaturized == true {
                guard Date() < deadline else { throw RelayFailure.message("SwiftUI main scene did not reopen: \(phase)") }
                try await Task.sleep(for: .milliseconds(25))
            }
            try await Task.sleep(for: .milliseconds(100)) // Let queued scene-open events settle.
            guard NSApp.windows.filter({ $0.identifier == RelayDelegate.mainWindowIdentifier && $0.isVisible }).count == 1 else {
                let windows = NSApp.windows.filter { $0.identifier == RelayDelegate.mainWindowIdentifier }.map { "\($0.windowNumber):visible=\($0.isVisible):minimized=\($0.isMiniaturized)" }.joined(separator: ", ")
                throw RelayFailure.message("Expected one visible main window at \(phase): \(windows)")
            }
        }
        try await waitForMain("cold LaunchServices import")
        mainWindow()?.close()
        try await Task.sleep(for: .milliseconds(100))
        _ = delegate.applicationShouldHandleReopen(NSApp, hasVisibleWindows: false)
        delegate.showMainWindow(in: NSApp) // Bursts must still create only one scene.
        try await waitForMain("Dock reopen")
        mainWindow()?.miniaturize(nil)
        let minimizeDeadline = Date().addingTimeInterval(3)
        while mainWindow()?.isMiniaturized != true || mainWindow()?.isVisible != false {
            guard Date() < minimizeDeadline else { throw RelayFailure.message("Main window did not finish minimizing") }
            try await Task.sleep(for: .milliseconds(25))
        }
        try await Task.sleep(for: .milliseconds(150))
        _ = delegate.applicationShouldHandleReopen(NSApp, hasVisibleWindows: true)
        try await waitForMain("minimized reopen")
        guard mainWindow()?.isMiniaturized == false else { throw RelayFailure.message("Main window remained minimized") }

        let settings = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
                                styleMask: [.titled, .closable], backing: .buffered, defer: false)
        settings.title = "Settings lifecycle fixture"; settings.isReleasedWhenClosed = false
        settings.orderBack(nil)
        defer { settings.close() }
        mainWindow()?.close()
        try await Task.sleep(for: .milliseconds(100))
        _ = delegate.applicationShouldHandleReopen(NSApp, hasVisibleWindows: true)
        try await waitForMain("Settings-only reopen")

        mainWindow()?.close()
        try await Task.sleep(for: .milliseconds(100))
        // The Python driver now sends a real LaunchServices file-open event.
        try Data().write(to: root.appendingPathComponent("awaiting-finder-import"))
        try await waitForMain("warm LaunchServices import")
        await videoImportTask?.value
        guard engine === originalEngine, Set(jobs.map(\.id)) == ids,
              jobs.allSatisfy({ $0.state == "needs_review" && $0.approvedRevision == nil }), processingTask == nil else {
            throw RelayFailure.message("Window recreation restarted the store or duplicated/approved imports")
        }
        try Data(#"{"closed_reopened":true,"minimized_restored":true,"settings_only_reopened":true,"imports_reopened":true,"single_main_window":true,"store_preserved":true,"imports_not_approved":true}"#.utf8)
            .write(to: root.appendingPathComponent("window-lifecycle.json"))
    }
}
