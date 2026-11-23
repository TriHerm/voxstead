import Foundation
import OSLog

/// One local diagnostic sample per live suggestion. Timestamps use a monotonic clock.
@MainActor
final class LiveReplyTiming {
    static let isEnabled = ProcessInfo.processInfo.environment["VOXSTEAD_LOG_REPLY_TIMING"] == "1"
    private static let logger = Logger(subsystem: "labs.triherm.voxstead", category: "LiveReplyTiming")

    private let recognizedAt: ContinuousClock.Instant?
    private let startedAt = ContinuousClock.now
    private let mode: String
    private let trigger: String
    var requestedAt: ContinuousClock.Instant?
    var replyReadyAt: ContinuousClock.Instant?

    init(request: LiveMeetingRequest, recognizedAt: ContinuousClock.Instant?) {
        self.recognizedAt = recognizedAt
        mode = request.phoneCall ? "call" : "meeting"
        trigger = request.automaticReply ? "automatic" : "manual"
    }

    func record(outcome: String) {
        let now = ContinuousClock.now
        let scheduling = Self.elapsed(from: recognizedAt, to: startedAt)
        let preparation = Self.elapsed(from: startedAt, to: requestedAt)
        let response = Self.elapsed(from: requestedAt, to: replyReadyAt)
        let total = Self.elapsed(from: recognizedAt ?? startedAt, to: replyReadyAt)
        let finished = Self.elapsed(from: startedAt, to: now)
        Self.logger.notice("mode=\(self.mode, privacy: .public) trigger=\(self.trigger, privacy: .public) outcome=\(outcome, privacy: .public) scheduling_ms=\(scheduling, privacy: .public) preparation_ms=\(preparation, privacy: .public) response_to_reply_ms=\(response, privacy: .public) time_to_reply_ms=\(total, privacy: .public) job_ms=\(finished, privacy: .public)")
    }

    private static func elapsed(from start: ContinuousClock.Instant?, to end: ContinuousClock.Instant?) -> String {
        guard let start, let end else { return "unavailable" }
        let parts = start.duration(to: end).components
        return String(parts.seconds * 1_000 + parts.attoseconds / 1_000_000_000_000_000)
    }
}
