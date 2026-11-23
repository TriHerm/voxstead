import Foundation
import Testing
@testable import Voxstead

struct MeetingAssistanceTests {
    @Test func languageChoicesIncludeNativeNamesAndSearch() {
        #expect(ExplanationLanguage.all.count > 100)
        #expect(Set(ExplanationLanguage.all.map(\.id)).count == ExplanationLanguage.all.count)
        #expect(ExplanationLanguage.matching("español").contains { $0.id == "es" })
        #expect(ExplanationLanguage.matching("Japanese").contains { $0.id == "ja" })
        #expect(ExplanationLanguage.matching("  ").count == ExplanationLanguage.all.count)
        #expect(ExplanationLanguage.matching("not-a-language-123").isEmpty)
    }

    @Test func liveRequestKeepsAnOlderPassageWhenThePartialHasChanged() {
        let passage = TranscriptSegment(time: 13, source: .system, text: "The hot standby takes over if the primary fails.")
        let session = VoiceSession(kind: .meeting, title: "Architecture", segments: [
            .init(time: 60, source: .system, text: "Let's switch to another topic.")
        ])
        let explain = LiveMeetingRequest(action: .explain, passage: passage)
        #expect(explain.context(for: session).contains("Selected passage [00:13]"))
        #expect(explain.context(for: session).contains(passage.text))
        #expect(!explain.context(for: session).contains("another topic"))
    }

    @Test func liveRequestsOnlySendPreparationNotesForRepliesAndPreparation() {
        let assistance = MeetingAssistance(explanationLanguage: "Spanish", replyMeaning: true,
                                            preparation: "Ask for the budget ceiling.")
        let session = VoiceSession(kind: .meeting, title: "Planning", segments: [
            .init(time: 0, source: .system, text: "The launch is penciled in for Tuesday.")
        ], meeting: .init(assistance: assistance))
        let explain = LiveMeetingRequest(action: .explain)
        let recap = LiveMeetingRequest(action: .catchUp)
        let reply = LiveMeetingRequest(action: .suggest)
        let prep = LiveMeetingRequest(action: .prepare, speechLanguage: "English")
        #expect(!explain.context(for: session).contains("budget ceiling"))
        #expect(!recap.context(for: session).contains("budget ceiling"))
        #expect(reply.context(for: session).contains("budget ceiling"))
        #expect(reply.instructions(for: assistance).contains("meaning in Spanish"))
        #expect(prep.context(for: session).contains("budget ceiling"))
        #expect(!prep.context(for: session).contains("Tuesday"))
        #expect(explain.instructions(for: assistance).contains("preferred language: Spanish"))
        #expect(recap.instructions(for: assistance).contains("language spoken in the transcript"))
    }

    @Test func olderMeetingDetailsRemainReadable() throws {
        let data = Data(#"{"notes":"Keep me","summary":"Resumen","decisions":[],"actions":[],"coaching":[]}"#.utf8)
        let details = try JSONDecoder().decode(MeetingDetails.self, from: data)
        #expect(details.assistance == nil)
        #expect(details.summary == "Resumen")
    }

    @Test func replySuggestionRejectsAnIncompleteOrMultilinePhrase() throws {
        #expect(throws: WorkspaceError.self) {
            try ReplySuggestion.decode(#"{"sentence":"Can we check?","meaning":null}"#, includeMeaning: true)
        }
        #expect(throws: WorkspaceError.self) {
            try ReplySuggestion.decode(#"{"sentence":"Can we check?\nAnother line.","meaning":null}"#, includeMeaning: false)
        }
        let reply = try ReplySuggestion.decode(
            #"{"sentence":" 明日でよろしいですか？ ","meaning":"Would tomorrow work?"}"#, includeMeaning: false
        )
        #expect(reply.sentence == "明日でよろしいですか？")
        #expect(reply.meaning == nil)
    }

    @Test func phoneReplyShowsAWholePhraseBeforeTheMeaningArrives() {
        #expect(ReplySuggestion.streamedSentence(in: #"{"sentence":"Can you confirm"#) == nil)
        #expect(ReplySuggestion.streamedSentence(in: #"{"sentence":"Can you confirm Friday?","meaning":"¿Puede"#)
                == "Can you confirm Friday?")
        #expect(ReplySuggestion.streamedSentence(in: #"{"sentence":"Did you say \"Friday\"?""#)
                == #"Did you say "Friday"?"#)
        #expect(ReplySuggestion.streamedSentence(in: #"{"sentence":"First line.\nSecond line.","meaning":"#) == nil)
    }

    @Test func phoneRepliesAcceptAtMostTwoSentencesIncludingDuringStreaming() throws {
        let two = #"{"sentence":"Thursday works. Can you send the proof?","meaning":null}"#
        let three = #"{"sentence":"Thursday works. Send the proof. We can review it.","meaning":null}"#
        #expect(try ReplySuggestion.decode(two, includeMeaning: false, maximumSentences: 2).sentence
                == "Thursday works. Can you send the proof?")
        #expect(ReplySuggestion.streamedSentence(in: three, maximumSentences: 2) == nil)
        #expect(throws: WorkspaceError.self) {
            try ReplySuggestion.decode(three, includeMeaning: false, maximumSentences: 2)
        }
    }

    @Test func phoneQuestionDetectionRecognizesQuestionsBeforeFinalPunctuation() {
        for text in ["Puedes confirmar la fecha", "Bueno cuándo llega el pedido", "Me puedes decir el precio",
                     "Cuéntame sobre tu experiencia", "Tell me about your project", "Please walk me through it"] {
            #expect(PhoneCallTurns.invitesReply(text))
        }
        #expect(!PhoneCallTurns.invitesReply("Ya enviamos el documento ayer."))
        #expect(PhoneCallTurns.isQuestion("Could you send the proof"))
        #expect(PhoneCallTurns.isQuestion("So which option would you pick"))
        #expect(PhoneCallTurns.isQuestion("Is Tuesday okay?"))
        #expect(!PhoneCallTurns.isQuestion("We can send the proof tomorrow."))
        #expect(!PhoneCallTurns.isQuestion("How nice to hear from you."))
    }

    @Test func phoneCallWithMacAudioUsesInputRolesWithoutRelabelingAnEarlierPhase() {
        let turns = PhoneCallTurns(phaseStart: 10, separateInputs: true)
        let earlier = TranscriptSegment(time: 5, source: .microphone, text: "Earlier caller", speaker: "Caller")
        let user = TranscriptSegment(time: 11, source: .microphone, text: "Thanks")
        let remote = TranscriptSegment(time: 12, source: .system, text: "Can you hear me?")
        #expect(turns.label(for: earlier) == "Caller")
        #expect(turns.label(for: user) == "You")
        #expect(turns.label(for: remote) == "Caller")
        #expect(turns.split(remote, words: []).first?.speaker == "Caller")
        #expect(PhoneCallTurns(phaseStart: 13).label(for: remote) == nil)
    }

    @Test func phoneCallWithMacAudioWaitsForRemoteSilenceAndDoesNotInterruptTheMicrophone() throws {
        let now = ContinuousClock.now
        var turns = PhoneCallTurns(phaseStart: 10, separateInputs: true)
        turns.lastMacTranscriptUpdate = now - .milliseconds(200)
        let question = TranscriptSegment(time: 11, source: .system, text: "Could you confirm the date?", endTime: 12)
        let remote = now - .milliseconds(550)
        let previousUser = now - .milliseconds(1_200)

        #expect(turns.macAudioReplyOpportunity(for: question, now: now, lastMacSignal: now - .milliseconds(200),
                                               lastMicSignal: previousUser, enabledSince: nil) == nil)
        #expect(turns.macAudioReplyOpportunity(for: question, now: now, lastMacSignal: remote,
                                               lastMicSignal: now, enabledSince: nil) == nil)
        #expect(turns.macAudioReplyOpportunity(for: question, now: now, lastMacSignal: remote,
                                               lastMicSignal: previousUser, enabledSince: now) == nil)
        let opportunity = try #require(turns.macAudioReplyOpportunity(for: question, now: now, lastMacSignal: remote,
                                                                       lastMicSignal: previousUser, enabledSince: nil))
        #expect(opportunity == 1..<2)
        turns.markRequested(through: opportunity.upperBound, from: opportunity.lowerBound)
        #expect(turns.macAudioReplyOpportunity(for: question, now: now, lastMacSignal: remote,
                                               lastMicSignal: previousUser, enabledSince: nil) == nil)
    }

    @Test func phoneRepliesWaitForTheCallerAndIgnoreRevisedCopiesOfTheSameTurn() throws {
        var turns = PhoneCallTurns(phaseStart: 10)
        let caller = TranscriptSegment(time: 13.5, source: .microphone,
                                       text: "Can you send it Friday?", endTime: 15.2)
        turns.speakers = .init(through: 2.1, voices: [.init(slot: 2, start: 0.5, end: 1.8)])
        turns.identifySelf(as: 2)
        turns.speakers = .init(through: 5.3, voices: [.init(slot: 0, start: 3.4, end: 5.2)])
        turns.observeCaller(in: caller)
        #expect(turns.label(for: caller) == "Caller")
        #expect(turns.replyOpportunity(for: caller) == nil)

        turns.speakers.through = 5.9
        let opportunity = try #require(turns.replyOpportunity(for: caller))
        turns.markRequested(through: opportunity.end, from: opportunity.start)
        turns.speakers = .init(through: 6.2, voices: [.init(slot: 0, start: 3.5, end: 5.5)])
        #expect(turns.replyOpportunity(for: caller) == nil)

        turns.speakers.voices.append(.init(slot: 2, start: 5.6, end: 6.2))
        #expect(turns.userHasStartedTalking)
        #expect(turns.replyOpportunity(for: caller) == nil)

        turns.speakers = .init(through: 8.8, voices: [
            .init(slot: 0, start: 7, end: 8.1),
            .init(slot: 2, start: 7.1, end: 8.05)
        ])
        let overlap = TranscriptSegment(time: 17, source: .microphone, text: "Friday or Monday?", endTime: 18)
        #expect(turns.slot(for: overlap) == nil)
        #expect(turns.replyOpportunity(for: overlap) == nil)
    }

    @Test func phoneTurnsCanSplitTwoVoicesInsideOneTranscriptionResult() {
        var turns = PhoneCallTurns()
        turns.speakers = .init(through: 4.5, voices: [
            .init(slot: 1, start: 0.2, end: 1.8),
            .init(slot: 0, start: 2, end: 4.0)
        ])
        turns.identifySelf(as: 1)
        let caller = TranscriptSegment(time: 2, source: .microphone, text: "Can you confirm Friday?", endTime: 4)
        turns.observeCaller(in: caller)
        let mixed = TranscriptSegment(time: 0.2, source: .microphone,
                                      text: "Sure. Can you confirm Friday?", endTime: 4)
        let pieces = turns.split(mixed, words: [
            .init(start: 0.2, end: 1.8, text: "Sure."),
            .init(start: 2, end: 2.8, text: " Can you"),
            .init(start: 2.8, end: 4, text: " confirm Friday?")
        ])
        #expect(pieces.map(\.text) == ["Sure.", "Can you confirm Friday?"])
        #expect(pieces.compactMap(\.speaker) == ["You", "Caller"])
    }

    @Test func meetingAutoRepliesUseNewQuestionsFromTheConversationInput() {
        let remote = TranscriptSegment(time: 12, source: .system, text: "When should we send the draft?")
        var local = remote
        local.source = .microphone
        #expect(LiveMeetingRequest.warrantsAutoReply(to: remote, separateInputs: true, lastRequested: 10))
        #expect(!LiveMeetingRequest.warrantsAutoReply(to: remote, separateInputs: true, lastRequested: 12))
        #expect(!LiveMeetingRequest.warrantsAutoReply(to: remote, separateInputs: true, lastRequested: 14))
        #expect(!LiveMeetingRequest.warrantsAutoReply(to: local, separateInputs: true, lastRequested: nil))
        #expect(LiveMeetingRequest.warrantsAutoReply(to: local, separateInputs: false, lastRequested: nil))
        let request = LiveMeetingRequest(action: .suggest, passage: remote, automaticReply: true)
        let context = request.context(for: VoiceSession(kind: .meeting, title: "Planning", segments: [remote]))
        #expect(context.hasSuffix(remote.text))
    }

    @Test func replyLanguageAndMeaningAreIndependentInMeetingsAndCalls() throws {
        let settings = MeetingAssistance(explanationLanguage: "Portuguese", replyLanguage: "English", replyMeaning: true)
        for phone in [true, false] {
            let request = LiveMeetingRequest(action: .suggest, speechLanguage: "French", phoneCall: phone)
            let prompt = request.instructions(for: settings)
            #expect(prompt.contains("Write the sentence in English"))
            #expect(prompt.contains("meaning in Portuguese"))
            #expect(!prompt.contains("Write it in French"))
        }
        let thought = LiveMeetingRequest(action: .suggest, speechLanguage: "French", thoughtToPhrase: "Me faltan dos días.", phoneCall: true)
        #expect(thought.instructions(for: settings).contains("spoken reply in English"))
        let context = thought.context(for: VoiceSession(kind: .meeting, title: "A call", segments: [
            .init(time: 1, source: .system, text: "Unrelated private transcript.")
        ]))
        #expect(context.contains("Me faltan dos días."))
        #expect(!context.contains("Unrelated"))
        let legacy = try JSONDecoder().decode(MeetingAssistance.self, from: Data(#"{"mode":"conversation","explanationLanguage":"Spanish"}"#.utf8))
        #expect(legacy.replyLanguage == nil)
        for phrase in ConversationPhrase.allCases {
            for language in ConversationPhrase.languages { #expect(phrase.text(in: language)?.isEmpty == false) }
            #expect(phrase.text(in: "ja") == nil)
        }
    }

    @Test func onlyAutomaticPhoneRequestsCanDeclineToSuggest() {
        let automatic = LiveMeetingRequest(action: .suggest, phoneCall: true, automaticReply: true)
        let manual = LiveMeetingRequest(action: .suggest, phoneCall: true)
        #expect(automatic.shouldSkipAutomaticAnswer(#"{"sentence":null,"meaning":null}"#))
        #expect(!manual.shouldSkipAutomaticAnswer(#"{"sentence":null,"meaning":null}"#))
        #expect(!automatic.shouldSkipAutomaticAnswer(#"{"sentence":"Could you repeat that?","meaning":null}"#))
    }

    @Test @MainActor func supportPreferencesSurviveLibraryReloadWithoutChangingTranscript() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let library = LibraryFile(url: folder.appending(path: "library.json"))
        let session = VoiceSession(kind: .meeting, title: "Interview", segments: [
            .init(time: 0, source: .system, text: "Tell me about your experience.")
        ])
        try library.save(WorkspaceDocument(sessions: [session]))
        let store = WorkspaceStore(library: library)
        store.updateMeeting(session.id) {
            $0.assistance = .init(mode: .languageSupport, explanationLanguage: "Español")
        }
        let restored = try #require(try library.load().sessions.first)
        #expect(restored.meeting?.assistance?.mode == .languageSupport)
        #expect(restored.meeting?.assistance?.explanationLanguage == "Español")
        #expect(restored.transcript == session.transcript)
        store.updateMeeting(session.id) { $0.assistance?.mode = .interview }
        #expect(try library.load().sessions.first?.meeting?.assistance?.mode == .interview)
    }
}
