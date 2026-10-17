import Carbon
import XCTest
@testable import IFlicksCapture

private actor Harness {
    var process: IFlicksProcess? = IFlicksProcess(pid: 101, launchUnixMs: 1)
    var events: [IFlicksObservation] = []
    var status = IFlicksCaptureStatus()
    func current() -> IFlicksProcess? { process }
    func setProcess(_ value: IFlicksProcess?) { process = value }
    func record(_ value: IFlicksObservation) { events.append(value) }
    func update(_ value: IFlicksCaptureStatus) { status = value }
    func kinds() -> [String] { events.map(\.event) }
}
private actor FakeTransport: IFlicksTransport {
    var results: [Result<[IFlicksVideo], IFlicksQueryFailure>]
    var calls = 0
    var active = 0
    var maxActive = 0
    var timeouts: [TimeInterval] = []
    var delay: UInt64
    init(_ results: [Result<[IFlicksVideo], IFlicksQueryFailure>], delay: UInt64 = 0) {
        self.results = results; self.delay = delay
    }
    func sample(process: IFlicksProcess, timeout: TimeInterval) async throws -> [IFlicksVideo] {
        calls += 1; active += 1; maxActive = max(maxActive, active); timeouts.append(timeout)
        defer { active -= 1 }
        // Model a synchronous send: cancellation cannot make it finish early.
        if delay > 0 {
            await withCheckedContinuation { continuation in
                DispatchQueue.global().asyncAfter(deadline: .now() + Double(delay) / 1_000_000_000) { continuation.resume() }
            }
        }
        return try (results.count > 1 ? results.removeFirst() : results[0]).get()
    }
}
final class CaptureTests: XCTestCase {
    private func video(_ id: String = "a", _ state: String = "working", _ path: String = "/input.mp4") -> IFlicksVideo {
        IFlicksVideo(id: id, status: state, statusCode: state == "completed" ? "kCpl" : "kWrk", progress: state == "completed" ? 100 : 20, filePath: path)
    }
    private func sampler(_ fake: FakeTransport, _ harness: Harness) -> IFlicksSampler {
        IFlicksSampler(transport: fake, provider: { await harness.current() },
            sink: { await harness.record($0) }, update: { await harness.update($0) })
    }
    private func waitForCall(_ fake: FakeTransport) async throws {
        for _ in 0..<100 {
            if await fake.calls > 0 { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Sampler did not query")
    }
    func testInventoryChangesMultipleVideosRemovalAndRetainedExit() async {
        let harness = Harness()
        let fake = FakeTransport([.success([video(), video("b")]),
            .success([video("a", "completed", "/output.mp4"), video("b")]), .success([video("b")])])
        let sampler = sampler(fake, harness)
        await sampler.tick(); await sampler.tick(); await sampler.tick()
        await harness.setProcess(nil); await sampler.tick()
        let events = await harness.events
        XCTAssertEqual(events.map(\.event), ["iflicks_app_started", "iflicks_snapshot", "iflicks_snapshot", "iflicks_queue_removed", "iflicks_snapshot", "iflicks_app_exited"])
        XCTAssertEqual(events[1].reason, "initial_inventory")
        XCTAssertEqual(events[2].videos?.first?.filePath, "/output.mp4")
        XCTAssertEqual(events[3].removedVideoIds, ["a"])
        let status = await harness.status
        XCTAssertEqual(status.videos.map(\.id), ["b"])
        XCTAssertNotNil(status.lastSuccessfulSampleUnixMs)
        XCTAssertFalse(events.contains { $0.event.contains("completed") })
    }
    func testPermissionDenialPausesQueriesButRestartRecovers() async {
        let harness = Harness()
        let fake = FakeTransport([.failure(IFlicksQueryFailure(-1743, "Denied")), .success([video()])])
        let sampler = sampler(fake, harness)
        await sampler.tick(); await sampler.tick()
        var count = await fake.calls
        XCTAssertEqual(count, 1)
        let status = await harness.status
        XCTAssertTrue(status.message.contains("unavailable"))
        await harness.setProcess(IFlicksProcess(pid: 102, launchUnixMs: 2))
        await sampler.tick()
        count = await fake.calls
        XCTAssertEqual(count, 2)
        let events = await harness.events
        XCTAssertEqual(events.filter { $0.event == "iflicks_app_started" }.count, 2)
        XCTAssertEqual(events.first { $0.event == "iflicks_query_error" }?.errorCode, -1743)
    }
    func testTimeoutRecordsGapAndRetriesWithoutOverlap() async throws {
        let harness = Harness()
        let fake = FakeTransport([.failure(IFlicksQueryFailure(-1712, "One-second query timeout")), .success([video()])], delay: 300_000_000)
        let sampler = sampler(fake, harness)
        let first = Task { await sampler.tick() }
        try await waitForCall(fake)
        await sampler.tick() // Re-entrant requests cannot overlap.
        await first.value
        await sampler.tick()
        let events = await harness.events
        XCTAssertTrue(events.contains { $0.event == "iflicks_query_error" && $0.errorCode == -1712 })
        XCTAssertTrue(events.contains { $0.event == "iflicks_sampling_gap" && ($0.missedIntervals ?? 0) > 0 })
        let maxActive = await fake.maxActive
        let timeouts = await fake.timeouts
        XCTAssertEqual(maxActive, 1)
        XCTAssertEqual(timeouts, [1, 1])
    }
    func testExitDuringQueryDiscardsReplyAndRestartInventories() async throws {
        let harness = Harness()
        let fake = FakeTransport([.success([video()])], delay: 100_000_000)
        let sampler = sampler(fake, harness)
        let first = Task { await sampler.tick() }
        try await waitForCall(fake)
        await harness.setProcess(nil)
        await first.value
        let initial = await harness.events
        XCTAssertFalse(initial.contains { $0.event == "iflicks_snapshot" })
        XCTAssertTrue(initial.contains { $0.event == "iflicks_app_exited" })
        await harness.setProcess(IFlicksProcess(pid: 101, launchUnixMs: 3)) // PID reuse.
        await sampler.tick()
        let events = await harness.events
        XCTAssertEqual(events.last?.reason, "initial_inventory")
        XCTAssertEqual(events.last?.process?.launchUnixMs, 3)
    }
    func testStopWaitsForBoundedInFlightQueryAndEmissions() async throws {
        let harness = Harness()
        let fake = FakeTransport([.success([video()])], delay: 400_000_000)
        let sampler = sampler(fake, harness)
        await sampler.start()
        try await waitForCall(fake)
        let began = ProcessInfo.processInfo.systemUptime
        await sampler.stop()
        let duration = ProcessInfo.processInfo.systemUptime - began
        XCTAssertGreaterThan(duration, 0.25)
        XCTAssertLessThan(duration, 1.3)
        let events = await harness.events
        XCTAssertEqual(events.last?.event, "iflicks_capture_state")
        XCTAssertEqual(events.last?.state, "stopped")
        let count = await fake.calls
        try await Task.sleep(nanoseconds: 300_000_000)
        let later = await fake.calls
        XCTAssertEqual(count, later)
        XCTAssertTrue(events.contains { $0.event == "iflicks_snapshot" })
    }
    func testUnchangedSamplesAndAbsentProcessProduceNoInventedEvents() async {
        let harness = Harness()
        await harness.setProcess(nil)
        let fake = FakeTransport([.success([video()])])
        let sampler = sampler(fake, harness)
        await sampler.tick()
        let calls = await fake.calls
        XCTAssertEqual(calls, 0)
        await harness.setProcess(IFlicksProcess(pid: 101, launchUnixMs: 1))
        await sampler.tick(); await sampler.tick()
        let events = await harness.events
        XCTAssertEqual(events.filter { $0.event == "iflicks_snapshot" }.count, 1)
    }
    func testShortLivedWorkspaceLifecycleDrainsBeforeStop() async {
        let harness = Harness()
        await harness.setProcess(nil)
        let fake = FakeTransport([.success([])])
        let sampler = sampler(fake, harness)
        await sampler.start()
        let process = IFlicksProcess(pid: 999, launchUnixMs: 50)
        await sampler.processLaunched(process)
        await sampler.processExited(process)
        await sampler.stop()
        let kinds = await harness.kinds()
        XCTAssertTrue(kinds.contains("iflicks_app_started"))
        XCTAssertTrue(kinds.contains("iflicks_app_exited"))
        XCTAssertEqual(kinds.last, "iflicks_capture_state")
        let count = await fake.calls
        XCTAssertEqual(count, 0)
    }
    func testNativeRequestsAreReadOnlyAndAddressKernelPID() {
        for property in AppleEventTransport.properties {
            let event = AppleEventTransport.request(pid: 123456, property: property)
            XCTAssertEqual(event.eventClass, AEEventClass(kAECoreSuite))
            XCTAssertEqual(event.eventID, AEEventID(kAEGetData))
            XCTAssertEqual(event.attributeDescriptor(forKeyword: AEKeyword(keyAddressAttr))?.descriptorType, OSType(typeKernelProcessID))
            let object = event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))!
            XCTAssertEqual(object.descriptorType, OSType(typeObjectSpecifier))
            XCTAssertEqual(object.forKeyword(AEKeyword(keyAEKeyData))?.typeCodeValue, AppleEventTransport.code(property))
            let videos = object.forKeyword(AEKeyword(keyAEContainer))!
            XCTAssertEqual(videos.forKeyword(AEKeyword(keyAEKeyForm))?.enumCodeValue, OSType(formAbsolutePosition))
            // An absolute ordinal has descriptor type 'abso', not 'enum'.
            // Cocoa rejects the latter with errAECoercionFail (-1700).
            let ordinal = videos.forKeyword(AEKeyword(keyAEKeyData))!
            XCTAssertEqual(ordinal.descriptorType, OSType(typeAbsoluteOrdinal))
            XCTAssertEqual(ordinal.data, withUnsafeBytes(of: OSType(kAEAll)) { Data($0) })
        }
        XCTAssertEqual(AppleEventTransport.properties, ["ID  ", "pSts", "file", "pPrg"])
    }
    func testNativeQueryErrorsIdentifyPropertyAndPreserveCode() {
        let failure = AppleEventTransport.queryFailure(property: "pSts", code: -1700, detail: nil)
        XCTAssertEqual(failure.code, -1700)
        XCTAssertTrue(failure.message.contains("status [pSts]"))
        XCTAssertTrue(failure.message.contains("type conversion"))
        let timeout = AppleEventTransport.queryFailure(property: "ID  ", code: -1712, detail: "One-second query timeout")
        XCTAssertTrue(timeout.message.contains("id [ID  ]"))
        XCTAssertTrue(timeout.message.contains("One-second query timeout"))
    }
    func testObservationEncodingMatchesTypedRustContract() throws {
        var event = IFlicksObservation(event: "iflicks_snapshot")
        event.process = IFlicksProcess(pid: 1, launchUnixMs: 2)
        event.sampleStartedUnixMs = 3; event.sampleFinishedUnixMs = 4
        event.videos = [video()]; event.removedVideoIds = ["b"]
        let encoder = JSONEncoder(); encoder.keyEncodingStrategy = .convertToSnakeCase
        let object = try JSONSerialization.jsonObject(with: encoder.encode(event)) as! [String: Any]
        XCTAssertNotNil(object["sample_started_unix_ms"])
        XCTAssertNotNil(object["removed_video_ids"])
        XCTAssertNil(object["sequence"])
    }
}
