import AppKit
import SwiftUI
import XCTest
@testable import Relay

final class CreditsTests: XCTestCase {
    private var directory: URL {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { root.deleteLastPathComponent() }
        return root.appendingPathComponent("build/credits")
    }

    func testPlaybackWaitsThenUsesElapsedTimeAndStopsAtEnd() {
        var playback = CreditsPlayback()
        playback.advance(seconds: 1.5, maximum: 100)
        XCTAssertEqual(playback.position, 0)
        playback.advance(seconds: 1, maximum: 100)
        XCTAssertEqual(playback.position, 9, accuracy: 0.001)
        playback.advance(seconds: 10, maximum: 100)
        XCTAssertEqual(playback.position, 100)
        XCTAssertTrue(playback.completed)
        playback.advance(seconds: 10, maximum: 100)
        XCTAssertEqual(playback.position, 100)
    }

    func testFrameRateDoesNotChangeDistance() {
        var slow = CreditsPlayback(), fast = CreditsPlayback()
        for _ in 0..<300 { slow.advance(seconds: 1.0 / 30, maximum: 1000) }
        for _ in 0..<1200 { fast.advance(seconds: 1.0 / 120, maximum: 1000) }
        XCTAssertEqual(slow.position, 144, accuracy: 0.001)
        XCTAssertEqual(fast.position, slow.position, accuracy: 0.001)
    }

    func testManualScrollAndAccessibilityReplayRemainPaused() {
        var playback = CreditsPlayback()
        playback.manualScroll(to: 72)
        playback.advance(seconds: 50, maximum: 1000)
        XCTAssertEqual(playback.position, 72)
        playback.replay(staticMode: true)
        XCTAssertTrue(playback.paused)
        XCTAssertEqual(playback.position, 0)
        playback.replay(staticMode: false)
        XCTAssertFalse(playback.paused)
        XCTAssertEqual(playback.delay, 2)
        playback.advance(seconds: .nan, maximum: 1000)
        XCTAssertEqual(playback.position, 0)
    }

    func testLifecycleAndInteractionSuspendPlayback() {
        let playback = CreditsPlayback()
        XCTAssertTrue(playback.shouldRun(visible: true, active: true, staticMode: false, interacting: false, maximum: 100))
        XCTAssertFalse(playback.shouldRun(visible: false, active: true, staticMode: false, interacting: false, maximum: 100))
        XCTAssertFalse(playback.shouldRun(visible: true, active: false, staticMode: false, interacting: false, maximum: 100))
        XCTAssertFalse(playback.shouldRun(visible: true, active: true, staticMode: true, interacting: false, maximum: 100))
        XCTAssertFalse(playback.shouldRun(visible: true, active: true, staticMode: false, interacting: true, maximum: 100))
        XCTAssertFalse(playback.shouldRun(visible: true, active: true, staticMode: false, interacting: false, maximum: 0))
    }

    func testBundledInventoryLoadsWithTruthfulStatsAndCompleteNotices() throws {
        let inventory = try CreditsInventory.load(directory: directory)
        XCTAssertGreaterThan(inventory.entries.count, 40)
        let indirect = try XCTUnwrap(inventory.entries.first { $0.id == "zenlib" })
        XCTAssertEqual(indirect.integrationLines, 0)
        XCTAssertTrue(indirect.line.contains("MediaInfo"))
        let tmdb = try XCTUnwrap(inventory.entries.first { $0.id == "tmdb" })
        XCTAssertTrue(tmdb.line.contains(tmdb.integrationLines.formatted()))
        XCTAssertFalse(tmdb.line.contains("{count}"))
        XCTAssertNotNil(tmdb.logo)
        XCTAssertEqual(inventory.inspiration.name, "iFlicks")
        XCTAssertTrue(inventory.notices.contains { $0.id == "rust-unicode-ident" && $0.text.contains("UNICODE") })
        XCTAssertThrowsError(try CreditsInventory.load(directory: directory.appendingPathComponent("missing")))
    }

    @MainActor
    func testNativeScrollBridgeMeasuresScrollableContentAndStopsAtClosingThanks() async throws {
        let inventory = try CreditsInventory.load(directory: directory)
        var maximum = 0.0
        var manual: [Double] = []
        let wrapper = CreditsScrollView(inventory: inventory, directory: directory, position: 0,
                                        onManualScroll: { manual.append($0) }, onMaximum: { maximum = $0 },
                                        onFocus: { _ in }, onVisibility: { _ in })
        let coordinator = wrapper.makeCoordinator()
        let scroll = CreditsNativeScrollView(frame: NSRect(x: 0, y: 0, width: 820, height: 480))
        scroll.hasVerticalScroller = true
        scroll.contentView.postsBoundsChangedNotifications = true
        coordinator.attach(scroll)
        scroll.tile()
        coordinator.layoutDocument()
        // Allow the bridge's deferred geometry notification to reach SwiftUI.
        await Task.yield()
        XCTAssertGreaterThan(maximum, 1000)
        XCTAssertTrue(try XCTUnwrap(scroll.documentView).isFlipped)
        XCTAssertEqual(scroll.contentView.bounds.minY, 0)
        coordinator.scroll(to: 90)
        XCTAssertEqual(scroll.contentView.bounds.minY, 90, accuracy: 1)
        XCTAssertTrue(manual.isEmpty, "Programmatic scrolling must not pause itself")
        coordinator.scroll(to: maximum)
        XCTAssertEqual(scroll.contentView.bounds.maxY, scroll.documentView!.frame.height, accuracy: 1)
        scroll.onUserScroll?()
        XCTAssertFalse(manual.isEmpty)
        coordinator.detach()
    }

    @MainActor
    func testNativeWindowLifecycleAndTextFocusSuspendTheRoll() async throws {
        _ = NSApplication.shared
        let inventory = try CreditsInventory.load(directory: directory)
        var visibility: [Bool] = []
        var focus: [Bool] = []
        let wrapper = CreditsScrollView(inventory: inventory, directory: directory, position: 0,
                                        onManualScroll: { _ in }, onMaximum: { _ in },
                                        onFocus: { focus.append($0) }, onVisibility: { visibility.append($0) })
        let coordinator = wrapper.makeCoordinator()
        let scroll = CreditsNativeScrollView(frame: NSRect(x: 0, y: 0, width: 820, height: 480))
        coordinator.attach(scroll)
        let window = NSWindow(contentRect: scroll.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = scroll
        window.orderBack(nil)
        window.update()
        // Drain native visibility notifications before testing responder changes.
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(visibility.last, true)
        let document = try XCTUnwrap(scroll.documentView)
        let selectableText = NSTextView(frame: NSRect(x: 0, y: 0, width: 100, height: 30))
        document.addSubview(selectableText)
        XCTAssertTrue(window.makeFirstResponder(selectableText))
        window.update()
        await Task.yield()
        XCTAssertEqual(focus.last, true)
        XCTAssertTrue(window.makeFirstResponder(nil))
        window.update()
        await Task.yield()
        XCTAssertEqual(focus.last, false)
        window.close()
        await Task.yield()
        XCTAssertEqual(visibility.last, false)
        coordinator.detach()
    }

    @MainActor
    func testCreditsRenderInBothAppearancesWithReadableNoticesAndLocalLogos() async throws {
        _ = NSApplication.shared
        let inventory = try CreditsInventory.load(directory: directory)
        let output = directory.deletingLastPathComponent().appendingPathComponent("qa/credits")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let model = RelayModel()
        model.smokeMode = true
        model.settingsTab = "credits"

        func capture<V: View>(_ root: V, name: String, appearance: NSAppearance.Name, width: CGFloat = 820, height: CGFloat = 680) async throws {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                                  styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: appearance)
            let host = NSHostingView(rootView: root.frame(width: width, height: height).background(.background))
            window.contentView = host
            window.orderBack(nil)
            defer { window.close() }
            try await Task.sleep(for: .milliseconds(250))
            host.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent(name + ".png"))
        }

        for (label, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            try await capture(ProcessingSettingsView(model: model, creditsResourceDirectory: directory), name: label + "-settings", appearance: appearance)
        }
        let logoEntries = inventory.entries.filter { $0.logo != nil }
        for entry in logoEntries {
            XCTAssertNotNil(NSImage(contentsOf: directory.appendingPathComponent(try XCTUnwrap(entry.logo).file)))
        }
        let logoInventory = CreditsInventory(schemaVersion: 1, entries: logoEntries, notices: inventory.notices, inspiration: inventory.inspiration)
        try await capture(CreditsRollContent(inventory: logoInventory, directory: directory, onFocus: { _ in }),
                          name: "logo-attribution", appearance: .aqua, height: 1200)
        try await capture(CreditsNoticesView(notices: inventory.notices), name: "notices", appearance: .aqua, width: 758, height: 588)
    }
}
