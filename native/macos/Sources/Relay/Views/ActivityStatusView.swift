import SwiftUI

struct ActivityStatusView: View {
    let model: RelayModel
    var body: some View {
        if !model.activityMessages.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(model.activityMessages, id: \.self) { message in
                    HStack(alignment: .top, spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(message).font(.callout).fixedSize(horizontal: false, vertical: true)
                    }
                }
                if model.catalogBusy {
                    HStack {
                        Text("You can select and preview videos while searching.").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Stop Search") {
                            model.cancelCatalogSearch()
                            model.catalogMessage = "Search stopped. Matches already found remain available."
                            model.folderSearchSummary = model.catalogMessage
                        }.controlSize(.small)
                    }
                }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(12).background(.bar)
        }
    }
}
