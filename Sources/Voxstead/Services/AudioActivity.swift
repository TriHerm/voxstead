import AVFoundation
import Foundation

enum AudioActivity: Equatable, Sendable {
    case waiting, quiet, signal

    var title: String {
        switch self {
        case .waiting: "Waiting for audio"
        case .quiet: "Quiet"
        case .signal: "Signal detected"
        }
    }
}

/// Records the start of the input and the latest activity.
final class AudioActivityMeter: @unchecked Sendable {
    private let lock = NSLock()
    private var firstBuffer: ContinuousClock.Instant?
    private var lastBuffer: ContinuousClock.Instant?
    private var lastSignal: ContinuousClock.Instant?

    var startTime: ContinuousClock.Instant? { lock.withLock { firstBuffer } }
    var signalTime: ContinuousClock.Instant? { lock.withLock { lastSignal } }

    func receive(_ buffer: AVAudioPCMBuffer, at time: ContinuousClock.Instant = .now) {
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return }
        let hasSignal = Self.hasSignal(buffer, frames: frames)
        lock.withLock {
            if firstBuffer == nil { firstBuffer = time }
            lastBuffer = time
            if hasSignal { lastSignal = time }
        }
    }

    func activity(at time: ContinuousClock.Instant = .now) -> AudioActivity {
        lock.withLock {
            guard let lastBuffer, time - lastBuffer <= .seconds(2) else { return .waiting }
            if let lastSignal, time - lastSignal <= .milliseconds(850) { return .signal }
            return .quiet
        }
    }

    private static func hasSignal(_ buffer: AVAudioPCMBuffer, frames: Int) -> Bool {
        let step = max(1, frames / 64)
        let channels = Int(buffer.format.channelCount)
        let interleaved = buffer.format.isInterleaved
        let sampleStride = buffer.stride
        for channel in 0..<channels {
            let plane = interleaved ? 0 : channel
            let offset = interleaved ? channel : 0
            for frame in stride(from: 0, to: frames, by: step) {
                let index = frame * sampleStride + offset
                if let samples = buffer.floatChannelData {
                    if abs(samples[plane][index]) >= 0.008 { return true }
                } else if let samples = buffer.int16ChannelData {
                    if abs(Int(samples[plane][index])) >= 262 { return true }
                } else if let samples = buffer.int32ChannelData {
                    if abs(Int64(samples[plane][index])) >= 17_179_869 { return true }
                }
            }
        }
        return false
    }
}

struct CaptureIssue: LocalizedError, Sendable {
    enum Kind: Sendable { case microphone, macAudio, transcription, gap }
    let kind: Kind
    let message: String
    var errorDescription: String? { message }
}
