import Foundation

/// Stores the last finalized segment included in a successful recap.
struct MeetingCatchUpCheckpoint: Codable, Sendable {
    let segmentID: UUID
    let latestTimestamp: String
    var exchangeID: UUID?

    func latestCoveredSegment(in recorded: [TranscriptSegment]) -> TranscriptSegment? {
        guard let index = recorded.lastIndex(where: { $0.id == segmentID }) else { return nil }
        return recorded[...index].max { $0.time < $1.time }
    }
}

struct MeetingCatchUp: Sendable {
    private static let fromStartTitle = "Catch me up · From the start"
    private static let sinceLastTitle = "Catch me up · Since last recap"
    let segments: [TranscriptSegment]
    let checkpoint: MeetingCatchUpCheckpoint?
    let startsAtBeginning: Bool

    init(session: VoiceSession, fromBeginning: Bool = false) {
        // Segments are appended when recognition finalizes them. A late segment from
        // another audio source may have an older timestamp, but is still new to the recap.
        let recorded = session.segments
        let previousID = session.meeting?.catchUpCheckpoint?.segmentID
        let previousIndex = fromBeginning ? nil : recorded.lastIndex { $0.id == previousID }
        startsAtBeginning = previousIndex == nil
        if let previousIndex {
            segments = Array(recorded.dropFirst(previousIndex + 1))
        } else {
            segments = recorded
        }
        if let last = recorded.last, let latest = recorded.max(by: { $0.time < $1.time }) {
            checkpoint = .init(segmentID: last.id, latestTimestamp: latest.timestamp)
        } else {
            checkpoint = nil
        }
    }

    var transcript: String {
        segments.sorted { $0.time < $1.time }.map {
            "[\($0.timestamp)] \($0.speaker ?? $0.source.title): \($0.text)"
        }.joined(separator: "\n")
    }

    var title: String {
        startsAtBeginning ? Self.fromStartTitle : Self.sinceLastTitle
    }

    static func latestRecap(in session: VoiceSession) -> Exchange? {
        guard let checkpoint = session.meeting?.catchUpCheckpoint else { return nil }
        if let id = checkpoint.exchangeID {
            return session.exchanges.last { $0.id == id }
        }
        return session.exchanges.last { $0.prompt == fromStartTitle || $0.prompt == sinceLastTitle }
    }

    func context(text: String, condensed: Bool = false) -> String {
        let scope = startsAtBeginning
            ? "Scope: finalized speech from the start of this meeting."
            : "Scope: finalized speech newly available since the last successful recap. Summarize only this material."
        let label = condensed ? "Notes from every part of the recap scope" : "Transcript"
        return "\(scope)\n\n\(label):\n\(text)"
    }
}
