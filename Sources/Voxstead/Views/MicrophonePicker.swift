import SwiftUI

struct MicrophonePicker: View {
    @Binding var selection: String?
    @State private var devices: [MicrophoneDevice] = []
    @State private var defaultName: String?

    var body: some View {
        Picker("Microphone", selection: $selection) {
            Text(defaultName.map { "System default · \($0)" } ?? "System default")
                .tag(nil as String?)
            ForEach(devices) { device in
                Text(device.name).tag(Optional(device.id))
            }
            if let selection, !devices.contains(where: { $0.id == selection }) {
                Text("Selected microphone unavailable").tag(Optional(selection))
            }
        }
        .task {
            while !Task.isCancelled {
                let current = MicrophoneDevice.available()
                if devices != current { devices = current }
                let name = MicrophoneDevice.defaultName()
                if defaultName != name { defaultName = name }
                do { try await Task.sleep(for: .seconds(1)) }
                catch { return }
            }
        }
    }
}
