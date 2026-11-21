import Foundation

enum SpeechVocabulary {
    static func clean(_ entries: [String], limit: Int = 100) -> [String] {
        var seen: Set<String> = []
        var terms: [String] = []
        for entry in entries {
            if terms.count >= limit { break }
            let clean = String(entry.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
            if !clean.isEmpty, seen.insert(clean.lowercased()).inserted { terms.append(clean) }
        }
        return terms
    }

    static func meetingTerms(from input: String) -> [String] {
        clean(input.split { $0.isNewline || $0 == "," }.map(String.init), limit: 30)
    }
}
