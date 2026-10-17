import AppKit
import Carbon
import IFlicksCapture
import RelayKit

/// Explicit user action. Consent can wait indefinitely for a human; keep it on
/// an independent queue, outside sampler/controller actors and the Quit drain.
@MainActor enum AutomationPermission {
    static func request() async throws -> String {
        if IFlicksProcess.running() == nil {
            let config = NSWorkspace.OpenConfiguration(); config.activates = true
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: "/Applications/iFlicks 3.app"), configuration: config) { _, error in
                    if let error { continuation.resume(throwing: error) } else { continuation.resume() }
                }
            }
        }
        guard let process = IFlicksProcess.running() else { throw RelayFailure.message("Open iFlicks before requesting Automation access") }
        let status: Int32 = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let target = NSAppleEventDescriptor(processIdentifier: process.pid)
                let result = AEDeterminePermissionToAutomateTarget(target.aeDesc, AEEventClass(kAECoreSuite), AEEventID(kAEGetData), true)
                continuation.resume(returning: result)
            }
        }
        guard status == 0 else { throw RelayFailure.message("Automation access was not granted (\(status)). Enable RELAY → iFlicks in System Settings → Privacy & Security → Automation, then retry handoff.") }
        return "Automation access granted. Retry Send to iFlicks for prepared jobs."
    }
}
