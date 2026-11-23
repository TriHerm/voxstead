import Foundation

enum ConversationPhrase: String, CaseIterable, Identifiable {
    case pause = "Ask for a moment"
    case slower = "Ask them to slow down"
    case repeatLast = "Ask them to repeat"
    case clarify = "Ask for an example"

    var id: Self { self }
    static let languages = ["en", "es", "fr", "pt", "de"]

    func text(in code: String) -> String? {
        let translations: [String: String]
        switch self {
        case .pause:
            translations = ["en": "Could you give me a moment to think?", "es": "¿Me das un momento para pensar?",
                            "fr": "Vous pouvez me laisser un instant pour réfléchir ?", "pt": "Pode me dar um momento para pensar?",
                            "de": "Könnten Sie mir einen Moment zum Nachdenken geben?"]
        case .slower:
            translations = ["en": "Could you speak a little more slowly?", "es": "¿Puedes hablar un poco más despacio?",
                            "fr": "Vous pourriez parler un peu plus lentement ?", "pt": "Pode falar um pouco mais devagar?",
                            "de": "Könnten Sie etwas langsamer sprechen?"]
        case .repeatLast:
            translations = ["en": "Could you repeat that last part?", "es": "¿Puedes repetir la última parte?",
                            "fr": "Vous pourriez répéter la dernière partie ?", "pt": "Pode repetir a última parte?",
                            "de": "Könnten Sie den letzten Teil wiederholen?"]
        case .clarify:
            translations = ["en": "Could you give me an example?", "es": "¿Me puedes dar un ejemplo?",
                            "fr": "Vous pourriez me donner un exemple ?", "pt": "Pode me dar um exemplo?",
                            "de": "Könnten Sie mir ein Beispiel geben?"]
        }
        return translations[code]
    }
}
