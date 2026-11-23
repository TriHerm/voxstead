import SwiftUI

struct WorkspaceHomeView: View {
    let store: WorkspaceStore
    let canStart: Bool
    let importText: () -> Void
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                meetingCard
                dictationRow
                recentSessions
                if store.selectedProvider == nil {
                    HStack(alignment: .firstTextBaseline, spacing: 9) {
                        Label("Connect AI for live help and summaries.", systemImage: "sparkles")
                            .font(.callout).foregroundStyle(.secondary)
                        Button("Set up AI") { store.openSettings(.providers) }
                            .buttonStyle(.link)
                    }
                }
            }
            .frame(maxWidth: 780, alignment: .leading)
            .padding(30)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .background(.background)
        .navigationTitle("Home")
    }

    private var meetingCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                Text("Meetings and calls")
                    .font(.largeTitle.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                Button("Try an example") { store.destination = .practice }
                    .buttonStyle(.link)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 230), spacing: 12)], spacing: 12) {
                startOption("Start a meeting", icon: "video", detail: "Follow the transcript and capture decisions.", tint: .accentColor) {
                    store.showMeetingSetup = true
                }
                startOption("Phone call", icon: "phone", detail: "Read live captions and find a reply.", tint: .teal) {
                    store.openPhoneCallSetup()
                }
            }
        }
    }

    private func startOption(_ title: String, icon: String, detail: String, tint: Color,
                             action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Image(systemName: icon).font(.title2.weight(.medium)).foregroundStyle(tint)
                    Spacer()
                    Image(systemName: "chevron.forward").font(.callout.weight(.semibold)).foregroundStyle(.secondary)
                }
                .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.title3.weight(.semibold))
                    Text(detail).font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(18)
            .frame(maxWidth: .infinity, minHeight: 122, alignment: .topLeading)
            .background {
                RoundedRectangle(cornerRadius: 14)
                    .fill(reduceTransparency ? AnyShapeStyle(.background) : AnyShapeStyle(tint.opacity(0.07)))
            }
            .overlay { RoundedRectangle(cornerRadius: 14).strokeBorder(.separator) }
            .contentShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityHint(detail)
        .disabled(!canStart)
    }

    private var dictationRow: some View {
        HStack(spacing: 14) {
            Image(systemName: "mic")
                .font(.title2)
                .foregroundStyle(Color.accentColor)
                .frame(width: 30)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text("Dictation").font(.headline)
                Text("Hold Control + Option + D to dictate into any app.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Start dictation") { store.startCapture(.dictation) }
                .controlSize(.large)
                .disabled(!canStart)
        }
        .padding(14)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
    }

    private var recentSessions: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text("Recent sessions").font(.headline).accessibilityAddTraits(.isHeader)
                Spacer()
                Menu("Import") {
                    Button("Transcribe audio file…") { store.importAudio() }.disabled(!canStart)
                    Button("Add transcript…", action: importText)
                }
                .fixedSize()
            }
            if store.document.sessions.isEmpty {
                Text("Record a meeting or start dictating to see your sessions here.")
                    .font(.callout).foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            } else {
                ForEach(store.document.sessions.prefix(3)) { session in
                    Button { store.selected = session.id } label: {
                        HStack(spacing: 12) {
                            Image(systemName: session.kind.icon)
                                .foregroundStyle(Color.accentColor)
                                .frame(width: 24)
                                .accessibilityHidden(true)
                            Text(session.title).lineLimit(1).fontWeight(.medium)
                            Spacer()
                            Text(session.created.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption).foregroundStyle(.secondary)
                            Image(systemName: "chevron.right")
                                .font(.caption).foregroundStyle(.tertiary)
                                .accessibilityHidden(true)
                        }
                        .padding(.vertical, 8)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(session.title)
                    Divider().accessibilityHidden(true)
                }
            }
        }
    }
}
