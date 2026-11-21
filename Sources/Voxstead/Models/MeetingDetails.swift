import Foundation
import NaturalLanguage

struct ActionItem: Codable, Identifiable, Sendable {
    var id = UUID()
    var title: String
    var owner = ""
    var due = ""
    var complete = false
    var generated: Bool?

    static func reconcile(
        _ current: [ActionItem], with draft: [DebriefDraft.Task], submitted: [ActionItem]? = nil
    ) -> [ActionItem] {
        let previous = submitted ?? current
        let retained = current.filter { $0.generated != true || $0.complete }
        let retainedIDs = Set(retained.map(\.id))
        var usedTitles = Set(retained.map { normalizedTitle($0.title) })
        var usedIDs = retainedIDs
        var refreshed: [ActionItem] = []

        for task in draft.prefix(24) {
            let title = task.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = normalizedTitle(title)
            guard !key.isEmpty, !usedTitles.contains(key) else { continue }

            let exact = current.first { normalizedTitle($0.title) == key }
                ?? previous.first { normalizedTitle($0.title) == key }
            let reportedID = task.existingTaskID.flatMap(UUID.init(uuidString:))
            let matchID = exact?.id ?? previous.first { $0.id == reportedID }?.id
            if let matchID {
                // Ignore a response for a task the user removed while the request was running.
                guard current.contains(where: { $0.id == matchID }), usedIDs.insert(matchID).inserted else { continue }
            }
            usedTitles.insert(key)
            refreshed.append(ActionItem(id: matchID ?? UUID(), title: title,
                                        owner: task.owner ?? "", due: task.due ?? "", generated: true))
        }
        return retained + refreshed
    }

    private static func normalizedTitle(_ title: String) -> String {
        title.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
            .split { !$0.isLetter && !$0.isNumber }.joined(separator: " ")
    }
}

struct CoachingNote: Codable, Sendable, Identifiable {
    var id = UUID()
    var habit: String
    var observation: String
    var quote: String
    var suggestion: String
    var provider: String
}

struct MeetingDetails: Codable, Sendable {
    var assistance: MeetingAssistance?
    var notes = ""
    var summary = ""
    var decisions: [String] = []
    var actions: [ActionItem] = []
    var coaching: [CoachingNote] = []
    var cardHistory: [TrackedLiveCard]?
    var catchUpCheckpoint: MeetingCatchUpCheckpoint?
    var recapDates: [String]?
    var openRequirements: [String]?
}

struct LiveCard: Codable, Sendable, Identifiable {
    var id: String { evidence + heading }
    let heading: String
    let detail: String
    let evidence: String
}

struct TrackedLiveCard: Codable, Identifiable, Sendable {
    enum Status: String, Codable, Sendable {
        case pending = "Pending"
        case resolved = "Resolved"
        case dismissed = "Dismissed"
    }
    let id: String
    var card: LiveCard
    let discovered: Date
    let timestamp: String
    var status: Status = .pending

    var sourceSegmentID: UUID? {
        guard let source = id.split(separator: ":", maxSplits: 1).first else { return nil }
        return UUID(uuidString: String(source))
    }
}

struct QuickPrompt: Codable, Identifiable, Sendable {
    var id = UUID()
    var label: String
    var instruction: String

    static let presets = [
        QuickPrompt(label: "What should I say?", instruction: "Suggest one natural sentence to say next, based on what was just discussed."),
        QuickPrompt(label: "Catch me up", instruction: "Catch me up on what has happened so far, including any decisions and open questions.")
    ]
}

struct WritingPersona: Codable, Identifiable, Sendable {
    var id: UUID { profileID }
    var profileID = UUID()
    var bundleID = ""
    var instructions = ""
}

struct LibraryExchange: Codable, Identifiable, Sendable {
    struct Source: Codable, Identifiable, Sendable {
        struct Excerpt: Codable, Identifiable, Sendable {
            let id: UUID
            let timestamp: String
        }
        let id: UUID
        let title: String
        var excerpts: [Excerpt]?
    }
    var id = UUID()
    let prompt: String
    let answer: String
    let provider: String
    let sources: [Source]
}

struct LibraryContext: Sendable {
    let sources: [VoiceSession]
    let text: String
    let citations: [LibraryExchange.Source]

    static func build(question: String, sessions: [VoiceSession]) -> LibraryContext {
        let stop: Set<String> = [
            "about", "across", "and", "are", "call", "calls", "did", "for", "from", "have", "meeting", "meetings",
            "said", "show", "that", "the", "there", "they", "this", "was", "were", "what", "when", "where", "which",
            "will", "with", "you", "como", "con", "cual", "cuando", "del", "donde", "esta", "las", "los", "para",
            "por", "que", "quien", "una"
        ]
        let terms = Set(tokens(question).filter { !stop.contains($0) })
        let meetings = sessions.filter { $0.kind == .meeting && !$0.segments.isEmpty }
        let scored: [(session: VoiceSession, score: Int)] = meetings.map { session in
            let words = session.segments.flatMap { tokens($0.text) } + tokens(session.meeting?.notes ?? "")
            let transcriptMatches = terms.intersection(words).count
            let titleMatches = terms.intersection(tokens(session.title)).count
            return (session, transcriptMatches + 3 * titleMatches)
        }
        let ranked = scored.sorted { left, right in
            if left.score == right.score { return left.session.created > right.session.created }
            return left.score > right.score
        }
        let matches = ranked.filter { $0.score > 0 }
        let sources = (matches.isEmpty ? ranked : matches).prefix(8).map { $0.session }
        var citations: [LibraryExchange.Source] = []
        let context = sources.enumerated().map { index, session in
            let ordered = session.segments.sorted { $0.time < $1.time }
            let relevant = ordered.indices.filter { i in !terms.isDisjoint(with: tokens(ordered[i].text)) }
            var lines: [String] = []
            if let notes = session.meeting?.notes, !notes.isEmpty {
                lines.append("User notes: " + excerpt(notes, terms: terms, limit: 1_500))
            }
            var size = lines.joined().count
            var seen: Set<Int> = []
            var excerpts: [LibraryExchange.Source.Excerpt] = []
            let chosen = relevant.isEmpty ? Array(ordered.indices) : relevant.flatMap { [$0 - 1, $0, $0 + 1] }
            for i in chosen where ordered.indices.contains(i) && seen.insert(i).inserted && size < 6_000 {
                let segment = ordered[i]
                let text = excerpt(segment.text, terms: terms, limit: min(1_200, 6_000 - size))
                lines.append("[\(segment.timestamp)] \(segment.source.title): \(text)")
                excerpts.append(.init(id: segment.id, timestamp: segment.timestamp))
                size += text.count
            }
            citations.append(.init(id: session.id, title: session.title, excerpts: excerpts))
            return "[\(index + 1)] \(session.title)\n\(lines.joined(separator: "\n"))"
        }.joined(separator: "\n\n")
        return LibraryContext(sources: sources, text: context, citations: citations)
    }

    private static func tokens(_ text: String) -> [String] {
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = text
        return tokenizer.tokens(for: text.startIndex..<text.endIndex)
            .map { normalized(String(text[$0])) }
            .filter { $0.count >= 3 || $0.unicodeScalars.contains { $0.value > 0x2ff } }
    }

    private static func normalized(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }

    private static func excerpt(_ text: String, terms: Set<String>, limit: Int) -> String {
        guard text.count > limit else { return text }
        let hit = terms.sorted().compactMap {
            text.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive])?.lowerBound
        }.min() ?? text.startIndex
        let from = text.index(hit, offsetBy: -min(180, limit / 3), limitedBy: text.startIndex) ?? text.startIndex
        return (from == text.startIndex ? "" : "…") + String(text[from...].prefix(limit)) + "…"
    }
}

func quoteAppears(_ quote: String, in transcript: String) -> Bool {
    let clean = quote.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    let text = transcript.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    return clean.count >= 8 && text.range(of: clean, options: [.caseInsensitive, .diacriticInsensitive]) != nil
}
