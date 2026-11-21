import SwiftUI

struct ReplySuggestionView: View {
    let suggestion: ReplySuggestion
    let copy: @MainActor (String) -> Void
    var showMeaning: Bool = true

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(suggestion.sentence)
                .font(.title3.weight(.semibold))
                .textSelection(.enabled)
            if showMeaning, let meaning = suggestion.meaning {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Meaning").font(.caption.weight(.medium))
                    Text(meaning).font(.callout).textSelection(.enabled)
                }
                .foregroundStyle(.secondary)
                .accessibilityElement(children: .combine)
            }
            Button { copy(suggestion.sentence) } label: {
                Label("Copy phrase", systemImage: "document.on.document")
            }
            .controlSize(.small)
        }
    }
}
