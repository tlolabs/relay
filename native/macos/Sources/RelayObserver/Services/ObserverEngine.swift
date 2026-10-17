import CRelayObserver
import Foundation
import IFlicksCapture

// Actor ownership serializes all calls and guarantees that no pointer is used
// after destruction. Long-running Rust scans execute on Rust's worker thread;
// stop/join executes off the UI's main actor.
actor ObserverEngine {
    private var handle: UnsafeMutableRawPointer?

    func start(folders: [URL], recursive: Bool, captureIFlicks: Bool, bundle: URL) throws -> ObserverSnapshot {
        guard handle == nil else { throw ObserverError.message("A capture is already running.") }
        guard relay_observer_api_version() == 2 else { throw ObserverError.message("Incompatible Rust observer library.") }
        let config: [String: Any] = [
            "roots": folders.map(\.path), "log_directory": folders[0].path,
            "app_bundle": bundle.path, "recursive": recursive, "capture_iflicks": captureIFlicks
        ]
        let text = String(decoding: try JSONSerialization.data(withJSONObject: config), as: UTF8.self)
        handle = text.withCString { relay_observer_start($0) }
        guard handle != nil else { throw ObserverError.message(Self.take(relay_observer_last_error())) }
        return try snapshot()
    }

    func snapshot() throws -> ObserverSnapshot {
        guard let handle else { throw ObserverError.message("No active observer.") }
        return try ObserverSnapshot.decode(Self.take(relay_observer_snapshot(handle)))
    }

    func notice(_ notices: [NativeNotice]) {
        guard let handle else { return }
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        for notice in notices {
            guard let data = try? encoder.encode(notice) else { continue }
            let text = String(decoding: data, as: UTF8.self)
            // A full native queue is recorded as an observation_gap by Rust.
            _ = text.withCString { relay_observer_notice(handle, $0) }
        }
    }

    func iflicks(_ observation: IFlicksObservation) {
        guard let handle else { return }
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        guard let data = try? encoder.encode(observation) else { return }
        let text = String(decoding: data, as: UTF8.self)
        _ = text.withCString { relay_observer_iflicks_event(handle, $0) }
    }

    func marker(_ text: String) throws {
        guard let handle else { throw ObserverError.message("Start a capture before adding a marker.") }
        guard text.withCString({ relay_observer_marker(handle, $0) }) != 0 else {
            throw ObserverError.message("The marker was not accepted. The capture may have stopped or its event queue may be full.")
        }
    }

    func stop() throws -> ObserverSnapshot? {
        guard let handle else { return nil }
        defer { relay_observer_destroy(handle); self.handle = nil }
        return try ObserverSnapshot.decode(Self.take(relay_observer_stop(handle)))
    }

    deinit { if let handle { relay_observer_destroy(handle) } }

    private static func take(_ pointer: UnsafeMutablePointer<CChar>?) -> String {
        guard let pointer else { return "The observer returned no response." }
        defer { relay_observer_free_string(pointer) }
        return String(cString: pointer)
    }
}
