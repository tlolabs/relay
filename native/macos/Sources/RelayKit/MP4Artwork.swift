import Foundation
import Darwin

/// Disable only iTunes cover-art atoms. Keeping each atom's size and payload
/// preserves chunk offsets, media bytes, chapters, and all other metadata.
enum MP4Artwork {
    static func remove(path: String, expected: FileFingerprint? = nil, verify: () throws -> Void) throws -> Int {
        let fd = open(path, O_RDWR | O_NOFOLLOW)
        guard fd >= 0 else { throw RelayFailure.message("Cannot open the finished TV output to remove artwork") }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        var original = stat()
        guard fstat(fd, &original) == 0, original.st_mode & S_IFMT == S_IFREG,
              flock(fd, LOCK_EX | LOCK_NB) == 0 else { throw RelayFailure.message("The TV output is unavailable or in use") }
        defer { flock(fd, LOCK_UN) }
        if let expected, !OutputInspector.matches(original, expected) { throw RelayFailure.message("The TV output changed before artwork removal") }
        let size = UInt64(original.st_size)
        var offsets: [UInt64] = [], visited = 0
        func read(_ offset: UInt64, _ count: Int) throws -> Data {
            try handle.seek(toOffset: offset)
            let data = try handle.read(upToCount: count) ?? Data()
            guard data.count == count else { throw RelayFailure.message("Incomplete MP4 metadata; artwork was left in place") }
            return data
        }
        func integer(_ bytes: Data) -> UInt64 { bytes.reduce(0) { ($0 << 8) | UInt64($1) } }
        func walk(_ start: UInt64, _ end: UInt64, _ parent: String) throws {
            var cursor = start
            while cursor < end {
                visited += 1
                guard visited <= 100_000, end - cursor >= 8 else { throw RelayFailure.message("Invalid MP4 metadata; artwork was left in place") }
                let header = try read(cursor, 8)
                let kind = String(decoding: header.suffix(4), as: UTF8.self)
                var length = integer(header.prefix(4)), headerSize: UInt64 = 8
                if length == 1 { length = integer(try read(cursor + 8, 8)); headerSize = 16 }
                if length == 0 { length = end - cursor }
                guard length >= headerSize, length <= end - cursor else { throw RelayFailure.message("Invalid MP4 atom size; artwork was left in place") }
                if parent == "ilst", kind == "covr" { offsets.append(cursor + 4) }
                let descend = (parent.isEmpty && kind == "moov") ||
                    (parent == "moov" && ["udta", "meta"].contains(kind)) ||
                    (parent == "udta" && kind == "meta") || (parent == "meta" && kind == "ilst")
                if descend {
                    let extra: UInt64 = kind == "meta" ? 4 : 0
                    guard length >= headerSize + extra else { throw RelayFailure.message("Incomplete MP4 metadata") }
                    try walk(cursor + headerSize + extra, cursor + length, kind)
                }
                cursor += length
            }
        }
        try walk(0, size, "")
        guard !offsets.isEmpty else { throw RelayFailure.message("This file's embedded artwork is not supported by the MP4 artwork cleaner. Remove it manually before confirming the output.") }
        var current = stat(), named = stat()
        guard fstat(fd, &current) == 0, lstat(path, &named) == 0,
              current.st_dev == named.st_dev, current.st_ino == named.st_ino,
              current.st_size == original.st_size, current.st_mtimespec.tv_sec == original.st_mtimespec.tv_sec,
              current.st_mtimespec.tv_nsec == original.st_mtimespec.tv_nsec else {
            throw RelayFailure.message("The finished output changed before artwork removal. Select it again.")
        }
        var changed: [UInt64] = []
        do {
            for offset in offsets {
                try handle.seek(toOffset: offset)
                changed.append(offset)
                try handle.write(contentsOf: Data("free".utf8))
            }
            try handle.synchronize()
            try verify()
            guard lstat(path, &named) == 0, named.st_dev == original.st_dev, named.st_ino == original.st_ino else { throw RelayFailure.message("The output path changed during artwork removal") }
            return offsets.count
        } catch {
            // Restore the original atom types if the post-edit probe fails.
            for offset in changed { try handle.seek(toOffset: offset); try handle.write(contentsOf: Data("covr".utf8)) }
            try handle.synchronize()
            throw error
        }
    }
}
