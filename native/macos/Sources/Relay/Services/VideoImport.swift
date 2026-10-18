import Foundation
import UniformTypeIdentifiers
import RelayKit

enum VideoImport {
    // Keep this list aligned with relay-core's video() predicate.
    static let extensions = ["mp4", "m4v", "mkv", "mov", "avi", "webm", "ts"]
    static var contentTypes: [UTType] { extensions.compactMap { UTType(filenameExtension: $0) } }
    static func accepts(_ url: URL) -> Bool {
        guard url.isFileURL, extensions.contains(url.pathExtension.lowercased()),
              let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else { return false }
        return values.isRegularFile == true && values.isSymbolicLink != true
    }
}

extension RelayModel {
    @discardableResult func enqueueVideos(_ urls: [URL]) -> Bool {
        guard !closing else { return false }
        let videos = urls.filter(VideoImport.accepts).map(\.standardizedFileURL)
        guard !videos.isEmpty else { return false }
        for url in videos where !pendingVideoURLs.contains(url) { pendingVideoURLs.append(url) }
        startPendingVideoImports()
        return true
    }

    func startPendingVideoImports() {
        guard !closing, engine != nil, videoImportTask == nil, !pendingVideoURLs.isEmpty else { return }
        videoImportTask = Task { [weak self] in
            guard let self else { return }
            defer { videoImportTask = nil }
            while !pendingVideoURLs.isEmpty, !Task.isCancelled {
                if busy || savingDraft {
                    do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
                    continue
                }
                guard let engine else { return }
                let urls = pendingVideoURLs
                pendingVideoURLs = []
                await perform("Adding videos to the queue…") {
                    var failures: [String] = []
                    for url in urls {
                        do { self.snapshot = try await engine.execute(["command": "direct_add", "path": url.path]) }
                        catch { failures.append("\(url.lastPathComponent): \(error.localizedDescription)") }
                    }
                    // Keep the current editor and its unsaved changes intact.
                    if self.group != "Queue" { self.selectJobs(self.selectedIds, in: "Queue") }
                    await self.prepareLocalEvidence()
                    self.beginFolderSearchIfNeeded()
                    self.scheduleCatalogRefreshIfDue()
                    if !failures.isEmpty { self.error = failures.joined(separator: "\n") }
                }
            }
        }
    }
}
