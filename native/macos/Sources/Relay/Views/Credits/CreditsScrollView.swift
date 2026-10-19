import AppKit
import SwiftUI

@MainActor
struct CreditsScrollView: NSViewRepresentable {
    let inventory: CreditsInventory
    let directory: URL
    let position: Double
    let onManualScroll: (Double) -> Void
    let onMaximum: (Double) -> Void
    let onFocus: (Bool) -> Void
    let onVisibility: (Bool) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> CreditsNativeScrollView {
        let scroll = CreditsNativeScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.contentView.postsBoundsChangedNotifications = true
        context.coordinator.attach(scroll)
        return scroll
    }

    func updateNSView(_ scroll: CreditsNativeScrollView, context: Context) {
        context.coordinator.owner = self
        context.coordinator.layoutDocument()
        context.coordinator.scroll(to: position)
    }

    static func dismantleNSView(_ scroll: CreditsNativeScrollView, coordinator: Coordinator) {
        coordinator.detach()
    }

    @MainActor final class Coordinator {
        var owner: CreditsScrollView
        private weak var scrollView: CreditsNativeScrollView?
        private var hosting: NSHostingView<AnyView>?
        private var observers: [NSObjectProtocol] = []
        private var windowObservers: [NSObjectProtocol] = []
        private var layingOut = false
        private var scrolling = false
        private var width = 0.0
        private var maximum = -1.0
        private var shown: Bool?
        private var linkFocused = false
        private var nativeFocused = false
        private var reportedFocus = false

        init(_ owner: CreditsScrollView) { self.owner = owner }

        func attach(_ scroll: CreditsNativeScrollView) {
            scrollView = scroll
            let host = NSHostingView(rootView: AnyView(EmptyView()))
            hosting = host
            scroll.documentView = host
            scroll.onLayout = { [weak self] in self?.layoutDocument() }
            scroll.onWindowChange = { [weak self] in self?.observeWindow() }
            scroll.onUserScroll = { [weak self] in
                guard let self, let scroll = self.scrollView else { return }
                self.owner.onManualScroll(Double(scroll.contentView.bounds.minY))
            }
            observers.append(NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification, object: scroll.contentView, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, !self.layingOut, !self.scrolling, let scroll = self.scrollView else { return }
                    self.owner.onManualScroll(Double(scroll.contentView.bounds.minY))
                }
            })
            observers.append(NotificationCenter.default.addObserver(
                forName: NSScrollView.willStartLiveScrollNotification, object: scroll, queue: .main
            ) { [weak self] _ in MainActor.assumeIsolated { self?.scrollView?.onUserScroll?() } })
            observeWindow()
        }

        func layoutDocument() {
            guard !layingOut, let scroll = scrollView, let host = hosting else { return }
            let newWidth = Double(scroll.contentSize.width)
            guard newWidth > 0 else { return }
            layingOut = true
            defer { layingOut = false }
            if width != newWidth {
                width = newWidth
                let content = CreditsRollContent(inventory: owner.inventory, directory: owner.directory,
                                                 onFocus: { [weak self] focused in
                    self?.linkFocused = focused
                    self?.reportFocus()
                })
                host.rootView = AnyView(content.frame(width: newWidth))
                host.setFrameSize(NSSize(width: newWidth, height: max(host.frame.height, 1)))
                host.layoutSubtreeIfNeeded()
                host.setFrameSize(NSSize(width: newWidth, height: host.fittingSize.height))
            }
            let newMaximum = max(0, Double(host.frame.height - scroll.contentSize.height))
            if maximum != newMaximum {
                maximum = newMaximum
                DispatchQueue.main.async { [weak self] in self?.owner.onMaximum(newMaximum) }
            }
        }

        func scroll(to position: Double) {
            guard let scroll = scrollView, maximum >= 0 else { return }
            let y = min(max(0, position), maximum)
            guard abs(Double(scroll.contentView.bounds.minY) - y) > 0.01 else { return }
            scrolling = true
            scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
            scroll.reflectScrolledClipView(scroll.contentView)
            scrolling = false
        }

        private func observeWindow() {
            windowObservers.forEach(NotificationCenter.default.removeObserver)
            windowObservers.removeAll()
            guard let window = scrollView?.window else { reportVisibility(false); return }
            for name in [NSWindow.didBecomeKeyNotification, NSWindow.didChangeOcclusionStateNotification,
                         NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification] {
                windowObservers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self, weak window] _ in
                    MainActor.assumeIsolated {
                        self?.reportVisibility(window?.isVisible == true && window?.isMiniaturized == false)
                    }
                })
            }
            windowObservers.append(NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.reportVisibility(false) }
            })
            windowObservers.append(NotificationCenter.default.addObserver(forName: NSWindow.didUpdateNotification, object: window, queue: .main) { [weak self, weak window] _ in
                MainActor.assumeIsolated {
                    guard let self, let host = self.hosting else { return }
                    self.reportVisibility(window?.isVisible == true && window?.isMiniaturized == false)
                    // Includes selectable text as well as SwiftUI links. Keyboard
                    // focus must hold the roll even after the pointer leaves it.
                    self.nativeFocused = (window?.firstResponder as? NSView)?.isDescendant(of: host) == true
                    self.reportFocus()
                }
            })
            reportVisibility(window.isVisible && !window.isMiniaturized)
        }

        private func reportFocus() {
            let focused = linkFocused || nativeFocused
            guard focused != reportedFocus else { return }
            reportedFocus = focused
            DispatchQueue.main.async { [weak self] in self?.owner.onFocus(focused) }
        }

        private func reportVisibility(_ value: Bool) {
            guard shown != value else { return }
            shown = value
            DispatchQueue.main.async { [weak self] in self?.owner.onVisibility(value) }
        }

        func detach() {
            (observers + windowObservers).forEach(NotificationCenter.default.removeObserver)
            observers.removeAll()
            windowObservers.removeAll()
            scrollView?.onLayout = nil
            scrollView?.onUserScroll = nil
            scrollView?.onWindowChange = nil
            // SwiftUI owns disappearance state. Writing it synchronously during
            // dismantle re-enters the view graph while that graph is destroyed.
        }
    }
}

/// The content remains a normal, accessible native scroll view. Trackpad,
/// keyboard and scroller interactions hand control back to the user.
final class CreditsNativeScrollView: NSScrollView {
    var onLayout: (() -> Void)?
    var onWindowChange: (() -> Void)?
    var onUserScroll: (() -> Void)?

    override func tile() { super.tile(); onLayout?() }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); onWindowChange?() }
    override func scrollWheel(with event: NSEvent) { onUserScroll?(); super.scrollWheel(with: event) }
    override func keyDown(with event: NSEvent) {
        if [123, 124, 125, 126, 115, 119, 116, 121, 49].contains(event.keyCode) { onUserScroll?() }
        super.keyDown(with: event)
    }
}
