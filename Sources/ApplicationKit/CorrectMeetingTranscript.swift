import Foundation
import PortavozCore

public protocol TranscriptCorrectionRepository: Sendable {
    func transcriptCorrectionHistory(
        for meetingID: MeetingID
    ) async throws -> [TranscriptCorrectionEvent]

    func appendTranscriptCorrections(
        _ events: [TranscriptCorrectionEvent]
    ) async throws -> [TranscriptCorrectionEvent]
}

public struct TranscriptCorrectionEditorContext: Sendable, Equatable {
    public let original: MeetingTranscriptContent.Row
    public let current: MeetingTranscriptContent.Row
    public let history: [TranscriptCorrectionEvent]
    public let hasTextCorrection: Bool
    public let hasSpeakerCorrection: Bool
    public let hasStructuralCorrection: Bool

    public init(
        original: MeetingTranscriptContent.Row,
        current: MeetingTranscriptContent.Row,
        history: [TranscriptCorrectionEvent],
        hasTextCorrection: Bool,
        hasSpeakerCorrection: Bool,
        hasStructuralCorrection: Bool
    ) {
        self.original = original
        self.current = current
        self.history = history
        self.hasTextCorrection = hasTextCorrection
        self.hasSpeakerCorrection = hasSpeakerCorrection
        self.hasStructuralCorrection = hasStructuralCorrection
    }
}

public extension MeetingReviewReadModel {
    /// Produces the one correction-aware reading currently adopted by Meeting
    /// Detail. Other consumers remain on accepted transcript material until
    /// their invalidation contracts explicitly opt in.
    func transcriptContent(
        chapterTitles: [TimeInterval: String] = [:]
    ) -> MeetingTranscriptContent {
        let material: MeetingTranscriptBaseMaterial = core.isRefinedTranscript
            ? .refined
            : .raw
        let currentCorrections = corrections.filter {
            $0.baseTranscriptRevision == meeting.transcriptRevision
        }
        let accepted = MeetingTranscriptContent.accepted(
            baseTranscriptRevision: meeting.transcriptRevision,
            segments: segments,
            chapterTitles: chapterTitles,
            baseMaterial: material)
        guard let composition = try? ComposeTranscript().execute(
            baseTranscriptRevision: meeting.transcriptRevision,
            baseMaterial: material,
            segments: segments,
            chapterTitles: chapterTitles,
            corrections: currentCorrections)
        else { return accepted }
        return composition.composed
    }

    func transcriptCorrectionEditorContext(
        for current: MeetingTranscriptContent.Row
    ) -> TranscriptCorrectionEditorContext? {
        guard current.sourceSegmentIDs.count == 1,
              let sourceID = current.sourceSegmentIDs.first,
              let source = segments.first(where: { $0.id == sourceID })
        else { return nil }
        let original = MeetingTranscriptContent.Row(
            id: source.id,
            sourceSegmentIDs: [source.id],
            speakerID: source.speakerID,
            channel: source.channel,
            text: source.text,
            language: source.language,
            startTime: source.startTime,
            endTime: source.endTime,
            confidence: source.confidence,
            isFinal: source.isFinal)
        let currentHistory = corrections
            .filter {
                $0.baseTranscriptRevision == meeting.transcriptRevision
                    && $0.targetSegmentIDs.contains(sourceID)
            }
            .sorted(by: TranscriptCorrectionPolicy.precedes)
        let superseded = Set(currentHistory.compactMap(\.supersedesCorrectionID))
        let active = currentHistory.filter {
            $0.deletedAt == nil && !superseded.contains($0.id)
        }
        let effectiveActive = active.filter {
            if case .restore = $0.kind { return false }
            return true
        }
        let domains = Set(effectiveActive.compactMap {
            try? TranscriptCorrectionPolicy.correctionDomain(of: $0, in: currentHistory)
        })
        return TranscriptCorrectionEditorContext(
            original: original,
            current: current,
            history: currentHistory,
            hasTextCorrection: domains.contains(.text),
            hasSpeakerCorrection: domains.contains(.speaker),
            hasStructuralCorrection: domains.contains(.structure))
    }
}

public struct CorrectMeetingTranscriptRequest: Sendable, Equatable {
    public let meetingID: MeetingID
    public let baseTranscriptRevision: Int
    public let original: MeetingTranscriptContent.Row
    public let correctedText: String
    public let correctedSpeakerID: SpeakerID?

    public init(
        meetingID: MeetingID,
        baseTranscriptRevision: Int,
        original: MeetingTranscriptContent.Row,
        correctedText: String,
        correctedSpeakerID: SpeakerID?
    ) {
        self.meetingID = meetingID
        self.baseTranscriptRevision = baseTranscriptRevision
        self.original = original
        self.correctedText = correctedText
        self.correctedSpeakerID = correctedSpeakerID
    }
}

public enum CorrectMeetingTranscriptError: Error, Equatable, LocalizedError, Sendable {
    case invalidTarget
    case invalidText
    case incompatibleStructuralCorrection

    public var errorDescription: String? {
        switch self {
        case .invalidTarget:
            "This transcript line no longer matches the accepted recording."
        case .invalidText:
            "Corrected transcript text must contain spoken content."
        case .incompatibleStructuralCorrection:
            "This line has a structural correction that must be reviewed first."
        }
    }
}

public struct CorrectMeetingTranscriptResult: Sendable, Equatable {
    public let events: [TranscriptCorrectionEvent]

    public init(events: [TranscriptCorrectionEvent]) {
        self.events = events
    }

    public var changed: Bool { !events.isEmpty }
}

/// Owns the write policy for one focused text/speaker edit. Independent lanes
/// are appended atomically, and returning to accepted evidence emits a
/// superseding restore event instead of deleting history.
public struct CorrectMeetingTranscript: ApplicationUseCase {
    private let repository: any TranscriptCorrectionRepository
    private let sourceDeviceID: UUID
    private let now: @Sendable () -> Date

    public init(
        repository: any TranscriptCorrectionRepository,
        sourceDeviceID: UUID,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.repository = repository
        self.sourceDeviceID = sourceDeviceID
        self.now = now
    }

    public func execute(
        _ request: CorrectMeetingTranscriptRequest
    ) async throws -> CorrectMeetingTranscriptResult {
        guard request.baseTranscriptRevision >= 0,
              request.original.sourceSegmentIDs.count == 1,
              let sourceSegmentID = request.original.sourceSegmentIDs.first
        else { throw CorrectMeetingTranscriptError.invalidTarget }

        let text = request.correctedText.trimmingCharacters(
            in: .whitespacesAndNewlines)
        guard TranscriptContentPolicy.hasLexicalContent(text) else {
            throw CorrectMeetingTranscriptError.invalidText
        }

        let history = try await repository.transcriptCorrectionHistory(
            for: request.meetingID)
        try TranscriptCorrectionPolicy.validateHistory(
            history,
            meetingID: request.meetingID)
        let terminals = try terminalCorrections(
            in: history,
            target: sourceSegmentID,
            revision: request.baseTranscriptRevision)
        if terminals[.structure] != nil {
            throw CorrectMeetingTranscriptError.incompatibleStructuralCorrection
        }

        var events: [TranscriptCorrectionEvent] = []
        let desiredText = request.correctedText == request.original.text
            ? request.original.text
            : text
        if let event = replacementEvent(
            desiredText: desiredText,
            request: request,
            target: sourceSegmentID,
            predecessor: terminals[.text]) {
            events.append(event)
        }
        if let event = speakerEvent(
            desiredSpeakerID: request.correctedSpeakerID,
            request: request,
            target: sourceSegmentID,
            predecessor: terminals[.speaker]) {
            events.append(event)
        }
        guard !events.isEmpty else {
            return CorrectMeetingTranscriptResult(events: [])
        }
        let persisted = try await repository.appendTranscriptCorrections(events)
        return CorrectMeetingTranscriptResult(events: persisted)
    }
}

private extension CorrectMeetingTranscript {
    func terminalCorrections(
        in history: [TranscriptCorrectionEvent],
        target: UUID,
        revision: Int
    ) throws -> [TranscriptCorrectionDomain: TranscriptCorrectionEvent] {
        let superseded = Set(history.compactMap(\.supersedesCorrectionID))
        let active = history.filter {
            $0.baseTranscriptRevision == revision
                && $0.targetSegmentIDs.contains(target)
                && $0.deletedAt == nil
                && !superseded.contains($0.id)
        }
        var result: [TranscriptCorrectionDomain: TranscriptCorrectionEvent] = [:]
        for event in active {
            let domain = try TranscriptCorrectionPolicy.correctionDomain(
                of: event,
                in: history)
            result[domain] = event
        }
        return result
    }

    func replacementEvent(
        desiredText: String,
        request: CorrectMeetingTranscriptRequest,
        target: UUID,
        predecessor: TranscriptCorrectionEvent?
    ) -> TranscriptCorrectionEvent? {
        let currentText: String
        switch predecessor?.kind {
        case .replaceText(let text, _): currentText = text
        default: currentText = request.original.text
        }
        guard desiredText != currentText else { return nil }
        let kind: TranscriptCorrectionKind = desiredText == request.original.text
            ? .restore
            : .replaceText(text: desiredText, language: request.original.language)
        return event(
            request: request,
            target: target,
            kind: kind,
            predecessor: predecessor)
    }

    func speakerEvent(
        desiredSpeakerID: SpeakerID?,
        request: CorrectMeetingTranscriptRequest,
        target: UUID,
        predecessor: TranscriptCorrectionEvent?
    ) -> TranscriptCorrectionEvent? {
        let currentSpeakerID: SpeakerID?
        switch predecessor?.kind {
        case .changeSpeaker(let speakerID): currentSpeakerID = speakerID
        default: currentSpeakerID = request.original.speakerID
        }
        guard desiredSpeakerID != currentSpeakerID else { return nil }
        let kind: TranscriptCorrectionKind = desiredSpeakerID == request.original.speakerID
            ? .restore
            : .changeSpeaker(desiredSpeakerID)
        return event(
            request: request,
            target: target,
            kind: kind,
            predecessor: predecessor)
    }

    func event(
        request: CorrectMeetingTranscriptRequest,
        target: UUID,
        kind: TranscriptCorrectionKind,
        predecessor: TranscriptCorrectionEvent?
    ) -> TranscriptCorrectionEvent {
        let minimumDate = predecessor.map {
            $0.createdAt.addingTimeInterval(0.001)
        } ?? .distantPast
        let timestamp = max(now(), minimumDate)
        return TranscriptCorrectionEvent(
            meetingID: request.meetingID,
            baseTranscriptRevision: request.baseTranscriptRevision,
            targetSegmentIDs: [target],
            kind: kind,
            sourceDeviceID: sourceDeviceID,
            createdAt: timestamp,
            supersedesCorrectionID: predecessor?.id)
    }
}
