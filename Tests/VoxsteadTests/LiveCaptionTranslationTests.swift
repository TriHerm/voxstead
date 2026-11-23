import Foundation
import Testing
@testable import Voxstead

struct LiveCaptionTranslationTests {
    @Test func captionsDetectEnglishEvenWhenRecognitionIsSetToSpanish() {
        let english = "How do we get to these seeds? Most of the ants are trying to walk back."
        #expect(CaptionSourceLanguage.detect(english, fallback: "es-MX") == "en")
        #expect(CaptionSourceLanguage.detect("El presupuesto del prototipo se revisará el próximo jueves.", fallback: "en-US") == "es")
        #expect(CaptionSourceLanguage.detect("OK", fallback: "es-MX") == "es-MX")
    }

    @Test func captionQueuePreviewsNewSpeechWithoutRepeatingEveryRevision() {
        var queue = CaptionQueue()
        let now = ContinuousClock.now
        let prior = TranscriptSegment(time: 2, source: .system, text: "A previous finalized decision.")
        let partial = TranscriptSegment(time: 9, source: .system, text: "We should review the prototype")
        let edited = TranscriptSegment(time: 9, source: .system, text: "We should review the prototype on Thursday.")
        let preview = queue.next(recentFinals: [prior], partials: [partial], at: now)
        #expect(preview?.segment.id == partial.id)
        #expect(preview?.isPreview == true)
        #expect(queue.nextPreviewDeadline(for: [partial], at: now) == nil)
        #expect(queue.nextPreviewDeadline(for: [], at: now) == nil)
        #expect(queue.nextPreviewDeadline(for: [edited], at: now + .milliseconds(180)) == now + .milliseconds(400))
        let final = queue.next(recentFinals: [prior], partials: [edited], at: now + .milliseconds(180))
        #expect(final?.segment.id == prior.id)
        #expect(final?.isPreview == false)
        #expect(queue.next(recentFinals: [prior], partials: [edited], at: now + .milliseconds(300)) == nil)
        #expect(queue.next(recentFinals: [prior], partials: [edited], at: now + .milliseconds(400))?.isPreview == true)
        var sameContent = edited
        sameContent.id = UUID()
        #expect(queue.next(recentFinals: [prior], partials: [sameContent], at: now + .seconds(2)) == nil)
        #expect(queue.next(recentFinals: [prior, sameContent], partials: [], at: now + .seconds(2))?.isPreview == false)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["VOXSTEAD_TEST_TRANSLATION"] == "1"))
    func installedTranslationReturnsSpanishDuringAnEnglishPreview() async throws {
        let pair = CaptionLanguagePair(source: "en", target: "es")
        try #require(await pair.availability() == .installed)
        let translator = LocalCaptionTranslator(target: "es")
        let preview = CaptionWork(segment: .init(time: 7, source: .system,
                                                text: "We should review the draft before Tuesday."), isPreview: true)
        let start = ContinuousClock.now
        let result = try await translator.translate(preview, recognitionLanguage: "es-MX")
        let elapsed = ContinuousClock.now - start
        guard case .translation(let text, let source) = result else {
            Issue.record("The English preview should be translated into Spanish.")
            return
        }
        print("Installed English-to-Spanish preview: \(elapsed)")
        #expect(source == "en")
        #expect(text.localizedCaseInsensitiveContains("borrador"))
        #expect(text.localizedCaseInsensitiveContains("martes"))
        let final = try await translator.translate(CaptionWork(segment: preview.segment, isPreview: false), recognitionLanguage: "es-MX")
        guard case .translation(let finalText, _) = final else {
            Issue.record("The matching final should keep its translated preview.")
            return
        }
        #expect(finalText == text)
        var edited = preview.segment
        edited.text = "We should review the draft before Friday."
        let correction = try await translator.translate(CaptionWork(segment: edited, isPreview: false), recognitionLanguage: "es-MX")
        guard case .translation(let correctedText, _) = correction else {
            Issue.record("The revised final should be translated.")
            return
        }
        #expect(correctedText.localizedCaseInsensitiveContains("viernes"))
        let spanish = CaptionWork(segment: .init(time: 9, source: .system,
                                                text: "El presupuesto del prototipo se revisará el próximo jueves."), isPreview: false)
        let sameLanguage = try await translator.translate(spanish, recognitionLanguage: "en-US")
        guard case .unchanged = sameLanguage else {
            Issue.record("Spanish speech already in the target language should remain as transcribed.")
            return
        }
    }
}
