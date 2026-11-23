import Foundation
import NaturalLanguage
import Translation

struct CaptionLanguagePair: Hashable, Sendable {
    let source: String
    let target: String

    var name: String { "\(Self.name(for: source)) → \(Self.name(for: target))" }
    var sourceLanguage: Locale.Language { Locale.Language(identifier: source) }
    var targetLanguage: Locale.Language { Locale.Language(identifier: target) }

    static func name(for identifier: String) -> String {
        Locale(identifier: "en").localizedString(forIdentifier: identifier) ?? identifier
    }

    static func code(for identifier: String) -> String? {
        Locale.Language(identifier: identifier).languageCode?.identifier
    }

    var configuration: TranslationSession.Configuration {
        if #available(macOS 26.4, *) {
            return .init(source: sourceLanguage, target: targetLanguage, preferredStrategy: .lowLatency)
        }
        return .init(source: sourceLanguage, target: targetLanguage)
    }

    func availability() async -> LanguageAvailability.Status {
        if #available(macOS 26.4, *) {
            return await LanguageAvailability(preferredStrategy: .lowLatency).status(from: sourceLanguage, to: targetLanguage)
        }
        return await LanguageAvailability().status(from: sourceLanguage, to: targetLanguage)
    }
}

struct CaptionWork: Sendable {
    let segment: TranscriptSegment
    let isPreview: Bool
}

struct CaptionQueue {
    private struct Preview {
        let segment: TranscriptSegment
        let sentAt: ContinuousClock.Instant
    }

    private static let previewInterval: Duration = .milliseconds(400)
    private var handled: Set<UUID> = []
    private var previews: [AudioSource: Preview] = [:]
    private var prioritizeFinal = false

    private func readyAt(_ segment: TranscriptSegment, now: ContinuousClock.Instant) -> ContinuousClock.Instant? {
        guard segment.text.count >= 8 else { return nil }
        guard let previous = previews[segment.source] else { return now }
        guard segment.time != previous.segment.time || segment.text != previous.segment.text else { return nil }
        return previous.sentAt + Self.previewInterval
    }

    // A revised preview can become eligible without another recognition callback.
    func nextPreviewDeadline(for partials: [TranscriptSegment], at now: ContinuousClock.Instant) -> ContinuousClock.Instant? {
        partials.compactMap { readyAt($0, now: now) }.filter { $0 > now }.min()
    }

    mutating func next(
        recentFinals: [TranscriptSegment], partials: [TranscriptSegment], at now: ContinuousClock.Instant
    ) -> CaptionWork? {
        let final = recentFinals.reversed().first { !handled.contains($0.id) }
        let preview = partials.filter { segment in
            guard let deadline = readyAt(segment, now: now) else { return false }
            return deadline <= now
        }.max { $0.time < $1.time }

        // Give newer speech a preview while allowing finalized turns to catch up.
        if let preview, final == nil || (!prioritizeFinal && preview.time >= (final?.time ?? 0)) {
            previews[preview.source] = Preview(segment: preview, sentAt: now)
            prioritizeFinal = true
            return CaptionWork(segment: preview, isPreview: true)
        }
        if let final {
            handled.insert(final.id)
            prioritizeFinal = false
            return CaptionWork(segment: final, isPreview: false)
        }
        return nil
    }
}

enum CaptionTranslationResult: Sendable {
    case unchanged
    case translation(text: String, source: String)
    case download(CaptionLanguagePair)
    case unsupported(CaptionLanguagePair)
}

enum CaptionSourceLanguage {
    static func detect(_ text: String, fallback: String?) -> String? {
        let sample = String(text.suffix(600))
        if sample.count >= 20 {
            let recognizer = NLLanguageRecognizer()
            recognizer.processString(sample)
            let guesses = recognizer.languageHypotheses(withMaximum: 2).sorted { $0.value > $1.value }
            if let first = guesses.first, first.key != .undetermined, first.value >= 0.55,
               first.value - (guesses.dropFirst().first?.value ?? 0) >= 0.18 {
                return first.key.rawValue
            }
        }
        return fallback
    }
}

/// Owned by one caption task, which invokes its non-Sendable Apple sessions serially.
final class LocalCaptionTranslator {
    private let target: String
    private var sessions: [CaptionLanguagePair: TranslationSession] = [:]
    private var translatedPreviews: [AudioSource: (time: Double, original: String, pair: CaptionLanguagePair, text: String)] = [:]
    private var unavailable: [CaptionLanguagePair: CaptionTranslationResult] = [:]
    private var detected: [AudioSource: (language: String, time: Double)] = [:]

    init(target: String) { self.target = target }

    func resetDetectedLanguages() {
        detected.removeAll()
        translatedPreviews.removeAll()
    }

    func translate(_ work: CaptionWork, recognitionLanguage: String?) async throws -> CaptionTranslationResult {
        let segment = work.segment
        guard segment.text.contains(where: \.isLetter) else { return .unchanged }
        let previous = detected[segment.source]
        let guess = CaptionSourceLanguage.detect(segment.text, fallback: nil)
        if let guess, previous == nil || segment.time >= (previous?.time ?? 0) {
            detected[segment.source] = (guess, segment.time)
        }
        let fallback = previous.flatMap { $0.time <= segment.time ? $0.language : nil } ?? recognitionLanguage
        guard let source = guess ?? fallback,
              CaptionLanguagePair.code(for: source) != CaptionLanguagePair.code(for: target) else {
            return .unchanged
        }

        let pair = CaptionLanguagePair(source: source, target: target)
        if !work.isPreview, let preview = translatedPreviews[segment.source],
           preview.time == segment.time, preview.original == segment.text, preview.pair == pair {
            return .translation(text: preview.text, source: source)
        }
        if let unavailablePair = unavailable[pair] { return unavailablePair }
        let session: TranslationSession
        if let ready = sessions[pair] {
            session = ready
        } else {
            let status = await pair.availability()
            guard status == .installed else {
                let result: CaptionTranslationResult = status == .supported ? .download(pair) : .unsupported(pair)
                unavailable[pair] = result
                return result
            }
            if #available(macOS 26.4, *) {
                session = TranslationSession(installedSource: pair.sourceLanguage, target: pair.targetLanguage,
                                             preferredStrategy: .lowLatency)
            } else {
                session = TranslationSession(installedSource: pair.sourceLanguage, target: pair.targetLanguage)
            }
            sessions[pair] = session
        }
        try Task.checkCancellation()
        do {
            let text = try await session.translate(segment.text).targetText
            if work.isPreview {
                translatedPreviews[segment.source] = (segment.time, segment.text, pair, text)
            }
            return .translation(text: text, source: source)
        } catch TranslationError.nothingToTranslate, TranslationError.unableToIdentifyLanguage {
            return .unchanged
        } catch TranslationError.notInstalled {
            sessions.removeValue(forKey: pair)
            let result = CaptionTranslationResult.download(pair)
            unavailable[pair] = result
            return result
        }
    }
}
