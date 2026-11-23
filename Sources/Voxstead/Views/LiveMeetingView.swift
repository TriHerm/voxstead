import SwiftUI

struct CaptureSignalView: View {
    let includesMacAudio: Bool
    let activity: (AudioSource) -> AudioActivity

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.4)) { _ in
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 18) { indicators }
                VStack(alignment: .leading, spacing: 5) { indicators }
            }
        }
    }

    @ViewBuilder
    private var indicators: some View {
        indicator(.microphone)
        if includesMacAudio { indicator(.system) }
    }

    private func indicator(_ source: AudioSource) -> some View {
        let state = activity(source)
        return HStack(spacing: 5) {
            Image(systemName: state == .signal ? "waveform" : "circle.dotted")
                .foregroundStyle(state == .signal ? Color.green : Color.secondary)
                .accessibilityHidden(true)
            Text(source.title).fontWeight(.medium)
            Text(state.title).foregroundStyle(.secondary)
        }
        .font(.caption)
        .fixedSize(horizontal: true, vertical: false)
        .accessibilityElement(children: .combine)
    }
}

struct LiveMeetingView: View {
    @Bindable var store: WorkspaceStore
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.openWindow) private var openWindow
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @State private var question = ""
    @State private var brief = true
    @State private var useTools = false
    @State private var showTranscript = true
    @State private var compact = false
    @State private var showMeetingOptions = false
    @State private var showQuickPhrases = false
    @State private var thought = ""
    @State private var showCards = false
    @State private var showQuestionOptions = false
    @State private var showPreparationOptions = false
    @State private var preparationDraft = ""

    var body: some View {
        Group {
            if let meeting = store.activeMeeting {
                panel(meeting)
            } else {
                ContentUnavailableView {
                    Label("No meeting in progress", systemImage: "video")
                } actions: {
                    Button("Open workspace") { openWindow(id: "workspace") }
                }
            }
        }
        .frame(minWidth: 420, minHeight: compact ? 300 : 385)
        .background(.background)
        .onAppear {
            store.livePanelVisible = true
            if store.activeMeeting == nil {
                openWindow(id: "workspace")
                dismissWindow(id: "live-meeting")
            }
        }
        .onDisappear { store.livePanelVisible = false }
        .onChange(of: store.captureID) { _, id in
            thought = ""
            showQuickPhrases = false
            if id == nil {
                openWindow(id: "workspace")
                dismissWindow(id: "live-meeting")
            }
        }
        .sheet(item: Binding(get: { store.approvalInLivePanel ? store.approval : nil },
                             set: { if $0 == nil { store.resolveApproval(false) } })) {
            ApprovalView(approval: $0, decide: store.resolveApproval)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if let error = store.error {
                RecoveryBanner(message: error, dismiss: { store.error = nil }, settings: {
                    openWindow(id: "workspace")
                    store.openSettings()
                })
            }
        }
    }

    private func panel(_ meeting: VoiceSession) -> some View {
        let canAsk = !meeting.segments.isEmpty || !store.partials.isEmpty
        let phoneCall = preferences(for: meeting).isPhoneCall
        return VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "circle.fill")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(store.captureReady ? Color.green : Color.secondary)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 7) {
                        Text(store.captureReady ? (phoneCall ? "Phone call · Listening" : "Live")
                             : store.captureStatus ?? "Preparing…")
                            .font(.headline)
                        if store.captureReady, let language = store.meetingLanguage {
                            Text(SpokenLanguagePicker.name(for: language)).font(.caption).foregroundStyle(.secondary)
                                .lineLimit(1)
                                .help("Language used to recognize speech. Pause to change it.")
                        }
                    }
                    let microphone = store.captureMicrophoneName ?? "Microphone"
                    Text(store.captureAppName.map { "\(microphone) + \($0)" } ?? microphone)
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                .layoutPriority(1)
                Spacer()
                Button { showQuickPhrases.toggle() } label: {
                    Image(systemName: "text.book.closed")
                }
                .accessibilityLabel("Quick phrases")
                .help("Quick phrases in five languages, available offline")
                .popover(isPresented: $showQuickPhrases) {
                    let settings = preferences(for: meeting)
                    let spoken = settings.replyLanguage.flatMap { ExplanationLanguage.lookup($0)?.id }
                        ?? store.meetingLanguage.flatMap(CaptionLanguagePair.code)
                    VStack(alignment: .leading, spacing: 12) {
                        if let provider = store.selectedProvider {
                            Text("Phrase my thought").font(.headline)
                            TextField("Write what you mean in any language", text: $thought, axis: .vertical)
                                .lineLimit(1...4)
                            ExplanationLanguagePicker(selection: Binding(
                                get: { preferences(for: meeting).replyLanguage ?? "" },
                                set: { value in updateAssistance(meeting.id) { $0.replyLanguage = value.isEmpty ? nil : value } }
                            ), label: "Say my reply in", allowsOriginal: true, originalLabel: "Conversation language")
                            Button("Phrase it with \(provider.name)") {
                                let draft = thought.trimmingCharacters(in: .whitespacesAndNewlines)
                                let language = store.meetingLanguage.map { SpokenLanguagePicker.name(for: $0) }
                                let request = LiveMeetingRequest(action: .suggest, speechLanguage: language,
                                                                 thoughtToPhrase: draft, phoneCall: settings.isPhoneCall)
                                guard let current = store.activeMeeting, current.id == meeting.id else { return }
                                store.ask(session: current, prompt: "Phrase my thought", useTools: false, brief: true, liveRequest: request)
                                thought = ""
                                showQuickPhrases = false
                            }
                            .disabled(thought.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                      || thought.count > 500 || store.runningID != nil)
                            if thought.count > 500 { Text("Use 500 characters or fewer.").font(.caption) }
                            Divider()
                        }
                        ConversationPhrasesView(spoken: spoken, meaning: ExplanationLanguage.lookup(settings.explanationLanguage)?.id)
                    }
                    .frame(width: 330).padding()
                }
                if !phoneCall {
                    Button { compact.toggle() } label: {
                        Image(systemName: compact ? "arrow.up.left.and.arrow.down.right" : "arrow.down.right.and.arrow.up.left")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(compact ? "Expand panel" : "Compact panel")
                    .help(compact ? "Expand panel" : "Compact panel")
                }
                Button { store.meetingPanelPinned.toggle() } label: {
                    Image(systemName: store.meetingPanelPinned ? "pin.fill" : "pin")
                }
                .buttonStyle(.borderless)
                .help(store.meetingPanelPinned ? "Unpin window" : "Keep window above other apps")
                .accessibilityLabel(store.meetingPanelPinned ? "Unpin window" : "Pin window")
                Button(store.isPaused ? "Resume" : "Pause") { store.pauseOrResumeMeeting() }
                    .disabled(!store.captureReady && store.captureStatus != "Paused")
                    .help(store.isPaused ? "Resume recording with the selected microphone and language."
                                         : "Pause recording to adjust the microphone or spoken language.")
                endButton(phoneCall: phoneCall)
                    .disabled(store.captureStatus == "Pausing…" || store.captureStatus == "Finalizing transcript…")
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 11)
            .background(reduceTransparency ? AnyShapeStyle(.background) : AnyShapeStyle(.regularMaterial))
            if store.captureReady {
                CaptureSignalView(includesMacAudio: store.captureAppName != nil, activity: store.captureActivity)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .background(Color.primary.opacity(0.035))
            } else if let issue = store.captureIssue {
                VStack(alignment: .leading, spacing: 8) {
                    Label(issue.message, systemImage: "exclamationmark.circle")
                        .font(.callout).foregroundStyle(.secondary)
                    if store.isPaused && store.captureAppName != nil && issue.kind == .macAudio {
                        Button("Continue with microphone only") { store.resumeMeetingWithMicrophone() }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
            }
            if store.isPaused && store.captureStatus == "Paused" {
                pausedCaptureOptions
            }
            Divider()

            if phoneCall {
                phoneReplyPanel(meeting, canAsk: canAsk)
            } else {
                meetingTools(meeting, canAsk: canAsk)
            }
        }
    }

    @ViewBuilder
    private func endButton(phoneCall: Bool) -> some View {
        if phoneCall, let provider = store.selectedProvider {
            Menu {
                Button("End without recap") { store.stopCapture() }
            } label: {
                Text("End & recap")
            } primaryAction: {
                store.stopCapture(withPhoneRecap: true)
            }
            .fixedSize()
            .help("End the call and send the finished transcript to \(provider.name) for a recap.")
        } else {
            Button("End") { store.stopCapture() }
                .buttonStyle(.bordered)
                .help("End recording and finish the transcript.")
        }
    }

    private func phoneReplyPanel(_ meeting: VoiceSession, canAsk: Bool) -> some View {
        let waiting = store.runningID == meeting.id && store.generatingLiveReply
        let recent = store.recentPhoneSpeech
        let settings = preferences(for: meeting)
        return VStack(spacing: 0) {
            if let notes = settings.preparation, !notes.isEmpty {
                pinnedPhoneContext(notes)
                    .padding(.horizontal, 12)
                    .padding(.top, 10)
            }
            VStack(alignment: .leading, spacing: 6) {
                Label("Live captions", systemImage: "captions.bubble")
                    .font(.headline).accessibilityAddTraits(.isHeader)
                ScrollViewReader { proxy in
                    ScrollView {
                        phoneSpeech(recent, callerName: settings.callerName)
                        Color.clear.frame(height: 1).id("latest-phone-caption")
                    }
                    .onChange(of: recent.last?.text, initial: true) { _, _ in
                        proxy.scrollTo("latest-phone-caption", anchor: .bottom)
                    }
                }
            }
            .frame(minHeight: 112, maxHeight: .infinity, alignment: .topLeading)
            .padding(12)

            if store.selectedProvider != nil || store.liveReply != nil {
                suggestedReplyPanel(meeting, waiting: waiting, showMeaning: settings.showsReplyMeaning)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 10)
            }
            Divider()
            HStack(spacing: 9) {
                if store.selectedProvider != nil {
                    Button {
                        store.requestPhoneReply(meeting)
                    } label: {
                        Label("What should I say?", systemImage: "text.bubble")
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut("3", modifiers: [.command, .option])
                    .disabled(!canAsk || store.runningID != nil)
                    .help("Suggest one or two short sentences (⌘⌥3)")
                    Button("Clarify") {
                        store.requestPhoneReply(meeting, focus: .clarify)
                    }
                    .disabled(!canAsk || store.runningID != nil)
                    .help("Give me a short question I can say to clarify what I heard.")
                } else {
                    Button("Add an AI provider…") {
                        openWindow(id: "workspace")
                        store.openSettings(.providers)
                    }
                }
                Spacer()
                phoneReplyOptions(meeting, waiting: waiting)
            }
            .padding(12)
            .background(reduceTransparency ? AnyShapeStyle(.background) : AnyShapeStyle(.regularMaterial))
        }
    }

    private func pinnedPhoneContext(_ notes: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("Pinned context", systemImage: "pin.fill").font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            ViewThatFits(in: .vertical) {
                Text(notes).fixedSize(horizontal: false, vertical: true)
                ScrollView { Text(notes).frame(maxWidth: .infinity, alignment: .leading) }
            }
            .frame(maxHeight: 105, alignment: .topLeading)
            .font(.callout)
            .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 9))
    }

    private func suggestedReplyPanel(_ meeting: VoiceSession, waiting: Bool, showMeaning: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label("Suggested reply", systemImage: "text.bubble")
                    .font(.caption.weight(.semibold)).accessibilityAddTraits(.isHeader)
                Spacer()
                if let provider = store.selectedProvider {
                    Toggle("Auto replies", isOn: Binding(get: { store.autoRepliesEnabled },
                                                         set: { store.setAutoReplies($0) }))
                        .toggleStyle(.switch).controlSize(.mini)
                        .help("Send questions and context to \(provider.name) for suggested replies")
                }
                if preferences(for: meeting).isPhoneCall, !waiting, let reply = store.liveReply {
                    Button("Simpler") {
                        store.requestPhoneReply(meeting, focus: .simplify(reply.sentence))
                    }
                    .buttonStyle(.link)
                    .disabled(store.runningID != nil || store.selectedProvider == nil)
                }
                if waiting || store.liveReply != nil {
                    Button {
                        if waiting { store.cancelModel() }
                        store.showLiveReply(nil)
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(waiting ? "Cancel reply" : "Dismiss reply")
                }
            }
            if waiting {
                if store.answerPreview.isEmpty {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text(store.liveReply?.sentence ?? "Finding a short reply…").font(.callout).foregroundStyle(.secondary)
                    }
                } else {
                    Text(store.answerPreview).font(.title3.weight(.semibold)).textSelection(.enabled)
                }
            } else if let reply = store.liveReply {
                let phrase = ReplySuggestionView(suggestion: reply, copy: store.copyText, showMeaning: showMeaning)
                ViewThatFits(in: .vertical) {
                    phrase.fixedSize(horizontal: false, vertical: true)
                    ScrollView { phrase.frame(maxWidth: .infinity, alignment: .leading) }.frame(height: 145)
                }
                .frame(maxHeight: 145, alignment: .topLeading)
            } else {
                Text(store.isPaused ? "Recording paused" : (store.autoRepliesEnabled
                     ? "Listening for a turn to respond to…" : "Use What should I say? for a reply."))
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }

    private func phoneReplyOptions(_ meeting: VoiceSession, waiting: Bool) -> some View {
        Menu {
            if store.selectedProvider != nil {
                Toggle("Show reply meaning (\(preferences(for: meeting).explanationLanguage))", isOn: Binding(
                    get: { preferences(for: meeting).showsReplyMeaning },
                    set: { enabled in updateAssistance(meeting.id) { $0.replyMeaning = enabled } }
                ))
            }
            if let phrase = phoneHoldingPhrase {
                Button("Give me a moment") {
                    store.showLiveReply(ReplySuggestion(sentence: phrase, meaning: nil))
                }
                .disabled(waiting)
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .fixedSize()
        .accessibilityLabel("Reply options")
    }

    private func phoneSpeech(_ recent: [TranscriptSegment], callerName: String?) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            if store.captureReady {
                switch store.phoneVoiceStatus {
                case .loading:
                    Label("Preparing on-device voice detection…", systemImage: "waveform")
                        .font(.caption).foregroundStyle(.secondary)
                case .ready where store.phoneTurns.ownSlot == nil:
                    Text("Say a few words, then mark your line with That’s me.")
                        .font(.caption).foregroundStyle(.secondary)
                case .unavailable:
                    Text("Voice labels unavailable. Captions are still on.")
                        .font(.caption).foregroundStyle(.secondary)
                case .ready, .separateInputs:
                    EmptyView()
                }
            }
            if recent.isEmpty {
                Text("Waiting for speech from the microphone…").font(.callout).foregroundStyle(.secondary)
            }
            ForEach(Array(recent.enumerated()), id: \.offset) { _, speech in
                phoneSpeechLine(speech, callerName: callerName)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func phoneSpeechLine(_ speech: TranscriptSegment, callerName: String?) -> some View {
        let canIdentify = store.captureReady && store.phoneVoiceStatus == .ready
            && store.phoneTurns.slot(for: speech) != nil && speech.speaker != "You"
        let name = (speech.speaker == "Caller" ? callerName : nil) ?? speech.speaker ?? "Unidentified voice"
        return VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(name).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                if speech.speaker == "Caller", PhoneCallTurns.isQuestion(speech.text) {
                    Text("Question").font(.caption).foregroundStyle(Color.accentColor)
                }
                Spacer()
                if canIdentify && store.phoneTurns.ownSlot == nil {
                    Button("That’s me") { store.identifyPhoneVoice(speech) }
                        .controlSize(.small)
                }
            }
            Text(speech.text).font(.body).textSelection(.enabled)
        }
        .contextMenu {
            if canIdentify { Button("Mark this voice as mine") { store.identifyPhoneVoice(speech) } }
        }
    }

    private var phoneHoldingPhrase: String? {
        let preferred = store.activeMeeting?.meeting?.assistance?.replyLanguage.flatMap { ExplanationLanguage.lookup($0)?.id }
        guard let language = preferred ?? store.meetingLanguage else { return nil }
        switch Locale(identifier: language).language.languageCode?.identifier {
        case "en": return "Could you give me a moment to check?"
        case "es": return "¿Me da un momento para verificarlo?"
        default: return nil
        }
    }

    private func meetingTools(_ meeting: VoiceSession, canAsk: Bool) -> some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    LiveTranscriptPane(store: store, sessionID: meeting.id,
                                       preferredLanguage: Binding(
                                        get: { preferences(for: meeting).explanationLanguage },
                                        set: { language in updateAssistance(meeting.id) { $0.explanationLanguage = language } }
                                       ),
                                       captionsEnabled: Binding(
                                        get: { preferences(for: meeting).translateCaptions == true },
                                        set: { enabled in setCaptionTranslation(enabled, for: meeting.id) }
                                       ),
                                       isExpanded: $showTranscript)
                        .id(meeting.id)
                    if (!store.generatingLiveReply && !store.answerPreview.isEmpty)
                        || (meeting.exchanges.last.map { $0.replySuggestion == nil } ?? false) {
                        answerCard(meeting)
                    }
                    if !compact { liveCards(meeting) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
            }
            if store.selectedProvider != nil || store.liveReply != nil {
                suggestedReplyPanel(meeting, waiting: store.generatingLiveReply && store.runningID == meeting.id,
                                showMeaning: preferences(for: meeting).showsReplyMeaning)
                    .padding(.horizontal, 12).padding(.bottom, 6)
            }

            Divider()
            VStack(alignment: .leading, spacing: 9) {
                if let provider = store.selectedProvider {
                    quickActions(meeting, canAsk: canAsk)
                    if let checkpoint = meeting.meeting?.catchUpCheckpoint {
                        catchUpStatus(meeting, checkpoint: checkpoint)
                    } else if canAsk && meeting.segments.isEmpty {
                        Text("Catch me up becomes available once the first line is saved.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if store.runningID == meeting.id && !store.generatingLiveReply {
                        HStack {
                            ProgressView().controlSize(.small)
                            Text(store.modelStatus ?? "Preparing your answer…").font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Button("Cancel") { store.cancelModel() }
                        }
                    }
                    HStack {
                        TextField("Ask about this meeting", text: $question)
                            .textFieldStyle(.plain)
                            .onSubmit { submit(meeting, canAsk: canAsk) }
                        Button { submit(meeting, canAsk: canAsk) } label: {
                            Image(systemName: "arrow.up")
                        }
                        .buttonStyle(.borderedProminent)
                        .buttonBorderShape(.circle)
                        .accessibilityLabel("Send question")
                        .disabled(!canAsk || question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                  || store.runningID != nil)
                    }
                    .padding(.leading, 10)
                    .padding(.trailing, 4)
                    .padding(.vertical, 4)
                    .background(Color.primary.opacity(0.065), in: RoundedRectangle(cornerRadius: 10))
                    Text("AI actions send excerpts to \(provider.name).")
                        .font(.caption2).foregroundStyle(.secondary)
                } else {
                    HStack {
                        Button("Add an AI provider…") {
                            openWindow(id: "workspace")
                            store.openSettings(.providers)
                        }
                        Spacer()
                        meetingOptionsButton(meeting)
                    }
                }
            }
            .padding(12)
            .background(reduceTransparency ? AnyShapeStyle(.background) : AnyShapeStyle(.regularMaterial))
        }
    }

    private func answerCard(_ meeting: VoiceSession) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            if store.runningID == meeting.id && !store.generatingLiveReply && !store.answerPreview.isEmpty {
                VStack(alignment: .leading, spacing: 7) {
                    Label("Writing answer…", systemImage: "sparkles")
                        .font(.caption.weight(.medium)).foregroundStyle(.secondary)
                    Text(store.answerPreview).lineSpacing(4)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(13)
            } else if let answer = meeting.exchanges.last {
                VStack(alignment: .leading, spacing: 7) {
                    Label(answer.prompt, systemImage: "sparkles").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                    if let suggestion = answer.replySuggestion {
                        ReplySuggestionView(suggestion: suggestion, copy: store.copyText)
                    } else {
                        AnswerText(text: answer.answer)
                        Button { store.copyText(answer.answer) } label: { Label("Copy answer", systemImage: "document.on.document") }
                            .controlSize(.small)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(13)
                .background(reduceTransparency ? AnyShapeStyle(.background) : AnyShapeStyle(.quaternary.opacity(0.35)),
                            in: RoundedRectangle(cornerRadius: 14))
                .overlay(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.accentColor.opacity(0.65))
                        .frame(width: 3)
                        .padding(.vertical, 14)
                }
            }
        }
    }

    private var pausedCaptureOptions: some View {
        VStack(alignment: .leading, spacing: 8) {
            LabeledContent("Microphone") {
                MicrophonePicker(selection: Binding(
                    get: { store.captureMicrophoneID },
                    set: { value in store.selectPausedMicrophone(value) }
                ))
                .labelsHidden()
            }
            LabeledContent("Spoken language") {
                SpokenLanguagePicker(selection: Binding(
                    get: { store.meetingLanguage ?? store.document.settings.locale },
                    set: { store.selectPausedMeetingLanguage($0) }
                ))
                .labelsHidden()
            }
            Text("Changes apply to what Voxstead records after you resume.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(11)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 9))
        .padding(.horizontal, 12)
        .padding(.bottom, 10)
    }

    private func preferences(for meeting: VoiceSession) -> MeetingAssistance {
        meeting.meeting?.assistance ?? MeetingAssistance()
    }

    private func setCaptionTranslation(_ enabled: Bool, for meetingID: UUID) {
        store.updateMeeting(meetingID) {
            var settings = $0.assistance ?? MeetingAssistance()
            settings.translateCaptions = enabled
            $0.assistance = settings
        }
    }

    private func quickActions(_ meeting: VoiceSession, canAsk: Bool) -> some View {
        HStack(alignment: .top, spacing: 9) {
            GlassEffectContainer(spacing: 8) {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) {
                        explanationAndRecap(meeting)
                        quickAction(.suggest, icon: "bubble.left.and.text.bubble.right", key: "3", meeting: meeting)
                    }
                    .fixedSize(horizontal: true, vertical: false)
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 8) { explanationAndRecap(meeting) }
                        quickAction(.suggest, icon: "bubble.left.and.text.bubble.right", key: "3", meeting: meeting)
                    }
                }
            }
            .disabled(!canAsk || store.runningID != nil)
            Spacer(minLength: 0)
            meetingOptionsButton(meeting)
        }
    }

    @ViewBuilder
    private func explanationAndRecap(_ meeting: VoiceSession) -> some View {
        quickAction(.explain, icon: "character.bubble", key: "1", meeting: meeting)
        quickAction(.catchUp, icon: "text.alignleft", key: "2", meeting: meeting)
    }

    private func quickAction(_ action: LiveMeetingAction, icon: String, key: KeyEquivalent, meeting: VoiceSession) -> some View {
        Button {
            store.askLive(action, session: meeting)
        } label: {
            Label(action.title, systemImage: icon).lineLimit(1)
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.capsule)
        .controlSize(.small)
        .keyboardShortcut(key, modifiers: [.command, .option])
        .disabled(action == .catchUp && !hasNewRecapSpeech(meeting))
        .help(actionHelp(action, meeting: meeting))
    }

    private func hasNewRecapSpeech(_ meeting: VoiceSession) -> Bool {
        guard let last = meeting.segments.last else { return false }
        return last.id != meeting.meeting?.catchUpCheckpoint?.segmentID
    }

    private func actionHelp(_ action: LiveMeetingAction, meeting: VoiceSession) -> String {
        switch action {
        case .explain: "Explain recent speech in \(preferences(for: meeting).explanationLanguage)"
        case .catchUp: "Summarize finalized speech since your last recap"
        default: action.instruction
        }
    }

    private func catchUpStatus(_ meeting: VoiceSession, checkpoint: MeetingCatchUpCheckpoint) -> some View {
        HStack {
            let title = hasNewRecapSpeech(meeting)
                ? "Last recap through \(checkpoint.latestTimestamp)"
                : "Caught up through \(checkpoint.latestTimestamp)"
            if let segment = checkpoint.latestCoveredSegment(in: meeting.segments) {
                Button {
                    store.openTranscript(meeting.id, excerpt: .init(id: segment.id, timestamp: segment.timestamp))
                    openWindow(id: "workspace")
                } label: {
                    Label(title, systemImage: "arrow.up.right")
                }
                .buttonStyle(.link)
                .help("Open the transcript at the latest speech covered by the recap")
            } else {
                Text(title).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Recap from start") { store.catchUp(sessionID: meeting.id, fromBeginning: true) }
                .buttonStyle(.link)
                .disabled(store.runningID != nil)
        }
        .font(.caption)
    }

    private func meetingOptionsButton(_ meeting: VoiceSession) -> some View {
        Button {
            preparationDraft = preferences(for: meeting).preparation ?? ""
            showMeetingOptions = true
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .buttonStyle(.glass)
        .accessibilityLabel("Meeting help settings")
        .help("Change the language and style of meeting help.")
        .popover(isPresented: $showMeetingOptions) {
            meetingOptions(meeting)
        }
    }

    private func meetingOptions(_ meeting: VoiceSession) -> some View {
        let settings = preferences(for: meeting)
        return ScrollView {
            VStack(alignment: .leading, spacing: 11) {
                Text("Meeting help").font(.headline).accessibilityAddTraits(.isHeader)
                VStack(alignment: .leading, spacing: 4) {
                    ExplanationLanguagePicker(selection: Binding(
                        get: { settings.explanationLanguage },
                        set: { language in updateAssistance(meeting.id) { $0.explanationLanguage = language } }
                    ), label: "Help language")
                    Text("Used for explanations, translated captions, and the meaning of replies.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Toggle("Explain suggested replies", isOn: Binding(
                    get: { settings.showsReplyMeaning },
                    set: { value in updateAssistance(meeting.id) { $0.replyMeaning = value } }
                ))
                .help("Show the meaning below the sentence you can say aloud.")
                VStack(alignment: .leading, spacing: 4) {
                    Picker("Reply style", selection: Binding(
                        get: { settings.mode },
                        set: { mode in updateAssistance(meeting.id) { $0.mode = mode } }
                    )) {
                        ForEach(MeetingAssistance.Mode.allCases) { Text($0.title).tag($0) }
                    }
                    Text(settings.mode.detail).font(.caption).foregroundStyle(.secondary)
                }
                Divider()
                DisclosureGroup("Typed questions", isExpanded: $showQuestionOptions) {
                    questionOptions(meeting)
                        .padding(.top, 6)
                }
                DisclosureGroup("Preparation notes", isExpanded: $showPreparationOptions) {
                    preparationOptions(meeting)
                        .padding(.top, 6)
                }
                if store.selectedProvider?.kind == .chatGPT { ChatGPTUsageLabel() }
            }
            .padding(16)
        }
        .frame(width: 356)
        .frame(idealHeight: 258, maxHeight: 435)
    }

    private func questionOptions(_ meeting: VoiceSession) -> some View {
        let customPrompts = store.quickPrompts.filter { prompt in
            !QuickPrompt.presets.contains { $0.label == prompt.label && $0.instruction == prompt.instruction }
        }
        return VStack(alignment: .leading, spacing: 7) {
            Picker("Answer length", selection: $brief) {
                Text("Brief").tag(true)
                Text("Detailed").tag(false)
            }
            Text("Choose how much detail to show when you type a question.")
                .font(.caption).foregroundStyle(.secondary)
            if store.document.settings.servers.contains(where: \.enabled) {
                Toggle("Use connected tools", isOn: $useTools)
                Text("The assistant can request a tool. You approve each call.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !customPrompts.isEmpty, store.selectedProvider != nil {
                Menu("Custom prompts") {
                    ForEach(customPrompts) { prompt in
                        Button(prompt.label) {
                            showMeetingOptions = false
                            store.ask(session: meeting, prompt: prompt.label, useTools: useTools,
                                      brief: brief, instruction: prompt.instruction)
                        }
                    }
                }
                .disabled((meeting.segments.isEmpty && store.partials.isEmpty) || store.runningID != nil)
            }
        }
    }

    private func preparationOptions(_ meeting: VoiceSession) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Add goals or questions. The assistant can use these notes to prepare or suggest a reply.")
                .font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $preparationDraft)
                .frame(height: 74)
                .scrollContentBackground(.hidden)
                .padding(4)
                .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 7))
                .accessibilityLabel("Preparation notes")
            if preparationDraft.count > 3_000 {
                Text("Shorten your notes to 3,000 characters before saving.").font(.caption)
            }
            HStack {
                Button("Save notes") {
                    savePreparation(meeting.id)
                    showMeetingOptions = false
                }
                Spacer()
                Button("Help me prepare") {
                    savePreparation(meeting.id)
                    showMeetingOptions = false
                    if let current = store.activeMeeting { store.askLive(.prepare, session: current) }
                }
                .disabled(store.selectedProvider == nil || store.runningID != nil
                          || preparationDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .buttonStyle(.borderedProminent)
            }
            .disabled(preparationDraft.count > 3_000)
        }
    }

    private func updateAssistance(_ id: UUID, change: (inout MeetingAssistance) -> Void) {
        store.cancelLiveCards()
        store.lastSuccessfulCardAttempt = nil
        store.updateMeeting(id) {
            var settings = $0.assistance ?? MeetingAssistance()
            change(&settings)
            $0.assistance = settings
        }
    }

    private func savePreparation(_ id: UUID) {
        let clean = preparationDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        updateAssistance(id) { $0.preparation = clean.isEmpty ? nil : String(clean.prefix(3_000)) }
    }

    private func liveCards(_ meeting: VoiceSession) -> some View {
        let cards = (meeting.meeting?.cardHistory ?? []).filter { $0.status == .pending }
        return DisclosureGroup(isExpanded: $showCards) {
            VStack(alignment: .leading, spacing: 9) {
                Button("Scan now") { store.requestLiveCards(force: true) }
                    .disabled(meeting.segments.isEmpty || !store.captureReady || store.selectedProvider == nil || store.liveCardStatus == "Checking the transcript…")
                Toggle("Scan new transcript automatically", isOn: Binding(
                    get: { store.liveAutomationEnabled },
                    set: { store.setLiveAutomation($0) }
                ))
                .controlSize(.small)
                .disabled(store.selectedProvider == nil && !store.liveAutomationEnabled)
                .help("Look for new follow-ups while you talk. Uses your selected AI provider.")
                if let status = store.liveCardStatus {
                    Text(status).font(.caption).foregroundStyle(.secondary)
                }
                ForEach(Array(cards.suffix(2).reversed())) { item in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(item.card.heading).font(.callout.weight(.semibold))
                            Spacer()
                            Menu {
                                Button("Mark resolved") { store.setLiveCardStatus(.resolved, for: item.id, session: meeting.id) }
                                Button("Dismiss") { store.setLiveCardStatus(.dismissed, for: item.id, session: meeting.id) }
                            } label: { Image(systemName: "ellipsis.circle") }
                            .fixedSize()
                            .accessibilityLabel("Card actions")
                        }
                        Text(item.card.detail)
                        Text("“\(item.card.evidence)”").font(.caption).foregroundStyle(.secondary)
                        HStack(spacing: 5) {
                            Text(item.timestamp)
                            Text(item.discovered, style: .relative)
                        }.font(.caption2).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
                }
            }
            .padding(.top, 7)
        } label: {
            Text(cards.isEmpty ? "Live cards" : "Live cards · \(cards.count) open")
                .font(.callout.weight(.medium))
        }
        .padding(.horizontal, 6)
    }

    private func submit(_ meeting: VoiceSession, canAsk: Bool) {
        let prompt = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canAsk, !prompt.isEmpty, store.runningID == nil else { return }
        store.ask(session: meeting, prompt: prompt, useTools: useTools, brief: brief)
        question = ""
    }
}

struct AnswerText: View {
    let text: String

    var body: some View {
        let answer = try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))
        Text(answer ?? AttributedString(text)).lineSpacing(4).textSelection(.enabled)
    }
}
