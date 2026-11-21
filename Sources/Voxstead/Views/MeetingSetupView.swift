import AppKit
import SwiftUI

struct MeetingSetupView: View {
    let store: WorkspaceStore
    let phoneCall: Bool
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow
    @State private var source: String
    @State private var apps: [CaptureApp] = []
    @State private var setupError: String?
    @State private var showPreparation: Bool
    @State private var preparation: String
    @State private var showLanguageSupport = false
    @State private var explanationLanguage: String
    @State private var translateCaptions: Bool
    @State private var includeMeaning: Bool
    @State private var showSpeechTerms = false
    @State private var speechTerms = ""
    @State private var prepAnswer: String?
    @State private var callLocale = "en-US"
    @State private var callerName = ""

    private struct CaptureApp: Identifiable {
        let id: String
        let name: String
    }

    init(store: WorkspaceStore, phoneCall: Bool) {
        self.store = store
        self.phoneCall = phoneCall
        _source = State(initialValue: !phoneCall && store.document.settings.includeSystemAudio ? "system" : "mic")
        _preparation = State(initialValue: store.meetingSetupPreparation)
        _showPreparation = State(initialValue: !store.meetingSetupPreparation.isEmpty)
        let captions = phoneCall ? nil : store.document.settings.meetingCaptionLanguage
        _explanationLanguage = State(initialValue: phoneCall ? "Spanish" : (captions ?? "English"))
        _translateCaptions = State(initialValue: captions != nil)
        _includeMeaning = State(initialValue: false)
    }

    private var audioCheck: MeetingAudioCheck { store.meetingAudioCheck }
    private var selectedApp: CaptureApp? { apps.first { $0.id == source } }
    private var sourceAvailable: Bool { source == "mic" || source == "system" || selectedApp != nil }
    private var canUseCapture: Bool { store.captureID == nil && !store.importingAudio && !store.isQuitting }
    private var preparing: Bool { store.runningID == WorkspaceStore.meetingPrepJobID }
    private var spokenLocale: String { phoneCall ? callLocale : store.document.settings.locale }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: phoneCall ? "phone.fill" : "video.fill")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 39, height: 39)
                    .background(Color.accentColor.opacity(0.11), in: RoundedRectangle(cornerRadius: 11))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(phoneCall ? "Phone call" : "Start a meeting")
                        .font(.title2.weight(.semibold)).accessibilityAddTraits(.isHeader)
                    Text(phoneCall ? "Choose audio from your phone on speaker or a call on this Mac."
                         : "Check your audio and choose how to follow the conversation.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            .padding(19)

            ScrollView {
                VStack(alignment: .leading, spacing: 13) {
                    if phoneCall {
                        phonePreparation
                        phoneLanguage
                        audioSection
                    } else {
                        audioSection
                        languageSection
                        DisclosureGroup("Preparation notes", isExpanded: $showPreparation) {
                            preparationControls
                        }
                        .padding(13)
                        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 13))
                    }
                    if let setupError {
                        Label(setupError, systemImage: "exclamationmark.circle")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 19)
                .padding(.bottom, 16)
            }
            .frame(minHeight: 305, idealHeight: phoneCall ? 470 : 393, maxHeight: 505)

            Divider()
            HStack(spacing: 9) {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(phoneCall ? "Start listening" : "Start meeting", action: startMeeting)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!sourceAvailable || !canUseCapture || audioCheck.isRunning || preparing
                              || preparation.count > 3_000)
            }
            .padding(.horizontal, 19)
            .padding(.vertical, 13)
        }
        .frame(width: 500)
        .background(.background)
        .onChange(of: source) { _, _ in audioCheck.clearResult() }
        .onChange(of: store.document.settings.microphoneID) { _, _ in audioCheck.clearResult() }
        .onChange(of: spokenLocale) { _, _ in
            audioCheck.clearResult()
            prepAnswer = nil
        }
        .onChange(of: preparation) { _, _ in prepAnswer = nil }
        .onChange(of: speechTerms) { _, _ in audioCheck.clearResult() }
        .onDisappear {
            audioCheck.dismiss()
            if preparing { store.cancelModel() }
        }
        .task {
            audioCheck.clearResult()
            refreshApps()
        }
    }

    private var audioSection: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack {
                Label("Audio", systemImage: "waveform").font(.headline)
                Spacer()
                Button(action: refreshApps) {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Refresh audio apps")
                .accessibilityLabel("Refresh audio apps")
                .disabled(audioCheck.isRunning || preparing)
            }
            VStack(spacing: 9) {
                LabeledContent("Microphone") {
                    MicrophonePicker(selection: Binding(
                        get: { store.document.settings.microphoneID },
                        set: { value in store.updateSettings { $0.microphoneID = value } }
                    ))
                    .labelsHidden()
                }
                let audioLabel = phoneCall ? "Call audio" : "Meeting audio"
                LabeledContent(audioLabel) {
                    Picker(audioLabel, selection: $source) {
                        Text("Microphone only").tag("mic")
                        Text("Microphone + all Mac audio").tag("system")
                        if !apps.isEmpty {
                            Divider()
                            ForEach(apps) { app in Text("Microphone + \(app.name)").tag(app.id) }
                        }
                    }
                    .labelsHidden()
                }
            }
            .disabled(audioCheck.isRunning || preparing)
            Divider()
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(audioCheck.message ?? (source == "mic"
                    ? (phoneCall ? "For a phone on speaker, check that the microphone can hear both voices."
                       : "Check that your microphone can hear you.")
                    : "For browser calls, choose the browser playing the call."))
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if audioCheck.isRunning {
                    Button("Stop check") { audioCheck.cancelByUser() }
                } else {
                    Button("Check audio") {
                        audioCheck.start(locale: spokenLocale, systemAudio: source != "mic",
                                         target: selectedApp?.id, microphoneID: store.document.settings.microphoneID,
                                         vocabulary: SpeechVocabulary.clean(SpeechVocabulary.meetingTerms(from: speechTerms)
                                                                            + (store.document.settings.speechVocabulary ?? [])),
                                         phoneCall: phoneCall)
                    }
                    .disabled(!sourceAvailable || !canUseCapture || preparing)
                    .help("Check audio on this Mac without saving a transcript")
                }
            }
            if audioCheck.isListening {
                CaptureSignalView(includesMacAudio: source != "mic", activity: audioCheck.activity)
            }
            if !audioCheck.speechPreview.isEmpty { audioCheckPreview }
        }
        .padding(13)
        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 13))
    }

    private var audioCheckPreview: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("What Voxstead heard").font(.caption.weight(.semibold))
            ForEach([AudioSource.microphone, .system], id: \.self) { input in
                if let text = audioCheck.speechPreview[input] {
                    Text("\(input.title): \(text)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 7))
    }

    private var languageSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Language", systemImage: "character.bubble").font(.headline)
            LabeledContent("Spoken language") {
                SpokenLanguagePicker(selection: Binding(
                    get: { store.document.settings.locale },
                    set: { code in store.updateSettings { $0.locale = code } }
                ))
                .labelsHidden()
            }
            Text("Choose the language people will speak. Captions can use a different language.")
                .font(.caption).foregroundStyle(.secondary)
            DisclosureGroup("Names and terms", isExpanded: $showSpeechTerms) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Help Voxstead hear names, acronyms, and unusual words in this meeting.")
                        .font(.caption).foregroundStyle(.secondary)
                    TextField("Enter terms separated by commas", text: $speechTerms)
                        .textFieldStyle(.roundedBorder)
                }
                .padding(.top, 5)
            }
            .font(.callout)
            Divider()
            LabeledContent("Translate live captions") {
                Toggle("Translate live captions", isOn: $translateCaptions)
                    .toggleStyle(.switch)
                    .labelsHidden()
            }
            if translateCaptions {
                ExplanationLanguagePicker(selection: $explanationLanguage, label: "Translate and explain in")
                if let target = ExplanationLanguage.lookup(explanationLanguage),
                   CaptionLanguagePair.code(for: store.document.settings.locale) != target.id {
                    CaptionLanguagesButton(pair: .init(source: store.document.settings.locale, target: target.id)) {}
                }
            }
            DisclosureGroup("Reply options", isExpanded: $showLanguageSupport) {
                VStack(alignment: .leading, spacing: 9) {
                    if !translateCaptions {
                        ExplanationLanguagePicker(selection: $explanationLanguage, label: "Explain in")
                    }
                    Toggle("Show the meaning of suggested replies", isOn: $includeMeaning)
                }
                .padding(.top, 6)
            }
            .font(.callout)
        }
        .disabled(audioCheck.isRunning || preparing)
        .padding(13)
        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 13))
    }

    private var phonePreparation: some View {
        VStack(alignment: .leading, spacing: 7) {
            Label("Before the call", systemImage: "note.text").font(.headline)
            TextField("Caller’s name (optional)", text: $callerName)
                .textFieldStyle(.roundedBorder)
            Text("Add goals, dates, codes, or limits. These notes stay visible during the call and guide your replies.")
                .font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $preparation)
                .frame(height: 72)
                .scrollContentBackground(.hidden)
                .padding(4)
                .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 7))
                .accessibilityLabel("Phone call preparation notes")
            if preparation.count > 3_000 {
                Text("Keep your notes to 3,000 characters.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(13)
        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 13))
    }

    private var phoneLanguage: some View {
        VStack(alignment: .leading, spacing: 9) {
            SpokenLanguagePicker(selection: $callLocale)
            Toggle("Show the meaning of suggested replies", isOn: $includeMeaning)
            if includeMeaning {
                ExplanationLanguagePicker(selection: $explanationLanguage, label: "Explain in")
            }
            if store.selectedProvider == nil {
                Text("Captions work on this Mac. Connect an AI provider in Settings for suggested replies and recaps.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let provider = store.selectedProvider {
                Text("Requesting a reply shares recent speech and your notes with \(provider.name).")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .disabled(audioCheck.isRunning)
        .padding(13)
        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 13))
    }

    private func startMeeting() {
        let app = selectedApp
        let terms = SpeechVocabulary.meetingTerms(from: speechTerms)
        let assistance = MeetingAssistance(mode: includeMeaning ? .languageSupport : .conversation,
                                           explanationLanguage: explanationLanguage,
                                           translateCaptions: translateCaptions ? true : nil,
                                           preparation: preparation, speechTerms: terms.isEmpty ? nil : terms,
                                           phoneCall: phoneCall ? true : nil,
                                           callerName: phoneCall ? callerName : nil)
        if store.startCapture(.meeting, meetingAudio: source != "mic", targetBundle: app?.id,
                              targetName: app?.name, assistance: assistance, meetingLocale: spokenLocale) != nil {
            let nextCaptionLanguage = translateCaptions ? explanationLanguage : nil
            if !phoneCall, store.document.settings.meetingCaptionLanguage != nextCaptionLanguage {
                store.updateSettings { $0.meetingCaptionLanguage = nextCaptionLanguage }
            }
            dismiss()
            openWindow(id: "live-meeting")
        } else {
            setupError = store.error ?? "Finish the current capture or import before starting a meeting."
        }
    }

    private var preparationControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Write your goal, key questions, or constraints. Your notes stay with the meeting and can guide suggested replies.")
                .font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $preparation)
                .frame(height: 62)
                .scrollContentBackground(.hidden)
                .padding(4)
                .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 7))
                .accessibilityLabel("Meeting preparation notes")
                .disabled(preparing)
            if preparation.count > 3_000 {
                Text("Shorten your notes to 3,000 characters before continuing.").font(.caption)
            }
            if preparing {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Preparing…").foregroundStyle(.secondary)
                    Spacer()
                    Button("Cancel") { store.cancelModel() }
                }
            } else if let provider = store.selectedProvider {
                HStack {
                    Button("Help me prepare") {
                        prepAnswer = nil
                        store.askMeetingPreparation(preparation, onResult: { prepAnswer = $0 })
                    }
                    .disabled(preparation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || preparation.count > 3_000 || store.runningID != nil)
                    Text("Sends these notes to \(provider.name).")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if let prepAnswer {
                ScrollView { AnswerText(text: prepAnswer).frame(maxWidth: .infinity, alignment: .leading) }
                    .frame(maxHeight: 116)
            } else if !preparing, let error = store.error {
                Text(error).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.top, 8)
    }

    private func refreshApps() {
        var seen: Set<String> = []
        apps = NSWorkspace.shared.runningApplications.compactMap { app in
            guard app.activationPolicy == .regular, let id = app.bundleIdentifier,
                  let name = app.localizedName, id != Bundle.main.bundleIdentifier, seen.insert(id).inserted else { return nil }
            return CaptureApp(id: id, name: name)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}
