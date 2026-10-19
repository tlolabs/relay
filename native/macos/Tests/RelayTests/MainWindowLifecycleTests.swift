import AppKit
import XCTest
@testable import Relay

@MainActor final class MainWindowLifecycleTests: XCTestCase {
    private func window(main: Bool) -> NSWindow {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
                              styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.identifier = main ? RelayDelegate.mainWindowIdentifier : NSUserInterfaceItemIdentifier("relay.test.settings")
        return window
    }

    func testClosedAndMinimizedMainWindowAreRestoredWithoutCreatingAnotherScene() {
        let main = window(main: true)
        defer { main.close() }
        let delegate = RelayDelegate()
        var opens = 0
        delegate.openMainWindow = { opens += 1 }
        main.orderOut(nil)
        XCTAssertFalse(delegate.applicationShouldHandleReopen(NSApp, hasVisibleWindows: false))
        XCTAssertTrue(main.isVisible)
        main.miniaturize(nil)
        delegate.showMainWindow(in: NSApp)
        XCTAssertFalse(main.isMiniaturized)
        XCTAssertEqual(opens, 0)
    }

    func testOnlySettingsAndNoRetainedMainWindowRequestTheMainScene() {
        let settings = window(main: false)
        settings.orderBack(nil)
        defer { settings.close() }
        let delegate = RelayDelegate()
        var opens = 0
        delegate.openMainWindow = { opens += 1 }
        XCTAssertFalse(delegate.applicationShouldHandleReopen(NSApp, hasVisibleWindows: true))
        delegate.showMainWindow(in: NSApp)
        XCTAssertEqual(opens, 1, "A visible Settings window must not consume Dock reopen")
    }

    func testReopenBeforeSceneActionAttachmentIsRemembered() {
        _ = NSApplication.shared
        let delegate = RelayDelegate()
        delegate.showMainWindow(in: NSApp)
        var opens = 0
        delegate.openMainWindow = { opens += 1 }
        XCTAssertEqual(opens, 1)
    }

    func testColdOpenUsesTheRegisteredLaunchWindowBeforeFlushingPendingReopen() {
        _ = NSApplication.shared
        let delegate = RelayDelegate()
        delegate.application(NSApp, open: [])
        let main = window(main: true)
        defer { main.close() }
        delegate.mainWindowAttached()
        var opens = 0
        delegate.openMainWindow = { opens += 1 }
        XCTAssertTrue(main.isVisible)
        XCTAssertEqual(opens, 0, "The already-created launch scene must satisfy its pending file-open")
    }
}
