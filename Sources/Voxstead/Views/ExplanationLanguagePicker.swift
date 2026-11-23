import SwiftUI

struct ExplanationLanguagePicker: View {
    @Binding var selection: String
    var label = "Explain in"
    var allowsOriginal = false
    var compact = false
    var originalLabel = "Original language"
    @State private var isPresented = false
    @State private var query = ""

    var body: some View {
        HStack {
            if !compact {
                Text(label).foregroundStyle(.secondary)
                Spacer()
            }
            Button {
                query = ""
                isPresented = true
            } label: {
                Label(selection.isEmpty ? originalLabel : selection, systemImage: "chevron.up.chevron.down")
                    .lineLimit(1)
            }
            .accessibilityLabel("\(label): \(selection.isEmpty ? originalLabel : selection)")
            .popover(isPresented: $isPresented) {
                VStack(alignment: .leading, spacing: 12) {
                    Text(label).font(.headline)
                    TextField("Search languages", text: $query)
                        .textFieldStyle(.roundedBorder)
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            if allowsOriginal && query.isEmpty {
                                Button(originalLabel) {
                                    selection = ""
                                    isPresented = false
                                }
                            }
                            let matches = ExplanationLanguage.matching(query)
                            ForEach(matches) { language in
                                Button {
                                    selection = language.name
                                    isPresented = false
                                } label: {
                                    HStack {
                                        Text(language.title)
                                        Spacer()
                                        if selection == language.name || selection == language.nativeName {
                                            Image(systemName: "checkmark")
                                        }
                                    }
                                    .padding(8)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                            if matches.isEmpty {
                                Text("No matching languages").foregroundStyle(.secondary).padding(8)
                            }
                        }
                    }
                    Text("Translation quality depends on your AI provider.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(16)
                .frame(width: 340, height: 390)
            }
        }
    }
}
