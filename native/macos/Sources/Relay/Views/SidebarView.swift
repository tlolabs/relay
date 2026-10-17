import SwiftUI

struct SidebarView: View {
    @Bindable var model: RelayModel
    var body: some View {
        List(selection: Binding<String?>(get: { model.group }, set: { model.group = $0 ?? "Review"; model.selectedIds = [] })) {
            Section("Workspace") {
                Label("Review", systemImage: "tray.full").tag("Review")
                Label("Active", systemImage: "arrow.triangle.2.circlepath").tag("Active")
                Label("Completed", systemImage: "checkmark.circle").tag("Completed")
            }
            if !model.groups.isEmpty {
                Section("Suggested batches") {
                    ForEach(model.groups, id: \.self) { group in Label(group, systemImage: group == "Movies" ? "film" : "tv").tag(group) }
                }
            }
        }.listStyle(.sidebar)
        .navigationTitle("RELAY")
    }
}
