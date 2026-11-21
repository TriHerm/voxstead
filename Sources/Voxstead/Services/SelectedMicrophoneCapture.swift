import AVFoundation
import CoreMedia

/// Binds an audio-only capture session to the chosen input for its entire lifetime.
final class SelectedMicrophoneCapture: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    static let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000,
                                      channels: 1, interleaved: true)!

    private let device: AVCaptureDevice
    private let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "labs.triherm.voxstead.microphone.session", qos: .userInitiated)
    private let sampleQueue = DispatchQueue(label: "labs.triherm.voxstead.microphone.samples", qos: .userInitiated)
    private let receive: @Sendable (AVAudioPCMBuffer) -> Void

    init(device: AVCaptureDevice, receive: @escaping @Sendable (AVAudioPCMBuffer) -> Void) {
        self.device = device
        self.receive = receive
    }

    func start() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            sessionQueue.async {
                do {
                    let input = try AVCaptureDeviceInput(device: self.device)
                    guard self.session.canAddInput(input) else { throw self.unavailable }
                    self.session.addInput(input)

                    let output = AVCaptureAudioDataOutput()
                    output.audioSettings = Self.format.settings
                    guard self.session.canAddOutput(output) else { throw self.unavailable }
                    self.session.addOutput(output)
                    output.setSampleBufferDelegate(self, queue: self.sampleQueue)
                    self.session.startRunning()
                    guard self.session.isRunning, self.device.isConnected else { throw self.unavailable }
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: CaptureIssue(
                        kind: .microphone, message: "Could not start \(self.device.localizedName). \(error.localizedDescription)"
                    ))
                }
            }
        }
    }

    func isRunning() async -> Bool {
        await withCheckedContinuation { continuation in
            sessionQueue.async {
                continuation.resume(returning: self.session.isRunning && self.device.isConnected)
            }
        }
    }

    func stop() async {
        await withCheckedContinuation { continuation in
            sessionQueue.async {
                if self.session.isRunning { self.session.stopRunning() }
                self.sampleQueue.async { continuation.resume() }
            }
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sample: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let buffer = pcmBuffer(from: sample) else { return }
        receive(buffer)
    }

    private var unavailable: CaptureIssue {
        CaptureIssue(kind: .microphone, message: "Reconnect it or choose another input.")
    }
}

func pcmBuffer(from sample: CMSampleBuffer) -> AVAudioPCMBuffer? {
    guard sample.isValid, sample.numSamples > 0, let description = sample.formatDescription,
          let format = AVAudioFormat(cmAudioFormatDescription: description) as AVAudioFormat?,
          let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(sample.numSamples)) else { return nil }
    buffer.frameLength = AVAudioFrameCount(sample.numSamples)
    let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
        sample, at: 0, frameCount: Int32(sample.numSamples), into: buffer.mutableAudioBufferList
    )
    return status == noErr ? buffer : nil
}
