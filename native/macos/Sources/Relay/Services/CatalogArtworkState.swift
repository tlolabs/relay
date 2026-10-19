import AppKit
import ImageIO
import Observation

enum ArtworkThumbnail {
    /// Decode and orient a bounded bitmap off the main actor. The largest
    /// current artwork view is 230 points high; 768 pixels also covers Retina.
    static func decode(_ data: Data, maxPixelSize: Int = 768) async throws -> CGImage {
        let task = Task.detached(priority: .utility) {
            try Task.checkCancellation()
            guard maxPixelSize > 0,
                  let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
                  let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceShouldCacheImmediately: true,
                    kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
                  ] as CFDictionary) else { throw ArtworkError.invalidImage }
            try Task.checkCancellation()
            return image
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: { task.cancel() }
    }

    private enum ArtworkError: Error { case invalidImage }
}

/// A request token protects state even when a transport/decoder ignores task
/// cancellation. New, missing, invalid and failed URLs all show a placeholder.
@MainActor @Observable
final class CatalogArtworkState {
    private(set) var requestedURL: String?
    private(set) var image: NSImage?
    @ObservationIgnored private var request = UUID()

    func load(_ text: String?,
              fetch: (URL) async throws -> Data,
              decode: (Data) async throws -> CGImage = { try await ArtworkThumbnail.decode($0) }) async {
        let token = UUID()
        request = token
        requestedURL = text
        image = nil
        guard let text, let url = URL(string: text), url.scheme == "https", url.host != nil else { return }
        do {
            try Task.checkCancellation()
            let data = try await fetch(url)
            try Task.checkCancellation()
            guard request == token else { return }
            let bitmap = try await decode(data)
            try Task.checkCancellation()
            guard request == token else { return }
            image = NSImage(cgImage: bitmap, size: .zero)
        } catch {
            // A failed old request must not erase a newer successful request.
            if request == token { image = nil }
        }
    }
}
