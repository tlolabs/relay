import AppKit
import Observation
import UniformTypeIdentifiers
import XCTest
import RelayKit
@testable import Relay

@MainActor final class FileImportTests: XCTestCase {
    private func fixture() throws -> (URL, RelayModel, RelayEngine) {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let model = RelayModel(); model.smokeMode = true
        model.databaseURL = root.appendingPathComponent("state/jobs.sqlite")
        let engine = try RelayEngine(database: model.databaseURL!)
        return (root, model, engine)
    }

    private func video(_ name: String, in root: URL) throws -> URL {
        let url = root.appendingPathComponent(name)
        try Data("fixture".utf8).write(to: url)
        return url
    }

    private func imageData(_ type: NSBitmapImageRep.FileType = .png) throws -> Data {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let pixels = try XCTUnwrap(bitmap.bitmapData)
        for y in 0..<2 { for x in 0..<2 {
            let offset = y * bitmap.bytesPerRow + x * 4
            pixels[offset] = 255; pixels[offset + 1] = 0; pixels[offset + 2] = 0; pixels[offset + 3] = 255
        } }
        return try XCTUnwrap(bitmap.representation(using: type, properties: [:]))
    }

    func testVideoValidationAcceptsSupportedFilesAndRejectsOtherInputs() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for ext in VideoImport.extensions {
            XCTAssertTrue(VideoImport.accepts(try video("A.\(ext.uppercased())", in: root)))
        }
        XCTAssertFalse(VideoImport.accepts(try video("poster.png", in: root)))
        XCTAssertFalse(VideoImport.accepts(root.appendingPathComponent("missing.mp4")))
        XCTAssertFalse(VideoImport.accepts(URL(string: "https://example.com/video.mp4")!))
        let directory = root.appendingPathComponent("folder.mp4")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        XCTAssertFalse(VideoImport.accepts(directory))
        let link = root.appendingPathComponent("link.mp4")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: root.appendingPathComponent("A.MP4"))
        XCTAssertFalse(VideoImport.accepts(link))
    }

    func testStartupAndBusyImportsAreBufferedAndDeduplicated() async throws {
        let (root, model, engine) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try video("First.mp4", in: root), second = try video("Second.mkv", in: root)
        XCTAssertTrue(model.enqueueVideos([first, first]))
        XCTAssertNil(model.videoImportTask, "A launch-time open must wait for the job store")
        XCTAssertEqual(model.pendingVideoURLs, [first])
        model.engine = engine; model.busy = true
        model.startPendingVideoImports()
        await Task.yield()
        XCTAssertTrue(model.enqueueVideos([second]))
        XCTAssertTrue(model.jobs.isEmpty)
        model.busy = false
        await model.videoImportTask?.value
        XCTAssertNil(model.error)
        XCTAssertEqual(Set(model.jobs.map(\.filename)), ["First.mp4", "Second.mkv"])
        XCTAssertTrue(model.pendingVideoURLs.isEmpty)
        XCTAssertTrue(model.enqueueVideos([first, second]))
        await model.videoImportTask?.value
        XCTAssertEqual(model.jobs.count, 2)
        await engine.close()
    }

    func testOneFailedImportDoesNotDiscardTheRemainingVideosOrCurrentDraft() async throws {
        let (root, model, engine) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        model.engine = engine
        let first = try video("First.mp4", in: root)
        model.enqueueVideos([first]); await model.videoImportTask?.value
        model.selectedIds = Set(model.jobs.map(\.id)); model.loadDraft()
        let editing = model.editingId
        model.draft.title = "Unsaved title"
        let failed = try video("Disappeared.mov", in: root), last = try video("Last.webm", in: root)
        model.busy = true
        model.enqueueVideos([failed, last])
        try FileManager.default.removeItem(at: failed)
        model.busy = false
        await model.videoImportTask?.value
        XCTAssertEqual(model.jobs.count, 2)
        XCTAssertTrue(model.error?.contains("Disappeared.mov") == true)
        XCTAssertEqual(model.selectedJob?.id, editing)
        XCTAssertEqual(model.draft.title, "Unsaved title")
        XCTAssertTrue(model.hasUnsavedChanges)
        await engine.close()
    }

    func testLocalArtworkIsCachedAndSavedAcrossSelectedVideos() async throws {
        let (root, model, engine) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        model.engine = engine
        model.enqueueVideos([try video("First.mp4", in: root), try video("Second.mp4", in: root)])
        await model.videoImportTask?.value
        model.selectedIds = Set(model.jobs.map(\.id)); model.loadDraft()
        model.draftDirect.artworkUrl = "https://example.com/old.jpg"
        let request = model.artworkSelection
        let source = root.appendingPathComponent("poster.png"), data = try imageData()
        try data.write(to: source)
        XCTAssertTrue(model.importLocalArtwork(source))
        let stored = URL(fileURLWithPath: model.draftDirect.artworkPath)
        XCTAssertNotEqual(stored, source)
        XCTAssertNotEqual(model.artworkSelection, request)
        XCTAssertEqual(model.draftDirect.artworkUrl, "")
        XCTAssertTrue(model.draftDirect.overrides.contains("artwork"))
        try FileManager.default.removeItem(at: source)
        XCTAssertEqual(try Data(contentsOf: stored), data)
        await model.persistDraft()
        XCTAssertNil(model.error)
        XCTAssertTrue(model.jobs.allSatisfy { $0.options.artworkPath == stored.path && $0.options.overrides.contains("artwork") })
        XCTAssertFalse(model.hasUnsavedChanges)
        await engine.close()
    }

    func testImageDropConversionAndInvalidArtworkPreserveExistingArtwork() async throws {
        let (root, model, engine) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        model.engine = engine
        model.enqueueVideos([try video("First.mp4", in: root)]); await model.videoImportTask?.value
        model.selectedIds = Set(model.jobs.map(\.id)); model.loadDraft()
        XCTAssertTrue(try model.importArtworkData(imageData(.tiff)))
        let stored = model.draftDirect.artworkPath
        XCTAssertTrue(stored.hasSuffix(".png"))
        XCTAssertNotNil(NSImage(contentsOfFile: stored))
        XCTAssertThrowsError(try model.importArtworkData(Data("not an image".utf8)))
        XCTAssertEqual(model.draftDirect.artworkPath, stored)
        model.busy = true
        XCTAssertFalse(try model.importArtworkData(imageData()))
        model.busy = false; model.snapshot?.jobs[0].state = "complete"
        XCTAssertFalse(try model.importArtworkData(imageData()))
        await engine.close()
    }

    func testArtworkDropReadsFinderURLsAndImageProviders() async throws {
        let (root, model, engine) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        model.engine = engine
        model.enqueueVideos([try video("First.mp4", in: root)]); await model.videoImportTask?.value
        model.selectedIds = Set(model.jobs.map(\.id)); model.loadDraft()
        let source = root.appendingPathComponent("poster.png"), data = try imageData()
        try data.write(to: source)
        let fileProvider = NSItemProvider()
        fileProvider.registerDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier, visibility: .all) { completion in
            completion(source.dataRepresentation, nil); return nil
        }
        let imageProvider = NSItemProvider()
        imageProvider.registerDataRepresentation(forTypeIdentifier: UTType.png.identifier, visibility: .all) { completion in
            completion(data, nil); return nil
        }
        XCTAssertFalse(model.acceptArtworkDrop([fileProvider, imageProvider]))
        XCTAssertFalse(model.acceptArtworkDrop([NSItemProvider(object: "text" as NSString)]))
        for (index, provider) in [fileProvider, imageProvider].enumerated() {
            let applied = expectation(description: "Artwork provider \(index) loaded")
            withObservationTracking { _ = model.draftDirect.artworkPath } onChange: { applied.fulfill() }
            XCTAssertTrue(model.acceptArtworkDrop([provider]), "Editable: \(model.canImportArtwork); types: \(provider.registeredTypeIdentifiers)")
            await fulfillment(of: [applied], timeout: 3)
            XCTAssertNil(model.error)
            XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: model.draftDirect.artworkPath)), data)
        }
        await engine.close()
    }
}
