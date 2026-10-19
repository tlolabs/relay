import XCTest
import Foundation
import Darwin
@testable import RelayKit

final class MediaProcessConcurrencyTests: XCTestCase {
    private let shell = URL(fileURLWithPath: "/bin/sh")

    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("RELAY-process-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func arguments(_ root: URL, name: String, trap: String = "") -> [String] {
        ["-c", """
        \(trap)
        printf '%s' "$$" > "$1"
        while [ ! -e "$2" ]; do /bin/sleep 0.02; done
        printf '%s' "$3"
        """, "relay-process-fixture", root.appendingPathComponent("\(name).pid").path,
         root.appendingPathComponent("\(name).release").path, name]
    }

    private func waitUntilStarted(_ root: URL, name: String) async throws -> pid_t {
        let marker = root.appendingPathComponent("\(name).pid")
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if let value = try? String(contentsOf: marker), let pid = pid_t(value) { return pid }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw RelayFailure.message("Disposable \(name) process did not start")
    }

    private func release(_ root: URL, name: String) throws {
        try Data().write(to: root.appendingPathComponent("\(name).release"))
    }

    private func assertCancelled(_ task: Task<Data, Error>, file: StaticString = #filePath, line: UInt = #line) async {
        do { _ = try await task.value; XCTFail("Operation should be cancelled", file: file, line: line) }
        catch is CancellationError {}
        catch { XCTFail("Expected CancellationError, received \(error)", file: file, line: line) }
    }

    private func checkOverlap(completing name: String) async throws {
        let root = try fixture(), processor = DirectProcessor()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = Task { try await processor.run(shell, arguments(root, name: "first"), timeout: 5) }
        let second = Task { try await processor.run(shell, arguments(root, name: "second"), timeout: 5) }
        defer { first.cancel(); second.cancel() }
        let firstPID = try await waitUntilStarted(root, name: "first")
        let secondPID = try await waitUntilStarted(root, name: "second")
        try release(root, name: name)
        let completed = name == "first" ? first : second
        let remaining = name == "first" ? second : first
        let remainingPID = name == "first" ? secondPID : firstPID
        let output = try await completed.value
        XCTAssertEqual(String(decoding: output, as: UTF8.self), name)
        XCTAssertEqual(kill(remainingPID, 0), 0, "Other operation must remain running")
        await processor.cancel()
        await assertCancelled(remaining)
        XCTAssertNotEqual(kill(remainingPID, 0), 0, "Explicit cancellation must still own the remaining child")
    }

    func testFirstCompletionDoesNotClearAnotherOperation() async throws { try await checkOverlap(completing: "first") }
    func testSecondCompletionDoesNotClearAnotherOperation() async throws { try await checkOverlap(completing: "second") }

    func testTaskCancellationOnlyStopsItsOwnOperation() async throws {
        let root = try fixture(), processor = DirectProcessor()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = Task { try await processor.run(shell, arguments(root, name: "cancelled"), timeout: 5) }
        let second = Task { try await processor.run(shell, arguments(root, name: "kept"), timeout: 5) }
        defer { first.cancel(); second.cancel() }
        let firstPID = try await waitUntilStarted(root, name: "cancelled")
        let secondPID = try await waitUntilStarted(root, name: "kept")
        first.cancel()
        await assertCancelled(first)
        XCTAssertNotEqual(kill(firstPID, 0), 0)
        XCTAssertEqual(kill(secondPID, 0), 0, "Task cancellation must not terminate another call")
        try release(root, name: "kept")
        let output = try await second.value
        XCTAssertEqual(String(decoding: output, as: UTF8.self), "kept")
    }

    func testExplicitCancellationStopsAllCallsAndRemainsLatchedUntilReset() async throws {
        let root = try fixture(), processor = DirectProcessor()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = Task { try await processor.run(shell, arguments(root, name: "first"), timeout: 5) }
        let second = Task { try await processor.run(shell, arguments(root, name: "second"), timeout: 5) }
        defer { first.cancel(); second.cancel() }
        _ = try await waitUntilStarted(root, name: "first")
        _ = try await waitUntilStarted(root, name: "second")
        await processor.cancel()
        await assertCancelled(first)
        await assertCancelled(second)
        let blocked = Task { try await processor.run(shell, arguments(root, name: "blocked")) }
        await assertCancelled(blocked)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("blocked.pid").path))
        await processor.resetCancellation()
        let output = try await processor.run(shell, ["-c", "printf reset"])
        XCTAssertEqual(String(decoding: output, as: UTF8.self), "reset")
    }

    func testAlreadyCancelledTaskDoesNotLaunch() async throws {
        let root = try fixture(), processor = DirectProcessor()
        defer { try? FileManager.default.removeItem(at: root) }
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await processor.run(shell, arguments(root, name: "never"))
        }
        await assertCancelled(task)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("never.pid").path))
    }

    func testLaunchFailureDoesNotPreventLaterRun() async throws {
        let root = try fixture(), processor = DirectProcessor()
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            _ = try await processor.run(root.appendingPathComponent("missing-tool"), [], timeout: 1)
            XCTFail("Missing executable should fail")
        } catch { XCTAssertFalse(error is CancellationError) }
        let output = try await processor.run(shell, ["-c", "printf recovered"])
        XCTAssertEqual(String(decoding: output, as: UTF8.self), "recovered")
    }

    func testTimeoutCannotReportSuccessWhenTerminationHandlerExitsZero() async throws {
        let root = try fixture(), processor = DirectProcessor()
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            _ = try await processor.run(shell, arguments(root, name: "timeout", trap: "trap 'exit 0' TERM"), timeout: 0.2)
            XCTFail("Timed-out command must fail even if it exits zero after SIGTERM")
        } catch { XCTAssertTrue(error.localizedDescription.contains("timed out"), "\(error)") }
        let pid = try XCTUnwrap(pid_t(String(contentsOf: root.appendingPathComponent("timeout.pid"))))
        XCTAssertNotEqual(kill(pid, 0), 0)
    }

    func testTimeoutEscalatesWhenProcessIgnoresTermination() async throws {
        let root = try fixture(), processor = DirectProcessor()
        defer { try? FileManager.default.removeItem(at: root) }
        let started = Date()
        do {
            _ = try await processor.run(shell, arguments(root, name: "stubborn", trap: "trap '' TERM"), timeout: 0.2)
            XCTFail("Ignoring SIGTERM must not defeat timeout")
        } catch { XCTAssertTrue(error.localizedDescription.contains("timed out"), "\(error)") }
        XCTAssertLessThan(Date().timeIntervalSince(started), 4)
        let pid = try XCTUnwrap(pid_t(String(contentsOf: root.appendingPathComponent("stubborn.pid"))))
        XCTAssertNotEqual(kill(pid, 0), 0)
    }

    func testLargeStandardOutputAndErrorAreDrainedTogether() async throws {
        let processor = DirectProcessor()
        let output = try await processor.run(shell, ["-c", "i=0; while [ \"$i\" -lt 20000 ]; do printf 12345678; printf abcdefgh >&2; i=$((i + 1)); done"], timeout: 5)
        XCTAssertEqual(output.count, 160_000)
    }
}
