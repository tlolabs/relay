import CoreServices
import Foundation

// FSEvents only supplies hints. Rust performs independent metadata snapshots
// and logs dropped-event/root-change flags without claiming completeness.
final class FolderWatcher {
    private var stream: FSEventStreamRef?
    private let receive: @Sendable ([NativeNotice]) -> Void

    init(receive: @escaping @Sendable ([NativeNotice]) -> Void) { self.receive = receive }

    func start(folders: [URL]) throws {
        stop()
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, pathsPointer, flags, ids in
            guard let info else { return }
            let watcher = Unmanaged<FolderWatcher>.fromOpaque(info).takeUnretainedValue()
            let paths = unsafeBitCast(pathsPointer, to: NSArray.self) as! [String]
            let gapMask = UInt32(kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagKernelDropped | kFSEventStreamEventFlagEventIdsWrapped | kFSEventStreamEventFlagRootChanged | kFSEventStreamEventFlagMount | kFSEventStreamEventFlagUnmount)
            let timestamp = UInt64(Date().timeIntervalSince1970 * 1000)
            let events = (0..<count).map { index in
                NativeNotice(path: paths[index], flags: flags[index], eventId: String(ids[index]),
                    receivedUnixMs: timestamp, gap: flags[index] & gapMask != 0, error: nil)
            }
            watcher.receive(events)
        }
        let createFlags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagWatchRoot | kFSEventStreamCreateFlagNoDefer)
        guard let stream = FSEventStreamCreate(kCFAllocatorDefault, callback, &context,
            folders.map(\.path) as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.25, createFlags) else {
            throw ObserverError.message("Could not create the native filesystem watcher. Metadata scans are still available.")
        }
        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, DispatchQueue.main)
        guard FSEventStreamStart(stream) else {
            stop()
            throw ObserverError.message("Could not start native filesystem notifications. One-second metadata scans will continue.")
        }
    }

    func stop() {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
        }
    }

    deinit { stop() }
}
