import SwiftUI

struct GlobalActionItemsView: View {
    let store: WorkspaceStore
    @Binding var includeCompleted: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("Action items", systemImage: "checklist").font(.title2.weight(.semibold))
                Spacer()
            }
            Toggle("Show completed", isOn: $includeCompleted)
            let groups = store.document.sessions.filter { !visibleItems(in: $0).isEmpty }
            if groups.isEmpty {
                ContentUnavailableView("No action items to show", systemImage: "checklist",
                                       description: Text("Add an action item in a meeting’s Debrief."))
            } else {
                List {
                    ForEach(groups) { session in
                        Section {
                            ForEach(visibleItems(in: session)) { item in
                                Toggle(isOn: Binding(get: { item.complete }, set: { done in
                                    store.updateMeeting(session.id) {
                                        guard let index = $0.actions.firstIndex(where: { $0.id == item.id }) else { return }
                                        $0.actions[index].complete = done
                                        $0.actions[index].generated = false
                                    }
                                })) {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(item.title)
                                        Text([item.owner, item.due].filter { !$0.isEmpty }.joined(separator: " · "))
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                                .toggleStyle(.checkbox)
                            }
                        } header: {
                            Button(session.title) { store.openDebrief(session.id) }
                                .buttonStyle(.link)
                        }
                    }
                }
            }
        }
        .padding(22)
        .frame(maxWidth: 760)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func visibleItems(in session: VoiceSession) -> [ActionItem] {
        (session.meeting?.actions ?? []).filter { includeCompleted || !$0.complete }
    }
}
