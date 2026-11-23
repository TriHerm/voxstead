import AVFoundation
import SwiftUI

struct ConversationPhrasesView: View {
    let practice: Bool
    @State private var spoken: String
    @State private var meaning: String
    @State private var phrase = ConversationPhrase.pause
    @State private var synthesizer: AVSpeechSynthesizer?

    init(spoken: String?, meaning: String?, practice: Bool = false) {
        self.practice = practice
        _spoken = State(initialValue: spoken.flatMap { ConversationPhrase.languages.contains($0) ? $0 : nil } ?? "en")
        _meaning = State(initialValue: meaning.flatMap { ConversationPhrase.languages.contains($0) ? $0 : nil } ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(practice ? "Practice a phrase" : "Quick phrases").font(.headline)
            Picker("Say it in", selection: $spoken) { languageChoices }
            Picker("Show meaning in", selection: $meaning) {
                Text("Hide meaning").tag("")
                languageChoices
            }
            Picker("What you want to do", selection: $phrase) {
                ForEach(ConversationPhrase.allCases) { Text($0.rawValue).tag($0) }
            }
            if let text = phrase.text(in: spoken) {
                Text(text).font(.title3.weight(.semibold)).textSelection(.enabled)
                if spoken != meaning, let translation = phrase.text(in: meaning) {
                    Text(translation).foregroundStyle(.secondary).textSelection(.enabled)
                }
                if practice {
                    Button("Listen slowly", systemImage: "speaker.wave.2") {
                        let player = synthesizer ?? AVSpeechSynthesizer()
                        synthesizer = player
                        player.stopSpeaking(at: .immediate)
                        let utterance = AVSpeechUtterance(string: text)
                        utterance.voice = AVSpeechSynthesisVoice(language: spoken)
                        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 0.82
                        player.speak(utterance)
                    }
                }
            }
        }
        .onDisappear { synthesizer?.stopSpeaking(at: .immediate) }
        .onChange(of: spoken) { synthesizer?.stopSpeaking(at: .immediate) }
        .onChange(of: phrase) { synthesizer?.stopSpeaking(at: .immediate) }
    }

    private var languageChoices: some View {
        ForEach(ConversationPhrase.languages, id: \.self) { code in
            Text(Locale(identifier: "en").localizedString(forLanguageCode: code) ?? code).tag(code)
        }
    }
}
