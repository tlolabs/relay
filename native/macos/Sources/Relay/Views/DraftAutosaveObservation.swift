import SwiftUI

/// Shared by the real editor and hosting tests so tests exercise SwiftUI's
/// deferred change callbacks, rather than manually invoking an autosave flag.
struct DraftAutosaveObservation: ViewModifier {
    let model: RelayModel

    func body(content: Content) -> some View {
        content
            .onChange(of: model.selectedIds) { _, _ in
                if model.selectedJob?.id != model.editingId { model.loadDraft() }
            }
            .onChange(of: model.draft) { _, _ in model.scheduleAutosave() }
            .onChange(of: model.draftDirect) { _, _ in model.scheduleAutosave() }
            .onChange(of: model.draftSubtitles) { _, _ in model.scheduleAutosave() }
    }
}
