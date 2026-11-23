import SwiftUI

struct LiveTranscriptPane: View {
    let store: WorkspaceStore
    let sessionID: UUID
    @Binding var preferredLanguage: String
    @Binding var captionsEnabled: Bool
    @Binding var isExpanded: Bool

    @State private var revision = UUID()
    @State private var missingPair: CaptionLanguagePair?
    @State private var captionStatus: String?
    @State private var latestSource: (language: String, time: Double)?
    @State private var translations: [UUID: String] = [:]
    @State private var previews: [AudioSource: Preview] = [:]
    @State private var followLatest = true
    @State private var finalizedRows: [Row] = []

    private struct Preview {
        let time: Double
        let text: String
    }

    private struct Run: Hashable, Sendable {
        let target: String?
        let revision: UUID
    }

    private struct Row: Identifiable {
        enum ID: Hashable { case finalized(UUID), partial(AudioSource) }
        let segment: TranscriptSegment
        var isPartial = false
        var id: ID { isPartial ? .partial(segment.source) : .finalized(segment.id) }
    }

    private var run: Run {
        Run(target: captionsEnabled ? ExplanationLanguage.lookup(preferredLanguage)?.id : nil, revision: revision)
    }

    private var meeting: VoiceSession? {
        guard store.captureID == sessionID else { return nil }
        return store.activeMeeting
    }

    private var partialRows: [Row] {
        store.partials.values.sorted { $0.time < $1.time }.map { Row(segment: $0, isPartial: true) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(spacing: 12) {
                Button { isExpanded.toggle() } label: {
                    Label("Transcript", systemImage: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.callout.weight(.semibold))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isExpanded ? "Hide transcript" : "Show transcript")
                Spacer()
                Toggle(isOn: $captionsEnabled) {
                    Label("Translate captions", systemImage: "captions.bubble")
                        .font(.caption.weight(.medium))
                }
                .toggleStyle(.switch)
                .controlSize(.small)
                .accessibilityLabel("Translate captions into \(preferredLanguage)")
                .help("Translate the recognized speech on this Mac.")
                .onChange(of: captionsEnabled) { _, enabled in
                    if enabled { isExpanded = true }
                }
                if captionsEnabled {
                    ExplanationLanguagePicker(selection: $preferredLanguage, label: "Caption language", compact: true)
                        .controlSize(.small)
                }
            }
            if isExpanded {
                let liveRows = partialRows
                if let missingPair, captionsEnabled {
                    CaptionLanguagesButton(pair: missingPair) { revision = UUID() }.id(missingPair)
                } else if let captionStatus, captionsEnabled {
                    HStack {
                        Text(captionStatus).font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Retry") { revision = UUID() }.buttonStyle(.link).font(.caption)
                    }
                } else if captionsEnabled, let latestSource, let spoken = store.meetingLanguage,
                          CaptionLanguagePair.code(for: latestSource.language) != CaptionLanguagePair.code(for: spoken) {
                    Text("Detected \(CaptionLanguagePair.name(for: latestSource.language)) · Spoken language is set to \(CaptionLanguagePair.name(for: spoken))")
                        .font(.caption).foregroundStyle(.secondary)
                        .help("Choose the actual spoken language in meeting setup for clearer speech recognition.")
                }
                if finalizedRows.isEmpty && liveRows.isEmpty {
                    Text("Waiting for speech…").font(.callout).foregroundStyle(.secondary)
                } else {
                    transcript(liveRows)
                }
            }
        }
        .padding(12)
        .background(.background, in: RoundedRectangle(cornerRadius: 13))
        .overlay { RoundedRectangle(cornerRadius: 13).strokeBorder(.separator).allowsHitTesting(false) }
        .onChange(of: meeting?.segments.last?.id, initial: true) {
            // Meeting capture appends finals in recognition order. The other input can finalize an older line later.
            finalizedRows = (meeting?.segments ?? []).sorted { $0.time < $1.time }.map { Row(segment: $0) }
        }
        .onChange(of: run.target) { _, _ in
            translations = [:]
            previews = [:]
            latestSource = nil
        }
        .onChange(of: store.meetingLanguage) { _, _ in latestSource = nil }
        .task(id: run) {
            let current = run
            captionStatus = nil
            missingPair = nil
            guard let target = current.target else {
                if captionsEnabled { captionStatus = "Choose a caption language in Meeting options." }
                return
            }
            await translate(target: target, run: current)
        }
    }

    private func transcript(_ liveRows: [Row]) -> some View {
        let latest = liveRows.last ?? finalizedRows.last
        return ScrollViewReader { proxy in
            VStack(alignment: .trailing, spacing: 6) {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 11) {
                        ForEach(finalizedRows) { row in transcriptLine(row) }
                        ForEach(liveRows) { row in transcriptLine(row) }
                        Color.clear.frame(height: 1).id("latest")
                    }
                }
                .defaultScrollAnchor(followLatest ? .bottom : nil, for: .sizeChanges)
                .frame(maxHeight: 245)
                .onChange(of: latest?.id) { _, _ in
                    if followLatest { proxy.scrollTo("latest", anchor: .bottom) }
                }
                .onChange(of: latest?.segment.text, initial: true) { _, _ in
                    if followLatest { proxy.scrollTo("latest", anchor: .bottom) }
                }
                .onChange(of: latest.flatMap { caption(for: $0)?.text }) { _, _ in
                    if followLatest { proxy.scrollTo("latest", anchor: .bottom) }
                }
                Toggle("Follow latest", isOn: $followLatest)
                    .font(.caption)
                    .toggleStyle(.checkbox)
                    .controlSize(.small)
                    .onChange(of: followLatest) { _, follows in
                        if follows { proxy.scrollTo("latest", anchor: .bottom) }
                    }
            }
        }
    }

    private func caption(for row: Row) -> (text: String, isPreview: Bool)? {
        guard captionsEnabled else { return nil }
        let segment = row.segment
        if let translated = translations[segment.id] { return (translated, false) }
        if let preview = previews[segment.source], preview.time == segment.time { return (preview.text, true) }
        return nil
    }

    private func transcriptLine(_ row: Row) -> some View {
        let segment = row.segment
        let translated = caption(for: row)
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Label(segment.speaker ?? segment.source.title,
                      systemImage: segment.source == .microphone ? "mic" : "speaker.wave.2")
                    .fontWeight(.medium)
                if row.isPartial {
                    Text("Live").foregroundStyle(.tint)
                }
                if let translated {
                    Text(translated.isPreview ? "\(preferredLanguage) · Preview" : preferredLanguage)
                }
                Spacer()
                Text(segment.timestamp).monospacedDigit()
                if let meeting, store.selectedProvider != nil {
                    Button {
                        store.askLive(.explain, session: meeting, passage: segment)
                    } label: {
                        Image(systemName: "character.bubble")
                    }
                    .buttonStyle(.borderless)
                    .disabled(store.runningID != nil)
                    .help("Explain this passage")
                    .accessibilityLabel("Explain passage at \(segment.timestamp)")
                }
            }
            .font(.caption).foregroundStyle(.secondary)
            if let translated {
                Text(translated.text).font(.body.weight(.medium)).textSelection(.enabled)
            }
            Text(segment.text)
                .font(translated == nil ? .body : .callout)
                .foregroundStyle(translated == nil ? Color.primary : Color.secondary)
                .textSelection(.enabled)
        }
    }

    nonisolated private func translate(target: String, run current: Run) async {
        var queue = CaptionQueue()
        let translator = LocalCaptionTranslator(target: target)
        var lastRecognition: String?
        // Coalesce changes during translation and read the latest speech when the worker is free.
        let (changes, signal) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let observer = Task { @MainActor in
            let updates = Observations {
                (meeting?.segments.last?.id, store.partials, store.meetingLanguage)
            }
            for await _ in updates {
                if Task.isCancelled { break }
                signal.yield(())
            }
            signal.finish()
        }
        var timer: Task<Void, Never>?
        defer {
            observer.cancel()
            timer?.cancel()
            signal.finish()
        }
        var events = changes.makeAsyncIterator()
        while !Task.isCancelled {
            let snapshot = await MainActor.run {
                guard let meeting, run == current else { return nil as (finals: [TranscriptSegment], partials: [TranscriptSegment], recognition: String?)? }
                return (finals: Array(meeting.segments.suffix(24)), partials: Array(store.partials.values),
                        recognition: store.meetingLanguage)
            }
            guard let snapshot else { return }
            if lastRecognition != snapshot.recognition {
                translator.resetDetectedLanguages()
                lastRecognition = snapshot.recognition
            }
            let now = ContinuousClock.now
            guard let work = queue.next(recentFinals: snapshot.finals, partials: snapshot.partials, at: now) else {
                timer?.cancel()
                if let deadline = queue.nextPreviewDeadline(for: snapshot.partials, at: now) {
                    timer = Task {
                        do { try await Task.sleep(until: deadline, clock: .continuous) }
                        catch { return }
                        signal.yield(())
                    }
                }
                guard await events.next() != nil else { return }
                continue
            }
            do {
                let result = try await translator.translate(work, recognitionLanguage: snapshot.recognition)
                try Task.checkCancellation()
                await MainActor.run {
                    guard !Task.isCancelled, run == current, meeting != nil else { return }
                    switch result {
                    case .translation(let text, let source):
                        captionStatus = nil
                        if work.segment.time >= (latestSource?.time ?? 0) {
                            latestSource = (source, work.segment.time)
                        }
                        if work.isPreview {
                            previews[work.segment.source] = Preview(time: work.segment.time, text: text)
                        } else {
                            translations[work.segment.id] = text
                        }
                    case .unchanged:
                        if previews[work.segment.source]?.time == work.segment.time {
                            previews[work.segment.source] = nil
                        }
                        if work.segment.time >= (latestSource?.time ?? 0) { latestSource = nil }
                    case .download(let pair):
                        if missingPair == nil { missingPair = pair }
                    case .unsupported(let pair):
                        captionStatus = "On-device captions are unavailable for \(pair.name)."
                    }
                }
            } catch {
                if Task.isCancelled { return }
                await MainActor.run {
                    guard run == current else { return }
                    captionStatus = "Caption translation paused. Retry to continue."
                }
                return
            }
        }
    }
}
