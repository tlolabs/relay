import XCTest
import Foundation
@testable import RelayKit

private final class ImportCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<Int, Error>?
    func set(_ value: Task<Int, Error>) { lock.lock(); task = value; lock.unlock() }
    func cancel() { lock.lock(); task?.cancel(); lock.unlock() }
}
final class IMDbIndexTests: XCTestCase {
    private let basicsHeader = "tconst\ttitleType\tprimaryTitle\toriginalTitle\tisAdult\tstartYear\tendYear\truntimeMinutes\tgenres\n"
    private let episodesHeader = "tconst\tparentTconst\tseasonNumber\tepisodeNumber\n"
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true); return url
    }
    private func sources(_ folder: URL) throws -> (URL, URL) {
        let basics = folder.appendingPathComponent("title.basics.tsv"), episodes = folder.appendingPathComponent("title.episode.tsv")
        try (basicsHeader + "tt1\ttvSeries\tCrowd Control\tCrowd Control\t0\t2025\t\\N\t30\tComedy\n" +
             "tt2\ttvEpisode\tA Witch Hunt\tA Witch Hunt\t0\t2026\t\\N\t30\tComedy\n" +
             "tt3\ttvEpisode\tLocalized Title\tEverybody Pregnant\t0\t2026\t\\N\t30\tComedy\n" +
             "tt4\tmovie\tA Movie\tA Movie\t0\t2020\t\\N\t90\tDrama\n").write(to: basics, atomically: true, encoding: .utf8)
        try (episodesHeader + "tt2\ttt1\t2\t4\ntt3\ttt1\t2\t\\N\n").write(to: episodes, atomically: true, encoding: .utf8)
        return (basics, episodes)
    }
    func testStreamedGzipImportFindsParentSeriesMoviesAndUnknownEpisodeNumbers() async throws {
        let folder = try folder(); defer { try? FileManager.default.removeItem(at: folder) }
        let (basics, episodes) = try sources(folder), index = folder.appendingPathComponent("imdb.sqlite")
        let gzip = Process(); gzip.executableURL = URL(fileURLWithPath: "/usr/bin/gzip"); gzip.arguments = ["-k", basics.path]
        try gzip.run(); gzip.waitUntilExit(); XCTAssertEqual(gzip.terminationStatus, 0)
        let store = IMDbIndex()
        let rows = try await store.importFiles(basics: basics.appendingPathExtension("gz"), episodes: episodes, destination: index)
        XCTAssertEqual(rows, 6)
        let tv = try await store.search(titles: ["A Witch Hunt", "Everybody Pregnant"], kind: "tv", index: index)
        XCTAssertEqual(tv.evidence.count, 2); XCTAssertEqual(Set(tv.evidence.map(\.title)), ["Crowd Control"])
        XCTAssertEqual(tv.evidence.first { $0.episode?.title == "A Witch Hunt" }?.episode?.number, 4)
        XCTAssertNil(tv.evidence.first { $0.episode?.title == "Localized Title" }?.episode?.number)
        XCTAssertEqual(Set(tv.evidence.compactMap(\.ids.imdb)), ["tt1"])
        let movies = try await store.search(titles: ["A Movie"], kind: "movie", index: index)
        XCTAssertEqual(movies.evidence.first?.year, 2020); XCTAssertEqual(movies.evidence.first?.ids.imdb, "tt4")
    }
    func testMalformedReimportPreservesPreviousCompleteIndex() async throws {
        let folder = try folder(); defer { try? FileManager.default.removeItem(at: folder) }
        let (basics, episodes) = try sources(folder), index = folder.appendingPathComponent("imdb.sqlite"), store = IMDbIndex()
        _ = try await store.importFiles(basics: basics, episodes: episodes, destination: index)
        let before = try Data(contentsOf: index)
        try "wrong\theader\n".write(to: episodes, atomically: true, encoding: .utf8)
        do { _ = try await store.importFiles(basics: basics, episodes: episodes, destination: index); XCTFail("Malformed dataset must fail") } catch {}
        XCTAssertEqual(try Data(contentsOf: index), before)
        let result = try await store.search(titles: ["A Witch Hunt"], kind: "tv", index: index)
        XCTAssertEqual(result.evidence.count, 1)
    }
    func testCancellationAfterPartialImportPreservesPreviousIndex() async throws {
        let folder = try folder(); defer { try? FileManager.default.removeItem(at: folder) }
        let (basics, episodes) = try sources(folder), index = folder.appendingPathComponent("imdb.sqlite"), store = IMDbIndex()
        _ = try await store.importFiles(basics: basics, episodes: episodes, destination: index)
        let before = try Data(contentsOf: index)
        let many = basicsHeader + (0..<25_000).map { "tt\($0 + 100)\tmovie\tMovie \($0)\tMovie \($0)\t0\t2020\t\\N\t90\tDrama\n" }.joined()
        try many.write(to: basics, atomically: true, encoding: .utf8)
        let cancellation = ImportCancellation()
        let task = Task { try await store.importFiles(basics: basics, episodes: episodes, destination: index) { count in if count >= 10_000 { cancellation.cancel() } } }
        cancellation.set(task)
        do { _ = try await task.value; XCTFail("Import should cancel") } catch is CancellationError {} catch { XCTFail("Expected cancellation, got \(error)") }
        XCTAssertEqual(try Data(contentsOf: index), before)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: folder.path).contains { $0.hasPrefix("imdb-import-") })
    }
}
