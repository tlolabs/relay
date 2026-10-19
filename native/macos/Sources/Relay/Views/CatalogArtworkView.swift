import SwiftUI
import RelayKit

/// Artwork uses the same paced, budgeted transport as catalog API requests.
struct CatalogArtworkView: View {
    @Bindable var model: RelayModel
    let url: String?
    @State private var artwork = CatalogArtworkState()
    var body: some View {
        // URL identity also gates rendering before SwiftUI starts the new task.
        let image = artwork.requestedURL == url ? artwork.image : nil
        Group { if let image { Image(nsImage:image).resizable().scaledToFit() } else { Image(systemName:"photo").resizable().scaledToFit().padding(12).foregroundStyle(.secondary) } }
        .task(id:url) {
            await artwork.load(url) { try await model.posterData(for: $0) }
        }
    }
}
