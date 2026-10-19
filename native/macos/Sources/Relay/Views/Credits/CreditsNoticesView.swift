import SwiftUI

struct CreditsNoticesView: View {
    let notices: [CreditNotice]
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    private var filtered: [CreditNotice] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return term.isEmpty ? notices : notices.filter {
            ($0.name + "\n" + $0.source + "\n" + $0.text).localizedStandardContains(term)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Licenses & Notices").font(.title2.weight(.semibold))
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            TextField("Search names, licenses and notice text", text: $query)
                .textFieldStyle(.roundedBorder).accessibilityLabel("Search notices")
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 24) {
                    ForEach(filtered) { notice in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(notice.name).font(.headline)
                            Text(notice.source).font(.caption).foregroundStyle(.secondary)
                            Text(notice.text).font(.system(.callout, design: .monospaced))
                                .fixedSize(horizontal: false, vertical: true)
                            Divider()
                        }.textSelection(.enabled)
                    }
                    if filtered.isEmpty {
                        Text("No notices match your search.").foregroundStyle(.secondary)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(.trailing, 12)
            }
        }.padding(24).frame(width: 710, height: 540)
    }
}
