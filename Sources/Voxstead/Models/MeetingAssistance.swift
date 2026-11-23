import Foundation

/// Optional per-meeting preferences preserve compatibility with existing saved sessions.
struct MeetingAssistance: Codable, Sendable, Equatable {
    var mode: Mode = .conversation
    var explanationLanguage = "English"
    var replyLanguage: String?
    var replyMeaning: Bool?
    var translateCaptions: Bool?
    var preparation: String?
    var speechTerms: [String]?
    var phoneCall: Bool?
    var automaticPhoneReplies: Bool?
    var callerName: String?

    var isPhoneCall: Bool { phoneCall == true }

    var showsReplyMeaning: Bool { replyMeaning ?? (mode == .languageSupport) }

    enum Mode: String, Codable, CaseIterable, Identifiable, Sendable {
        case conversation, languageSupport, interview
        var id: String { rawValue }
        var title: String {
            switch self {
            case .conversation: "Conversation"
            case .languageSupport: "Language support"
            case .interview: "Interview practice"
            }
        }

        var detail: String {
            switch self {
            case .conversation: "Suggests a natural reply for an everyday meeting."
            case .languageSupport: "Helps you understand and reply in another language."
            case .interview: "Helps you frame an answer using the experience you provide."
            }
        }
    }

    static let transcriptLanguageRule = """
    Write natural-language output in the language spoken in the transcript, not the language of these instructions or UI labels.
    For mixed-language conversations, follow the latest substantive speaker turn for live replies and Catch me up, and the predominant language for saved summaries.
    Summary and Catch me up must stay in the spoken language, even when the question, interface, prior answers, or preferred explanation language are English.
    Keep JSON keys unchanged and preserve exact quotations in their original language. If the language is unclear, do not guess facts.
    """

    var liveInstruction: String {
        switch mode {
        case .conversation:
            return Self.transcriptLanguageRule
        case .languageSupport:
            return Self.transcriptLanguageRule + """
            \nHelp the user participate in a language they are learning. Give any suggested sentence first in the language being spoken.
            Then give a short translation and a plain-language explanation in this preferred language: \(explanationLanguage.prefix(80)).
            Keep Catch me up and summaries in the spoken language without translating them. Only translate a recap when the user explicitly requests translation.
            Clearly separate suggested wording from its translated meaning. Use the preferred explanation language for an explicit request to explain the latest speech.
            Do not invent what the user knows or intends. Flag unclear transcript wording instead of presenting a guess as a reliable translation.
            """
        case .interview:
            return Self.transcriptLanguageRule + """
            \nAct as an interview practice coach. Identify what the question is asking and suggest a concise answer structure.
            Use only experience or achievements the user has actually supplied. If details are missing, suggest a clarifying question
            or a clearly marked placeholder. Never invent credentials, personal experience, employers, or results.
            """
        }
    }
}
