import SwiftUI
import QuickLookThumbnailing
import RelayKit

struct QueueThumbnail: View {
    let job: RelayJob
    @State private var thumbnail: NSImage?
    var body: some View {
        Group {
            if let thumbnail { Image(nsImage: thumbnail).resizable().scaledToFit() }
            else { Image(systemName: "film").resizable().scaledToFit().padding(12).foregroundStyle(.secondary) }
        }
        .task(id: "\(job.id):\(job.options.artworkPath):\(job.outputPath ?? job.currentPath)") {
            if job.identity.kind == "movie", !job.options.artworkPath.isEmpty, let image = NSImage(contentsOfFile: job.options.artworkPath) { thumbnail = image; return }
            let path = job.outputPath ?? job.currentPath
            let request = QLThumbnailGenerator.Request(fileAt: URL(fileURLWithPath: path), size: CGSize(width: 240,height: 160), scale: 2, representationTypes: .thumbnail)
            thumbnail = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request).nsImage
        }
    }
}
