import AVFoundation
import CoreMedia
import Foundation
import ScreenCaptureKit
import Speech

@MainActor
final class SpeechCapture {
    static func macAudioStartIssue(_ error: Error) -> CaptureIssue {
        let cause = error as NSError
        if cause.domain == SCStreamErrorDomain && cause.code == SCStreamError.Code.userDeclined.rawValue {
            return CaptureIssue(kind: .macAudio, message: "Allow Voxstead in System Settings → Privacy & Security → Screen & System Audio Recording, then reopen Voxstead. You can also use the microphone only.")
        }
        return CaptureIssue(kind: .macAudio, message: "Mac audio could not start. \(cause.localizedDescription)")
    }

    private let audioEngine = AVAudioEngine()
    private var didInstallTap = false
    private var selectedMicrophone: SelectedMicrophoneCapture?
    private var systemStream: SCStream?
    private var systemOutput: SystemAudioOutput?
    private var tracks: [SpeechTrack] = []
    private var whisperRecording: WhisperRecording?
    private var onWhisperResult: ((TranscriptSegment, Bool) -> Void)?
    private var onWhisperFailure: ((CaptureIssue) -> Void)?
    private var engineMonitor: Task<Void, Never>?
    private(set) var microphoneName: String?

    func activity(for source: AudioSource) -> AudioActivity {
        tracks.first { $0.source == source }?.feed.activity.activity() ?? .waiting
    }

    func lastSignal(for source: AudioSource) -> ContinuousClock.Instant? {
        tracks.first { $0.source == source }?.feed.activity.signalTime
    }

    func start(
        locale: Locale, systemAudio: Bool, targetBundle: String? = nil, microphoneID: String? = nil,
        whisper: WhisperEngine? = nil,
        vocabulary: [String] = [], kind: SessionKind = .meeting, phoneCall: Bool = false,
        speakerStream: PhoneSpeakerStream? = nil,
        onPhoneWords: ((UUID, [PhoneTimedWord]) -> Void)? = nil,
        onUpdate: @escaping (TranscriptSegment, Bool) -> Void,
        onFailure: @escaping @MainActor @Sendable (CaptureIssue) -> Void
    ) async throws {
        try Task.checkCancellation()
        guard await AVCaptureDevice.requestAccess(for: .audio) else {
            throw CaptureIssue(kind: .microphone, message: "Allow microphone access in System Settings → Privacy & Security → Microphone.")
        }
        try Task.checkCancellation()
        if let whisper, microphoneID == nil {
            whisperRecording = try WhisperRecording(engine: whisper)
            microphoneName = MicrophoneDevice.defaultName()
            onWhisperResult = onUpdate
            onWhisperFailure = onFailure
            return
        }
        do {
            let device = try microphoneID.map { try MicrophoneDevice.captureDevice(for: $0) }
            microphoneName = device?.localizedName ?? MicrophoneDevice.defaultName()
            let micFormat = device == nil ? audioEngine.inputNode.outputFormat(forBus: 0) : SelectedMicrophoneCapture.format
            guard micFormat.sampleRate > 0, micFormat.channelCount > 0 else {
                throw CaptureIssue(kind: .microphone, message: "No microphone is available. Check the input in System Settings → Sound.")
            }

            if let whisper, let device {
                let recorder = try WhisperRecording(engine: whisper, inputFormat: micFormat)
                whisperRecording = recorder
                onWhisperResult = onUpdate
                onWhisperFailure = onFailure
                guard let receive = recorder.microphoneReceiver else {
                    throw WorkspaceError("Could not set up the selected microphone for dictation.")
                }
                try await startSelectedMicrophone(device, receive: receive)
                monitorMicrophone(onFailure: onFailure)
                return
            }
            let language = try await Self.supportedLanguage(locale)
            try Task.checkCancellation()

            var systemFilter: SCContentFilter?
            if systemAudio {
                do {
                    let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                    guard let display = content.displays.first else {
                        throw CaptureIssue(kind: .macAudio, message: "No display is available to set up Mac audio.")
                    }
                    if let targetBundle {
                        let targets = content.applications.filter { $0.bundleIdentifier == targetBundle }
                        guard !targets.isEmpty else { throw CaptureIssue(kind: .macAudio, message: "The selected meeting app is no longer available. Reopen it or use the microphone.") }
                        systemFilter = SCContentFilter(display: display, including: targets, exceptingWindows: [])
                    } else {
                        systemFilter = SCContentFilter(display: display, excludingWindows: [])
                    }
                } catch let error as CaptureIssue {
                    throw error
                } catch {
                    try Task.checkCancellation()
                    throw Self.macAudioStartIssue(error)
                }
            }

            let mic = try await SpeechTrack.prepare(locale: language, source: .microphone,
                                                    naturalFormat: micFormat, vocabulary: vocabulary,
                                                    kind: kind, phoneCall: phoneCall, speakerStream: speakerStream)
            tracks = [mic]
            var system: SpeechTrack?
            if systemFilter != nil {
                let track = try await SpeechTrack.prepare(locale: language, source: .system,
                                                          naturalFormat: nil, vocabulary: vocabulary, kind: kind,
                                                          phoneCall: phoneCall)
                tracks.append(track)
                system = track
            }
            try Task.checkCancellation()
            let sharedOrigin = phoneCall && systemAudio ? ContinuousClock.now : nil
            for track in tracks {
                track.listen(onUpdate: onUpdate, onFailure: onFailure,
                             onPhoneWords: track.source == .microphone ? onPhoneWords : nil, timeOrigin: sharedOrigin)
            }
            if let device {
                try await startSelectedMicrophone(device, receive: { mic.feed.append($0) })
            } else {
                try startDefaultMicrophone(format: micFormat, tap: Self.microphoneTap(for: mic.feed))
            }

            if let filter = systemFilter, let system {
                let configuration = SCStreamConfiguration()
                configuration.capturesAudio = true
                configuration.excludesCurrentProcessAudio = true
                configuration.sampleRate = 48_000
                configuration.channelCount = 1
                let output = SystemAudioOutput(feed: system.feed) { [weak self] issue in
                    guard self?.systemStream != nil else { return }
                    onFailure(issue)
                }
                let stream = SCStream(filter: filter, configuration: configuration, delegate: output)
                try stream.addStreamOutput(output, type: .audio, sampleHandlerQueue: output.queue)
                systemOutput = output
                systemStream = stream
                do {
                    try await stream.startCapture()
                } catch {
                    try Task.checkCancellation()
                    throw Self.macAudioStartIssue(error)
                }
            }
            try Task.checkCancellation()
            guard await microphoneIsRunning() else { throw Self.microphoneStopped }
            monitorMicrophone(onFailure: onFailure)
        } catch {
            await cancel()
            throw error
        }
    }

    private func startSelectedMicrophone(
        _ device: AVCaptureDevice, receive: @escaping @Sendable (AVAudioPCMBuffer) -> Void
    ) async throws {
        let source = SelectedMicrophoneCapture(device: device, receive: receive)
        selectedMicrophone = source
        try await source.start()
        try Task.checkCancellation()
    }

    private func startDefaultMicrophone(format: AVAudioFormat, tap: @escaping AVAudioNodeTapBlock) throws {
        let node = audioEngine.inputNode
        guard node.outputFormat(forBus: 0) == format else {
            throw CaptureIssue(kind: .microphone, message: "The audio device changed during setup. Select a microphone and try again.")
        }
        node.installTap(onBus: 0, bufferSize: 2048, format: format, block: tap)
        didInstallTap = true
        do {
            try audioEngine.start()
        } catch {
            throw CaptureIssue(kind: .microphone, message: "The microphone could not start. \(error.localizedDescription)")
        }
    }

    private func microphoneIsRunning() async -> Bool {
        if let selectedMicrophone { return await selectedMicrophone.isRunning() }
        return audioEngine.isRunning
    }

    private func monitorMicrophone(onFailure: @escaping @MainActor @Sendable (CaptureIssue) -> Void) {
        engineMonitor = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(500)) }
                catch { return }
                guard let self else { return }
                let isRunning = await self.microphoneIsRunning()
                if Task.isCancelled { return }
                if !isRunning {
                    onFailure(Self.microphoneStopped)
                    return
                }
            }
        }
    }

    private static let microphoneStopped = CaptureIssue(
        kind: .microphone,
        message: "The microphone stopped. Check your audio device, then resume."
    )

    // AVAudioEngine calls this from its audio queue, never from MainActor.
    // Keeping construction nonisolated prevents inherited executor assertions.
    nonisolated static func microphoneTap(for feed: AudioFeed) -> AVAudioNodeTapBlock {
        { buffer, _ in feed.append(buffer) }
    }

    nonisolated static func livePreset(for kind: SessionKind, phoneCall: Bool = false) -> SpeechTranscriber.Preset {
        var preset = SpeechTranscriber.Preset.progressiveTranscription
        if phoneCall {
            preset.reportingOptions.insert(.fastResults)
            preset.attributeOptions.insert(.audioTimeRange)
        } else if kind == .meeting {
            preset.reportingOptions.remove(.fastResults)
        }
        return preset
    }

    static func transcribeFile(_ url: URL, locale: Locale, vocabulary: [String] = []) async throws -> [TranscriptSegment] {
        let language = try await supportedLanguage(locale)
        let file = try AVAudioFile(forReading: url)
        let transcriber = SpeechTranscriber(locale: language, preset: .transcription)
        if let installation = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await installation.downloadAndInstall()
        }
        try Task.checkCancellation()
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        try await configureVocabulary(vocabulary, on: analyzer)
        return try await withTaskCancellationHandler {
            async let segments: [TranscriptSegment] = collectFileResults(transcriber)
            do {
                if let end = try await analyzer.analyzeSequence(from: file) {
                    try await analyzer.finalizeAndFinish(through: end)
                } else {
                    await analyzer.cancelAndFinishNow()
                }
                return try await segments
            } catch {
                await analyzer.cancelAndFinishNow()
                throw error
            }
        } onCancel: {
            Task { await analyzer.cancelAndFinishNow() }
        }
    }

    fileprivate static func configureVocabulary(_ vocabulary: [String], on analyzer: SpeechAnalyzer) async throws {
        guard !vocabulary.isEmpty else { return }
        let context = AnalysisContext()
        context.contextualStrings[.general] = vocabulary
        try await analyzer.setContext(context)
    }

    private nonisolated static func collectFileResults(_ transcriber: SpeechTranscriber) async throws -> [TranscriptSegment] {
        var segments: [TranscriptSegment] = []
        for try await result in transcriber.results where result.isFinal {
            let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let time = result.range.start.seconds
            segments.append(.init(time: time.isFinite ? max(0, time) : 0, source: .microphone, text: text))
        }
        return segments
    }

    private static func supportedLanguage(_ locale: Locale) async throws -> Locale {
        guard SpeechTranscriber.isAvailable,
              let language = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
            throw WorkspaceError("On-device speech recognition is unavailable for this language or Mac.")
        }
        return language
    }

    func finish() async {
        if let recorder = whisperRecording {
            await stopSources()
            whisperRecording = nil
            do {
                for segment in try await recorder.finish() { onWhisperResult?(segment, true) }
            } catch { onWhisperFailure?(CaptureIssue(kind: .transcription, message: error.localizedDescription)) }
            return
        }
        await stopSources()
        for track in tracks { track.feed.finish() }
        for track in tracks { await track.finish() }
        tracks.removeAll()
    }

    func cancel() async {
        await stopSources()
        whisperRecording?.discard()
        whisperRecording = nil
        for track in tracks { await track.cancel() }
        tracks.removeAll()
    }

    private func stopSources() async {
        engineMonitor?.cancel()
        engineMonitor = nil
        if let selectedMicrophone {
            await selectedMicrophone.stop()
            self.selectedMicrophone = nil
        }
        if didInstallTap {
            audioEngine.stop()
            audioEngine.inputNode.removeTap(onBus: 0)
            didInstallTap = false
        }
        if let stream = systemStream {
            systemStream = nil
            try? await stream.stopCapture()
            if let output = systemOutput {
                try? stream.removeStreamOutput(output, type: .audio)
            }
        }
        systemOutput = nil
    }
}

@MainActor
private final class SpeechTrack {
    let feed: AudioFeed
    private let stream: AsyncStream<AnalyzerInput>
    private let analyzer: SpeechAnalyzer
    private let transcriber: SpeechTranscriber
    let source: AudioSource
    private var consumer: Task<Void, Never>?
    private var analysis: Task<CMTime?, Error>?

    private init(transcriber: SpeechTranscriber, analyzer: SpeechAnalyzer, format: AVAudioFormat, source: AudioSource,
                 speakerStream: PhoneSpeakerStream?) {
        self.transcriber = transcriber
        self.analyzer = analyzer
        self.source = source
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream(bufferingPolicy: .bufferingNewest(256))
        self.stream = stream
        self.feed = AudioFeed(format: format, continuation: continuation, speakerStream: speakerStream)
    }

    static func prepare(locale: Locale, source: AudioSource, naturalFormat: AVAudioFormat?,
                        vocabulary: [String], kind: SessionKind, phoneCall: Bool = false,
                        speakerStream: PhoneSpeakerStream? = nil) async throws -> SpeechTrack {
        let transcriber = SpeechTranscriber(locale: locale, preset: SpeechCapture.livePreset(for: kind, phoneCall: phoneCall))
        if let installation = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await installation.downloadAndInstall()
        }
        try Task.checkCancellation()
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber], considering: naturalFormat) else {
            throw WorkspaceError("No compatible audio format was found for speech recognition.")
        }
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        try await SpeechCapture.configureVocabulary(vocabulary, on: analyzer)
        try await analyzer.prepareToAnalyze(in: format)
        return SpeechTrack(transcriber: transcriber, analyzer: analyzer, format: format, source: source,
                           speakerStream: speakerStream)
    }

    func listen(onUpdate: @escaping (TranscriptSegment, Bool) -> Void, onFailure: @escaping @MainActor @Sendable (CaptureIssue) -> Void,
                onPhoneWords: ((UUID, [PhoneTimedWord]) -> Void)? = nil, timeOrigin: ContinuousClock.Instant? = nil) {
        consumer = Task { [transcriber, source, feed] in
            do {
                for try await result in transcriber.results {
                    let time = result.range.start.seconds
                    let end = result.range.end.seconds
                    // Both analyzers count from their own first sample. Align phone tracks to the capture start.
                    var offset: Double = 0
                    if let timeOrigin, let start = feed.activity.startTime {
                        let elapsed = (start - timeOrigin).components
                        offset = max(0, Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18)
                    }
                    let segment = TranscriptSegment(time: offset + (time.isFinite ? max(0, time) : 0), source: source,
                                                    text: String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines),
                                                    endTime: end.isFinite ? offset + max(0, end) : nil)
                    if let onPhoneWords, !segment.text.isEmpty {
                        var words: [PhoneTimedWord] = []
                        for run in result.text.runs {
                            let text = String(result.text[run.range].characters)
                            if let range = run.audioTimeRange, range.start.seconds.isFinite, range.end.seconds.isFinite {
                                words.append(PhoneTimedWord(start: range.start.seconds, end: range.end.seconds, text: text))
                            } else if !words.isEmpty {
                                words[words.count - 1].text += text
                            }
                        }
                        if !words.isEmpty { onPhoneWords(segment.id, words) }
                    }
                    onUpdate(segment, result.isFinal)
                }
            } catch {
                if !Task.isCancelled { onFailure(CaptureIssue(kind: .transcription, message: error.localizedDescription)) }
            }
        }
        analysis = Task { [analyzer, stream, feed] in
            do {
                let end = try await analyzer.analyzeSequence(stream)
                if feed.droppedInput {
                    onFailure(CaptureIssue(kind: .gap, message: "Audio processing fell behind. The transcript may have gaps."))
                }
                return end
            } catch {
                if !Task.isCancelled { onFailure(CaptureIssue(kind: .transcription, message: error.localizedDescription)) }
                throw error
            }
        }
    }

    func finish() async {
        do {
            if let end = try await analysis?.value {
                try await analyzer.finalizeAndFinish(through: end)
            } else {
                await analyzer.cancelAndFinishNow()
            }
        } catch {
            await analyzer.cancelAndFinishNow()
        }
        await consumer?.value
    }

    func cancel() async {
        feed.finish()
        analysis?.cancel()
        consumer?.cancel()
        await analyzer.cancelAndFinishNow()
    }
}

// Each feed converts buffers on one source queue. Activity and loss are synchronized separately.
final class AudioFeed: @unchecked Sendable {
    let format: AVAudioFormat
    private let continuation: AsyncStream<AnalyzerInput>.Continuation
    private let speakerStream: PhoneSpeakerStream?
    private var converter: AVAudioConverter?
    private let lock = NSLock()
    private var didDropInput = false
    let activity = AudioActivityMeter()

    var droppedInput: Bool { lock.withLock { didDropInput } }

    init(format: AVAudioFormat, continuation: AsyncStream<AnalyzerInput>.Continuation,
         speakerStream: PhoneSpeakerStream? = nil) {
        self.format = format
        self.continuation = continuation
        self.speakerStream = speakerStream
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        guard buffer.frameLength > 0 else { return }
        let inputFormat = buffer.format
        if converter?.inputFormat != inputFormat {
            converter = AVAudioConverter(from: inputFormat, to: format)
            if inputFormat.channelCount > format.channelCount { converter?.downmix = true }
        }
        let capacity = AVAudioFrameCount(ceil(Double(buffer.frameLength) * format.sampleRate / inputFormat.sampleRate)) + 64
        guard let converter, let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
            lock.withLock { didDropInput = true }
            return
        }

        let input = OneBuffer(buffer)
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, flag in
            flag.pointee = input.buffer == nil ? .noDataNow : .haveData
            defer { input.buffer = nil }
            return input.buffer
        }
        if status == .error {
            lock.withLock { didDropInput = true }
        } else if output.frameLength > 0 {
            activity.receive(output)
            speakerStream?.append(output)
            if case .dropped = continuation.yield(AnalyzerInput(buffer: output)) {
                lock.withLock { didDropInput = true }
            }
        }
    }

    func finish() {
        continuation.finish()
        speakerStream?.finish()
    }

    private final class OneBuffer: @unchecked Sendable {
        var buffer: AVAudioPCMBuffer?
        init(_ buffer: AVAudioPCMBuffer) { self.buffer = buffer }
    }
}

private final class SystemAudioOutput: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    let queue = DispatchQueue(label: "labs.triherm.voxstead.systemAudio", qos: .userInitiated)
    private let feed: AudioFeed
    private let onFailure: @MainActor (CaptureIssue) -> Void

    init(feed: AudioFeed, onFailure: @escaping @MainActor (CaptureIssue) -> Void) {
        self.feed = feed
        self.onFailure = onFailure
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer, of type: SCStreamOutputType) {
        if type == .audio, let buffer = pcmBuffer(from: sample) { feed.append(buffer) }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        let message = error.localizedDescription
        Task { @MainActor [onFailure] in onFailure(CaptureIssue(kind: .macAudio, message: "Mac audio was interrupted. \(message)")) }
    }
}
