import Foundation
import SQLite3
import Darwin

/// Optional, local-only index of IMDb's non-commercial title.basics and
/// title.episode datasets. Import is streamed into a temporary SQLite file;
/// cancellation or malformed input leaves the previous complete index intact.
public actor IMDbIndex {
    public init() {}
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    public func importFiles(basics: URL, episodes: URL, destination: URL, progress: @Sendable (Int) -> Void = { _ in }) async throws -> Int {
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let temporary = destination.deletingLastPathComponent().appendingPathComponent("imdb-import-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: temporary) }
        var db: OpaquePointer?
        guard sqlite3_open(temporary.path, &db) == SQLITE_OK, let db else { throw RelayFailure.message("Cannot create the IMDb index") }
        defer { sqlite3_close(db) }
        sqlite3_progress_handler(db, 10_000, { _ in Task.isCancelled ? 1 : 0 }, nil)
        try execute(db, "PRAGMA journal_mode=DELETE; PRAGMA synchronous=NORMAL; CREATE TABLE titles(id TEXT PRIMARY KEY,name TEXT NOT NULL,normalized TEXT NOT NULL,original_normalized TEXT NOT NULL,year INTEGER,kind TEXT NOT NULL); CREATE TABLE episodes(id TEXT PRIMARY KEY,parent TEXT NOT NULL,season INTEGER,number INTEGER); BEGIN;")
        var titleStatement: OpaquePointer?, episodeStatement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "INSERT INTO titles VALUES(?,?,?,?,?,?)", -1, &titleStatement, nil) == SQLITE_OK,
              sqlite3_prepare_v2(db, "INSERT INTO episodes VALUES(?,?,?,?)", -1, &episodeStatement, nil) == SQLITE_OK else { throw RelayFailure.message("Cannot prepare the IMDb index") }
        defer { sqlite3_finalize(titleStatement); sqlite3_finalize(episodeStatement) }
        var count = 0, episodeCount = 0
        let accepted = Set(["movie", "tvMovie", "tvSeries", "tvMiniSeries", "tvEpisode"])
        try await stream(basics, header: ["tconst", "titleType", "primaryTitle", "originalTitle", "isAdult", "startYear", "endYear", "runtimeMinutes", "genres"]) { fields in
            guard fields.count == 9 else { throw RelayFailure.message("Malformed IMDb title row") }
            guard accepted.contains(fields[1]) else { return }
            sqlite3_reset(titleStatement); sqlite3_clear_bindings(titleStatement)
            bind(titleStatement, 1, fields[0]); bind(titleStatement, 2, fields[2])
            bind(titleStatement, 3, EpisodeClues.normalized(fields[2])); bind(titleStatement, 4, EpisodeClues.normalized(fields[3]))
            if let year = Int32(fields[5]) { sqlite3_bind_int(titleStatement, 5, year) }
            bind(titleStatement, 6, fields[1])
            guard sqlite3_step(titleStatement) == SQLITE_DONE else { try Task.checkCancellation(); throw RelayFailure.message("Cannot insert an IMDb title row") }
            count += 1
            if count % 10_000 == 0 { progress(count) }
        }
        try await stream(episodes, header: ["tconst", "parentTconst", "seasonNumber", "episodeNumber"]) { fields in
            guard fields.count == 4 else { throw RelayFailure.message("Malformed IMDb episode row") }
            sqlite3_reset(episodeStatement); sqlite3_clear_bindings(episodeStatement)
            bind(episodeStatement, 1, fields[0]); bind(episodeStatement, 2, fields[1])
            if let season = Int32(fields[2]) { sqlite3_bind_int(episodeStatement, 3, season) }
            if let number = Int32(fields[3]) { sqlite3_bind_int(episodeStatement, 4, number) }
            guard sqlite3_step(episodeStatement) == SQLITE_DONE else { try Task.checkCancellation(); throw RelayFailure.message("Cannot insert an IMDb episode row") }
            episodeCount += 1
            if episodeCount % 10_000 == 0 { progress(count + episodeCount) }
        }
        guard count > 0, episodeCount > 0 else { throw RelayFailure.message("Both IMDb datasets must contain records") }
        try Task.checkCancellation()
        try execute(db, "COMMIT; CREATE INDEX titles_name ON titles(normalized,kind); CREATE INDEX titles_original ON titles(original_normalized,kind); ANALYZE;")
        try Task.checkCancellation()
        guard rename(temporary.path, destination.path) == 0 else { throw RelayFailure.message("Cannot publish the completed IMDb index") }
        progress(count + episodeCount)
        return count + episodeCount
    }
    public func search(titles: [String], kind: String, index: URL, activity: @escaping DiscoveryActivityHandler = { _ in }) async throws -> DiscoveryReport {
        guard FileManager.default.fileExists(atPath: index.path) else {
            return DiscoveryReport(statuses: [ProviderStatus(source: .imdb, message: "Import the free datasets in Settings to enable local search", incomplete: false)])
        }
        var db: OpaquePointer?
        guard sqlite3_open_v2(index.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else { throw RelayFailure.message("Cannot open the local IMDb index") }
        defer { sqlite3_close(db) }
        let sql = kind == "movie" ?
            "SELECT t.id,t.name,t.year,NULL,NULL,NULL,NULL FROM titles t WHERE (t.normalized=? OR t.original_normalized=?) AND t.kind IN ('movie','tvMovie') LIMIT 1001" :
            "SELECT p.id,p.name,p.year,t.id,t.name,e.season,e.number FROM titles t JOIN episodes e ON e.id=t.id JOIN titles p ON p.id=e.parent WHERE (t.normalized=? OR t.original_normalized=?) AND t.kind='tvEpisode' LIMIT 1001"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { throw RelayFailure.message("The IMDb index needs to be rebuilt") }
        defer { sqlite3_finalize(statement) }
        var result: [DiscoveryEvidence] = [], limited = false
        func text(_ column: Int32) -> String { sqlite3_column_text(statement, column).map { String(cString: $0) } ?? "" }
        func number(_ column: Int32) -> Int? { sqlite3_column_type(statement, column) == SQLITE_NULL ? nil : Int(sqlite3_column_int(statement, column)) }
        for title in EpisodeClues.unique(titles) {
            try Task.checkCancellation()
            await activity(.init(source: "IMDb", clues: [title], detail: "Searching local index"))
            sqlite3_reset(statement); sqlite3_clear_bindings(statement)
            let normalized = EpisodeClues.normalized(title)
            bind(statement, 1, normalized); bind(statement, 2, normalized)
            var rows = 0, status = sqlite3_step(statement)
            while status == SQLITE_ROW {
                rows += 1
                if rows > 1000 { limited = true; break }
                let showID = text(0)
                let episode = kind == "movie" ? nil : DiscoveredEpisode(title: text(4), season: number(5), number: number(6))
                result.append(DiscoveryEvidence(source: .imdb, recordID: kind == "movie" ? showID : text(3), kind: kind, title: text(1), year: number(2), ids: DiscoveryIDs(imdb: showID), episode: episode, matchedClue: title))
                status = sqlite3_step(statement)
            }
            guard status == SQLITE_DONE || limited && status == SQLITE_ROW else { throw RelayFailure.message("Could not query the IMDb index") }
        }
        await activity(.init(source: "IMDb", clues: titles, finished: true))
        return DiscoveryReport(evidence: Array(Set(result)), statuses: [ProviderStatus(source: .imdb, message: limited ? "Some common-title results were omitted; refine the title" : "\(Set(result).count) matching local records", incomplete: limited)])
    }
    private func bind(_ statement: OpaquePointer?, _ index: Int32, _ text: String) { _ = text.withCString { sqlite3_bind_text(statement, index, $0, -1, transient) } }
    private func execute(_ db: OpaquePointer, _ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { try Task.checkCancellation(); throw RelayFailure.message("IMDb index operation failed; the previous index is unchanged") }
    }
    private func stream(_ url: URL, header: [String], consume: ([String]) throws -> Void) async throws {
        let file: FileHandle, process: Process?
        if url.pathExtension.lowercased() == "gz" {
            let task = Process(), output = Pipe()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/gzip"); task.arguments = ["-dc", url.path]
            task.standardOutput = output; task.standardError = FileHandle.nullDevice
            try task.run(); file = output.fileHandleForReading; process = task
        } else { file = try FileHandle(forReadingFrom: url); process = nil }
        defer { try? file.close(); if process?.isRunning == true { process?.terminate() }; process?.waitUntilExit() }
        var buffer = Data(), first = true, lines = 0
        func line(_ data: Data.SubSequence) throws {
            guard let string = String(data: data, encoding: .utf8) else { throw RelayFailure.message("IMDb datasets must be UTF-8 TSV files") }
            let fields = string.trimmingCharacters(in: .newlines).split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            if first { guard fields == header else { throw RelayFailure.message("Select IMDb's title.basics.tsv and title.episode.tsv datasets") }; first = false }
            else { try consume(fields) }
        }
        while true {
            try Task.checkCancellation()
            let chunk = try file.read(upToCount: 65536) ?? Data()
            if chunk.isEmpty { break }
            buffer.append(chunk)
            var cursor = buffer.startIndex
            while let newline = buffer[cursor...].firstIndex(of: 10) {
                try line(buffer[cursor..<newline]); cursor = newline + 1; lines += 1
            }
            buffer.removeSubrange(buffer.startIndex..<cursor)
            guard buffer.count < 16 * 1024 * 1024 else { throw RelayFailure.message("IMDb dataset contains an oversized row") }
            if lines >= 10_000 { lines = 0; await Task.yield() }
        }
        if !buffer.isEmpty { try line(buffer[...]) }
        if let process { process.waitUntilExit(); guard process.terminationStatus == 0 else { throw RelayFailure.message("IMDb gzip dataset is incomplete or damaged") } }
        guard !first else { throw RelayFailure.message("IMDb dataset is empty") }
    }
}
