import Foundation
import Testing
@testable import Voxstead

struct LibraryTests {
    @Test @MainActor func corruptLibraryPreventsCaptureWithoutOverwritingData() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = LibraryFile(url: folder.appending(path: "library.json"))
        let original = Data("{ damaged".utf8)
        try original.write(to: file.url)
        let store = WorkspaceStore(library: file)
        #expect(store.libraryRecoveryNeeded)
        #expect(store.startCapture(.meeting) == nil)
        store.addTranscript(title: "Test", text: "Do not claim this can be saved")
        #expect(store.document.sessions.isEmpty)
        #expect(try Data(contentsOf: file.url) == original)
    }

    @Test @MainActor func restoringBackupKeepsTheDamagedOriginal() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = LibraryFile(url: folder.appending(path: "library.json"))
        let damaged = Data("{ broken".utf8)
        try damaged.write(to: file.url)
        let backup = LibraryFile(url: folder.appending(path: "backup.json"))
        let session = VoiceSession(kind: .meeting, title: "Recovered meeting")
        try backup.save(WorkspaceDocument(sessions: [session, session]))

        let store = WorkspaceStore(library: file)
        #expect(throws: WorkspaceError.self) { try LibraryFile.readBackup(backup.url) }
        #expect(try Data(contentsOf: file.url) == damaged)
        #expect(store.libraryRecoveryNeeded)

        try backup.save(WorkspaceDocument(sessions: [session]))
        try store.restoreLibrary(LibraryFile.readBackup(backup.url))
        #expect(!store.libraryRecoveryNeeded)
        #expect(store.selected == session.id)
        #expect(try file.load().sessions.map(\.id) == [session.id])
        let archives = try FileManager.default.contentsOfDirectory(
            at: folder.appending(path: "Library Recovery"), includingPropertiesForKeys: nil
        )
        #expect(archives.count == 1)
        #expect(try Data(contentsOf: #require(archives.first)) == damaged)
    }

    @Test @MainActor func failedSavePreventsQuitUntilPendingChangesAreWritten() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = LibraryFile(url: folder.appending(path: "library.json"))
        let session = VoiceSession(kind: .meeting, title: "Original")
        try file.save(WorkspaceDocument(sessions: [session]))
        let store = WorkspaceStore(library: file)
        let displaced = folder.appending(path: "displaced.json")
        try FileManager.default.moveItem(at: file.url, to: displaced)
        try FileManager.default.createDirectory(at: file.url, withIntermediateDirectories: false)
        store.rename(session.id, title: "Edited")
        #expect(store.hasUnsavedChanges)
        #expect(await !store.finishBeforeQuit())
        #expect(store.document.sessions.first?.title == "Edited")
        try FileManager.default.removeItem(at: file.url)
        try FileManager.default.moveItem(at: displaced, to: file.url)
        #expect(await store.finishBeforeQuit())
        #expect(!store.hasUnsavedChanges)
        #expect(try file.load().sessions.first?.title == "Edited")
    }

    @Test @MainActor func deletingMeetingRemovesOnlyAnswersDerivedFromIt() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = LibraryFile(url: folder.appending(path: "library.json"))
        let first = VoiceSession(kind: .meeting, title: "Removed")
        let second = VoiceSession(kind: .meeting, title: "Retained")
        let firstSource = LibraryExchange.Source(id: first.id, title: first.title)
        let secondSource = LibraryExchange.Source(id: second.id, title: second.title)
        let derived = LibraryExchange(prompt: "Both", answer: "Derived from both", provider: "Fixture",
                                      sources: [firstSource, secondSource])
        let unrelated = LibraryExchange(prompt: "Second", answer: "Retain this", provider: "Fixture",
                                        sources: [secondSource])
        try file.save(WorkspaceDocument(sessions: [first, second], libraryExchanges: [derived, unrelated]))
        WorkspaceStore(library: file).delete(first.id)
        let result = try file.load()
        #expect(result.sessions.map(\.id) == [second.id])
        #expect(result.libraryExchanges?.map(\.id) == [unrelated.id])
    }

    @Test func regeneratingTasksPreservesEditsAndRefreshesPendingSuggestions() {
        let completed = ActionItem(title: "Enviar diseño", complete: true, generated: true)
        let edited = ActionItem(title: "Ask Ana to review", owner: "Ana", generated: false)
        let pending = ActionItem(title: "Set a date", due: "Monday", generated: true)
        let old = ActionItem(title: "Obsolete suggestion", generated: true)
        let result = ActionItem.reconcile([completed, edited, pending, old], with: [
            .init(title: " ENVIAR DISENO! ", owner: nil, due: "Tuesday"),
            .init(title: "Set a date", owner: "Luis", due: "Friday")
        ])
        #expect(result.map(\.id) == [completed.id, edited.id, pending.id])
        #expect(result.first?.complete == true)
        #expect(result[1].owner == "Ana")
        #expect(result.last?.owner == "Luis")
        #expect(result.last?.due == "Friday")
    }

    @Test func regeneratedTasksCanMatchRewordedEditsAndIgnoreDeletedItems() {
        let original = ActionItem(title: "Send the deck", generated: true)
        var completed = original
        completed.title = "Send the final deck to Sara"
        completed.complete = true
        completed.generated = false
        let pending = ActionItem(title: "Schedule a call", generated: true)
        let removed = ActionItem(title: "Share the video", generated: true)
        let result = ActionItem.reconcile([completed, pending], with: [
            .init(title: "Enviar la presentación", owner: nil, due: nil, existingTaskID: completed.id.uuidString),
            .init(title: "Agendar llamada", owner: "Luis", due: "Friday", existingTaskID: pending.id.uuidString),
            .init(title: "Organizar la llamada", owner: nil, due: nil, existingTaskID: pending.id.uuidString),
            .init(title: "Compartir el video", owner: nil, due: nil, existingTaskID: removed.id.uuidString)
        ], submitted: [original, pending, removed])
        #expect(result.map(\.id) == [completed.id, pending.id])
        #expect(result.map(\.title) == ["Send the final deck to Sara", "Agendar llamada"])
        #expect(result.last?.owner == "Luis")
    }

    @Test func roundTripPreservesSourcesAndExportsInOrder() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = LibraryFile(url: folder.appending(path: "library.json"))
        #expect(try file.load().sessions.isEmpty)
        let session = VoiceSession(kind: .meeting, title: "Prueba", segments: [
            .init(time: 20, source: .system, text: "Acuerdo"),
            .init(time: 3, source: .microphone, text: "Inicio")
        ])
        try file.save(WorkspaceDocument(sessions: [session]))
        let loaded = try #require(try file.load().sessions.first)
        #expect(loaded.id == session.id)
        #expect(loaded.transcript == "[00:03] Microphone: Inicio\n[00:20] Mac audio: Acuerdo")
        #expect(loaded.markdown.contains("# Prueba"))
    }

    @Test func libraryContextFindsAnOlderRelevantMeeting() {
        let recent = VoiceSession(kind: .meeting, title: "Unrelated", segments: [
            .init(time: 0, source: .system, text: "We chose a venue for the party.")
        ])
        let relevant = VoiceSession(kind: .meeting, title: "Atlas rollout", created: .distantPast, segments: [
            .init(time: 12, source: .microphone, text: "We will start the Atlas rollout on Tuesday.")
        ])
        let dictation = VoiceSession(kind: .dictation, title: "Atlas rollout", segments: [
            .init(time: 0, source: .microphone, text: "Private dictation")
        ])
        let context = LibraryContext.build(question: "When is the Atlas rollout?", sessions: [recent, dictation, relevant])
        #expect(context.sources.first?.id == relevant.id)
        #expect(context.sources.count == 1)
        #expect(context.text.contains("[00:12] Microphone"))
        #expect(!context.text.contains("Private dictation"))
        #expect(quoteAppears("the Atlas rollout on Tuesday", in: context.text))
        #expect(!quoteAppears("the Atlas rollout on Monday", in: context.text))
    }

    @Test func decodesThePreviewLibraryWithoutNewFields() throws {
        let payload = """
        {
          "sessions": [],
          "settings": {"locale":"es-MX","includeSystemAudio":true,"copyDictation":false,"providers":[],"servers":[]}
        }
        """
        let document = try JSONDecoder().decode(WorkspaceDocument.self, from: Data(payload.utf8))
        #expect(document.settings.locale == "es-MX")
        #expect(document.settings.includeSystemAudio)
        #expect(!document.settings.copyDictation)
        #expect(document.settings.dictationLocale == nil)
        #expect(document.libraryExchanges == nil)
    }

    @Test @MainActor func remembersProviderAndCombinesLibraryFilters() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = LibraryFile(url: folder.appending(path: "library.json"))
        let first = ProviderProfile(name: "First", model: "one")
        let second = ProviderProfile(name: "Second", model: "two")
        var document = WorkspaceDocument(sessions: [
            VoiceSession(kind: .meeting, title: "Launch", segments: [.init(time: 0, source: .system, text: "Revisión del diseño")]),
            VoiceSession(kind: .dictation, title: "Shopping", segments: [.init(time: 0, source: .microphone, text: "Launch checklist")])
        ])
        document.settings.providers = [first, second]
        try file.save(document)
        let store = WorkspaceStore(library: file)
        store.providerID = second.id
        #expect(WorkspaceStore(library: file).providerID == second.id)
        store.sessionFilter = .meeting
        store.search = "  diseño  "
        #expect(store.visibleSessions.map(\.title) == ["Launch"])
        store.sessionFilter = .dictation
        #expect(store.visibleSessions.isEmpty)
        store.search = "launch"
        #expect(store.visibleSessions.map(\.title) == ["Shopping"])
        document.settings.preferredProviderID = UUID()
        try file.save(document)
        #expect(WorkspaceStore(library: file).providerID == first.id)
    }

    @Test @MainActor func guideResumesSkipsAndReopensWithoutRecording() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = LibraryFile(url: folder.appending(path: "library.json"))
        let fresh = WorkspaceStore(library: file)
        fresh.presentFirstUseGuide()
        #expect(fresh.showGuide)
        #expect(fresh.captureID == nil)
        #expect(fresh.document.settings.guideStep == 0)
        let resumedFirstPage = WorkspaceStore(library: file)
        resumedFirstPage.presentFirstUseGuide()
        #expect(resumedFirstPage.showGuide)
        fresh.updateSettings { $0.guideStep = 1 }
        let resumed = WorkspaceStore(library: file)
        resumed.presentFirstUseGuide()
        #expect(resumed.showGuide)
        #expect(resumed.document.settings.guideStep == 1)
        resumed.finishGuide()
        resumed.performGuideAction()
        #expect(!resumed.showGuide)
        #expect(resumed.captureID == nil)
        let skipped = WorkspaceStore(library: file)
        skipped.presentFirstUseGuide()
        #expect(!skipped.showGuide)
        skipped.openGuide()
        #expect(skipped.showGuide)
        #expect(skipped.document.settings.guideStep == 0)
        skipped.finishGuide(.meeting)
        #expect(!skipped.showMeetingSetup)
        skipped.performGuideAction()
        #expect(skipped.showMeetingSetup)
        #expect(skipped.captureID == nil)
        skipped.showMeetingSetup = false
        skipped.performGuideAction()
        #expect(!skipped.showMeetingSetup)
    }

    @Test @MainActor func existingLibrariesDoNotGetAnUnexpectedGuide() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = LibraryFile(url: folder.appending(path: "library.json"))
        try file.save(WorkspaceDocument())
        let store = WorkspaceStore(library: file)
        store.presentFirstUseGuide()
        #expect(!store.showGuide)
        store.openGuide()
        #expect(store.showGuide)
    }

    @Test @MainActor func guideOpensPracticeWithoutStartingARecordingOrChangingTheLibrary() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = LibraryFile(url: folder.appending(path: "library.json"))
        let meeting = VoiceSession(kind: .meeting, title: "Existing meeting")
        try file.save(WorkspaceDocument(sessions: [meeting]))
        let store = WorkspaceStore(library: file)
        #expect(store.destination == .home)

        store.openGuide()
        store.finishGuide(.practice)
        #expect(store.destination == .home)
        store.performGuideAction()
        #expect(store.destination == .practice)
        #expect(store.captureID == nil)
        #expect(store.runningID == nil)
        #expect(try file.load().sessions.map(\.id) == [meeting.id])
        store.selected = meeting.id
        #expect(store.destination == .session(meeting.id))
    }

    @Test @MainActor func followUpUsesOnlySelectedOpenActionsAndLeavesTheOriginalMeetingAlone() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = LibraryFile(url: folder.appending(path: "library.json"))
        let selected = ActionItem(title: "Confirm review", owner: "Elena", due: "Thursday")
        let unselected = ActionItem(title: "Ask for quote")
        let finished = ActionItem(title: "Send draft", complete: true)
        let meeting = VoiceSession(kind: .meeting, title: "Prototype",
                                   meeting: .init(decisions: ["Budget approved"], actions: [selected, unselected, finished]))
        try file.save(WorkspaceDocument(sessions: [meeting]))
        let store = WorkspaceStore(library: file)
        let before = try Data(contentsOf: file.url)
        store.prepareFollowUp(to: meeting.id, actionIDs: [selected.id, finished.id], includeDecisions: false)
        #expect(store.showMeetingSetup)
        #expect(store.meetingSetupPreparation.contains("Confirm review · Elena · Thursday"))
        #expect(!store.meetingSetupPreparation.contains("Ask for quote"))
        #expect(!store.meetingSetupPreparation.contains("Send draft"))
        #expect(!store.meetingSetupPreparation.contains("Budget approved"))
        #expect(store.captureID == nil)
        #expect(store.runningID == nil)
        #expect(try Data(contentsOf: file.url) == before)

        store.showMeetingSetup = false
        store.clearMeetingSetupPreparation()
        #expect(store.meetingSetupPreparation.isEmpty)
        store.prepareFollowUp(to: meeting.id, actionIDs: [], includeDecisions: true)
        #expect(store.meetingSetupPreparation.contains("Budget approved"))
    }

    @Test @MainActor func workspaceHistoryRemembersSectionsAndSkipsDeletedSessions() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = LibraryFile(url: folder.appending(path: "library.json"))
        let fragment = TranscriptSegment(time: 12, source: .system, text: "Let’s review on Thursday.")
        let meeting = VoiceSession(kind: .meeting, title: "Prototype", segments: [fragment])
        let removed = VoiceSession(kind: .dictation, title: "Old draft")
        try file.save(WorkspaceDocument(sessions: [meeting, removed]))
        let store = WorkspaceStore(library: file)

        store.destination = .actionItems
        store.openDebrief(meeting.id)
        #expect(store.section(for: meeting.id) == .debrief)
        store.navigate(.backward)
        #expect(store.destination == .actionItems)
        store.navigate(.forward)
        #expect(store.destination == .session(meeting.id))
        #expect(store.section(for: meeting.id) == .debrief)

        store.selected = removed.id
        store.destination = .practice
        store.delete(removed.id)
        store.navigate(.backward)
        #expect(store.destination == .session(meeting.id))
        store.openTranscript(meeting.id, excerpt: .init(id: fragment.id, timestamp: fragment.timestamp))
        #expect(store.section(for: meeting.id) == .transcript)
        #expect(store.transcriptJump?.id == fragment.id)
        store.navigate(.forward)
        #expect(store.destination == .practice)
        #expect(store.transcriptJump == nil)
        store.navigate(.backward)
        store.destination = .coach
        #expect(!store.canNavigate(.forward))
    }

    @Test func validatesEndpoints() throws {
        #expect(try validatedEndpoint("http://127.0.0.1:11434/v1").host() == "127.0.0.1")
        #expect(try validatedEndpoint("https://example.com/mcp").path == "/mcp")
        #expect(throws: WorkspaceError.self) { try validatedEndpoint("http://example.com") }
        #expect(throws: WorkspaceError.self) { try validatedEndpoint("https://user:secret@example.com") }
    }
}
