import AppKit
import SwiftUI
import XCTest
@testable import Relay

@MainActor final class PlatformPresentationTests: XCTestCase {
    private let appearances: [NSAppearance.Name] = [.aqua, .darkAqua, .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua]

    func testPrimaryStatusTextPaletteMeetsSmallTextContrastInFourAppearances() throws {
        for name in appearances {
            let appearance = try XCTUnwrap(NSAppearance(named: name))
            appearance.performAsCurrentDrawingAppearance {
                func luminance(_ color: NSColor) -> Double {
                    let rgb = color.usingColorSpace(.sRGB)!
                    func linear(_ component: CGFloat) -> Double {
                        let c = Double(component)
                        return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
                    }
                    return 0.2126 * linear(rgb.redComponent) + 0.7152 * linear(rgb.greenComponent) + 0.0722 * linear(rgb.blueComponent)
                }
                let foreground = luminance(.labelColor)
                for background in [NSColor.windowBackgroundColor, .controlBackgroundColor, .textBackgroundColor] {
                    let back = luminance(background)
                    let ratio = (max(foreground, back) + 0.05) / (min(foreground, back) + 0.05)
                    XCTAssertGreaterThanOrEqual(ratio, 4.5, "\(name.rawValue): primary status text palette")
                }
            }
        }
    }

    func testStatusAndNotificationSettingsRenderInFourAppearances() async throws {
        _ = NSApplication.shared
        let model = RelayModel(); model.smokeMode = true
        model.error = "A video needs review. Processing has not started."
        let output = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("build/qa/audit-followup")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for name in appearances {
            for settings in [false, true] {
                let size = settings ? NSSize(width: 820, height: 680) : NSSize(width: 1180, height: 800)
                let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.appearance = NSAppearance(named: name)
                let view = settings ? AnyView(ProcessingSettingsView(model: model)) : AnyView(ContentView(model: model))
                let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height).background(.background))
                window.contentView = host
                window.orderBack(nil)
                try await Task.sleep(for: .milliseconds(120))
                host.layoutSubtreeIfNeeded()
                let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                try png.write(to: output.appendingPathComponent("\(settings ? "settings" : "status")-\(name.rawValue).png"))
                window.close()
            }
        }
    }
}
