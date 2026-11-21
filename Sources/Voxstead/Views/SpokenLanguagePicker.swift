import Speech
import SwiftUI

struct SpokenLanguagePicker: View {
    @Binding var selection: String
    @State private var supported: [String] = []

    var body: some View {
        Picker("Spoken language", selection: $selection) {
            ForEach(Array(Set(supported + [selection])).sorted(), id: \.self) { code in
                Text(Self.name(for: code)).tag(code)
            }
        }
        .task { supported = await SpeechTranscriber.supportedLocales.map { $0.identifier(.bcp47) } }
    }

    static func name(for identifier: String) -> String {
        Locale(identifier: "en").localizedString(forIdentifier: identifier) ?? identifier
    }
}
