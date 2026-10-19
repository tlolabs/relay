import Foundation

/// Encoded artwork is retained by least-recent use, with both byte and entry
/// limits. Display thumbnails have a separate pixel limit in ArtworkThumbnail.
struct PosterDataCache {
    let byteLimit: Int
    let entryLimit: Int
    private var entries: [String: Data] = [:]
    private var recency: [String] = [] // Oldest use first; at most entryLimit keys.
    private(set) var byteCount = 0

    init(byteLimit: Int = 16 * 1024 * 1024, entryLimit: Int = 50) {
        self.byteLimit = max(0, byteLimit)
        self.entryLimit = max(0, entryLimit)
    }

    var count: Int { entries.count }

    mutating func data(for key: String) -> Data? {
        guard let data = entries[key] else { return nil }
        recency.removeAll { $0 == key }
        recency.append(key)
        return data
    }

    mutating func insert(_ data: Data, for key: String) {
        // A replacement must release its old cost even when the new value is
        // too large to retain. Never serve the obsolete value afterward.
        remove(key)
        guard entryLimit > 0, data.count <= byteLimit else { return }
        while entries.count >= entryLimit || byteCount > byteLimit - data.count {
            guard let oldest = recency.first else { break }
            remove(oldest)
        }
        entries[key] = data
        recency.append(key)
        byteCount += data.count
    }

    mutating func removeAll() {
        entries.removeAll()
        recency.removeAll()
        byteCount = 0
    }

    private mutating func remove(_ key: String) {
        if let old = entries.removeValue(forKey: key) { byteCount -= old.count }
        recency.removeAll { $0 == key }
    }
}
