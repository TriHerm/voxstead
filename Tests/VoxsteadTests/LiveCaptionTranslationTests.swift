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
        let final = queue.next(recentFinals: [prior], partials: [edited], at: now + .milliseconds(180))
        #expect(final?.segment.id == prior.id)
        #expect(final?.isPreview == false)
        #expect(queue.next(recentFinals: [prior], partials: [edited], at: now + .milliseconds(300)) == nil)
        #expect(queue.next(recentFinals: [prior], partials: [edited], at: now + .milliseconds(650))?.isPreview == true)
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
        let spanish = CaptionWork(segment: .init(time: 9, source: .system,
                                                text: "El presupuesto del prototipo se revisará el próximo jueves."), isPreview: false)
        let sameLanguage = try await translator.translate(spanish, recognitionLanguage: "en-US")
        guard case .unchanged = sameLanguage else {
            Issue.record("Spanish speech already in the target language should remain as transcribed.")
            return
        }
    }
}
