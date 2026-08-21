import ApplicationKit
import Foundation
import PortavozCore
import StorageKit

struct AskQualityCorpusMapping: Sendable {
    private struct Unit: Sendable {
        let id: String
        let sourceSegmentIDs: [String]
    }

    private struct SeededMeeting: Sendable {
        let meetingID: MeetingID
        let unitByUUID: [UUID: Unit]
    }

    private struct ProjectionConfiguration: Sendable {
        let retrievalUnit: AskQualityRetrievalUnit
        let semanticBoundaryEmbedding: (any RetrievalSemanticBoundaryEmbedding)?
        let expectedAdapter: String
    }

    private let unitByUUID: [UUID: Unit]
    private let externalMeetingIDByDomainID: [MeetingID: String]
    let adapter: String

    static func seed(
        fixture: AskQualityFixture,
        store: MeetingStore,
        retrievalUnit: AskQualityRetrievalUnit = .segment,
        semanticBoundaryEmbedding:
            (any RetrievalSemanticBoundaryEmbedding)? = nil
    ) async throws -> Self {
        let boundaryEmbedding: (any RetrievalSemanticBoundaryEmbedding)?
        if retrievalUnit == .semanticBoundary {
            if let semanticBoundaryEmbedding {
                boundaryEmbedding = semanticBoundaryEmbedding
            } else {
                boundaryEmbedding = try CLIAppleSentenceBoundaryEmbedding()
            }
        } else {
            boundaryEmbedding = nil
        }
        let adapter: String
        if let boundaryEmbedding {
            let proposal = try await boundaryEmbedding.boundaryProposal()
            let admission = try RetrievalSemanticBoundaryPreflight
                .admit(proposal)
            adapter = RetrievalSemanticBoundaryChunker
                .adapterIdentifier(for: admission)
        } else if let fixedAdapter = retrievalUnit.fixedAdapter {
            adapter = fixedAdapter
        } else {
            throw AskQualityBenchmarkError.invalidRetrievalUnit(
                retrievalUnit.rawValue)
        }
        let configuration = ProjectionConfiguration(
            retrievalUnit: retrievalUnit,
            semanticBoundaryEmbedding: boundaryEmbedding,
            expectedAdapter: adapter)
        let grouped = Dictionary(grouping: fixture.segments, by: \.meetingID)
        var unitByUUID: [UUID: Unit] = [:]
        var externalMeetingIDByDomainID: [MeetingID: String] = [:]
        for (meetingIndex, externalMeetingID) in grouped.keys.sorted().enumerated() {
            guard let fixtureSegments = grouped[externalMeetingID],
                  !fixtureSegments.isEmpty
            else { continue }
            let result = try await seedMeeting(
                externalMeetingID: externalMeetingID,
                meetingIndex: meetingIndex,
                segments: fixtureSegments,
                store: store,
                configuration: configuration)
            externalMeetingIDByDomainID[result.meetingID] = externalMeetingID
            unitByUUID.merge(result.unitByUUID) { _, latest in latest }
        }
        return Self(
            unitByUUID: unitByUUID,
            externalMeetingIDByDomainID: externalMeetingIDByDomainID,
            adapter: adapter)
    }

    private static func seedMeeting(
        externalMeetingID: String,
        meetingIndex: Int,
        segments fixtureSegments: [AskQualityFixtureSegment],
        store: MeetingStore,
        configuration: ProjectionConfiguration
    ) async throws -> SeededMeeting {
        let meetingID = MeetingID(rawValue: try deterministicUUID(
            namespace: "ask-quality-meeting",
            identifier: externalMeetingID))
        let speakerByOwner = try speakers(
            for: fixtureSegments,
            externalMeetingID: externalMeetingID)
        let speakers = meetingSpeakers(
            speakerByOwner: speakerByOwner,
            meetingID: meetingID)
        var externalIDByUUID: [UUID: String] = [:]
        let transcriptSegments = try transcriptSegments(
            from: fixtureSegments,
            meetingID: meetingID,
            speakerByOwner: speakerByOwner,
            externalIDByUUID: &externalIDByUUID)
        let meeting = makeMeeting(
            id: meetingID,
            index: meetingIndex,
            fixtureSegments: fixtureSegments,
            transcriptSegments: transcriptSegments)
        let projection = try await projectedUnits(
            configuration.retrievalUnit,
            meeting: meeting,
            speakers: speakers,
            segments: transcriptSegments,
            externalIDByUUID: externalIDByUUID,
            configuration: configuration)
        try await store.saveImportedMeeting(
            meeting,
            speakers: speakers,
            segments: projection.segments)
        return SeededMeeting(
            meetingID: meetingID,
            unitByUUID: projection.unitByUUID)
    }

    private static func projectedUnits(
        _ retrievalUnit: AskQualityRetrievalUnit,
        meeting: Meeting,
        speakers: [Speaker],
        segments: [TranscriptSegment],
        externalIDByUUID: [UUID: String],
        configuration: ProjectionConfiguration
    ) async throws -> (segments: [TranscriptSegment], unitByUUID: [UUID: Unit]) {
        switch retrievalUnit {
        case .segment:
            return try segmentProjection(
                segments: segments,
                externalIDByUUID: externalIDByUUID)
        case .speakerTurn:
            return try speakerTurnProjection(
                meeting: meeting,
                speakers: speakers,
                segments: segments,
                externalIDByUUID: externalIDByUUID)
        case .conversationWindow:
            return try conversationWindowProjection(
                meeting: meeting,
                speakers: speakers,
                segments: segments,
                externalIDByUUID: externalIDByUUID)
        case .semanticBoundary:
            return try await semanticBoundaryProjection(
                meeting: meeting,
                speakers: speakers,
                segments: segments,
                externalIDByUUID: externalIDByUUID,
                embedding: configuration.semanticBoundaryEmbedding,
                expectedAdapter: configuration.expectedAdapter)
        }
    }

    private static func segmentProjection(
        segments: [TranscriptSegment],
        externalIDByUUID: [UUID: String]
    ) throws -> (segments: [TranscriptSegment], unitByUUID: [UUID: Unit]) {
        let units = try segments.map { segment -> (UUID, Unit) in
            guard let externalID = externalIDByUUID[segment.id] else {
                throw AskQualityBenchmarkError.invalidFixture(
                    "segment candidate lost canonical source identity")
            }
            return (
                segment.id,
                Unit(id: externalID, sourceSegmentIDs: [externalID]))
        }
        return (segments, Dictionary(uniqueKeysWithValues: units))
    }

    private static func speakerTurnProjection(
        meeting: Meeting,
        speakers: [Speaker],
        segments: [TranscriptSegment],
        externalIDByUUID: [UUID: String]
    ) throws -> (segments: [TranscriptSegment], unitByUUID: [UUID: Unit]) {
        let chunks = try RetrievalTurnChunker.chunks(
            meetingID: meeting.id,
            transcriptRevision: meeting.transcriptRevision,
            correctionRevision: .accepted,
            segments: segments,
            speakers: speakers)
        return try chunkProjection(
            chunks: chunks,
            candidateLabel: "speaker-turn",
            identityNamespace: "ask-quality-speaker-turn-unit",
            externalIDByUUID: externalIDByUUID)
    }

    private static func conversationWindowProjection(
        meeting: Meeting,
        speakers: [Speaker],
        segments: [TranscriptSegment],
        externalIDByUUID: [UUID: String]
    ) throws -> (segments: [TranscriptSegment], unitByUUID: [UUID: Unit]) {
        let chunks = try RetrievalConversationWindowChunker.chunks(
            meetingID: meeting.id,
            transcriptRevision: meeting.transcriptRevision,
            correctionRevision: .accepted,
            segments: segments,
            speakers: speakers)
        return try chunkProjection(
            chunks: chunks,
            candidateLabel: "conversation-window",
            identityNamespace: "ask-quality-conversation-window-unit",
            externalIDByUUID: externalIDByUUID)
    }

    private static func chunkProjection(
        chunks: [RetrievalChunk],
        candidateLabel: String,
        identityNamespace: String,
        externalIDByUUID: [UUID: String]
    ) throws -> (segments: [TranscriptSegment], unitByUUID: [UUID: Unit]) {
        var projected: [TranscriptSegment] = []
        var mapping: [UUID: Unit] = [:]
        projected.reserveCapacity(chunks.count)
        mapping.reserveCapacity(chunks.count)
        for chunk in chunks {
            let candidate = try chunkCandidate(
                chunk,
                candidateLabel: candidateLabel,
                identityNamespace: identityNamespace,
                externalIDByUUID: externalIDByUUID)
            projected.append(candidate.segment)
            guard mapping.updateValue(
                candidate.unit,
                forKey: candidate.segment.id) == nil
            else {
                throw AskQualityBenchmarkError.invalidFixture(
                    "\(candidateLabel) candidate identity repeats")
            }
        }
        return (projected, mapping)
    }

    private static func chunkCandidate(
        _ chunk: RetrievalChunk,
        candidateLabel: String,
        identityNamespace: String,
        externalIDByUUID: [UUID: String]
    ) throws -> (segment: TranscriptSegment, unit: Unit) {
        guard let channel = chunk.sources.first?.channel else {
            throw AskQualityBenchmarkError.invalidFixture(
                "\(candidateLabel) candidate has no canonical source")
        }
        let identifier = try deterministicUUID(
            namespace: identityNamespace,
            identifier: chunk.id)
        let sourceIDs = try chunk.sourceSegmentIDs.map { sourceID in
            guard let externalID = externalIDByUUID[sourceID] else {
                throw AskQualityBenchmarkError.invalidFixture(
                    "\(candidateLabel) candidate lost canonical source identity")
            }
            return externalID
        }
        let speakerID = chunk.speakerIDs.count == 1
            ? chunk.speakerIDs.first
            : nil
        let language: String? = switch chunk.spokenLanguages.count {
        case 0: nil
        case 1: chunk.spokenLanguages.first
        default: "mixed"
        }
        return (
            TranscriptSegment(
                id: identifier,
                meetingID: chunk.meetingID,
                speakerID: speakerID,
                channel: channel,
                text: chunk.text,
                language: language,
                startTime: chunk.startTime,
                endTime: chunk.endTime,
                confidence: 1,
                isFinal: true),
            Unit(id: chunk.id, sourceSegmentIDs: sourceIDs))
    }

    private static func speakers(
        for segments: [AskQualityFixtureSegment],
        externalMeetingID: String
    ) throws -> [String: SpeakerID] {
        try Dictionary(uniqueKeysWithValues: Set(segments.map(\.owner)).map { owner in
            (
                owner,
                SpeakerID(rawValue: try deterministicUUID(
                    namespace: "ask-quality-speaker-\(externalMeetingID)",
                    identifier: owner))
            )
        })
    }

    private static func meetingSpeakers(
        speakerByOwner: [String: SpeakerID],
        meetingID: MeetingID
    ) -> [Speaker] {
        speakerByOwner.keys.sorted().compactMap { owner in
            speakerByOwner[owner].map {
                Speaker(
                    id: $0,
                    meetingID: meetingID,
                    label: owner,
                    displayName: owner,
                    isMe: false)
            }
        }
    }

    private static func transcriptSegments(
        from fixtureSegments: [AskQualityFixtureSegment],
        meetingID: MeetingID,
        speakerByOwner: [String: SpeakerID],
        externalIDByUUID: inout [UUID: String]
    ) throws -> [TranscriptSegment] {
        try fixtureSegments.sorted {
            ($0.timestampMilliseconds, $0.id) < ($1.timestampMilliseconds, $1.id)
        }.map { segment in
            let identifier = try deterministicUUID(
                namespace: "ask-quality-segment",
                identifier: segment.id)
            externalIDByUUID[identifier] = segment.id
            let start = TimeInterval(segment.timestampMilliseconds) / 1_000
            return TranscriptSegment(
                id: identifier,
                meetingID: meetingID,
                speakerID: speakerByOwner[segment.owner],
                channel: .system,
                text: segment.text,
                language: segment.language,
                startTime: start,
                endTime: start + 0.8,
                confidence: 1,
                isFinal: true)
        }
    }

    private static func makeMeeting(
        id: MeetingID,
        index: Int,
        fixtureSegments: [AskQualityFixtureSegment],
        transcriptSegments: [TranscriptSegment]
    ) -> Meeting {
        let first = fixtureSegments[0]
        let startedAt = Date(
            timeIntervalSince1970: 1_700_000_000 + TimeInterval(index * 3_600))
        return Meeting(
            id: id,
            title: first.meetingTitle,
            startedAt: startedAt,
            endedAt: startedAt.addingTimeInterval(
                (transcriptSegments.last?.endTime ?? 0) + 1),
            language: Set(fixtureSegments.map(\.language)).count == 1
                ? first.language
                : nil,
            transcriptRevision: first.transcriptRevision)
    }

    func observation(
        for citation: AskCitation
    ) throws -> AskQualityHitObservation {
        let unit = citation.segmentID.flatMap { unitByUUID[$0] }
        let meetingID = externalMeetingIDByDomainID[citation.meetingID]
            ?? "unknown-meeting"
        let milliseconds = citation.timestamp * 1_000
        guard milliseconds.isFinite,
              milliseconds >= 0,
              milliseconds <= Double(Int.max)
        else { throw AskQualityBenchmarkError.invalidTimestamp }
        return AskQualityHitObservation(
            unitID: unit?.id ?? "unknown-unit",
            sourceSegmentIDs: unit?.sourceSegmentIDs ?? ["unknown-segment"],
            meetingID: meetingID,
            timestampMilliseconds: Int(milliseconds.rounded()),
            transcriptRevision: citation.transcriptRevision)
    }

    private static func deterministicUUID(
        namespace: String,
        identifier: String
    ) throws -> UUID {
        let digest = OperationFingerprint.make(
            version: namespace,
            components: [identifier])
        let compact = String(digest.prefix(32))
        let value = [
            compact.prefix(8),
            compact.dropFirst(8).prefix(4),
            compact.dropFirst(12).prefix(4),
            compact.dropFirst(16).prefix(4),
            compact.dropFirst(20).prefix(12)
        ].map(String.init).joined(separator: "-")
        guard let result = UUID(uuidString: value) else {
            throw AskQualityBenchmarkError.invalidFixture("invalid identity digest")
        }
        return result
    }
}

private extension AskQualityCorpusMapping {
    private static func semanticBoundaryProjection(
        meeting: Meeting,
        speakers: [Speaker],
        segments: [TranscriptSegment],
        externalIDByUUID: [UUID: String],
        embedding: (any RetrievalSemanticBoundaryEmbedding)?,
        expectedAdapter: String
    ) async throws -> (segments: [TranscriptSegment], unitByUUID: [UUID: Unit]) {
        guard let embedding else {
            throw AskQualityBenchmarkError.invalidFixture(
                "semantic-boundary embedding is unavailable")
        }
        let result = try await RetrievalSemanticBoundaryChunker.chunks(
            meetingID: meeting.id,
            transcriptRevision: meeting.transcriptRevision,
            correctionRevision: .accepted,
            segments: segments,
            speakers: speakers,
            embedding: embedding)
        guard result.adapterIdentifier == expectedAdapter else {
            throw AskQualityBenchmarkError.invalidFixture(
                "semantic-boundary candidate identity changed during projection")
        }
        return try chunkProjection(
            chunks: result.chunks,
            candidateLabel: "semantic-boundary",
            identityNamespace: "ask-quality-semantic-boundary-unit",
            externalIDByUUID: externalIDByUUID)
    }
}
