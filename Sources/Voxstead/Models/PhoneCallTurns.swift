import Foundation

struct PhoneTimedWord {
    let start: Double
    let end: Double
    var text: String
}

struct PhoneCallTurns {
    private(set) var ownSlot: Int?
    private(set) var callerSlot: Int?
    private(set) var lastRequestedEnd: Double = 0
    private var lastRequestedStart: Double?
    var speakers = PhoneSpeakerSnapshot()
    var lastMacTranscriptUpdate: ContinuousClock.Instant?
    let phaseStart: Double
    let separateInputs: Bool

    init(phaseStart: Double = 0, separateInputs: Bool = false) {
        self.phaseStart = phaseStart
        self.separateInputs = separateInputs
    }

    func slot(for speech: TranscriptSegment) -> Int? {
        guard let end = speech.endTime, speech.time >= phaseStart else { return nil }
        return speakers.speaker(from: speech.time - phaseStart, to: end - phaseStart)
    }

    func label(for speech: TranscriptSegment) -> String? {
        if separateInputs, speech.time >= phaseStart {
            return speech.source == .system ? "Caller" : "You"
        }
        guard let slot = slot(for: speech) else { return speech.speaker }
        if slot == ownSlot { return "You" }
        if slot == callerSlot { return "Caller" }
        return "Voice \(slot + 1)"
    }

    func split(_ speech: TranscriptSegment, words: [PhoneTimedWord]) -> [TranscriptSegment] {
        if separateInputs || words.isEmpty || slot(for: speech) != nil {
            var tagged = speech
            tagged.speaker = label(for: speech)
            return [tagged]
        }
        var pieces: [(slot: Int?, start: Double, end: Double, text: String)] = []
        for word in words {
            let slot = speakers.speaker(from: word.start, to: max(word.start + 0.16, word.end))
            if let last = pieces.last, last.slot == slot, word.start - last.end < 0.65 {
                pieces[pieces.count - 1].end = word.end
                pieces[pieces.count - 1].text += word.text
            } else {
                pieces.append((slot, word.start, word.end, word.text))
            }
        }
        return pieces.compactMap { piece in
            let text = piece.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            var result = TranscriptSegment(time: piece.start + phaseStart, source: speech.source, text: text,
                                           endTime: piece.end + phaseStart)
            result.speaker = label(for: result)
            return result
        }
    }

    mutating func identifySelf(as slot: Int) {
        let previous = ownSlot
        ownSlot = slot
        if callerSlot == slot { callerSlot = previous }
        lastRequestedEnd = speakers.through
        lastRequestedStart = nil
    }

    mutating func observeCaller(in speech: TranscriptSegment) {
        guard let ownSlot, callerSlot == nil, let slot = slot(for: speech), slot != ownSlot,
              let end = speech.endTime, end - speech.time >= 0.45 else { return }
        callerSlot = slot
    }

    func replyOpportunity(for speech: TranscriptSegment) -> PhoneVoiceSpan? {
        guard let callerSlot, let latest = speakers.latest, latest.slot == callerSlot,
              isNewTurn(start: latest.start, end: latest.end),
              (0.40...4.0).contains(speakers.through - latest.end),
              speakers.speaker(from: max(latest.start, latest.end - 0.60), to: latest.end) == callerSlot,
              slot(for: speech) == callerSlot,
              let end = speech.endTime, abs(latest.end - (end - phaseStart)) < 0.95,
              Self.isQuestion(speech.text) else { return nil }
        return latest
    }

    func macAudioReplyOpportunity(
        for speech: TranscriptSegment, now: ContinuousClock.Instant,
        lastMacSignal: ContinuousClock.Instant?, lastMicSignal: ContinuousClock.Instant?,
        enabledSince: ContinuousClock.Instant?
    ) -> Range<Double>? {
        guard separateInputs, speech.source == .system, speech.time >= phaseStart,
              let end = speech.endTime, end > speech.time,
              let lastMacSignal, let lastMacTranscriptUpdate,
              now - lastMacTranscriptUpdate <= .seconds(4),
              enabledSince.map({ lastMacSignal > $0 }) ?? true,
              (.milliseconds(450)...Duration.seconds(4)).contains(now - lastMacSignal),
              lastMicSignal.map({ $0 <= lastMacSignal + .milliseconds(100)
                  && now - $0 >= .milliseconds(350) }) ?? true,
              isNewTurn(start: speech.time - phaseStart, end: end - phaseStart),
              Self.isQuestion(speech.text) else { return nil }
        return (speech.time - phaseStart)..<(end - phaseStart)
    }

    private func isNewTurn(start: Double, end: Double) -> Bool {
        end > lastRequestedEnd + 0.20 && (lastRequestedStart.map { abs(start - $0) > 0.24 } ?? true)
    }

    mutating func markRequested(through end: Double, from start: Double? = nil) {
        lastRequestedEnd = max(lastRequestedEnd, end)
        lastRequestedStart = start
    }

    var userHasStartedTalking: Bool {
        guard let ownSlot, let latest = speakers.latest, latest.slot == ownSlot,
              latest.end > lastRequestedEnd + 0.16 else { return false }
        return speakers.speaker(from: max(latest.start, latest.end - 0.50), to: latest.end) == ownSlot
    }

    static func isQuestion(_ text: String) -> Bool {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if clean.last == "?" || clean.last == "？" || clean.hasPrefix("¿") { return true }
        let words = clean.lowercased().split { !$0.isLetter }
        guard words.count >= 3 else { return false }
        let opening = words.drop(while: { ["so", "and", "well", "okay", "ok", "um"].contains($0) })
        guard let first = opening.first else { return false }
        let subjects: Set<Substring> = ["i", "you", "we", "they", "he", "she", "it", "there", "this", "that"]
        let verbs: Set<Substring> = ["am", "is", "are", "was", "were", "do", "does", "did",
                                     "can", "could", "will", "would", "should", "may", "have", "has"]
        if verbs.contains(first), let subject = opening.dropFirst().first, subjects.contains(subject) { return true }
        let interrogatives: Set<Substring> = ["what", "when", "where", "why", "how", "which", "who"]
        return interrogatives.contains(first) && opening.dropFirst().prefix(3).contains(where: verbs.contains)
    }
}
