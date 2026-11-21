import SwiftUI

struct LibraryAssistantDraft {
    var question = ""
    var folder: UUID?
}

struct LibraryAssistantView: View {
    @Bindable var store: WorkspaceStore
    @Binding var draft: LibraryAssistantDraft

    private var folder: UUID? {
        guard let id = draft.folder, store.document.folders?.contains(where: { $0.id == id }) == true else { return nil }
        return id
    }

    private var hasMeetings: Bool {
        store.document.sessions.contains {
            $0.kind == .meeting && !$0.segments.isEmpty && $0.id != store.captureID
                && (folder == nil || $0.folderID == folder)
        }
    }

    var body: some View {
        VStack(spacing: 14) {
            HStack {
                Label("Ask your meetings", systemImage: "bubble.left.and.bubble.right")
                    .font(.title2.weight(.semibold))
                Spacer()
            }
            if let folders = store.document.folders, !folders.isEmpty {
                Picker("Search in", selection: Binding(get: { folder }, set: { draft.folder = $0 })) {
                    Text("All meetings").tag(nil as UUID?)
                    ForEach(folders) { Text($0.name).tag(Optional($0.id)) }
                }
            }
            if let exchanges = store.document.libraryExchanges, !exchanges.isEmpty {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 17) {
                        ForEach(exchanges.reversed()) { exchange in
                            VStack(alignment: .leading, spacing: 8) {
                                Text(exchange.prompt).font(.headline)
                                Text(exchange.provider).font(.caption).foregroundStyle(.secondary)
                                AnswerText(text: exchange.answer)
                                DisclosureGroup("Meeting excerpts used") {
                                    ForEach(Array(exchange.sources.enumerated()), id: \.offset) { index, source in
                                        Button("[\(index + 1)] \(source.title)") {
                                            store.openTranscript(source.id)
                                        }
                                        .buttonStyle(.link)
                                        .disabled(!store.document.sessions.contains { $0.id == source.id })
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        if let excerpts = source.excerpts, !excerpts.isEmpty {
                                            HStack {
                                                Text("Jump to").font(.caption).foregroundStyle(.secondary)
                                                Menu("Transcript excerpts") {
                                                    ForEach(excerpts) { excerpt in
                                                        Button(excerpt.timestamp) {
                                                            store.openTranscript(source.id, excerpt: excerpt)
                                                        }
                                                    }
                                                }
                                                .disabled(!store.document.sessions.contains { $0.id == source.id })
                                            }
                                        }
                                    }
                                }
                            }
                            .padding(14)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 11))
                        }
                    }
                }
            } else {
                ContentUnavailableView(hasMeetings ? "Search across saved meetings" : "No saved meeting transcripts",
                                       systemImage: "text.magnifyingglass",
                                       description: Text(hasMeetings
                                        ? "Ask where a decision came up or what several calls agreed on."
                                        : "Record a meeting or add a transcript to get started."))
            }
            if let provider = store.selectedProvider {
                    if provider.kind == .chatGPT { ChatGPTUsageLabel() }
                HStack {
                    TextField("Ask across saved meetings", text: $draft.question).onSubmit(submit)
                    if store.runningID == WorkspaceStore.libraryJobID {
                        ProgressView().controlSize(.small)
                        Button("Cancel") { store.cancelModel() }
                    } else {
                        Button("Ask", action: submit)
                            .buttonStyle(.borderedProminent)
                            .disabled(!hasMeetings || draft.question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                      || store.runningID != nil)
                    }
                }
                Text("Voxstead searches locally, then sends excerpts from up to eight relevant meetings to \(provider.name).")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Button("Set up a provider…") {
                    store.openSettings(.providers)
                }
            }
        }
        .padding(22)
        .frame(maxWidth: 760)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func submit() {
        let prompt = draft.question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard hasMeetings, !prompt.isEmpty, store.runningID == nil else { return }
        store.askLibrary(prompt, folder: folder)
        draft.question = ""
    }
}

struct CoachView: View {
    let store: WorkspaceStore
    @State private var recentOnly = false
    @State private var currentHabitOnly = false
    private let habits = ["End with an owner and a date", "Ask one clarifying question", "Summarize the decision before closing"]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("Coach", systemImage: "person.crop.circle.badge.checkmark")
                    .font(.title2.weight(.semibold))
                Spacer()
            }
            Menu("Habit suggestions") {
                ForEach(habits, id: \.self) { habit in
                    Button(habit) { store.updateSettings { $0.coachingHabit = habit } }
                }
            }
            TextField("Communication habit", text: Binding(
                get: { store.coachingHabit },
                set: { value in store.updateSettings { $0.coachingHabit = value } }
            ))
            .textFieldStyle(.roundedBorder)
            Toggle("Review this habit after each meeting", isOn: Binding(
                get: { store.document.settings.autoCoach == true },
                set: { value in store.updateSettings { $0.autoCoach = value } }
            ))
            Text("Automatic reviews send transcript excerpts to the selected provider.")
                .font(.caption).foregroundStyle(.secondary)
            Divider()

            HStack {
                Toggle("Last 30 days", isOn: $recentOnly)
                Toggle("Current habit", isOn: $currentHabitOnly)
            }
            .toggleStyle(.checkbox)
            let reviewed = store.document.sessions.filter {
                (!recentOnly || $0.created >= Date.now.addingTimeInterval(-30 * 86_400)) && !reviews($0).isEmpty
            }
            if reviewed.isEmpty {
                ContentUnavailableView("No reviews yet", systemImage: "text.bubble",
                                       description: Text("Open a meeting’s Debrief to review this habit against your transcript."))
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 15) {
                        ForEach(reviewed) { session in
                            Button(session.title) { store.openDebrief(session.id) }
                                .buttonStyle(.link)
                            ForEach(reviews(session).reversed()) { note in
                                CoachingNoteView(note: note, copy: store.copyText)
                            }
                        }
                    }
                }
            }
        }
        .padding(22)
        .frame(maxWidth: 760)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func reviews(_ session: VoiceSession) -> [CoachingNote] {
        (session.meeting?.coaching ?? []).filter { !currentHabitOnly || $0.habit == store.coachingHabit }
    }
}
