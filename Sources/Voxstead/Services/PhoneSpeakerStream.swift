import AVFoundation
import FluidAudio
import Foundation
import Synchronization

/// Each slot is scoped to this recording phase. The user assigns their own role in the live panel.
struct PhoneVoiceSpan: Equatable, Sendable {
    let slot: Int
    let start: Double
    let end: Double
}

struct PhoneSpeakerSnapshot: Equatable, Sendable {
    var through: Double = 0
    var voices: [PhoneVoiceSpan] = []

    var latest: PhoneVoiceSpan? { voices.max { $0.end < $1.end } }

    func speaker(from start: Double, to end: Double) -> Int? {
        let duration = end - start
        guard duration >= 0.12, through >= end - 0.20 else { return nil }
        var coverage: [Int: Double] = [:]
        for voice in voices {
            let overlap = min(voice.end, end) - max(voice.start, start)
            if overlap > 0 { coverage[voice.slot, default: 0] += overlap }
        }
        guard let best = coverage.max(by: { $0.value < $1.value }),
              best.value >= duration * 0.53,
              !coverage.contains(where: { $0.key != best.key && $0.value >= duration * 0.23 }) else { return nil }
        return best.key
    }

    func speaker(for segment: TranscriptSegment) -> Int? {
        guard let end = segment.endTime else { return nil }
        return speaker(from: segment.time, to: end)
    }
}

/// Moves a copy of the PCM to a background task. The callback never runs inference.
final class PhoneSpeakerStream: Sendable {
    struct Chunk: Sendable {
        let samples: [Float]
        let sampleRate: Double
        let start: Double
    }

    private struct Position {
        var seconds: Double = 0
        var ready = false
    }

    let chunks: AsyncThrowingStream<Chunk, Error>
    private let input: AsyncThrowingStream<Chunk, Error>.Continuation
    private let position = Mutex(Position())

    init() {
        (chunks, input) = AsyncThrowingStream.makeStream(bufferingPolicy: .bufferingOldest(96))
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        let count = Int(buffer.frameLength)
        let rate = buffer.format.sampleRate
        let start = position.withLock { state -> Double? in
            defer { state.seconds += Double(count) / rate }
            return state.ready ? state.seconds : nil
        }
        guard let start else { return }
        let stride = buffer.stride
        let samples: [Float]
        if let channel = buffer.floatChannelData?[0] {
            samples = (0..<count).map { channel[$0 * stride] }
        } else if let channel = buffer.int16ChannelData?[0] {
            samples = (0..<count).map { Float(channel[$0 * stride]) / 32_768 }
        } else if let channel = buffer.int32ChannelData?[0] {
            samples = (0..<count).map { Float(channel[$0 * stride]) / 2_147_483_648 }
        } else {
            input.finish(throwing: WorkspaceError("This microphone format could not be used for voice detection."))
            return
        }
        if case .dropped = input.yield(Chunk(samples: samples, sampleRate: rate, start: start)) {
            input.finish(throwing: WorkspaceError("Voice detection fell behind the microphone."))
        }
    }

    func finish() { input.finish() }

    // A dedicated worker owns the diarizer and its mutable Core ML buffers for this phase.
    nonisolated func detect(
        onReady: @Sendable () async -> Void,
        onUpdate: @Sendable (PhoneSpeakerSnapshot) async -> Void
    ) async throws {
        var config = SortformerConfig.fastV2_1
        config.precision = .palettized
        var timelineConfig = DiarizerTimelineConfig.default(
            numSpeakers: config.numSpeakers, frameDurationSeconds: config.frameDurationSeconds
        )
        timelineConfig.maxStoredFrames = 750
        let models = try await SortformerModels.loadFromHuggingFace(config: config)
        try Task.checkCancellation()
        let diarizer = SortformerDiarizer(config: config, timelineConfig: timelineConfig)
        diarizer.initialize(models: models)
        position.withLock { $0.ready = true }
        await onReady()
        var audioStart: Double?
        for try await chunk in chunks {
            try Task.checkCancellation()
            let start = audioStart ?? chunk.start
            audioStart = start
            guard try diarizer.process(samples: chunk.samples, sourceSampleRate: chunk.sampleRate) != nil else { continue }
            let timeline = diarizer.timeline
            let through = Double(timeline.numFrames) * Double(config.frameDurationSeconds)
            var voices: [PhoneVoiceSpan] = []
            for speaker in timeline.speakers.values {
                let segments = Array(speaker.finalizedSegments.suffix(24)) + speaker.tentativeSegments
                for segment in segments where Double(segment.endTime) > through - 45 {
                    let span = PhoneVoiceSpan(slot: segment.speakerIndex, start: start + Double(segment.startTime),
                                              end: start + Double(segment.endTime))
                    if let previous = voices.last, previous.slot == span.slot, span.start <= previous.end + 0.01 {
                        voices[voices.count - 1] = PhoneVoiceSpan(slot: span.slot, start: previous.start,
                                                               end: max(previous.end, span.end))
                    } else {
                        voices.append(span)
                    }
                }
            }
            await onUpdate(PhoneSpeakerSnapshot(through: start + through, voices: voices))
        }
    }
}
