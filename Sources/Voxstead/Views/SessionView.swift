import SwiftUI

struct SessionView: View {
    @Bindable var store: WorkspaceStore
    let session: VoiceSession
    @State private var followSpeech = true
    @State private var question = ""
    @State private var withTools = false
    @State private var editingSpeaker: TranscriptSegment?
    @State private var speakerName = ""
    @State private var highlightedSegment: UUID?

    private var tab: SessionSection {
        get { store.section(for: session.id) }
        nonmutating set { store.setSection(newValue, for: session.id) }
    }

    private var active: Bool { store.captureID == session.id }
    private var hasTranscript: Bool { !session.segments.isEmpty || (active && !store.partials.isEmpty) }
    private var canAsk: Bool { !active || session.kind == .meeting }
    private var running: Bool { store.runningID == session.id }
    private var provider: ProviderProfile? { store.document.settings.providers.first { $0.id == store.providerID } }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 15) {
                VStack(alignment: .leading, spacing: 7) {
                    Label(session.kind.title, systemImage: session.kind.icon)
                        .font(.callout.weight(.medium))
                        .foregroundStyle(Color.accentColor)
                    Text(session.title)
                        .font(.system(size: 31, weight: .semibold))
                        .lineLimit(2)
                    Text(session.created.formatted(date: .long, time: .shortened))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Picker("Session view", selection: Binding(get: { tab }, set: { tab = $0 })) {
                    ForEach(SessionSection.allCases.filter { $0 != .debrief || session.kind == .meeting }, id: \.self) {
                        Text($0.rawValue).tag($0)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .fixedSize()
            }
            .frame(maxWidth: 760, alignment: .leading)
            .padding(.horizontal, 34)
            .padding(.top, 28)
            .padding(.bottom, 18)

            if store.guidedDictationID == session.id {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: active ? "mic" : "checkmark.circle")
                        .foregroundStyle(Color.accentColor)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(active ? "Your first dictation" : "Your words are saved").font(.headline)
                        Text(active ? "Say a short sentence, then choose Stop above. Automatic language detection shows the text after you stop." : "Use Copy text below, then paste into any app with Command + V. Next time, hold Control + Option + D to dictate without opening this window.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Got it") { store.guidedDictationID = nil }
                }
                .padding(18)
                .background(Color.accentColor.opacity(0.08))
            }
            Divider()
            switch tab {
            case .transcript: transcriptBody
            case .assistant: assistantBody
            case .debrief: DebriefView(store: store, session: session)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(.background)
        .alert("Speaker label", isPresented: Binding(
            get: { editingSpeaker != nil }, set: { if !$0 { editingSpeaker = nil } }
        )) {
            TextField("Speaker name", text: $speakerName)
            Button("Save") {
                guard let segment = editingSpeaker else { return }
                let name = String(speakerName.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
                store.updateSession(session.id) {
                    guard let index = $0.segments.firstIndex(where: { $0.id == segment.id }) else { return }
                    $0.segments[index].speaker = name.isEmpty ? nil : name
                }
                editingSpeaker = nil
            }
            Button("Cancel", role: .cancel) { editingSpeaker = nil }
        } message: {
            Text("Leave empty to use the audio source label.")
        }
    }

    private var transcriptBody: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    if !hasTranscript && !active {
                        Text("This session has no transcript yet.").foregroundStyle(.secondary)
                    }
                    if active && !hasTranscript && store.partials.isEmpty {
                        Label("Waiting for speech…", systemImage: "waveform")
                            .foregroundStyle(.secondary)
                    }
                    if session.kind == .dictation {
                        let partial = active ? store.partials[.microphone]?.text : nil
                        Text([session.transcript.isEmpty ? nil : session.transcript, partial].compactMap { $0 }.joined(separator: " "))
                            .font(.system(size: 17))
                            .lineSpacing(6)
                            .textSelection(.enabled)
                        if let output = session.processedDictation {
                            Divider()
                            Text("Dictation output").font(.headline)
                            AnswerText(text: output)
                            Button("Copy output") { store.copyText(output) }
                        }
                    } else {
                        ForEach(session.segments.sorted { $0.time < $1.time }) { segment in
                            segmentRow(segment)
                                .padding(5)
                                .background(highlightedSegment == segment.id ? Color.accentColor.opacity(0.15) : .clear,
                                            in: RoundedRectangle(cornerRadius: 6))
                                .id(segment.id)
                                .contextMenu {
                                    Button("Label speaker…") {
                                        speakerName = segment.speaker ?? ""
                                        editingSpeaker = segment
                                    }
                                    .disabled(active)
                                }
                        }
                        if active {
                            ForEach(store.partials.values.sorted { $0.time < $1.time }, id: \.source) { segment in
                                segmentRow(segment).foregroundStyle(.secondary)
                            }
                        }
                    }
                    Color.clear.frame(height: 1).id("speech-end")
                }
                .frame(maxWidth: 760, alignment: .leading)
                .padding(.horizontal, 34)
                .padding(.vertical, 22)
                .frame(maxWidth: .infinity)
            }
            .onChange(of: active ? store.partials.mapValues(\.id) : [:], initial: true) {
                if active && followSpeech { proxy.scrollTo("speech-end", anchor: .bottom) }
            }
            .onChange(of: session.segments.last?.id) {
                if active && followSpeech { proxy.scrollTo("speech-end", anchor: .bottom) }
            }
            .onChange(of: followSpeech) {
                if active && followSpeech { proxy.scrollTo("speech-end", anchor: .bottom) }
            }
            .onChange(of: store.transcriptJump?.id, initial: true) { _, id in
                guard let id, session.segments.contains(where: { $0.id == id }) else { return }
                if active { followSpeech = false }
                highlightedSegment = id
                proxy.scrollTo(id, anchor: .center)
                store.transcriptJump = nil
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                if active && session.kind == .meeting {
                    HStack {
                        Toggle("Follow speech", isOn: $followSpeech)
                        Spacer()
                        if store.selectedProvider != nil {
                            Toggle("Auto replies", isOn: Binding(get: { store.autoRepliesEnabled }, set: { store.setAutoReplies($0) }))
                        }
                    }
                    .controlSize(.small).padding(.horizontal, 22).padding(.vertical, 8)
                    if store.generatingLiveReply || store.liveReply != nil {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(store.generatingLiveReply ? "Preparing a reply…" : "Suggested reply")
                                .font(.caption).foregroundStyle(.secondary)
                            Text(store.generatingLiveReply && !store.answerPreview.isEmpty ? store.answerPreview :
                                    (store.liveReply?.sentence ?? "")).textSelection(.enabled)
                            if !store.generatingLiveReply, session.meeting?.assistance?.showsReplyMeaning == true,
                               let meaning = store.liveReply?.meaning {
                                Text(meaning).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                            }
                        }
                        .padding(.horizontal, 22).padding(.bottom, 8)
                    }
                }
                if hasTranscript {
                    HStack {
                        Button { store.copyText(session.transcript) } label: { Label("Copy text", systemImage: "document.on.document") }
                        Button { store.export(session) } label: { Label("Export…", systemImage: "square.and.arrow.up") }
                            .disabled(active)
                        Spacer()
                        Button { tab = .assistant } label: { Label("Open assistant", systemImage: "sparkle") }
                            .disabled(active && session.kind != .meeting)
                    }
                    .padding(.horizontal, 22)
                    .padding(.vertical, 12)
                    .background(.bar)
                    .overlay(alignment: .top) { Divider() }
                }
            }
        }
    }

    private func segmentRow(_ segment: TranscriptSegment) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            Text(segment.timestamp)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 5) {
                Text(segment.speaker ?? segment.source.title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
                Text(segment.text).font(.body).lineSpacing(4).textSelection(.enabled)
            }
        }
    }

    private var assistantBody: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 21) {
                if !canAsk {
                    Label("Finish dictation before asking the assistant.", systemImage: "mic")
                        .foregroundStyle(.secondary)
                } else if provider == nil {
                    Text("Connect a provider to work with this transcript.")
                        .foregroundStyle(.secondary)
                    Button("Set up a provider…") { store.openSettings(.providers) }
                        .buttonStyle(.borderedProminent)
                } else if session.exchanges.isEmpty {
                    Text("What would you like to take away from this session?")
                        .font(.title3.weight(.semibold))
                    HStack {
                        if session.kind == .dictation {
                            Button("Polish text") { submit("Polish the transcript for natural reading. Preserve its meaning and language. Return only the revised text.") }
                        }
                        Button("Summarize") { submit("Summarize the key points in a short list.") }
                        if session.kind == .meeting {
                            Button("Extract decisions") { submit("Extract decisions, owners, and next actions. Flag missing details.") }
                        }
                    }
                    .disabled(!hasTranscript || store.runningID != nil)
                }

                ForEach(session.exchanges) { exchange in
                    VStack(alignment: .leading, spacing: 9) {
                        Text(exchange.prompt).font(.headline)
                        Text(exchange.provider).font(.caption).foregroundStyle(.secondary)
                        if let suggestion = exchange.replySuggestion {
                            ReplySuggestionView(suggestion: suggestion, copy: store.copyText)
                        } else {
                            Text((try? AttributedString(markdown: exchange.answer,
                                                       options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(exchange.answer))
                                .lineSpacing(4).textSelection(.enabled)
                            Button { store.copyText(exchange.answer) } label: { Label("Copy answer", systemImage: "document.on.document") }
                                .controlSize(.small)
                        }
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary.opacity(0.38), in: RoundedRectangle(cornerRadius: 10))
                }
            }
            .frame(maxWidth: 760, alignment: .leading)
            .padding(.horizontal, 34)
            .padding(.vertical, 22)
            .frame(maxWidth: .infinity)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if canAsk, !store.document.settings.providers.isEmpty { composer }
        }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 10) {
            if provider?.kind == .chatGPT { ChatGPTUsageLabel() }
            HStack {
                Picker("Provider", selection: $store.providerID) {
                    ForEach(store.document.settings.providers) { profile in
                        Text(profile.name).tag(Optional(profile.id))
                    }
                }
                .fixedSize()
                .disabled(store.runningID != nil)
                if store.document.settings.servers.contains(where: \.enabled) {
                    Toggle("Use MCP", isOn: $withTools)
                        .disabled(store.runningID != nil)
                        .help("Offer tools from enabled servers. Each call requires your approval.")
                }
                Spacer()
                if running {
                    ProgressView().controlSize(.small)
                    Text(store.modelStatus ?? "").font(.caption).foregroundStyle(.secondary)
                    Button("Cancel") { store.cancelModel() }
                }
            }
            HStack {
                TextField("Ask about this session", text: $question)
                    .onSubmit { submitQuestion() }
                    .accessibilityLabel("Ask about this session")
                Button { submitQuestion() } label: { Label("Send", systemImage: "arrow.up") }
                    .buttonStyle(.borderedProminent)
                    .disabled(!hasTranscript || store.runningID != nil || question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            if let provider {
                Text("Sending shares transcript excerpts and up to four previous exchanges with \(provider.name).")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 12)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    private func submitQuestion() {
        let text = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, hasTranscript, store.runningID == nil else { return }
        submit(text)
        question = ""
    }

    private func submit(_ text: String) {
        store.ask(session: session, prompt: text, useTools: withTools)
    }
}
