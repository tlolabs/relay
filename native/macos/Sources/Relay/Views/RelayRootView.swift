import AppKit
import SwiftUI

struct RelayRootView: View {
    let model: RelayModel
    let delegate: RelayDelegate
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        ContentView(model: model)
            .background(MainWindowMarker {
                // A cold file-open can precede the first scene. Register its
                // native window before flushing that pending reopen request.
                delegate.mainWindowAttached()
                delegate.model = model
                delegate.openMainWindow = { openWindow(id: "relay") }
            })
    }
}

/// Identifies only RELAY's main scene; Settings must never be mistaken for it.
private struct MainWindowMarker: NSViewRepresentable {
    let onAttach: () -> Void
    func makeNSView(context: Context) -> Marker { let marker = Marker(); marker.onAttach = onAttach; return marker }
    func updateNSView(_ nsView: Marker, context: Context) {}

    final class Marker: NSView {
        var onAttach: (() -> Void)?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window?.identifier = RelayDelegate.mainWindowIdentifier
            if window != nil { onAttach?() }
        }
    }
}
