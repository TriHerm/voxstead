import SwiftUI

struct PracticeMeetingState {
    var continued = false
    var lastRecap: Bool?
    var result: Result?

    struct Result {
        let title: String
        let text: String
        var meaning: String?
    }
}

struct PracticeMeetingView: View {
    @Binding var state: PracticeMeetingState
    let canStart: Bool
    let start: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 7) {
                    Label("Practice meeting", systemImage: "play.rectangle")
                        .font(.largeTitle.weight(.semibold)).accessibilityAddTraits(.isHeader)
                    Text("Try the live tools with an English–Spanish sample, entirely on this Mac.")
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 13) {
                    HStack {
                        Text("Prototype review").font(.headline)
                        Spacer()
                        Text("Example transcript").font(.caption).foregroundStyle(.secondary)
                    }
                    transcriptLine("00:04", "Elena", "We agreed on a budget of eight thousand for the prototype.")
                    transcriptLine("00:12", "Elena", "Can we confirm the review date?")
                    if state.continued {
                        transcriptLine("00:22", "Mateo", "La revisión será el jueves. Falta confirmar quién enviará el prototipo.")
                        transcriptLine("00:29", "Elena", "Did we agree on the budget for the prototype?")
                    }
                    if !state.continued {
                        Button("Continue the conversation") { state.continued = true }
                            .buttonStyle(.link)
                    }
                }
                .padding(18)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 14))

                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) { actions }.fixedSize()
                    VStack(alignment: .leading, spacing: 8) { actions }
                }
                if let lastRecap = state.lastRecap {
                    Text(lastRecap ? "Last recap through 00:29" : "Last recap through 00:12")
                        .font(.caption).foregroundStyle(.secondary)
                }

                if let result = state.result {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(result.title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        Text(result.text).font(.title3.weight(.medium)).textSelection(.enabled)
                        if let meaning = result.meaning {
                            Text("Meaning in Spanish").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                            Text(meaning).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                    }
                    .padding(17)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 13))
                    .accessibilityElement(children: .combine)
                }

                Divider()
                ConversationPhrasesView(spoken: "en", meaning: "es", practice: true)
                Divider()
                HStack(spacing: 12) {
                    Button("Restart example") { reset() }.buttonStyle(.link)
                    Spacer()
                    Button("Start a meeting", action: start)
                        .buttonStyle(.borderedProminent)
                        .disabled(!canStart)
                }
            }
            .frame(maxWidth: 720, alignment: .leading)
            .padding(30)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .background(.background)
    }

    private var actions: some View {
        Group {
            Button {
                state.result = PracticeMeetingState.Result(title: "Explain · Spanish", text: state.continued
                    ? "Elena quiere confirmar qué presupuesto acordaron para el prototipo."
                    : "Elena quiere confirmar en qué fecha se hará la revisión del prototipo.")
            } label: {
                Label("Explain", systemImage: "character.bubble")
            }
            Button { recap() } label: {
                Label("Catch me up", systemImage: "text.alignleft")
            }
            Button {
                state.result = state.continued
                    ? PracticeMeetingState.Result(title: "What should I say?", text: "Yes, we agreed on eight thousand for the prototype.",
                             meaning: "Sí, acordamos ocho mil para el prototipo.")
                    : PracticeMeetingState.Result(title: "What should I say?", text: "What dates work for the review?",
                             meaning: "¿Qué fechas les vienen bien para la revisión?")
            } label: {
                Label("What should I say?", systemImage: "bubble.left.and.text.bubble.right")
            }
            if state.continued {
                Button {
                    state.result = PracticeMeetingState.Result(title: "Debrief", text: "The prototype budget is 8,000. The review is on Thursday. The team still needs an owner to send the prototype before the review.")
                } label: {
                    Label("Debrief", systemImage: "checklist")
                }
            }
        }
        .buttonStyle(.bordered)
    }

    private func transcriptLine(_ timestamp: String, _ speaker: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 11) {
            Text(timestamp).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(speaker).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Text(text).font(.callout)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func recap() {
        let text: String
        if state.lastRecap == state.continued {
            text = state.continued ? "You’re caught up." : "You’re caught up. Continue the conversation to see how the recap updates."
        } else if state.continued {
            let update = "The review is on Thursday. Who will send the prototype is still open."
            text = state.lastRecap == nil ? "The team approved 8,000 for the prototype. " + update : update
        } else {
            text = "The team approved 8,000 for the prototype. The review date is still open."
        }
        state.result = PracticeMeetingState.Result(title: state.lastRecap == nil ? "Catch me up · From the start" : "Catch me up · Since last recap", text: text)
        state.lastRecap = state.continued
    }

    private func reset() {
        state = PracticeMeetingState()
    }
}
