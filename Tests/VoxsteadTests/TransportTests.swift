import Foundation
import MCP
import Testing
@testable import Voxstead

struct TransportTests {
    private static let fixture = Bundle.module.url(forResource: "mcp_fixture", withExtension: "py")!

    @Test func modelCatalogUsesProviderAuthAndPagination() async throws {
        let (server, port) = try launchFixtureHTTP()
        defer { if server.isRunning { server.terminate() } }
        for kind in [ProviderKind.openAI, .anthropic, .gemini, .openRouter, .ollama, .compatible] {
            let profile = ProviderProfile(kind: kind, endpoint: "http://127.0.0.1:\(port)/v1")
            let models = try await ModelClient(profile: profile, key: "catalog-key").availableModels()
            #expect(models == (kind == .anthropic ? ["claude-a", "claude-b"] : ["chat-a", "chat-b"]))
        }
        let profile = ProviderProfile(kind: .compatible, endpoint: "http://127.0.0.1:\(port)/v1")
        do {
            _ = try await ModelClient(profile: profile, key: "wrong-key").availableModels()
            Issue.record("Expected an authentication failure")
        } catch {
            #expect(error.localizedDescription.contains("Check your API key"))
            #expect(!error.localizedDescription.contains("wrong-key"))
        }
    }

    @Test func mcpStdioRoundTrip() async throws {
        var profile = ServerProfile()
        profile.address = "/usr/bin/python3"
        profile.arguments = [Self.fixture.path]
        let connection = MCPConnection()
        do {
            try await connection.connect(profile, token: "")
            try await verifyEcho(connection)
            await connection.close()
        } catch {
            await connection.close()
            throw error
        }
    }

    @Test func mcpHTTPRoundTrip() async throws {
        let (server, port) = try launchFixtureHTTP()
        defer { if server.isRunning { server.terminate() } }
        let connection = MCPConnection()
        var profile = ServerProfile()
        profile.transport = .http
        profile.address = "http://127.0.0.1:\(port)/mcp"
        do {
            try await connection.connect(profile, token: "fixture-token")
            try await verifyEcho(connection)
            await connection.close()
        } catch {
            await connection.close()
            throw error
        }
    }

    @MainActor @Test func workspaceGatesMCPExecutionAndStoresTheAnswer() async throws {
        let (server, port) = try launchFixtureHTTP()
        defer { if server.isRunning { server.terminate() } }

        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let library = LibraryFile(url: folder.appending(path: "library.json"))
        let profile = ProviderProfile(kind: .compatible, endpoint: "http://127.0.0.1:\(port)/v1", model: "fixture")
        let tool = ServerProfile(name: "Fixture", address: "/usr/bin/python3", arguments: [Self.fixture.path], enabled: true)
        let session = VoiceSession(kind: .dictation, title: "Prueba", segments: [
            .init(time: 0, source: .microphone, text: "Texto de prueba")
        ])
        try library.save(WorkspaceDocument(sessions: [session], settings: WorkspaceSettings(providers: [profile], servers: [tool])))

        let store = WorkspaceStore(library: library)
        defer { store.cancelModel() }
        for allowed in [false, true] {
            store.ask(session: session, prompt: "Repite hola", useTools: true)
            try await waitFor { store.approval != nil || store.error != nil }
            #expect(store.error == nil)
            let approval = try #require(store.approval)
            #expect(approval.tool == "echo")
            #expect(approval.arguments.contains("hola"))
            #expect(store.document.sessions.first?.exchanges.count == (allowed ? 1 : 0))
            store.resolveApproval(allowed)
            try await waitFor { store.runningID == nil }
            #expect(store.error == nil)
            let answer = try #require(try library.load().sessions.first?.exchanges.last?.answer)
            #expect(answer.contains(allowed ? "\"echo\"" : "declined"))
        }
    }

    @MainActor @Test func debriefAndCoachKeepGroundedMeetingData() async throws {
        let (server, port) = try launchFixtureHTTP()
        defer { if server.isRunning { server.terminate() } }
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let library = LibraryFile(url: folder.appending(path: "library.json"))
        let provider = ProviderProfile(kind: .compatible, endpoint: "http://127.0.0.1:\(port)/v1", model: "fixture")
        let session = VoiceSession(kind: .meeting, title: "Weekly review", segments: [
            .init(time: 0, source: .microphone, text: "We agreed to send the draft tomorrow.")
        ], meeting: MeetingDetails(notes: "My notes", actions: [
            .init(title: "Send the draft", owner: "Me", complete: true)
        ]))
        try library.save(WorkspaceDocument(sessions: [session], settings: WorkspaceSettings(providers: [provider])))
        let store = WorkspaceStore(library: library)
        defer { store.cancelModel() }

        store.writeDebrief(for: session)
        try await waitFor { store.runningID == nil }
        #expect(store.error == nil)
        let details = try #require(try library.load().sessions.first?.meeting)
        #expect(details.summary == "The draft is due tomorrow.")
        #expect(details.notes == "My notes")
        #expect(details.actions.count == 1)
        #expect(details.actions.first?.complete == true)

        store.reviewMeeting(session)
        try await waitFor { store.runningID == nil }
        #expect(store.error == nil)
        let review = try #require(try library.load().sessions.first?.meeting?.coaching.last)
        #expect(review.quote == "We agreed to send the draft tomorrow.")
        #expect(review.suggestion == "I will send the draft tomorrow.")

        store.askLibrary("When is the draft due?")
        try await waitFor { store.runningID == nil }
        #expect(store.error == nil)
        let answer = try #require(try library.load().libraryExchanges?.last)
        #expect(answer.answer == "The draft is due tomorrow [1].")
        #expect(answer.sources.first?.id == session.id)
    }

    @MainActor @Test func meetingLanguagePolicyReachesDebriefAndEveryLiveMode() async throws {
        // The fixture checks the transmitted policy. This does not certify a real model's translations.
        let (server, port) = try launchFixtureHTTP()
        defer { if server.isRunning { server.terminate() } }
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let library = LibraryFile(url: folder.appending(path: "library.json"))
        let provider = ProviderProfile(kind: .compatible, endpoint: "http://127.0.0.1:\(port)/v1", model: "fixture")
        let examples = [
            ("Acordamos entregar el diseño mañana.", "Entregaremos el diseño mañana."),
            ("Nous avons décidé de livrer le dessin demain.", "Le dessin sera livré demain."),
            ("明日デザインを提出することに決まりました。", "明日デザインを提出します。")
        ]
        let sessions = examples.map { example in
            VoiceSession(kind: .meeting, title: "Language regression", segments: [
                .init(time: 0, source: .system, text: example.0)
            ])
        }
        try library.save(WorkspaceDocument(sessions: sessions, settings: WorkspaceSettings(providers: [provider])))
        let store = WorkspaceStore(library: library)
        defer { store.cancelModel() }
        for (index, session) in sessions.enumerated() {
            store.writeDebrief(for: session)
            try await waitFor { store.runningID == nil }
            #expect(store.error == nil)
            #expect(store.document.sessions.first { $0.id == session.id }?.meeting?.summary == examples[index].1)
            for mode in MeetingAssistance.Mode.allCases {
                store.updateMeeting(session.id) {
                    $0.assistance = .init(mode: mode, explanationLanguage: "English")
                }
                let current = try #require(store.document.sessions.first { $0.id == session.id })
                let prompt = QuickPrompt.presets[1]
                let answer = try await store.runModel(current, prompt: prompt.instruction, profile: provider,
                                                      servers: [], live: true, brief: true)
                #expect(answer == examples[index].1)
            }
        }
    }

    @MainActor @Test func meetingPreparationWorksBeforeCaptureWithoutCreatingASession() async throws {
        let (server, port) = try launchFixtureHTTP()
        defer { if server.isRunning { server.terminate() } }
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let library = LibraryFile(url: folder.appending(path: "library.json"))
        let provider = ProviderProfile(kind: .compatible, endpoint: "http://127.0.0.1:\(port)/v1", model: "meeting-prep-fixture")
        try library.save(WorkspaceDocument(settings: WorkspaceSettings(providers: [provider])))
        let store = WorkspaceStore(library: library)
        var prepared: String?
        store.askMeetingPreparation("Confirm the next review") { prepared = $0 }
        try await waitFor { store.runningID == nil }
        #expect(prepared == "Ask who owns the next review.")
        #expect(store.captureID == nil)
        #expect(try library.load().sessions.isEmpty)
    }

    @MainActor @Test func quickReplyUsesEarlierAgreementsAndSavesTheMeaningSeparately() async throws {
        let (server, port) = try launchFixtureHTTP()
        defer { if server.isRunning { server.terminate() } }
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let library = LibraryFile(url: folder.appending(path: "library.json"))
        let provider = ProviderProfile(kind: .compatible, endpoint: "http://127.0.0.1:\(port)/v1", model: "quick-reply-fixture")
        let agreement = TranscriptSegment(time: 0, source: .system, text: "Aprobamos el presupuesto de 8,000 para el prototipo.")
        let other = TranscriptSegment(time: 1, source: .system, text: "This unrelated opening should stay out of the request.")
        let filler = (2...12).map { TranscriptSegment(time: Double($0), source: .system, text: "Other agenda discussion.") }
        let question = TranscriptSegment(time: 13, source: .system, text: "¿Cómo confirmamos el presupuesto del prototipo?")
        let recap = Exchange(prompt: "Catch me up · From the start", answer: "Design review is on Thursday.", provider: provider.name)
        let unrelatedReply = Exchange(prompt: recap.prompt, answer: "This is a later custom answer.", provider: provider.name)
        let details = MeetingDetails(
            assistance: .init(mode: .languageSupport, explanationLanguage: "English"),
            catchUpCheckpoint: .init(segmentID: agreement.id, latestTimestamp: agreement.timestamp, exchangeID: recap.id)
        )
        let meeting = VoiceSession(kind: .meeting, title: "Design", segments: [question, agreement, other] + filler,
                                   exchanges: [recap, unrelatedReply], meeting: details)
        try library.save(WorkspaceDocument(sessions: [meeting], settings: WorkspaceSettings(providers: [provider])))
        let store = WorkspaceStore(library: library)
        let request = LiveMeetingRequest(action: .suggest, speechLanguage: "English")
        store.ask(session: meeting, prompt: request.action.title, useTools: false, brief: true, liveRequest: request)
        try await waitFor { store.runningID == nil }
        #expect(store.error == nil)
        let saved = try #require(try library.load().sessions.first)
        let suggestion = try #require(saved.exchanges.last?.replySuggestion)
        #expect(suggestion.sentence == "¿Podemos confirmar los 8,000 acordados para el prototipo?")
        #expect(suggestion.meaning == "Can we confirm the 8,000 we agreed on for the prototype?")
        #expect(saved.exchanges.last?.answer == suggestion.sentence)
        #expect(saved.markdown.contains(suggestion.meaning ?? "missing"))
        #expect(saved.meeting?.catchUpCheckpoint?.exchangeID == recap.id)

        store.updateMeeting(meeting.id) { $0.assistance?.replyMeaning = false }
        let updated = try #require(store.document.sessions.first)
        store.ask(session: updated, prompt: request.action.title, useTools: false, brief: true, liveRequest: request)
        try await waitFor { store.runningID == nil }
        #expect(store.error == nil)
        let withoutMeaning = try #require(try library.load().sessions.first?.exchanges.last?.replySuggestion)
        #expect(withoutMeaning.sentence == suggestion.sentence)
        #expect(withoutMeaning.meaning == nil)
    }

    @MainActor @Test func phoneReplyUsesCurrentSpeechAndTheEntirePreparation() async throws {
        let (server, port) = try launchFixtureHTTP()
        defer { if server.isRunning { server.terminate() } }
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let library = LibraryFile(url: folder.appending(path: "library.json"))
        let provider = ProviderProfile(kind: .compatible, endpoint: "http://127.0.0.1:\(port)/v1", model: "phone-reply-fixture")
        let notes = "Goal: ask about delivery.\n" + String(repeating: "Background. ", count: 110)
            + "\nNo date commitments until I check with my team."
        let earlier = (1...8).map {
            TranscriptSegment(time: Double($0), source: .microphone, text: "Earlier discussion \($0).")
        }
        let call = VoiceSession(
            kind: .meeting, title: "Phone call",
            segments: earlier + [.init(time: 9, source: .microphone, text: "Can you commit to Friday?")],
            meeting: .init(assistance: .init(explanationLanguage: "Spanish", replyMeaning: true,
                                             preparation: notes, phoneCall: true))
        )
        try library.save(WorkspaceDocument(sessions: [call], settings: WorkspaceSettings(providers: [provider])))
        let store = WorkspaceStore(library: library)
        let request = LiveMeetingRequest(action: .suggest, speechLanguage: "English (United States)", phoneCall: true)
        store.ask(session: call, prompt: request.action.title, useTools: false, liveRequest: request)
        try await waitFor { store.runningID == nil }
        #expect(store.error == nil)
        let saved = try #require(try library.load().sessions.first)
        #expect(saved.meeting?.assistance?.isPhoneCall == true)
        let reply = try #require(saved.exchanges.last?.replySuggestion)
        #expect(reply.sentence == "Could I check with my team and get back to you?")
        #expect(reply.meaning == "¿Puedo consultarlo con mi equipo y luego avisarle?")
    }

    @MainActor @Test func phoneRecapPersistsAgreementsDatesAndPendingRequirements() async throws {
        let (server, port) = try launchFixtureHTTP()
        defer { if server.isRunning { server.terminate() } }
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let library = LibraryFile(url: folder.appending(path: "library.json"))
        let provider = ProviderProfile(kind: .compatible, endpoint: "http://127.0.0.1:\(port)/v1", model: "phone-recap-fixture")
        let call = VoiceSession(
            kind: .meeting, title: "Phone call",
            segments: [.init(time: 5, source: .microphone,
                             text: "We agreed on batch A for Thursday. I will send the checklist. We still need the proof.")],
            meeting: .init(assistance: .init(preparation: "Ask whether Tuesday is possible.", phoneCall: true))
        )
        try library.save(WorkspaceDocument(sessions: [call], settings: WorkspaceSettings(providers: [provider])))
        let store = WorkspaceStore(library: library)
        store.writeDebrief(for: call)
        try await waitFor { store.runningID == nil }
        #expect(store.error == nil)
        let saved = try #require(try library.load().sessions.first)
        #expect(saved.meeting?.decisions == ["Ship batch A."])
        #expect(saved.meeting?.recapDates == ["Thursday · confirmed shipment"])
        #expect(saved.meeting?.openRequirements == ["Proof still needed."])
        #expect(saved.meeting?.actions.first?.title == "Send the checklist")
        #expect(saved.markdown.contains("## Open requirements"))
        #expect(!saved.markdown.contains("Tuesday"))
    }

    @MainActor @Test func regenerationKeepsACompletedTaskWhenTheProviderRewordsIt() async throws {
        let (server, port) = try launchFixtureHTTP()
        defer { if server.isRunning { server.terminate() } }
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let library = LibraryFile(url: folder.appending(path: "library.json"))
        let provider = ProviderProfile(kind: .compatible, endpoint: "http://127.0.0.1:\(port)/v1", model: "task-match-fixture")
        let task = ActionItem(title: "Send the draft", complete: true)
        let session = VoiceSession(kind: .meeting, title: "Action item regression", segments: [
            .init(time: 0, source: .system, text: "Ana, envía el borrador mañana.")
        ], meeting: .init(actions: [task]))
        try library.save(WorkspaceDocument(sessions: [session], settings: WorkspaceSettings(providers: [provider])))
        let store = WorkspaceStore(library: library)
        store.writeDebrief(for: session)
        try await waitFor { store.runningID == nil }
        #expect(store.error == nil)
        let details = try #require(try library.load().sessions.first?.meeting)
        #expect(details.summary == "El borrador se envía mañana.")
        #expect(details.actions.map(\.id) == [task.id])
        #expect(details.actions.first?.complete == true)
    }

    @MainActor @Test func catchUpRemembersSuccessfulRecapsAndIncludesLateSpeech() async throws {
        let (server, port) = try launchFixtureHTTP()
        defer { if server.isRunning { server.terminate() } }
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let library = LibraryFile(url: folder.appending(path: "library.json"))
        let provider = ProviderProfile(kind: .compatible, endpoint: "http://127.0.0.1:\(port)/v1", model: "catch-up-fixture")
        let opening = TranscriptSegment(time: 20, source: .system, text: "opening-checkpoint")
        let late = TranscriptSegment(time: 10, source: .microphone, text: "late-finalized-speech")
        let session = VoiceSession(kind: .meeting, title: "Recap test", segments: [opening])
        try library.save(WorkspaceDocument(sessions: [session], settings: WorkspaceSettings(providers: [provider])))
        let store = WorkspaceStore(library: library)

        store.catchUp(sessionID: session.id)
        store.updateSession(session.id) { $0.segments.append(late) }
        try await waitFor { store.runningID == nil }
        var saved = try #require(try library.load().sessions.first)
        #expect(saved.exchanges.last?.answer == "Opening recap.")
        #expect(saved.meeting?.catchUpCheckpoint?.segmentID == opening.id)

        store.catchUp(sessionID: session.id)
        try await waitFor { store.runningID == nil }
        saved = try #require(try library.load().sessions.first)
        #expect(saved.exchanges.last?.answer == "New speech recap.")
        #expect(saved.meeting?.catchUpCheckpoint?.segmentID == late.id)
        #expect(saved.meeting?.catchUpCheckpoint?.latestTimestamp == "00:20")
        let coverage = try #require(saved.meeting?.catchUpCheckpoint)
        let later = TranscriptSegment(time: 40, source: .microphone, text: "More speech")
        #expect(coverage.latestCoveredSegment(in: saved.segments + [later])?.id == opening.id)
        store.catchUp(sessionID: session.id)
        #expect(store.runningID == nil)

        store.catchUp(sessionID: session.id, fromBeginning: true)
        try await waitFor { store.runningID == nil }
        saved = try #require(try library.load().sessions.first)
        #expect(saved.exchanges.map(\.answer) == ["Opening recap.", "New speech recap.", "Full recap."])

        store.updateSession(session.id) {
            $0.segments.append(.init(time: 30, source: .system, text: "simulate-failed-recap"))
        }
        store.catchUp(sessionID: session.id)
        try await waitFor { store.runningID == nil }
        saved = try #require(try library.load().sessions.first)
        #expect(store.error != nil)
        #expect(saved.meeting?.catchUpCheckpoint?.segmentID == late.id)
        #expect(saved.exchanges.count == 3)
    }

    @MainActor @Test func longCatchUpUsesAllTranscriptParts() async throws {
        let (server, port) = try launchFixtureHTTP()
        defer { if server.isRunning { server.terminate() } }
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let library = LibraryFile(url: folder.appending(path: "library.json"))
        let provider = ProviderProfile(kind: .compatible, endpoint: "http://127.0.0.1:\(port)/v1", model: "long-catch-up-fixture")
        let padding = String(repeating: "We discussed options. ", count: 2_000)
        let session = VoiceSession(kind: .meeting, title: "Long recap", segments: [
            .init(time: 0, source: .system, text: "first-marker " + padding),
            .init(time: 1_200, source: .system, text: "middle-marker " + padding),
            .init(time: 2_500, source: .system, text: "last-marker")
        ])
        try library.save(WorkspaceDocument(sessions: [session], settings: WorkspaceSettings(providers: [provider])))
        let store = WorkspaceStore(library: library)
        store.catchUp(sessionID: session.id)
        try await waitFor { store.runningID == nil }
        let saved = try #require(try library.load().sessions.first)
        #expect(store.error == nil)
        #expect(saved.exchanges.last?.answer == "All three parts reviewed.")
        #expect(saved.meeting?.catchUpCheckpoint?.segmentID == session.segments.last?.id)
    }

    @MainActor @Test func longDebriefConsolidatesDecisionsFromTheMiddle() async throws {
        let (server, port) = try launchFixtureHTTP()
        defer { if server.isRunning { server.terminate() } }
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let library = LibraryFile(url: folder.appending(path: "library.json"))
        let provider = ProviderProfile(kind: .compatible, endpoint: "http://127.0.0.1:\(port)/v1",
                                       model: "long-debrief-fixture")
        let padding = String(repeating: "We discussed options. ", count: 3_000)
        let session = VoiceSession(kind: .meeting, title: "Long meeting", segments: [
            .init(time: 0, source: .system, text: "first-marker " + padding),
            .init(time: 1_800, source: .system, text: "middle-marker " + padding),
            .init(time: 3_600, source: .system, text: "last-marker")
        ])
        try library.save(WorkspaceDocument(sessions: [session], settings: WorkspaceSettings(providers: [provider])))
        let store = WorkspaceStore(library: library)
        defer { store.cancelModel() }
        store.writeDebrief(for: session)
        try await waitFor { store.runningID == nil }
        #expect(store.error == nil)
        #expect(try library.load().sessions.first?.meeting?.decisions == ["first-marker", "middle-marker", "last-marker"])
    }

    @MainActor private func waitFor(_ condition: () -> Bool) async throws {
        for _ in 0..<150 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw WorkspaceError("The app did not reach the expected state.")
    }

    private func launchFixtureHTTP() throws -> (Process, Int) {
        let output = Pipe()
        let server = Process()
        server.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        server.arguments = [Self.fixture.path, "http"]
        server.standardOutput = output
        try server.run()
        let data = output.fileHandleForReading.availableData
        let port = try #require(Int(String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)))
        return (server, port)
    }

    private func verifyEcho(_ connection: MCPConnection) async throws {
        let tools = try await connection.list()
        #expect(tools.map(\.name) == ["echo"])
        let result = try await connection.call("echo", arguments: ["word": .string("hola")])
        #expect(result.contains("hola"))
        #expect(result.contains("\"echo\""))
    }

    @Test(arguments: [ProviderKind.openAI, .anthropic])
    func providerToolRoundTrip(kind: ProviderKind) async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ProviderFixture.self]
        let profile = ProviderProfile(kind: kind, endpoint: "https://fixture.invalid/v1", model: "fixture-model")
        let model = ModelClient(profile: profile, key: "fixture-key", session: URLSession(configuration: configuration))
        let tool = ModelTool(name: "echo", description: "Echo a word", schema: .object(["type": .string("object")]))
        let proposed = try await model.reply(system: "system", prompt: "say hola", tools: [tool])
        let call = try #require(proposed.calls.first)
        #expect(call.name == "echo")
        #expect(call.arguments["word"] == .string("hola"))
        let final = try await model.continueReply(system: "system", results: [(call, "hola")], tools: [tool])
        #expect(final.text == "Resultado: hola.")
        #expect(final.calls.isEmpty)
    }
}

private final class ProviderFixture: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            let url = try #require(request.url)
            let stream = try #require(request.httpBodyStream)
            stream.open()
            defer { stream.close() }
            var data = Data()
            var bytes = [UInt8](repeating: 0, count: 4096)
            while true {
                let count = stream.read(&bytes, maxLength: bytes.count)
                if count < 0 { throw WorkspaceError("Fixture could not read request body") }
                if count == 0 { break }
                data.append(contentsOf: bytes.prefix(count))
            }
            let body = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
            let turns = try #require(body["messages"] as? [[String: Any]])
            #expect(body["model"] as? String == "fixture-model")
            #expect(request.httpMethod == "POST")
            #expect((body["tools"] as? [[String: Any]])?.count == 1)

            let output: String
            if url.path == "/v1/messages" {
                #expect(request.value(forHTTPHeaderField: "x-api-key") == "fixture-key")
                #expect(body["system"] as? String == "system")
                if turns.count == 1 {
                    output = #"{"content":[{"type":"tool_use","id":"call_1","name":"echo","input":{"word":"hola"}}]}"#
                } else {
                    let blocks = try #require(turns.last?["content"] as? [[String: String]])
                    #expect(blocks.first?["tool_use_id"] == "call_1")
                    #expect(blocks.first?["content"] == "hola")
                    output = #"{"content":[{"type":"text","text":"Resultado: hola."}]}"#
                }
            } else {
                #expect(url.path == "/v1/chat/completions")
                #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-key")
                if turns.count == 2 {
                    output = #"{"choices":[{"message":{"content":null,"tool_calls":[{"id":"call_1","type":"function","function":{"name":"echo","arguments":"{\"word\":\"hola\"}"}}]}}]}"#
                } else {
                    #expect(turns.last?["tool_call_id"] as? String == "call_1")
                    #expect(turns.last?["content"] as? String == "hola")
                    output = #"{"choices":[{"message":{"content":"Resultado: hola."}}]}"#
                }
            }
            let response = try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil))
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(output.utf8))
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
