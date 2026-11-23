import Foundation

enum PhoneVoiceStatus: Equatable {
    case loading, ready, separateInputs, unavailable
}

extension WorkspaceStore {
    var recentPhoneSpeech: [TranscriptSegment] {
        guard let meeting = activeMeeting else { return [] }
        let recorded = Array(meeting.segments.suffix(8)) + Array(partials.values)
        let ordered = recorded.sorted { $0.time < $1.time }
        return Array(ordered.flatMap {
            phoneTurns.split($0, words: phoneWords[$0.id] ?? [])
        }.suffix(8))
    }

    var autoRepliesEnabled: Bool {
        guard let provider = selectedProvider else { return false }
        return autoReplyProviderID == provider.id
    }

    func showLiveReply(_ reply: ReplySuggestion?) {
        liveReply = reply
    }

    func startPhoneTurnTracking(phaseStart: Double, separateInputs: Bool) -> PhoneSpeakerStream? {
        stopPhoneTurnTracking()
        phoneTurns = PhoneCallTurns(phaseStart: phaseStart, separateInputs: separateInputs)
        liveReply = nil
        phoneWords = [:]
        lastMacPhoneReplyRequest = nil
        if separateInputs {
            phoneVoiceStatus = .separateInputs
            phoneTurnTask = Task { [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .milliseconds(150)) }
                    catch { return }
                    guard let self else { return }
                    if self.autoRepliesEnabled { self.considerPhoneReply() }
                }
            }
            return nil
        }
        phoneVoiceStatus = .loading
        let stream = PhoneSpeakerStream()
        let generation = UUID()
        phoneTurnGeneration = generation
        phoneTurnTask = Task { [weak self] in
            do {
                try await stream.detect(onReady: { [weak self] in
                    await self?.phoneSpeakerReady(generation: generation)
                }, onUpdate: { [weak self] snapshot in
                    await self?.phoneSpeakerUpdated(snapshot, generation: generation)
                })
            } catch {
                guard let self, !Task.isCancelled, self.phoneTurnGeneration == generation else { return }
                self.phoneVoiceStatus = .unavailable
                if self.automaticReplyInProgress { self.cancelModel() }
            }
        }
        return stream
    }

    func stopPhoneTurnTracking() {
        pendingReplyTurn = nil
        meetingReplyTask?.cancel()
        meetingReplyTask = nil
        lastMeetingReplyTurn.removeAll()
        phoneTurnTask?.cancel()
        phoneTurnTask = nil
        phoneTurnGeneration = nil
        if automaticReplyInProgress { cancelModel() }
    }

    private func phoneSpeakerReady(generation: UUID) {
        guard phoneTurnGeneration == generation else { return }
        phoneVoiceStatus = .ready
    }

    private func phoneSpeakerUpdated(_ snapshot: PhoneSpeakerSnapshot, generation: UUID) {
        guard phoneTurnGeneration == generation else { return }
        phoneTurns.speakers = snapshot
        considerPhoneReply()
    }

    func setAutoReplies(_ enabled: Bool) {
        autoReplyFailures = 0
        autoReplyProviderID = enabled ? selectedProvider?.id : nil
        phoneTurns.markRequested(through: phoneTurns.speakers.through)
        lastMacPhoneReplyRequest = .now
        pendingReplyTurn = nil
        meetingReplyTask?.cancel()
        if !enabled && automaticReplyInProgress { cancelModel() }
    }

    func identifyPhoneVoice(_ speech: TranscriptSegment) {
        guard captureReady, phoneVoiceStatus == .ready, let slot = phoneTurns.slot(for: speech) else { return }
        if automaticReplyInProgress { cancelModel() }
        liveReply = nil
        pendingReplyTurn = nil
        meetingReplyTask?.cancel()
        phoneTurns.identifySelf(as: slot)
        if let id = activeMeeting?.id {
            // Name recent lines once the user maps the local diarizer's voice slot.
            let turns = phoneTurns
            updateSession(id) { meeting in
                let start = max(meeting.segments.count - 24, 0)
                for index in start..<meeting.segments.count {
                    let segment = meeting.segments[index]
                    if turns.slot(for: segment) != nil, let label = turns.label(for: segment) {
                        meeting.segments[index].speaker = label == "You" || label == "Caller" ? label : nil
                    }
                }
            }
        }
    }

    private func userStartedSpeaking() {
        guard automaticReplyInProgress else { return }
        if !answerPreview.isEmpty {
            showLiveReply(ReplySuggestion(sentence: answerPreview, meaning: nil))
        }
        cancelModel()
    }

    func considerPhoneReply() {
        guard captureReady, let meeting = activeMeeting else { return }
        if phoneVoiceStatus == .separateInputs {
            considerMacAudioPhoneReply(meeting)
            return
        }
        guard phoneVoiceStatus == .ready, let latest = recentPhoneSpeech.last else { return }
        phoneTurns.observeCaller(in: latest)
        if phoneTurns.userHasStartedTalking {
            userStartedSpeaking()
            return
        }
        guard autoRepliesEnabled, runningID == nil, !isQuitting,
              let turn = phoneTurns.replyOpportunity(for: latest) else { return }
        phoneTurns.markRequested(through: turn.end, from: turn.start)
        requestPhoneReply(meeting, automatically: true)
    }

    private func considerMacAudioPhoneReply(_ meeting: VoiceSession) {
        let micSpeech = phoneTurns.lastMicTranscriptUpdate
        if let micSpeech, let request = lastMacPhoneReplyRequest, micSpeech > request {
            userStartedSpeaking()
        }
        guard autoRepliesEnabled, runningID == nil, !isQuitting,
              let latest = recentPhoneSpeech.last(where: { $0.source == .system }),
              let turn = phoneTurns.macAudioReplyOpportunity(
                for: latest, now: .now, lastMacSignal: captureLastSignal(for: .system),
                lastMicSignal: micSpeech, enabledSince: lastMacPhoneReplyRequest
              ) else { return }
        phoneTurns.markRequested(through: turn.upperBound, from: turn.lowerBound)
        lastMacPhoneReplyRequest = .now
        requestPhoneReply(meeting, automatically: true)
    }

    func requestPhoneReply(_ meeting: VoiceSession, automatically: Bool = false, focus: PhoneReplyFocus = .respond) {
        if !automatically {
            let turn = phoneTurns.speakers.latest
            phoneTurns.markRequested(through: turn?.end ?? phoneTurns.speakers.through, from: turn?.start)
            if phoneTurns.separateInputs { lastMacPhoneReplyRequest = .now }
        }
        let language = meetingLanguage.flatMap { Locale(identifier: "en").localizedString(forIdentifier: $0) }
        let request = LiveMeetingRequest(action: .suggest, speechLanguage: language, phoneCall: true,
                                         automaticReply: automatically, phoneReplyFocus: focus)
        ask(session: meeting, prompt: request.action.title, useTools: false, brief: true, liveRequest: request)
    }
}
