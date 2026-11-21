import AVFoundation

struct MicrophoneDevice: Equatable, Identifiable, Sendable {
    let id: String
    let name: String

    static func available() -> [Self] {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external], mediaType: .audio,
                                         position: .unspecified).devices
            .map { Self(id: $0.uniqueID, name: $0.localizedName) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    static func defaultName() -> String? {
        AVCaptureDevice.default(for: .audio)?.localizedName
    }

    static func captureDevice(for id: String) throws -> AVCaptureDevice {
        guard let device = AVCaptureDevice(uniqueID: id), device.hasMediaType(.audio), device.isConnected else {
            throw CaptureIssue(kind: .microphone, message: "The selected microphone is unavailable. Reconnect it or choose another input.")
        }
        return device
    }
}
