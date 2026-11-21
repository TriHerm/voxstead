import Foundation
import Observation

/// Runs the same audio setup as a meeting, without creating a library session.
@MainActor @Observable
final class MeetingAudioCheck {
    private(set) var isRunning = false
    private(set) var isListening = false
    private(set) var message: String?
    private(set) var speechPreview: [AudioSource: String] = [:]
    @ObservationIgnored private var capture: SpeechCapture?
    @ObservationIgnored private var task: Task<Void, Never>?

    func start(locale: String, systemAudio: Bool, target: String?, microphoneID: String?,
               vocabulary: [String], phoneCall: Bool = false) {
        guard task == nil else { return }
        let service = SpeechCapture()
        capture = service
        isRunning = true
        message = "Preparing audio check…"
        speechPreview = [:]
        let onFailure: @MainActor @Sendable (CaptureIssue) -> Void = { [weak self] issue in
            guard issue.kind != .gap, let self, self.isRunning else { return }
            self.message = issue.message
            self.stop()
        }
        task = Task { [self, service] in
            var receivedMic = false
            var receivedMacAudio = false
            defer {
                capture = nil
                isRunning = false
                isListening = false
                task = nil
            }
            do {
                try await service.start(locale: Locale(identifier: locale), systemAudio: systemAudio,
                                        targetBundle: target, microphoneID: microphoneID, vocabulary: vocabulary,
                                        phoneCall: phoneCall,
                                        onUpdate: { [weak self, weak service] segment, _ in
                    guard let self, let service, !segment.text.isEmpty, self.capture === service else { return }
                    self.speechPreview[segment.source] = String(segment.text.suffix(160))
                }, onFailure: onFailure)
                try Task.checkCancellation()
                isListening = true
                message = systemAudio ? "Speak and play audio in the selected app."
                    : phoneCall ? "Play speech on the phone speaker and check what Voxstead hears."
                    : "Speak to check your microphone."
                let end = ContinuousClock.now + .seconds(12)
                while ContinuousClock.now < end {
                    receivedMic = receivedMic || service.activity(for: .microphone) == .signal
                    receivedMacAudio = receivedMacAudio || service.activity(for: .system) == .signal
                    try await Task.sleep(for: .milliseconds(150))
                }
                let name = service.microphoneName ?? "Microphone"
                let mic = receivedMic ? "Signal detected on \(name)." : "No signal detected on \(name)."
                let mac = receivedMacAudio ? "Mac audio signal detected." : "No Mac audio signal detected."
                if speechPreview.isEmpty && (receivedMic || receivedMacAudio) {
                    message = (systemAudio ? "\(mic) \(mac)" : mic) + " If you were speaking, check the spoken language and try again."
                } else {
                    message = systemAudio ? "\(mic) \(mac)" : mic
                }
            } catch {
                if !Task.isCancelled { message = error.localizedDescription }
            }
            isListening = false
            await service.cancel()
        }
    }

    func stop() { task?.cancel() }

    func dismiss() {
        stop()
        capture = nil
        speechPreview = [:]
        message = nil
    }

    func stopAndWait() async {
        task?.cancel()
        await task?.value
    }

    func cancelByUser() {
        if isRunning { message = "Audio check stopped." }
        stop()
    }

    func clearResult() {
        if !isRunning {
            message = nil
            speechPreview = [:]
        }
    }

    func activity(for source: AudioSource) -> AudioActivity {
        capture?.activity(for: source) ?? .waiting
    }
}
