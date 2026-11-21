import SwiftUI

struct DebriefView: View {
    let store: WorkspaceStore
    let session: VoiceSession
    @State private var newAction = ""
    @State private var editing: ActionItem?
    @State private var pendingOnly = false
    @State private var showFollowUp = false
    @State private var followUpActions: Set<UUID> = []
    @State private var includeDecisions = false

    private var details: MeetingDetails { session.meeting ?? MeetingDetails() }
    private var phoneCall: Bool { details.assistance?.isPhoneCall == true }
    private var openActions: [ActionItem] { details.actions.filter { !$0.complete } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 23) {
                HStack(alignment: .firstTextBaseline) {
                    Text(phoneCall ? "Call recap" : "Debrief").font(.title2.weight(.semibold))
                    Spacer()
                    Button(store.selectedProvider == nil ? "Set up AI" : details.summary.isEmpty
                           ? (phoneCall ? "Generate recap" : "Generate debrief") : "Regenerate") {
                        if store.selectedProvider == nil { store.openSettings(.providers) }
                        else { store.writeDebrief(for: session) }
                    }
                        .buttonStyle(.borderedProminent)
                        .disabled(session.id == store.captureID || session.segments.isEmpty || store.runningID != nil)
                }
                if !phoneCall {
                    Picker("Template", selection: Binding(
                        get: { session.debriefTemplate ?? .general },
                        set: { template in store.updateSession(session.id) { $0.debriefTemplate = template } }
                    )) {
                        ForEach(DebriefTemplate.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .disabled(store.runningID == session.id)
                }
                if !details.summary.isEmpty {
                    Text("Regenerate refreshes AI task suggestions. Your edits and completed tasks are kept.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if details.summary.isEmpty {
                    Text(phoneCall ? "Generate a recap of agreements, dates, open requirements, and next steps."
                         : "Keep your notes and next steps here. AI can turn a finished transcript into a summary and suggested actions.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                if store.runningID == session.id {
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text(store.modelStatus ?? "")
                        Spacer()
                        Button("Cancel") { store.cancelModel() }
                    }
                    .font(.callout).foregroundStyle(.secondary)
                }
                if !details.summary.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Summary").font(.headline)
                        AnswerText(text: details.summary)
                    }
                }
                recapList(phoneCall ? "Agreements" : "Decisions", items: details.decisions)
                if phoneCall {
                    recapList("Dates", items: details.recapDates ?? [])
                    recapList("Open requirements", items: details.openRequirements ?? [])
                    if let notes = details.assistance?.preparation, !notes.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Pinned context").font(.headline)
                            Text(notes).textSelection(.enabled)
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Notes").font(.headline)
                    TextEditor(text: Binding(get: {
                        store.document.sessions.first { $0.id == session.id }?.meeting?.notes ?? ""
                    }, set: { value in
                        store.updateMeeting(session.id) { $0.notes = value }
                    }))
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .frame(minHeight: 80, maxHeight: 130)
                    .background(.quaternary.opacity(0.32), in: RoundedRectangle(cornerRadius: 8))
                    .accessibilityLabel("Meeting notes")
                }

                VStack(alignment: .leading, spacing: 11) {
                    HStack(alignment: .firstTextBaseline) {
                    Text(phoneCall ? "Next steps" : "Action items").font(.headline)
                        Spacer()
                        if !details.actions.isEmpty {
                            Toggle("Pending only", isOn: $pendingOnly)
                                .toggleStyle(.checkbox)
                            Text("\(details.actions.filter(\.complete).count) of \(details.actions.count) complete")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    ForEach(details.actions.filter { !pendingOnly || !$0.complete }) { item in
                        HStack {
                            Toggle(isOn: Binding(get: {
                                store.document.sessions.first { $0.id == session.id }?.meeting?.actions
                                    .first { $0.id == item.id }?.complete ?? item.complete
                            }, set: { done in
                                store.updateMeeting(session.id) {
                                    guard let index = $0.actions.firstIndex(where: { $0.id == item.id }) else { return }
                                    $0.actions[index].complete = done
                                    $0.actions[index].generated = false
                                }
                            })) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(item.title).strikethrough(item.complete)
                                    let metadata = [item.owner, item.due].filter { !$0.isEmpty }
                                    if !metadata.isEmpty {
                                        Text(metadata.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            }
                            .toggleStyle(.checkbox)
                            Spacer()
                            Button { editing = item } label: { Image(systemName: "pencil") }
                                .buttonStyle(.borderless).accessibilityLabel("Edit \(item.title)")
                        }
                        Divider()
                    }
                    HStack {
                        TextField("New action item", text: $newAction)
                            .onSubmit(addAction)
                        Button("Add", action: addAction)
                            .disabled(newAction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    if !openActions.isEmpty || !details.decisions.isEmpty {
                        Button {
                            followUpActions = Set(openActions.map(\.id))
                            includeDecisions = !details.decisions.isEmpty
                            showFollowUp = true
                        } label: {
                            Label("Prepare follow-up", systemImage: "calendar.badge.clock")
                        }
                        .disabled(store.captureID != nil || store.importingAudio || store.isQuitting)
                        .popover(isPresented: $showFollowUp) { followUpPicker }
                    }
                }

                if let history = details.cardHistory, !history.isEmpty {
                    DisclosureGroup("Live card history") {
                        ForEach(history.reversed()) { item in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(item.card.heading).font(.callout.weight(.medium))
                                Text(item.card.detail)
                                HStack {
                                    Text(item.status.rawValue)
                                        .font(.caption).foregroundStyle(.secondary)
                                    if let id = item.sourceSegmentID, session.segments.contains(where: { $0.id == id }) {
                                        Button("View source at \(item.timestamp)") {
                                            store.openTranscript(session.id, excerpt: .init(id: id, timestamp: item.timestamp))
                                        }
                                        .buttonStyle(.link)
                                        .font(.caption)
                                    } else {
                                        Text(item.timestamp).font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            }
                            .padding(.vertical, 5)
                        }
                    }
                }
                Divider()
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("Coach").font(.headline)
                        Spacer()
                        Button("Review communication") { store.reviewMeeting(session) }
                            .disabled(session.id == store.captureID || session.segments.isEmpty || store.runningID != nil)
                    }
                    Text(store.coachingHabit).font(.callout).foregroundStyle(.secondary)
                    if let note = details.coaching.last { CoachingNoteView(note: note, copy: store.copyText) }
                }

                if let provider = store.selectedProvider {
                    if provider.kind == .chatGPT { ChatGPTUsageLabel() }
                    Text(details.actions.isEmpty
                         ? "Debrief and coaching send transcript excerpts to \(provider.name)."
                         : "Debrief and coaching send transcript excerpts to \(provider.name). Debrief also sends task titles to match existing actions.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: 760, alignment: .leading)
            .padding(.horizontal, 34)
            .padding(.vertical, 24)
            .frame(maxWidth: .infinity)
        }
        .sheet(item: $editing) { item in
            ActionItemEditor(item: item, save: { changed in
                store.updateMeeting(session.id) {
                    guard let index = $0.actions.firstIndex(where: { $0.id == changed.id }) else { return }
                    $0.actions[index] = changed
                    $0.actions[index].generated = false
                }
            }, remove: {
                store.updateMeeting(session.id) { $0.actions.removeAll { $0.id == item.id } }
            })
        }
    }

    private var followUpPicker: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Prepare a follow-up").font(.headline)
            Text("Choose what to bring into your next meeting’s preparation notes.")
                .font(.callout).foregroundStyle(.secondary)
            if !details.decisions.isEmpty {
                Toggle("Include decisions", isOn: $includeDecisions)
                    .toggleStyle(.checkbox)
            }
            if !openActions.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 7) {
                        ForEach(openActions) { item in
                            Toggle(item.title, isOn: Binding(
                                get: { followUpActions.contains(item.id) },
                                set: { include in
                                    if include { followUpActions.insert(item.id) }
                                    else { followUpActions.remove(item.id) }
                                }
                            ))
                            .toggleStyle(.checkbox)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(idealHeight: min(Double(openActions.count) * 28, 200), maxHeight: 200)
            }
            HStack {
                Button("Cancel") { showFollowUp = false }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Open meeting setup") {
                    showFollowUp = false
                    store.prepareFollowUp(to: session.id, actionIDs: followUpActions, includeDecisions: includeDecisions)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!includeDecisions && followUpActions.isDisjoint(with: openActions.map(\.id)))
            }
        }
        .padding(16)
        .frame(width: 340)
    }

    @ViewBuilder
    private func recapList(_ title: String, items: [String]) -> some View {
        if !items.isEmpty || (phoneCall && !details.summary.isEmpty) {
            VStack(alignment: .leading, spacing: 8) {
                Text(title).font(.headline)
                if items.isEmpty {
                    Text("None captured").font(.callout).foregroundStyle(.secondary)
                }
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    Label(item, systemImage: "smallcircle.filled.circle")
                }
            }
        }
    }

    private func addAction() {
        let title = newAction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        store.updateMeeting(session.id) { $0.actions.append(.init(title: title)) }
        newAction = ""
    }
}

private struct ActionItemEditor: View {
    @State var item: ActionItem
    let save: (ActionItem) -> Void
    let remove: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Edit action item").font(.title2.weight(.semibold))
            Form {
                TextField("Task", text: $item.title)
                TextField("Owner", text: $item.owner)
                TextField("Due date", text: $item.due)
                Toggle("Complete", isOn: $item.complete)
            }.formStyle(.grouped)
            HStack {
                Button("Delete", role: .destructive) { remove(); dismiss() }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    item.title = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
                    save(item)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(item.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(21)
        .frame(width: 440)
    }
}

struct CoachingNoteView: View {
    let note: CoachingNote
    let copy: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(note.habit).font(.headline)
            AnswerText(text: note.observation)
            if !note.quote.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    Text("From your microphone").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Text("“\(note.quote)”").italic().textSelection(.enabled)
                }
            }
            if !note.suggestion.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Try saying").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Text(note.suggestion).textSelection(.enabled)
                }
                Button { copy(note.suggestion) } label: { Label("Copy suggestion", systemImage: "document.on.document") }
            }
            Text(note.provider).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
    }
}
