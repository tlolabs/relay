import AppKit

/// Workspace notifications capture short-lived launches too; the sampler's
/// running-process probe also recovers from missed notifications.
@MainActor public final class IFlicksLifecycleMonitor {
    private var tokens: [NSObjectProtocol] = []
    public init(sampler: IFlicksSampler) {
        let center = NSWorkspace.shared.notificationCenter
        for (name, launched) in [(NSWorkspace.didLaunchApplicationNotification, true), (NSWorkspace.didTerminateApplicationNotification, false)] {
            tokens.append(center.addObserver(forName: name, object: nil, queue: .main) { notification in
                guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                      app.bundleIdentifier == "com.iflicksapp.iFlicks3" else { return }
                let identity = IFlicksProcess(application: app)
                Task {
                    if launched { await sampler.processLaunched(identity) }
                    else { await sampler.processExited(identity) }
                }
            })
        }
    }
    public func stop() {
        for token in tokens { NSWorkspace.shared.notificationCenter.removeObserver(token) }
        tokens.removeAll()
    }
    deinit { for token in tokens { NSWorkspace.shared.notificationCenter.removeObserver(token) } }
}
