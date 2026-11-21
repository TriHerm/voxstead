import Speech
import SwiftUI

/// No permission requests, model calls, or recording occur just by opening the guide.
struct FirstUseGuide: View {
    @Bindable var store: WorkspaceStore
    @State private var locales: [String] = []
    private var step: Int { min(2, max(0, store.document.settings.guideStep ?? 0)) }
    private let titles = ["Welcome to Voxstead", "Make dictation yours", "Try your first dictation"]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label("Getting started", systemImage: "waveform.path")
                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                if step > 0 {
                    Text("Dictation setup · \(step) of 2").font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(.bottom, 16)
            Text(titles[step]).font(.title.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
            if step > 0 {
                ProgressView(value: Double(step), total: 2)
                    .accessibilityLabel("Guide progress").padding(.vertical, 16)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    switch step {
                    case 0: welcome
                    case 1: preferences
                    default: practice
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 8)
            }
            Divider().padding(.vertical, 16)
            HStack {
                Button("Skip for now") { store.finishGuide() }.keyboardShortcut(.cancelAction)
                Spacer()
                if step > 0 { Button("Back") { move(to: step - 1) } }
                if step == 0 {
                    Button("Set up dictation") { move(to: 1) }
                } else if step == 1 {
                    Button("Continue") { move(to: step + 1) }
                        .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                } else {
                    Button("Start dictation") { store.finishGuide(.dictation) }
                        .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                }
            }
            Text("Reopen this guide anytime from Getting started in the sidebar.")
                .font(.caption).foregroundStyle(.secondary).padding(.top, 12)
        }
        .padding(26).frame(width: 560, height: 510)
        .interactiveDismissDisabled()
        .task(id: step) {
            if step == 1 { locales = await SpeechTranscriber.supportedLocales.map { $0.identifier(.bcp47) } }
        }
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Follow a conversation, catch up on what you missed, and find the words to respond.")
                .font(.title3).fixedSize(horizontal: false, vertical: true)
            feature("Start with your audio", "Choose your microphone and check that Voxstead can hear you and your calling app.", "video")
            feature("Try a bilingual example", "Practice using Explain, Catch me up, and What should I say? without opening a call.", "play.rectangle")
            HStack(spacing: 10) {
                Button("Start a meeting") { store.finishGuide(.meeting) }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                Button("Try an example") { store.finishGuide(.practice) }
                    .buttonStyle(.bordered)
            }
            .controlSize(.large)
        }
    }

    private var preferences: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("The interface stays in English. Choose how Voxstead recognizes your speech.")
                .foregroundStyle(.secondary)
            Picker("Dictation language", selection: Binding(
                get: { store.dictationLanguage },
                set: { value in store.updateSettings { $0.dictationLocale = value } }
            )) {
                if WhisperEngine.installed != nil || store.dictationLanguage == "auto" {
                    Text("Automatic · detect spoken language").tag("auto")
                }
                ForEach(Array(Set(locales + [store.document.settings.locale, "en-US", store.dictationLanguage].filter { $0 != "auto" })).sorted(), id: \.self) { code in
                    Text(Locale(identifier: "en").localizedString(forIdentifier: code) ?? code).tag(code)
                }
            }
            Text(WhisperEngine.installed != nil
                 ? "Automatic detects the dominant language of each clip. Live meetings use a separate language setting."
                 : "Choose a supported language for on-device recognition. Automatic language detection is not installed on this Mac.")
                .font(.callout).foregroundStyle(.secondary)
            Toggle("Copy finished dictations to the clipboard", isOn: Binding(
                get: { store.document.settings.copyDictation },
                set: { value in store.updateSettings { $0.copyDictation = value } }
            ))
            Text("Your transcript is always saved in the library. You can also copy it manually.")
                .font(.caption).foregroundStyle(.secondary)
            feature("Permissions when you need them", "macOS may ask for microphone access when you start. Accessibility is only needed for optional insertion at the cursor; copying and pasting does not require it.", "hand.raised")
        }
    }

    private var practice: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("A short sentence is enough. This uses your microphone and saves a real transcript to your library.")
                .font(.title3).fixedSize(horizontal: false, vertical: true)
            feature("1. Start and speak", "Choose Start dictation below. If macOS asks, allow microphone access to continue.", "mic")
            feature("2. Choose Stop", "Your transcript will appear in the workspace. Automatic detection processes the recording after you stop.", "stop.circle")
            feature("3. Copy and paste", "Use Copy text, then Command + V in your destination app.", "doc.on.clipboard")
            if let error = store.hotkeyError {
                Text("The global shortcut is unavailable: \(error). You can still start from the app.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Button("Set up a meeting instead") { store.finishGuide(.meeting) }
                Button("Go to workspace") { store.finishGuide() }
            }
        }
    }

    private func feature(_ title: String, _ detail: String, _ icon: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon).font(.title3).foregroundStyle(Color.accentColor)
                .frame(width: 26).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.headline)
                Text(detail).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func move(to step: Int) { store.updateSettings { $0.guideStep = step } }
}
