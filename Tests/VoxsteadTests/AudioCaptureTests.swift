import AVFoundation
import ScreenCaptureKit
import Speech
import Testing
@testable import Voxstead

private final class TapInvocation: @unchecked Sendable {
    let callback: @convention(block) (AVAudioPCMBuffer, AVAudioTime) -> Void
    init(_ callback: @escaping AVAudioNodeTapBlock) { self.callback = callback }
    func invoke() {
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 2048)!
        buffer.frameLength = 2048
        buffer.floatChannelData![0].initialize(repeating: 0, count: 2048)
        callback(buffer, AVAudioTime(sampleTime: 0, atRate: 48_000))
    }
}

struct AudioCaptureTests {
    @Test @MainActor func macAudioStartupDistinguishesPermissionFromDeviceFailure() {
        let denied = NSError(domain: SCStreamErrorDomain, code: SCStreamError.Code.userDeclined.rawValue)
        #expect(SpeechCapture.macAudioStartIssue(denied).message.contains("Privacy & Security"))
        let other = NSError(domain: "AudioDevice", code: denied.code,
                            userInfo: [NSLocalizedDescriptionKey: "Device disconnected."])
        #expect(SpeechCapture.macAudioStartIssue(other).message.contains("Device disconnected."))
        #expect(!SpeechCapture.macAudioStartIssue(other).message.contains("Privacy"))
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["VOXSTEAD_TEST_PHONE_AUDIO"] != nil))
    func phoneSpeakerModelSeparatesTwoVoices() async throws {
        let path = try #require(ProcessInfo.processInfo.environment["VOXSTEAD_TEST_PHONE_AUDIO"])
        let speakers = PhoneSpeakerStream()
        let (ready, readiness) = AsyncStream<Bool>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let (snapshots, results) = AsyncStream<PhoneSpeakerSnapshot>.makeStream()
        let worker = Task.detached {
            defer {
                readiness.finish()
                results.finish()
            }
            try await speakers.detect(onReady: {
                _ = readiness.yield(true)
            }, onUpdate: { _ = results.yield($0) })
        }
        defer {
            speakers.finish()
            worker.cancel()
        }
        let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
        let transcriber = SpeechTranscriber(locale: Locale(identifier: "en-US"),
                                            preset: SpeechCapture.livePreset(for: .meeting, phoneCall: true))
        let format = try #require(await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber],
                                                                               considering: file.processingFormat))
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        try await analyzer.prepareToAnalyze(in: format)
        let (audio, input) = AsyncStream<AnalyzerInput>.makeStream()
        let feed = AudioFeed(format: format, continuation: input, speakerStream: speakers)
        let collect = Task {
            var turns: [(String, Double, Double)] = []
            for try await result in transcriber.results where !result.isFinal {
                for run in result.text.runs {
                    guard let range = run.audioTimeRange else { continue }
                    turns.append((String(result.text[run.range].characters), range.start.seconds, range.end.seconds))
                }
            }
            return turns
        }
        let analyze = Task { try await analyzer.analyzeSequence(audio) }
        let latest = Task {
            var snapshot = PhoneSpeakerSnapshot()
            for await update in snapshots { snapshot = update }
            return snapshot
        }
        var started = ready.makeAsyncIterator()
        do {
            guard await started.next() == true else {
                try await worker.value
                throw WorkspaceError("Voice detection did not start.")
            }
            while file.framePosition < file.length {
                let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4_096))
                try file.read(into: buffer)
                feed.append(buffer)
                try await Task.sleep(for: .milliseconds(80))
            }
            feed.finish()
            if let end = try await analyze.value { try await analyzer.finalizeAndFinish(through: end) }
            else { await analyzer.cancelAndFinishNow() }
        } catch {
            feed.finish()
            analyze.cancel()
            collect.cancel()
            await analyzer.cancelAndFinishNow()
            throw error
        }
        try await worker.value
        let last = await latest.value
        #expect(Set(last.voices.filter { $0.end - $0.start >= 1 }.map(\.slot)).count == 2)
        let own = try #require(last.speaker(from: 1.0, to: 2.0))
        let caller = try #require(last.speaker(from: 6.5, to: 7.5))
        #expect(own != caller)
        let speech = try await collect.value
        #expect(speech.contains { $0.0.localizedCaseInsensitiveContains("schedule")
            && last.speaker(from: $0.1, to: max($0.1 + 0.15, $0.2)) == own })
        #expect(speech.contains { $0.0.localizedCaseInsensitiveContains("Friday")
            && last.speaker(from: $0.1, to: max($0.1 + 0.15, $0.2)) == caller })
    }

    @Test func speechOnEitherStereoChannelReachesTheMonoRecognizer() throws {
        let stereo = try #require(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 2))
        let mono = try #require(AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000,
                                              channels: 1, interleaved: true))
        for activeChannel in 0..<2 {
            let (_, continuation) = AsyncStream<AnalyzerInput>.makeStream()
            let feed = AudioFeed(format: mono, continuation: continuation)
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: stereo, frameCapacity: 256))
            let data = try #require(buffer.floatChannelData)
            buffer.frameLength = 256
            data[activeChannel].initialize(repeating: 0.4, count: 256)
            data[1 - activeChannel].initialize(repeating: 0, count: 256)
            feed.append(buffer)
            #expect(feed.activity.activity() == .signal)
            #expect(!feed.droppedInput)
            feed.finish()
        }
    }

    @Test func finalizedSpeechDoesNotHideTheNextPartialCaption() {
        let finalized = TranscriptSegment(time: 4, source: .system, text: "The draft is ready.", endTime: 8)
        let old = TranscriptSegment(time: 6, source: .system, text: "The draft")
        let next = TranscriptSegment(time: 8, source: .system, text: "The review is tomorrow.")
        let microphone = TranscriptSegment(time: 6, source: .microphone, text: "I can attend.")
        #expect(finalized.replacesPreview(old))
        #expect(!finalized.replacesPreview(next))
        #expect(!finalized.replacesPreview(microphone))
    }

    @Test func meetingTermsKeepSpecificVocabularyFirst() {
        let terms = SpeechVocabulary.meetingTerms(from: " TriHerm, Voxstead\ntriherm, , Audio Engine ")
        #expect(terms == ["TriHerm", "Voxstead", "Audio Engine"])
        #expect(SpeechVocabulary.clean(terms + ["TRIHERM", "MCP"], limit: 4) == ["TriHerm", "Voxstead", "Audio Engine", "MCP"])
    }

    @Test func unavailableMicrophoneDoesNotFallBackToTheSystemInput() {
        #expect(throws: CaptureIssue.self) {
            try MicrophoneDevice.captureDevice(for: "missing-\(UUID())")
        }
    }

    @Test func whisperRecordingFlushesStereoInputToAReadableFile() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("voxstead-\(UUID()).caf")
        defer { try? FileManager.default.removeItem(at: url) }
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 512))
        let samples = try #require(buffer.floatChannelData)
        buffer.frameLength = 512
        samples[0].initialize(repeating: 0.25, count: 512)
        samples[1].initialize(repeating: -0.5, count: 512)

        let recording = try WhisperInputFile(url: url, inputFormat: format)
        recording.append(buffer)
        try recording.finish()

        let audio = try AVAudioFile(forReading: url)
        #expect(audio.length == 512)
        #expect(audio.processingFormat.channelCount == 2)
        let readback = try #require(AVAudioPCMBuffer(pcmFormat: audio.processingFormat, frameCapacity: 512))
        try audio.read(into: readback)
        let captured = try #require(readback.floatChannelData)
        #expect(abs(captured[0][0] - 0.25) < 0.001)
        #expect(abs(captured[1][0] + 0.5) < 0.001)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["VOXSTEAD_TEST_MICROPHONE"] != nil))
    @MainActor func selectedMicrophoneCapturesWithoutChangingTheSystemInput() async throws {
        let name = try #require(ProcessInfo.processInfo.environment["VOXSTEAD_TEST_MICROPHONE"])
        try #require(AVCaptureDevice.authorizationStatus(for: .audio) == .authorized)
        let systemDevice = try #require(AVCaptureDevice.default(for: .audio))
        let selection = try #require(MicrophoneDevice.available().first { $0.name == name && $0.id != systemDevice.uniqueID })
        let device = try MicrophoneDevice.captureDevice(for: selection.id)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("voxstead-\(UUID()).caf")
        defer { try? FileManager.default.removeItem(at: url) }
        let meter = AudioActivityMeter()
        let recording = try WhisperInputFile(url: url, inputFormat: SelectedMicrophoneCapture.format)
        let capture = SelectedMicrophoneCapture(device: device) { buffer in
            meter.receive(buffer)
            recording.append(buffer)
        }
        do {
            try await capture.start()
            let deadline = ContinuousClock.now + .seconds(3)
            while meter.activity() == .waiting && ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(50))
            }
            #expect(await capture.isRunning())
            #expect(meter.activity() != .waiting)
            await capture.stop()
        } catch {
            await capture.stop()
            throw error
        }
        try recording.finish()
        let file = try AVAudioFile(forReading: url)
        #expect(file.length > 0)

        let speech = SpeechCapture()
        do {
            try await speech.start(locale: Locale(identifier: "en-US"), systemAudio: false,
                                   microphoneID: selection.id, onUpdate: { _, _ in }, onFailure: { _ in })
            #expect(speech.microphoneName == name)
            let deadline = ContinuousClock.now + .seconds(3)
            while speech.activity(for: .microphone) == .waiting && ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(50))
            }
            #expect(speech.activity(for: .microphone) != .waiting)
        } catch {
            await speech.cancel()
            throw error
        }
        await speech.cancel()
        #expect(AVCaptureDevice.default(for: .audio)?.uniqueID == systemDevice.uniqueID)
    }

    @Test func audioActivityDistinguishesSilenceAndExpiredInput() throws {
        let format = try #require(AVAudioFormat(commonFormat: .pcmFormatInt16,
                                               sampleRate: 16_000, channels: 2, interleaved: true))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 256))
        let samples = try #require(buffer.int16ChannelData)
        buffer.frameLength = 256
        samples[0].initialize(repeating: 0, count: 512)

        let meter = AudioActivityMeter()
        let start = ContinuousClock.now
        #expect(meter.activity(at: start) == .waiting)
        meter.receive(buffer, at: start)
        #expect(meter.activity(at: start) == .quiet)

        // Signal only in the second channel of the interleaved buffer.
        for frame in 0..<256 { samples[0][frame * 2 + 1] = .min }
        meter.receive(buffer, at: start + .milliseconds(200))
        #expect(meter.activity(at: start + .milliseconds(800)) == .signal)
        #expect(meter.activity(at: start + .seconds(2)) == .quiet)
        #expect(meter.activity(at: start + .seconds(3)) == .waiting)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["VOXSTEAD_TEST_AUDIO"] != nil))
    func audioFeedTranscribesARealFixture() async throws {
        let path = try #require(ProcessInfo.processInfo.environment["VOXSTEAD_TEST_AUDIO"])
        let transcriber = SpeechTranscriber(locale: Locale(identifier: "en-US"), preset: .transcription)
        let format = try #require(await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]))
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        try await analyzer.prepareToAnalyze(in: format)
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        let feed = AudioFeed(format: format, continuation: continuation)
        let collect = Task { () throws -> String in
            var result = ""
            for try await item in transcriber.results where item.isFinal { result += String(item.text.characters) }
            return result
        }
        let analyze = Task { try await analyzer.analyzeSequence(stream) }
        do {
            let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
            let callback = SpeechCapture.microphoneTap(for: feed)
            var detectedSignal = false
            while file.framePosition < file.length {
                let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 2048))
                try file.read(into: buffer)
                callback(buffer, AVAudioTime(sampleTime: file.framePosition, atRate: file.processingFormat.sampleRate))
                detectedSignal = detectedSignal || feed.activity.activity() == .signal
            }
            #expect(detectedSignal)
            feed.finish()
            if let end = try await analyze.value { try await analyzer.finalizeAndFinish(through: end) }
            else { await analyzer.cancelAndFinishNow() }
            let result = try await collect.value
            #expect(result.localizedCaseInsensitiveContains("Tuesday"))
            #expect(result.localizedCaseInsensitiveContains("draft"))
            #expect(!feed.droppedInput)
        } catch {
            feed.finish()
            analyze.cancel()
            collect.cancel()
            await analyzer.cancelAndFinishNow()
            throw error
        }
    }

    @Test @MainActor func microphoneTapRunsOffMainActor() async throws {
        let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true)!
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        let feed = AudioFeed(format: format, continuation: continuation)
        let invocation = await Task.detached {
            TapInvocation(SpeechCapture.microphoneTap(for: feed))
        }.value
        await Task.detached { invocation.invoke() }.value
        feed.finish()
        var count = 0
        for await _ in stream { count += 1 }
        #expect(count > 0)
        #expect(!feed.droppedInput)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["VOXSTEAD_TEST_TRANSLATION"] == "1"
                   && ProcessInfo.processInfo.environment["VOXSTEAD_TEST_AUDIO"] != nil),
          arguments: [false, true])
    func speechFixtureCanBeTranslatedBeforeFinalization(phoneCall: Bool) async throws {
        let path = try #require(ProcessInfo.processInfo.environment["VOXSTEAD_TEST_AUDIO"])
        let locale = Locale(identifier: "en-US")
        let preset = SpeechCapture.livePreset(for: .meeting, phoneCall: phoneCall)
        #expect(preset.reportingOptions.contains(.volatileResults))
        #expect(preset.reportingOptions.contains(.fastResults))
        let transcriber = SpeechTranscriber(locale: locale, preset: preset)
        let format = try #require(await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]))
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        try await analyzer.prepareToAnalyze(in: format)
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        let feed = AudioFeed(format: format, continuation: continuation)
        let readPreview = Task { () throws -> String? in
            var queue = CaptionQueue()
            let translator = LocalCaptionTranslator(target: "es")
            for try await item in transcriber.results where !item.isFinal {
                let text = String(item.text.characters)
                guard text.localizedCaseInsensitiveContains("draft") else { continue }
                let segment = TranscriptSegment(time: item.range.start.seconds, source: .system, text: text)
                guard let work = queue.next(recentFinals: [], partials: [segment], at: .now) else { continue }
                if case let .translation(translated, _) = try await translator.translate(work, recognitionLanguage: "en-US") {
                    return translated
                }
            }
            return nil
        }
        let analyze = Task { try await analyzer.analyzeSequence(stream) }
        do {
            let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
            while file.framePosition < file.length {
                let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 2048))
                try file.read(into: buffer)
                feed.append(buffer)
                try await Task.sleep(for: .milliseconds(35))
            }
            feed.finish()
            if let end = try await analyze.value { try await analyzer.finalizeAndFinish(through: end) }
            else { await analyzer.cancelAndFinishNow() }
            let translation = try #require(try await readPreview.value)
            #expect(translation.localizedCaseInsensitiveContains("borrador"))
        } catch {
            feed.finish()
            analyze.cancel()
            readPreview.cancel()
            await analyzer.cancelAndFinishNow()
            throw error
        }
    }
}
