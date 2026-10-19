import AppKit
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import Relay

final class PosterDataCacheTests: XCTestCase {
    func testReadsUpdateRecencyAndBothLimitsAreEnforced() {
        var cache = PosterDataCache(byteLimit: 8, entryLimit: 3)
        cache.insert(Data(repeating: 1, count: 3), for: "a")
        cache.insert(Data(repeating: 2, count: 3), for: "b")
        XCTAssertEqual(cache.data(for: "a"), Data(repeating: 1, count: 3))
        cache.insert(Data(repeating: 3, count: 3), for: "c")
        XCTAssertNil(cache.data(for: "b"), "The least recently read value is evicted for bytes")
        XCTAssertEqual(cache.byteCount, 6)
        cache.insert(Data(), for: "d")
        cache.insert(Data(), for: "e")
        XCTAssertNil(cache.data(for: "a"), "Zero-cost entries still obey the entry limit")
        XCTAssertEqual(cache.count, 3)
        XCTAssertEqual(cache.byteCount, 3)
    }

    func testReplacementOversizedValueAndClearAccountForEveryByte() {
        var cache = PosterDataCache(byteLimit: 6, entryLimit: 3)
        cache.insert(Data(repeating: 1, count: 4), for: "a")
        cache.insert(Data(repeating: 2, count: 2), for: "b")
        cache.insert(Data(repeating: 3, count: 1), for: "a")
        XCTAssertEqual(cache.count, 2)
        XCTAssertEqual(cache.byteCount, 3)
        cache.insert(Data(repeating: 4, count: 5), for: "a")
        XCTAssertNil(cache.data(for: "b"))
        XCTAssertEqual(cache.byteCount, 5)
        cache.insert(Data(repeating: 5, count: 7), for: "a")
        XCTAssertNil(cache.data(for: "a"), "An oversized replacement cannot retain obsolete bytes")
        XCTAssertEqual(cache.byteCount, 0)
        cache.insert(Data(repeating: 6, count: 7), for: "oversized")
        XCTAssertEqual(cache.count, 0)
        cache.insert(Data(repeating: 7, count: 6), for: "exact-budget")
        XCTAssertEqual(cache.byteCount, 6)
        cache.removeAll()
        XCTAssertEqual(cache.count, 0)
        XCTAssertEqual(cache.byteCount, 0)
        cache.insert(Data(repeating: 8, count: 6), for: "after-clear")
        XCTAssertNotNil(cache.data(for: "after-clear"))
    }
}

@MainActor final class CatalogArtworkTests: XCTestCase {
    private let firstURL = "https://image.tmdb.org/t/p/w185/first.jpg"
    private let secondURL = "https://image.tmdb.org/t/p/w185/second.jpg"

    func testSupersededDownloadCannotReplaceCurrentImage() async throws {
        let state = CatalogArtworkState(), download = ArtworkGate<Data>()
        let bitmap = try makeBitmap()
        let old = Task {
            await state.load(firstURL, fetch: { _ in try await download.wait() }, decode: { _ in bitmap })
        }
        await download.waitUntilStarted()
        await state.load(secondURL, fetch: { _ in Data([2]) }, decode: { _ in bitmap })
        let current = try XCTUnwrap(state.image)
        download.finish(.success(Data([1])))
        await old.value
        XCTAssertEqual(state.requestedURL, secondURL)
        XCTAssertTrue(state.image === current)
    }

    func testSupersededDecoderCannotPublishOrClearCurrentImage() async throws {
        let bitmap = try makeBitmap()
        for result: Result<CGImage, Error> in [.success(bitmap), .failure(FixtureFailure.failed)] {
            let state = CatalogArtworkState(), decoding = ArtworkGate<CGImage>()
            let old = Task {
                await state.load(firstURL, fetch: { _ in Data([1]) }, decode: { _ in try await decoding.wait() })
            }
            await decoding.waitUntilStarted()
            await state.load(secondURL, fetch: { _ in Data([2]) }, decode: { _ in bitmap })
            let current = try XCTUnwrap(state.image)
            decoding.finish(result)
            await old.value
            XCTAssertTrue(state.image === current, "Old decode success/failure cannot change new artwork")
        }
    }

    func testNewRequestClearsPreviousImageBeforeAwaitAndCancelledDownloadStaysEmpty() async throws {
        let state = CatalogArtworkState(), download = ArtworkGate<Data>()
        let bitmap = try makeBitmap()
        await state.load(firstURL, fetch: { _ in Data([1]) }, decode: { _ in bitmap })
        XCTAssertNotNil(state.image)
        var decodedCancelledRequest = false
        let pending = Task {
            await state.load(secondURL, fetch: { _ in try await download.wait() }, decode: { _ in
                decodedCancelledRequest = true
                return bitmap
            })
        }
        await download.waitUntilStarted()
        XCTAssertNil(state.image)
        pending.cancel()
        download.finish(.success(Data([2]))) // Transport deliberately ignores cancellation.
        await pending.value
        XCTAssertNil(state.image)
        XCTAssertFalse(decodedCancelledRequest)
    }

    func testNilInvalidFailedAndUndecodableURLsClearPreviousArtwork() async throws {
        let state = CatalogArtworkState()
        let bitmap = try makeBitmap()
        for text in [nil, "not a URL", secondURL] as [String?] {
            await state.load(firstURL, fetch: { _ in Data([1]) }, decode: { _ in bitmap })
            XCTAssertNotNil(state.image)
            await state.load(text, fetch: { _ in
                XCTAssertEqual(text, self.secondURL, "Nil/invalid URLs must not start a request")
                throw FixtureFailure.failed
            })
            XCTAssertNil(state.image)
        }
        await state.load(firstURL, fetch: { _ in Data([1]) }, decode: { _ in bitmap })
        await state.load(secondURL, fetch: { _ in Data("invalid image".utf8) })
        XCTAssertNil(state.image)
    }

    func testRealDecoderBoundsLargeBitmapDimensions() async throws {
        let bitmap = try makeBitmap(width: 2048, height: 1024)
        let encoded = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(encoded, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, bitmap, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let thumbnail = try await ArtworkThumbnail.decode(encoded as Data, maxPixelSize: 256)
        XCTAssertEqual(thumbnail.width, 256)
        XCTAssertEqual(thumbnail.height, 128)
    }

    private func makeBitmap(width: Int = 2, height: Int = 3) throws -> CGImage {
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try XCTUnwrap(context.makeImage())
    }

    private enum FixtureFailure: Error { case failed }
}

/// A deterministic suspension point; no network, sleeps, or image files.
@MainActor private final class ArtworkGate<Value> {
    private var pending: CheckedContinuation<Value, Error>?
    private var started: [CheckedContinuation<Void, Never>] = []

    func wait() async throws -> Value {
        try await withCheckedThrowingContinuation { continuation in
            pending = continuation
            started.forEach { $0.resume() }
            started.removeAll()
        }
    }

    func waitUntilStarted() async {
        if pending != nil { return }
        await withCheckedContinuation { started.append($0) }
    }

    func finish(_ result: Result<Value, Error>) {
        pending?.resume(with: result)
        pending = nil
    }
}
