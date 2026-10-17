import AppKit
import Foundation

public struct IFlicksProcess: Codable, Equatable, Sendable {
    public var pid: Int32
    public var launchUnixMs: UInt64?
    public var bundleIdentifier = "com.iflicksapp.iFlicks3"
    public var version: String?
    public init(pid: Int32, launchUnixMs: UInt64? = nil, version: String? = nil) {
        self.pid = pid; self.launchUnixMs = launchUnixMs; self.version = version
    }
    public init(application: NSRunningApplication) {
        self.init(pid: application.processIdentifier,
            launchUnixMs: application.launchDate.map { UInt64($0.timeIntervalSince1970 * 1000) },
            version: application.bundleURL.flatMap { Bundle(url: $0)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String })
    }
    public static func running() -> IFlicksProcess? {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.iflicksapp.iFlicks3").first,
              !app.isTerminated else { return nil }
        return IFlicksProcess(application: app)
    }
}

public struct IFlicksVideo: Codable, Equatable, Sendable {
    public var id: String
    public var status: String
    public var statusCode: String
    public var progress: Int64?
    public var filePath: String?
    public var fileError: String?
    public init(id: String, status: String, statusCode: String, progress: Int64?, filePath: String?, fileError: String? = nil) {
        self.id = id; self.status = status; self.statusCode = statusCode
        self.progress = progress; self.filePath = filePath; self.fileError = fileError
    }
}

public struct IFlicksObservation: Encodable, Sendable {
    public var event: String
    public var observedUnixMs = Self.now()
    public var process: IFlicksProcess?
    public var sampleStartedUnixMs: UInt64?
    public var sampleFinishedUnixMs: UInt64?
    public var lastSuccessfulSampleUnixMs: UInt64?
    public var videos: [IFlicksVideo]?
    public var removedVideoIds: [String]?
    public var errorCode: Int?
    public var message: String?
    public var missedIntervals: UInt64?
    public var durationMs: UInt64?
    public var reason: String?
    public var state: String?
    public static func now() -> UInt64 { UInt64(Date().timeIntervalSince1970 * 1000) }
}

public struct IFlicksCaptureStatus: Sendable {
    public init() {}
    public var message = "Waiting for iFlicks"
    public var lastSuccessfulSampleUnixMs: UInt64?
    public var videos: [IFlicksVideo] = []
}
public struct IFlicksQueryFailure: LocalizedError, Sendable {
    public var errorDescription: String? { message.contains("(\(code))") ? message : "\(message) (\(code))" }
    public var code: Int
    public var message: String
    public init(_ code: Int, _ message: String) { self.code = code; self.message = message }
}
public protocol IFlicksTransport: Sendable {
    func sample(process: IFlicksProcess, timeout: TimeInterval) async throws -> [IFlicksVideo]
}

/// One serial sampling loop. Cancellation stops future work; the bounded native
/// send already in progress is awaited before the Rust writer is stopped.
public actor IFlicksSampler {
    private let transport: any IFlicksTransport
    private let provider: @Sendable () async -> IFlicksProcess?
    private let sink: @Sendable (IFlicksObservation) async -> Void
    private let update: @Sendable (IFlicksCaptureStatus) async -> Void
    private var task: Task<Void, Never>?
    private var process: IFlicksProcess?
    private var previous: [IFlicksVideo]?
    private var denied = false
    private var inFlight = false
    private var status = IFlicksCaptureStatus()
    private var lastTick: UInt64?
    private var stopping = false
    private var lifecycle: [(IFlicksProcess, Bool, UInt64)] = []

    public init(transport: any IFlicksTransport, provider: @escaping @Sendable () async -> IFlicksProcess?,
                sink: @escaping @Sendable (IFlicksObservation) async -> Void,
                update: @escaping @Sendable (IFlicksCaptureStatus) async -> Void = { _ in }) {
        self.transport = transport; self.provider = provider; self.sink = sink; self.update = update
    }
    public func start() async {
        guard task == nil else { return }
        stopping = false
        await update(status)
        var event = observation("iflicks_capture_state"); event.state = "enabled"
        await sink(event)
        task = Task {
            var next = DispatchTime.now().uptimeNanoseconds
            while !Task.isCancelled {
                await self.tick()
                next += 250_000_000
                let now = DispatchTime.now().uptimeNanoseconds
                if next < now { next = now }
                try? await Task.sleep(nanoseconds: next - now)
            }
        }
    }
    public func stop() async {
        stopping = true
        let pending = task
        pending?.cancel()
        await pending?.value
        await drainLifecycle()
        task = nil
        status.message = "Stopped · last observations retained"
        var event = observation("iflicks_capture_state")
        event.state = "stopped"
        await sink(event); await update(status)
    }
    private func observation(_ kind: String) -> IFlicksObservation {
        var event = IFlicksObservation(event: kind)
        event.process = process
        event.lastSuccessfulSampleUnixMs = status.lastSuccessfulSampleUnixMs
        return event
    }
    // Notifications enqueue immutable observations. The sampling task drains
    // them, so Stop also awaits lifecycle log deliveries, not just query replies.
    public func processLaunched(_ identity: IFlicksProcess) {
        guard task != nil, !stopping else { return }
        lifecycle.append((identity, true, IFlicksObservation.now()))
    }
    public func processExited(_ identity: IFlicksProcess) {
        guard task != nil, !stopping else { return }
        lifecycle.append((identity, false, IFlicksObservation.now()))
    }
    private func drainLifecycle() async {
        while !lifecycle.isEmpty {
            let (identity, launched, time) = lifecycle.removeFirst()
            if launched { await transition(identity, observed: time) }
            else if process == identity { await transition(nil, observed: time) }
        }
    }
    private func transition(_ current: IFlicksProcess?, observed: UInt64? = nil) async {
        guard current != process else { return }
        var exit = process == nil ? nil : observation("iflicks_app_exited")
        if let observed { exit?.observedUnixMs = observed }
        process = current; previous = nil; denied = false
        var launch = current == nil ? nil : observation("iflicks_app_started")
        if let observed { launch?.observedUnixMs = observed }
        status.message = current == nil ? "iFlicks exited · last observations retained" : "Reading iFlicks"
        if let exit { await sink(exit) }
        if let launch { await sink(launch) }
        await update(status)
    }
    public func tick() async {
        guard !inFlight else { return }
        inFlight = true
        defer { inFlight = false }
        let monotonic = DispatchTime.now().uptimeNanoseconds
        if let lastTick, monotonic - lastTick > 375_000_000 {
            var gap = observation("iflicks_sampling_gap")
            gap.durationMs = (monotonic - lastTick) / 1_000_000
            gap.missedIntervals = max(1, (monotonic - lastTick) / 250_000_000 - 1)
            gap.message = "Sampling interval exceeded 250 ms"
            await sink(gap)
        }
        lastTick = monotonic
        await drainLifecycle()
        await transition(await provider())
        guard let queried = process, !denied, !Task.isCancelled else { return }
        let started = IFlicksObservation.now()
        var event = observation("iflicks_snapshot")
        event.sampleStartedUnixMs = started
        do {
            let videos = try await transport.sample(process: queried, timeout: 1)
            event.sampleFinishedUnixMs = IFlicksObservation.now()
            // A reply from an exited process cannot become a new inventory or
            // erase the last successful observations, even on immediate restart.
            await drainLifecycle()
            let current = await provider()
            guard current == queried, process == queried else {
                throw IFlicksQueryFailure(-600, "Process exited or restarted during query; reply discarded")
            }
            guard Set(videos.map(\.id)).count == videos.count, !videos.contains(where: { $0.id.isEmpty }) else {
                throw IFlicksQueryFailure(-1700, "Missing or duplicate video IDs")
            }
            let sorted = videos.sorted { $0.id < $1.id }
            let removed = (previous ?? []).map(\.id).filter { id in !sorted.contains { $0.id == id } }
            var emissions: [IFlicksObservation] = []
            if !removed.isEmpty {
                var removal = event; removal.event = "iflicks_queue_removed"
                removal.removedVideoIds = removed
                emissions.append(removal)
            }
            if previous != sorted {
                event.videos = sorted; event.reason = previous == nil ? "initial_inventory" : "changed"
                emissions.append(event)
            }
            previous = sorted; status.videos = sorted
            status.lastSuccessfulSampleUnixMs = event.sampleFinishedUnixMs
            status.message = "Reading iFlicks · \(sorted.count) video(s)"
            for emission in emissions { await sink(emission) }
        } catch {
            let failure = error as? IFlicksQueryFailure ?? IFlicksQueryFailure((error as NSError).code, error.localizedDescription)
            event.event = "iflicks_query_error"; event.sampleFinishedUnixMs = IFlicksObservation.now()
            event.errorCode = failure.code; event.message = failure.message
            if process == queried && (failure.code == -1743 || failure.code == -1744) {
                denied = true; status.message = "iFlicks capture unavailable · Automation access denied"
            } else { status.message = "iFlicks query unavailable · \(failure.message)" }
            await sink(event)
            await drainLifecycle()
            await transition(await provider())
        }
        let elapsed = DispatchTime.now().uptimeNanoseconds - monotonic
        if elapsed > 250_000_000 {
            var gap = observation("iflicks_sampling_gap")
            gap.durationMs = elapsed / 1_000_000
            gap.missedIntervals = max(1, elapsed / 250_000_000)
            gap.message = "Query occupied one or more sampling intervals"
            await sink(gap)
        }
        lastTick = DispatchTime.now().uptimeNanoseconds
        await drainLifecycle()
        await update(status)
    }
}
