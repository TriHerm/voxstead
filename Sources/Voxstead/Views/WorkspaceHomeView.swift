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
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 28) {
                meetingIntro.frame(minWidth: 300, maxWidth: .infinity, alignment: .leading)
                meetingActionsPreview
            }
            meetingIntro
        }
        .padding(24)
        .background {
            RoundedRectangle(cornerRadius: 20)
                .fill(.background)
            if !reduceTransparency {
                RoundedRectangle(cornerRadius: 20)
                    .fill(LinearGradient(colors: [Color.accentColor.opacity(0.17), Color.accentColor.opacity(0.04)],
                                         startPoint: .topTrailing, endPoint: .bottomLeading))
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 20)
                .strokeBorder(Color.accentColor.opacity(0.23))
                .allowsHitTesting(false)
        }
    }

    private var meetingIntro: some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(systemName: "video.fill")
                .font(.title3.weight(.semibold))
                .foregroundStyle(Color.accentColor)
                .accessibilityHidden(true)
            Text("Meetings and calls")
                .font(.largeTitle.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
            Text("Choose Meeting to track decisions and tasks. Choose Phone call for one-on-one captions and short replies.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 9) {
                Button("Start a meeting") { store.showMeetingSetup = true }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canStart)
                Button("Phone call", action: store.openPhoneCallSetup)
                    .buttonStyle(.bordered)
                    .disabled(!canStart)
            }
            .controlSize(.large)
            .padding(.top, 5)
            Button("Try an example") { store.destination = .practice }
                .buttonStyle(.link)
        }
    }

    private var meetingActionsPreview: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Explain", systemImage: "character.bubble")
            Label("Catch me up", systemImage: "text.alignleft")
            Label("What should I say?", systemImage: "bubble.left.and.text.bubble.right")
        }
        .font(.callout.weight(.medium))
        .foregroundStyle(.secondary)
        .padding(14)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
        .fixedSize()
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
