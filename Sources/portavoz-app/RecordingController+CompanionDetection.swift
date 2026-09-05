import ApplicationKit
import Foundation
import IntelligenceKit
import PortavozCore

// Live Apuntador detection (D26) and the D138 silence endpointer, split out
// of RecordingController for the type-body budget. Same type, same rules:
// closed rows dispatch on close, and the still-open remote row dispatches
// after two seconds of delta silence so a question followed by silence still
// cards during the meeting.
extension RecordingController {
    /// Live callbacks can publish more than one caption row before Start
    /// returns its committed session. Detection stays disabled during that
    /// preparation window, so drain every row that already closed, then arm
    /// the still-open tail once the lifecycle becomes `.recording`.
    func activateCompanionDetectionAfterRecordingStart() {
        guard phase == .recording else { return }
        for closed in captions.dropLast() where TurnEndpointPolicy.shouldDetect(
            after: speculativeTurnMark,
            rowID: closed.id,
            textCount: closed.text.count
        ) {
            dispatchCompanionDetection(for: closed)
        }
        lastOpenRowID = captions.last?.id
        armTurnEndpointDeadline()
    }

    /// The coalescer only ever grows the NEWEST row; when the newest row's
    /// id changes, the previous one closed for good — that's the moment a
    /// caption becomes a companion candidate. The D138 turn endpointer may
    /// have already detected the same row during the silence before this
    /// close; an unchanged text then adds nothing.
    func detectClosedRow() {
        guard captions.last?.id != lastOpenRowID else { return }
        let previousOpen = lastOpenRowID
        lastOpenRowID = captions.last?.id
        guard let closed = captions.last(where: { $0.id == previousOpen }) else { return }
        requestLiveSummaryRefresh()
        observeProactiveAssist()
        guard TurnEndpointPolicy.shouldDetect(
            after: speculativeTurnMark,
            rowID: closed.id,
            textCount: closed.text.count)
        else { return }
        dispatchCompanionDetection(for: closed)
    }

    /// D138 stage 0: closing is delta-driven, so silence never closes a row
    /// and a question followed by silence would never card during the
    /// meeting. After `TurnEndpointPolicy.silenceSeconds` without any new
    /// delta, the open remote row is treated as a finished turn and runs the
    /// SAME detection a real close would run. The row itself stays open —
    /// presentation is untouched, a late delta still extends it, and the
    /// mark plus the card dedup absorb the eventual real close.
    func armTurnEndpointDeadline() {
        turnEndpointTask?.cancel()
        turnEndpointTask = nil
        guard companionEnabled, phase == .recording,
              captions.last?.channel == .system else { return }
        turnEndpointTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(TurnEndpointPolicy.silenceSeconds))
            guard !Task.isCancelled else { return }
            self?.fireTurnEndpoint()
        }
    }

    private func fireTurnEndpoint() {
        guard phase == .recording, let open = captions.last else { return }
        guard TurnEndpointPolicy.shouldDetect(
            after: speculativeTurnMark,
            rowID: open.id,
            textCount: open.text.count)
        else { return }
        // Mark only what actually dispatched: if opt-out or lifecycle state
        // declined the deadline, the eventual real close remains eligible.
        guard dispatchCompanionDetection(for: open) else { return }
        speculativeTurnMark = SpeculativeTurnMark(
            rowID: open.id, textCount: open.text.count)
    }

    /// Returns whether a detection actually left for the scheduler, so the
    /// speculative path records its mark only on real work.
    @discardableResult
    private func dispatchCompanionDetection(for row: TranscriptSegment) -> Bool {
        guard companionEnabled, phase == .recording else { return false }
        // "Asked you" (D26): a mention of your name opens the gate
        // even when the sentence does not look like a question ("Johnny, tell us about the deploy").
        let ownerName = Self.companionOwnerName()
        guard TurnEndpointPolicy.isTurnEndCandidate(
            channel: row.channel,
            text: row.text,
            confidence: row.confidence,
            ownerName: ownerName
        ) else { return false }
        let closed = row

        let passages = recentPassages()
        let candidate = closed.text
        let askedAt = closed.startTime
        guard let services else { return false }
        let language = closed.language.flatMap { LanguageCode($0)?.identifier }
        let sourceMeetingID = meetingID
        companionCoordinator(services: services).submit(
            CompanionGenerationRequest(
                meetingID: sourceMeetingID,
                sourceTranscriptRevision: 0,
                sourceCorrectionRevision: .accepted,
                workflow: .liveRecording,
                candidate: candidate,
                questionSegmentIDs: [closed.id],
                recentTranscript: passages,
                ownerName: ownerName,
                outputLanguage: language,
                askedAt: askedAt))
        return true
    }

    func cancelCompanionGeneration() {
        companionWorkCoordinator?.cancel()
    }

    private func companionCoordinator(
        services: AppServices
    ) -> LiveCompanionWorkCoordinator {
        if let companionWorkCoordinator {
            return companionWorkCoordinator
        }
        let coordinator = LiveCompanionWorkCoordinator(
            generator: { [weak services] request in
                guard let services else { return .unavailable }
                // BYOK exists only after explicit Settings opt-in; otherwise
                // the injected client is nil and Companion remains on-device.
                let companion = ProviderNeutralProvenanceCompanion(
                    byok: await services.companionBYOKClient(),
                    egressConsentSource: .companionBYOKSettings,
                    allowsFoundationModelChallenger: services.appleSummaryAvailable)
                return await companion.generate(request)
            },
            receiver: { [weak self] request, result in
                self?.recordCompanionOutcome(
                    result,
                    sourceMeetingID: request.meetingID)
            })
        companionWorkCoordinator = coordinator
        return coordinator
    }

    /// The live meeting's recent closed rows as RAG passages, so a
    /// "context" question ("what did we say about the budget?") answers
    /// from what was JUST said.
    private func recentPassages() -> [RAGPassage] {
        captions.suffix(14).dropLast().map { row in
            RAGPassage(
                segmentID: row.id,
                meetingID: meetingID,
                meetingTitle: "This meeting",
                timestamp: row.startTime,
                text: (row.channel == .microphone ? "Me: " : "Them: ") + row.text)
        }
    }

    /// The name the meeting uses to address you: Settings if it
    /// was configured, otherwise your macOS account name. nil = detector off.
    static func companionOwnerName() -> String? {
        let custom = (UserDefaults.standard.string(forKey: "companionUserName") ?? "")
            .trimmingCharacters(in: .whitespaces)
        let name = custom.isEmpty ? NSFullUserName() : custom
        return name.isEmpty ? nil : name
    }
}
