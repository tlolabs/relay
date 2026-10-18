import AppKit
import UniformTypeIdentifiers
import RelayKit

extension RelayModel {
    var canImportArtwork: Bool { selectedJob?.editable == true && !busy && editingId == selectedJob?.id }

    @discardableResult func importLocalArtwork(_ url: URL) -> Bool {
        guard url.isFileURL, canImportArtwork else { return false }
        do { return try importArtworkData(Data(contentsOf: url)) }
        catch { self.error = error.localizedDescription; return false }
    }

    @discardableResult func importArtworkData(_ data: Data) throws -> Bool {
        guard canImportArtwork, let databaseURL else { return false }
        guard data.count <= 16 * 1024 * 1024, let image = NSImage(data: data), image.isValid else {
            throw RelayFailure.message("Choose an image no larger than 16 MiB.")
        }
        let bytes: Data
        let suffix: String
        if data.starts(with: [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]) { bytes = data; suffix = "png" }
        else if data.starts(with: [0xff, 0xd8, 0xff]) { bytes = data; suffix = "jpg" }
        else {
            guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
                  let png = bitmap.representation(using: .png, properties: [:]), png.count <= 16 * 1024 * 1024 else {
                throw RelayFailure.message("This image could not be converted to PNG artwork under 16 MiB.")
            }
            bytes = png; suffix = "png"
        }
        let folder = databaseURL.deletingLastPathComponent().appendingPathComponent("artwork", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent(UUID().uuidString + "." + suffix)
        try bytes.write(to: file, options: .atomic)
        artworkSelection = UUID() // Invalidate any catalog poster still downloading.
        draftDirect.artworkPath = file.path
        draftDirect.artworkUrl = ""
        draftDirect.artworkFingerprint = nil
        draftDirect.overrides.insert("artwork")
        scheduleAutosave()
        return true
    }

    func acceptArtworkDrop(_ providers: [NSItemProvider]) -> Bool {
        guard canImportArtwork, providers.count == 1, let provider = providers.first else { return false }
        let editing = editingId, selection = selectedIds
        let request = UUID()
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            artworkSelection = request
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, error in
                let url = (item as? URL) ?? (item as? Data).flatMap { URL(dataRepresentation: $0, relativeTo: nil) }
                Task { @MainActor in
                    guard self.editingId == editing, self.selectedIds == selection, self.canImportArtwork, self.artworkSelection == request else { return }
                    if let url { self.importLocalArtwork(url) }
                    else { self.error = error?.localizedDescription ?? "The dropped artwork file could not be read." }
                }
            }
            return true
        }
        let imageTypes = [UTType.png, .jpeg, .tiff, .gif, .heic, .image].map(\.identifier)
        guard let type = imageTypes.first(where: { provider.hasItemConformingToTypeIdentifier($0) })
            ?? provider.registeredTypeIdentifiers.first(where: { UTType($0)?.conforms(to: .image) == true }) else { return false }
        artworkSelection = request
        provider.loadDataRepresentation(forTypeIdentifier: type) { data, error in
            Task { @MainActor in
                guard self.editingId == editing, self.selectedIds == selection, self.canImportArtwork, self.artworkSelection == request else { return }
                do {
                    if let data { try self.importArtworkData(data) }
                    else { self.error = error?.localizedDescription ?? "The dropped image could not be read." }
                } catch { self.error = error.localizedDescription }
            }
        }
        return true
    }
}
