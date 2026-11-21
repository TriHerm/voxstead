import Foundation

enum SessionKind: String, Codable, CaseIterable, Sendable {
    case dictation, meeting
    var title: String { self == .dictation ? "Dictation" : "Meeting" }
    var icon: String { self == .dictation ? "mic" : "person.2" }
}

enum AudioSource: String, Codable, Sendable {
    case microphone, system
    var title: String { self == .microphone ? "Microphone" : "Mac audio" }
}

struct TranscriptSegment: Codable, Identifiable, Sendable {
    var id = UUID()
    var time: Double
    var source: AudioSource
    var text: String
    var speaker: String?
    var endTime: Double?

    func replacesPreview(_ preview: Self) -> Bool {
        guard source == preview.source else { return false }
        return preview.time <= time || preview.time < (endTime ?? time)
    }

    var timestamp: String {
        let seconds = time.isFinite ? Int(max(0, min(time, 360_000))) : 0
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
}

struct Exchange: Codable, Identifiable, Sendable {
    var id = UUID()
    var prompt: String
    var answer: String
    var provider: String
    var replySuggestion: ReplySuggestion?

    var answerWithMeaning: String {
        guard let meaning = replySuggestion?.meaning else { return answer }
        return "\(answer)\n\n\(meaning)"
    }
}

struct VoiceSession: Codable, Identifiable, Sendable {
    var id = UUID()
    var kind: SessionKind
    var title: String
    var created = Date()
    var segments: [TranscriptSegment] = []
    var exchanges: [Exchange] = []
    var meeting: MeetingDetails?
    var processedDictation: String?
    var folderID: UUID?
    var debriefTemplate: DebriefTemplate?

    var transcript: String {
        if kind == .dictation {
            return segments.map(\.text).joined(separator: " ")
        }
        return segments.sorted { $0.time < $1.time }.map {
            let speaker = $0.speaker.map { " (\($0))" } ?? ""
            return "[\($0.timestamp)] \($0.source.title)\(speaker): \($0.text)"
        }.joined(separator: "\n")
    }

    var markdown: String {
        var output = "# \(title)\n\n\(created.formatted(date: .long, time: .shortened))\n\n## Transcript\n\n\(transcript)\n"
        if let processedDictation {
            output += "\n## Dictation output\n\n\(processedDictation)\n"
        }
        if let meeting {
            if !meeting.notes.isEmpty { output += "\n## Notes\n\n\(meeting.notes)\n" }
            if !meeting.summary.isEmpty { output += "\n## Summary\n\n\(meeting.summary)\n" }
            if !meeting.decisions.isEmpty {
                let heading = meeting.assistance?.isPhoneCall == true ? "Agreements" : "Decisions"
                output += "\n## \(heading)\n\n" + meeting.decisions.map { "- " + $0 }.joined(separator: "\n") + "\n"
            }
            if let dates = meeting.recapDates, !dates.isEmpty {
                output += "\n## Dates\n\n" + dates.map { "- \($0)" }.joined(separator: "\n") + "\n"
            }
            if let requirements = meeting.openRequirements, !requirements.isEmpty {
                output += "\n## Open requirements\n\n" + requirements.map { "- \($0)" }.joined(separator: "\n") + "\n"
            }
            if !meeting.actions.isEmpty {
                output += "\n## Action items\n\n"
                for item in meeting.actions {
                    let details = [item.owner, item.due].filter { !$0.isEmpty }.joined(separator: " · ")
                    output += "- [\(item.complete ? "x" : " ")] \(item.title)\(details.isEmpty ? "" : " · " + details)\n"
                }
            }
        }
        if let note = meeting?.coaching.last {
            output += "\n## Coach: \(note.habit)\n\n\(note.observation)\n"
            if !note.quote.isEmpty { output += "\n> \(note.quote)\n" }
            if !note.suggestion.isEmpty { output += "\nTry saying: \(note.suggestion)\n" }
        }
        for exchange in exchanges {
            output += "\n## \(exchange.prompt)\n\n\(exchange.answerWithMeaning)\n"
        }
        return output
    }
}

enum ProviderKind: String, Codable, CaseIterable, Sendable {
    case openAI, anthropic, gemini, openRouter, ollama, compatible, chatGPT

    var title: String {
        switch self {
        case .chatGPT: "ChatGPT plan"
        case .openAI: "OpenAI"
        case .anthropic: "Anthropic"
        case .gemini: "Google Gemini"
        case .openRouter: "OpenRouter"
        case .ollama: "Ollama"
        case .compatible: "OpenAI-compatible"
        }
    }

    var baseURL: String {
        switch self {
        case .chatGPT: "https://api.openai.com/v1"
        case .openAI: "https://api.openai.com/v1"
        case .anthropic: "https://api.anthropic.com/v1"
        case .gemini: "https://generativelanguage.googleapis.com/v1beta/openai"
        case .openRouter: "https://openrouter.ai/api/v1"
        case .ollama: "http://localhost:11434/v1"
        case .compatible: ""
        }
    }

    var requiresKey: Bool { self != .ollama && self != .compatible && self != .chatGPT }
}

struct ProviderProfile: Codable, Identifiable, Hashable, Sendable {
    var id = UUID()
    var kind: ProviderKind = .openAI
    var name = "OpenAI"
    var endpoint = ProviderKind.openAI.baseURL
    var model = ""
}

enum MCPTransportKind: String, Codable, CaseIterable, Sendable {
    case stdio, http
    var title: String { self == .stdio ? "Local process (stdio)" : "Streamable HTTP" }
}

struct ServerProfile: Codable, Identifiable, Sendable {
    var id = UUID()
    var name = ""
    var transport: MCPTransportKind = .stdio
    var address = ""
    var arguments: [String] = []
    var environmentName: String?
    var enabled = false
}

enum SettingsPage: String, CaseIterable {
    case general = "General", recording = "Recording", providers = "AI providers"
    case personalize = "Personalize", tools = "Tools"
}

struct WorkspaceSettings: Codable {
    var guideDismissed: Bool?
    var guideStep: Int?
    var preferredProviderID: UUID?
    var locale = "en-US"
    var dictationLocale: String?
    var insertDictation: Bool?
    var translationLanguage: String?
    var meetingCaptionLanguage: String?
    var speechVocabulary: [String]?
    var microphoneID: String?
    var personas: [WritingPersona]?
    var prompts: [QuickPrompt]?
    var coachingHabit: String?
    var autoDebrief: Bool?
    var autoCoach: Bool?
    var includeSystemAudio = false
    var copyDictation = true
    var providers: [ProviderProfile] = []
    var servers: [ServerProfile] = []
}

struct SessionFolder: Codable, Identifiable, Sendable {
    var id = UUID()
    var name: String
}

enum DebriefTemplate: String, Codable, CaseIterable, Identifiable, Sendable {
    case general = "General"
    case followUp = "Follow-up"
    case interview = "Interview"

    var id: String { rawValue }

    var focus: String {
        switch self {
        case .general: "Focus on the main discussion, decisions, and next steps."
        case .followUp: "Focus on commitments, overdue or blocked work, and next steps with explicitly stated owners and dates."
        case .interview: "Focus on questions asked, experience explicitly described, and agreed next steps. Do not infer qualifications or make a hiring recommendation."
        }
    }
}

struct WorkspaceDocument: Codable {
    var sessions: [VoiceSession] = []
    var settings = WorkspaceSettings()
    var libraryExchanges: [LibraryExchange]?
    var folders: [SessionFolder]?
}

struct WorkspaceError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

func validatedEndpoint(_ input: String) throws -> URL {
    guard let parts = URLComponents(string: input),
          let url = parts.url, let host = parts.host?.lowercased(),
          !host.isEmpty, parts.user == nil, parts.password == nil, parts.fragment == nil
    else { throw WorkspaceError("Enter a valid URL without embedded credentials.") }
    let local = ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host)
    guard parts.scheme?.lowercased() == "https" || (local && parts.scheme?.lowercased() == "http") else {
        throw WorkspaceError("Use HTTPS for remote endpoints. Localhost also supports HTTP.")
    }
    return url
}
