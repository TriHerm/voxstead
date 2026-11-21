import AudioToolbox
import AVFoundation
import Foundation

struct WhisperEngine: Sendable {
    private let executable: URL
    private let model: URL

    static let directory = URL.applicationSupportDirectory.appending(path: "Voxstead/Speech")

    static var installed: WhisperEngine? {
        let executable = directory.appending(path: "whisper-cli-v1.9.5")
        let model = directory.appending(path: "ggml-base.bin")
        guard FileManager.default.isExecutableFile(atPath: executable.path),
              FileManager.default.isReadableFile(atPath: model.path) else { return nil }
        return WhisperEngine(executable: executable, model: model)
    }

    static func scratchDirectory() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appending(path: "voxstead-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        return folder
    }

    func transcribe(_ audio: URL, convert: Bool) async throws -> [TranscriptSegment] {
        let folder = try Self.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let input: URL
        if convert {
            input = folder.appending(path: "input.wav")
            try await Self.run(URL(fileURLWithPath: "/usr/bin/afconvert"),
                               ["-f", "WAVE", "-d", "LEI16@16000", "-c", "1", audio.path, input.path])
        } else {
            input = audio
        }
        let base = folder.appending(path: "out")
        try await Self.run(executable, ["-m", model.path, "-f", input.path, "-l", "auto", "-oj",
                                        "-of", base.path, "-sns", "-t", "4"])
        let report = try JSONDecoder().decode(Report.self, from: Data(contentsOf: base.appendingPathExtension("json")))
        return report.transcription.compactMap {
            let text = $0.text.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : TranscriptSegment(time: Double($0.offsets.from) / 1000, source: .microphone, text: text)
        }
    }

    private struct Report: Decodable {
        struct Entry: Decodable {
            struct Offsets: Decodable { let from: Int }
            let offsets: Offsets
            let text: String
        }
        let transcription: [Entry]
    }

    private static func run(_ executable: URL, _ arguments: [String]) async throws {
        let child = Process()
        child.executableURL = executable
        child.arguments = arguments
        child.standardOutput = FileHandle.nullDevice
        child.standardError = FileHandle.nullDevice
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                child.terminationHandler = { process in
                    if process.terminationStatus == 0 {
                        continuation.resume()
                    } else {
                        continuation.resume(throwing: WorkspaceError("\(executable.lastPathComponent) could not process this audio."))
                    }
                }
                do {
                    try Task.checkCancellation()
                    try child.run()
                    if Task.isCancelled, child.isRunning { child.terminate() }
                } catch { continuation.resume(throwing: error) }
            }
        } onCancel: {
            if child.isRunning { child.terminate() }
        }
        try Task.checkCancellation()
    }
}

@MainActor
final class WhisperRecording {
    private let folder: URL
    private let recorder: AVAudioRecorder?
    private let inputFile: WhisperInputFile?
    private let audioURL: URL
    private let engine: WhisperEngine

    init(engine: WhisperEngine, inputFormat: AVAudioFormat? = nil) throws {
        self.engine = engine
        let folder = try WhisperEngine.scratchDirectory()
        self.folder = folder
        do {
            if let inputFormat {
                audioURL = folder.appending(path: "dictation.caf")
                recorder = nil
                inputFile = try WhisperInputFile(url: audioURL, inputFormat: inputFormat)
            } else {
                audioURL = folder.appending(path: "dictation.wav")
                inputFile = nil
                let recording = try AVAudioRecorder(url: audioURL, settings: [
                    AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16_000.0, AVNumberOfChannelsKey: 1,
                    AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false
                ])
                guard recording.record() else { throw WorkspaceError("Could not start the microphone.") }
                recorder = recording
            }
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
    }

    var microphoneReceiver: (@Sendable (AVAudioPCMBuffer) -> Void)? {
        guard let inputFile else { return nil }
        return inputFile.append
    }

    func finish() async throws -> [TranscriptSegment] {
        recorder?.stop()
        defer { try? FileManager.default.removeItem(at: folder) }
        try inputFile?.finish()
        return try await engine.transcribe(audioURL, convert: inputFile != nil)
    }

    func discard() {
        recorder?.stop()
        try? inputFile?.finish()
        try? FileManager.default.removeItem(at: folder)
    }
}

/// Records a routed microphone for Whisper using Audio Toolbox's buffered file writer.
final class WhisperInputFile: @unchecked Sendable {
    private let lock = NSLock()
    private let inputFormat: AVAudioFormat
    private var file: ExtAudioFileRef?
    private var writeStatus: OSStatus = noErr

    init(url: URL, inputFormat: AVAudioFormat) throws {
        self.inputFormat = inputFormat
        guard let destination = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: inputFormat.sampleRate,
                                              channels: inputFormat.channelCount, interleaved: true) else {
            throw WorkspaceError("The selected microphone has an unsupported recording format.")
        }
        var description = destination.streamDescription.pointee
        var output: ExtAudioFileRef?
        try Self.check(ExtAudioFileCreateWithURL(url as CFURL, kAudioFileCAFType, &description, nil,
                                                 AudioFileFlags.eraseFile.rawValue, &output))
        guard let output else { throw WorkspaceError("Could not create the dictation recording.") }
        do {
            var input = inputFormat.streamDescription.pointee
            try Self.check(ExtAudioFileSetProperty(output, kExtAudioFileProperty_ClientDataFormat,
                                                   UInt32(MemoryLayout.size(ofValue: input)), &input))
            // Preallocate the async writer before the recording callback runs.
            try Self.check(ExtAudioFileWriteAsync(output, 0, nil))
            file = output
        } catch {
            _ = ExtAudioFileDispose(output)
            throw error
        }
    }

    deinit { try? finish() }

    func append(_ buffer: AVAudioPCMBuffer) {
        lock.withLock {
            guard let file, writeStatus == noErr, buffer.frameLength > 0 else { return }
            guard buffer.format == inputFormat else {
                writeStatus = kAudioFileUnsupportedDataFormatError
                return
            }
            writeStatus = ExtAudioFileWriteAsync(file, buffer.frameLength, buffer.audioBufferList)
        }
    }

    func finish() throws {
        let (output, status) = lock.withLock {
            let result = (file, writeStatus)
            file = nil
            return result
        }
        if let output {
            let finalStatus = ExtAudioFileDispose(output)
            try Self.check(status)
            try Self.check(finalStatus)
        }
    }

    private static func check(_ status: OSStatus) throws {
        guard status == noErr else { throw WorkspaceError("Could not write the microphone recording (Core Audio \(status)).") }
    }
}
