import SwiftUI
import RelayKit

/// Artwork uses the same paced, budgeted transport as catalog API requests.
struct CatalogArtworkView: View {
    @Bindable var model: RelayModel
    let url: String?
    @State private var image: NSImage?
    var body: some View {
        Group { if let image { Image(nsImage:image).resizable().scaledToFit() } else { Image(systemName:"photo").resizable().scaledToFit().padding(12).foregroundStyle(.secondary) } }
        .task(id:url) {
            guard let url, let address = URL(string:url) else { return }
            if let data=model.posterCache[url] { image=NSImage(data:data);return }
            do { let data=try await model.catalog.poster(url:address);model.posterCache[url]=data;image=NSImage(data:data) } catch {}
        }
    }
}
