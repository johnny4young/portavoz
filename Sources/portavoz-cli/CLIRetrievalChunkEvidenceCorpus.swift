import ApplicationKit
import Foundation
import PortavozCore

enum RetrievalChunkEvidenceRole: String, CaseIterable, Sendable {
    case segment
    case speakerTurn = "speaker-turn"
    case conversationWindow = "conversation-window"
    case semanticBoundary = "semantic-boundary"

    init(argument: String) throws {
        guard let value = Self(rawValue: argument) else {
            throw RetrievalChunkEvidenceError.invalidRetrievalUnit(argument)
        }
        self = value
    }

    var fixedAdapter: String? {
        switch self {
        case .segment:
            "segment-source-v1"
        case .speakerTurn:
            RetrievalTurnChunker.version
        case .conversationWindow:
            RetrievalConversationWindowChunker.version
        case .semanticBoundary:
            nil
        }
    }
}

enum RetrievalChunkCorrectionScenario: String, CaseIterable, Sendable {
    case publicationFences = "publication-fences"
    case normalizedEquivalentText = "normalized-equivalent-text"
    case textReplacement = "text-replacement"
    case actorReassignment = "actor-reassignment"
    case languageChange = "language-change"
    case structuralSplit = "structural-split"
    case structuralMerge = "structural-merge"
}

struct RetrievalChunkEvidenceMeeting: Sendable {
    let meetingID: MeetingID
    var transcriptRevision: Int
    var correctionRevision: TranscriptCorrectionRevision
    var segments: [TranscriptSegment]
    var speakers: [Speaker]

    var id: MeetingID {
        meetingID
    }
}

struct RetrievalChunkEvidenceUnit: Sendable {
    let id: String
    let sourceFingerprint: String
    let sourceCount: Int
    let turnCount: Int
}

struct RetrievalChunkEvidenceProjection: Sendable {
    let adapter: String
    let units: [RetrievalChunkEvidenceUnit]
    let semanticDiagnostics: RetrievalSemanticBoundaryDiagnostics?

    var sourceReferenceCount: Int {
        units.reduce(0) { $0 + $1.sourceCount }
    }

    var turnCount: Int {
        units.reduce(0) { $0 + $1.turnCount }
    }
}

struct RetrievalChunkEvidenceDelta: Equatable, Sendable {
    let retainedCount: Int
    let upsertCount: Int
    let removedCount: Int

    static func between(
        previous: RetrievalChunkEvidenceProjection,
        current: RetrievalChunkEvidenceProjection
    ) -> Self {
        let previousByID = Dictionary(
            previous.units.map { ($0.id, $0.sourceFingerprint) },
            uniquingKeysWith: { first, _ in first })
        let currentIDs = Set(current.units.map(\.id))
        var retained = 0
        var upserts = 0
        for unit in current.units {
            if previousByID[unit.id] == unit.sourceFingerprint {
                retained += 1
            } else {
                upserts += 1
            }
        }
        let removed = previous.units.reduce(into: 0) { count, unit in
            if !currentIDs.contains(unit.id) { count += 1 }
        }
        return Self(
            retainedCount: retained,
            upsertCount: upserts,
            removedCount: removed)
    }
}

enum RetrievalChunkEvidenceCorpus {
    static func meetings(
        from fixture: RetrievalChunkResourceFixture
    ) throws -> [RetrievalChunkEvidenceMeeting] {
        let grouped = Dictionary(grouping: fixture.segments, by: \.meetingID)
        return try grouped.keys.sorted().map { externalMeetingID in
            guard let source = grouped[externalMeetingID], !source.isEmpty else {
                throw RetrievalChunkEvidenceError.invalidCorpus
            }
            let meetingID = MeetingID(rawValue: try deterministicUUID(
                namespace: "retrieval-chunk-evidence-meeting",
                identifier: externalMeetingID))
            let owners = Set(source.map(\.owner)).sorted()
            let speakerByOwner = try Dictionary(uniqueKeysWithValues: owners.map { owner in
                (
                    owner,
                    SpeakerID(rawValue: try deterministicUUID(
                        namespace: "retrieval-chunk-evidence-speaker-\(externalMeetingID)",
                        identifier: owner))
                )
            })
            let speakers = owners.compactMap { owner in
                speakerByOwner[owner].map {
                    Speaker(
                        id: $0,
                        meetingID: meetingID,
                        label: owner,
                        displayName: owner)
                }
            }
            let ordered = source.sorted {
                ($0.timestampMilliseconds, $0.id)
                    < ($1.timestampMilliseconds, $1.id)
            }
            let segments = try ordered.map { item in
                let start = TimeInterval(item.timestampMilliseconds) / 1_000
                return TranscriptSegment(
                    id: try deterministicUUID(
                        namespace: "retrieval-chunk-evidence-segment",
                        identifier: item.id),
                    meetingID: meetingID,
                    speakerID: speakerByOwner[item.owner],
                    channel: .system,
                    text: item.text,
                    language: item.language,
                    startTime: start,
                    endTime: start + 0.8,
                    confidence: 1,
                    isFinal: true)
            }
            guard let revision = ordered.first?.transcriptRevision else {
                throw RetrievalChunkEvidenceError.invalidCorpus
            }
            return RetrievalChunkEvidenceMeeting(
                meetingID: meetingID,
                transcriptRevision: revision,
                correctionRevision: .accepted,
                segments: segments,
                speakers: speakers)
        }
    }

    static func projection(
        for meeting: RetrievalChunkEvidenceMeeting,
        role: RetrievalChunkEvidenceRole,
        embedding: (any RetrievalSemanticBoundaryEmbedding)?
    ) async throws -> RetrievalChunkEvidenceProjection {
        switch role {
        case .segment:
            return RetrievalChunkEvidenceProjection(
                adapter: role.fixedAdapter ?? "",
                units: meeting.segments.map(segmentUnit),
                semanticDiagnostics: nil)
        case .speakerTurn:
            let chunks = try RetrievalTurnChunker.chunks(
                meetingID: meeting.id,
                transcriptRevision: meeting.transcriptRevision,
                correctionRevision: meeting.correctionRevision,
                segments: meeting.segments,
                speakers: meeting.speakers)
            return chunkProjection(
                chunks: chunks,
                adapter: role.fixedAdapter ?? "")
        case .conversationWindow:
            let chunks = try RetrievalConversationWindowChunker.chunks(
                meetingID: meeting.id,
                transcriptRevision: meeting.transcriptRevision,
                correctionRevision: meeting.correctionRevision,
                segments: meeting.segments,
                speakers: meeting.speakers)
            return chunkProjection(
                chunks: chunks,
                adapter: role.fixedAdapter ?? "")
        case .semanticBoundary:
            guard let embedding else {
                throw RetrievalChunkEvidenceError.semanticEmbeddingUnavailable
            }
            let result = try await RetrievalSemanticBoundaryChunker.chunks(
                meetingID: meeting.id,
                transcriptRevision: meeting.transcriptRevision,
                correctionRevision: meeting.correctionRevision,
                segments: meeting.segments,
                speakers: meeting.speakers,
                embedding: embedding)
            return chunkProjection(
                chunks: result.chunks,
                adapter: result.adapterIdentifier,
                diagnostics: result.diagnostics)
        }
    }

    static func corrected(
        _ meeting: RetrievalChunkEvidenceMeeting,
        scenario: RetrievalChunkCorrectionScenario
    ) throws -> RetrievalChunkEvidenceMeeting {
        guard meeting.segments.count >= 2 else {
            throw RetrievalChunkEvidenceError.invalidCorpus
        }
        var result = meeting
        result.correctionRevision = try correctionRevision(for: scenario)
        switch scenario {
        case .publicationFences:
            result.transcriptRevision += 1
        case .normalizedEquivalentText:
            result.segments[0].text = " \n\(result.segments[0].text)\t "
        case .textReplacement:
            result.segments[0].text += " corrected"
        case .actorReassignment:
            let current = result.segments[0].speakerID
            guard let replacement = result.speakers
                .map(\.id)
                .first(where: { $0 != current })
            else {
                throw RetrievalChunkEvidenceError.invalidCorpus
            }
            result.segments[0].speakerID = replacement
        case .languageChange:
            result.segments[0].language = primaryLanguage(
                result.segments[0].language) == "en" ? "es" : "en"
        case .structuralSplit:
            let source = result.segments.removeFirst()
            let parts = try splitText(source.text)
            let middle = source.startTime + (source.endTime - source.startTime) / 2
            let first = copiedSegment(
                source,
                id: try deterministicUUID(
                    namespace: "retrieval-chunk-evidence-split",
                    identifier: "\(source.id.uuidString)-1"),
                text: parts.0,
                startTime: source.startTime,
                endTime: middle)
            let second = copiedSegment(
                source,
                id: try deterministicUUID(
                    namespace: "retrieval-chunk-evidence-split",
                    identifier: "\(source.id.uuidString)-2"),
                text: parts.1,
                startTime: middle,
                endTime: source.endTime)
            result.segments.insert(contentsOf: [first, second], at: 0)
        case .structuralMerge:
            let first = result.segments.removeFirst()
            let second = result.segments.removeFirst()
            let merged = copiedSegment(
                first,
                id: try deterministicUUID(
                    namespace: "retrieval-chunk-evidence-merge",
                    identifier: "\(first.id.uuidString)-\(second.id.uuidString)"),
                text: "\(first.text) \(second.text)",
                startTime: first.startTime,
                endTime: second.endTime)
            result.segments.insert(merged, at: 0)
        }
        return result
    }

    private static func chunkProjection(
        chunks: [RetrievalChunk],
        adapter: String,
        diagnostics: RetrievalSemanticBoundaryDiagnostics? = nil
    ) -> RetrievalChunkEvidenceProjection {
        RetrievalChunkEvidenceProjection(
            adapter: adapter,
            units: chunks.map {
                RetrievalChunkEvidenceUnit(
                    id: $0.id,
                    sourceFingerprint: $0.sourceFingerprint,
                    sourceCount: $0.sources.count,
                    turnCount: $0.turns.count)
            },
            semanticDiagnostics: diagnostics)
    }

    private static func segmentUnit(
        _ segment: TranscriptSegment
    ) -> RetrievalChunkEvidenceUnit {
        let text = normalizedText(segment.text)
        let language = normalizedLanguage(segment.language)
        return RetrievalChunkEvidenceUnit(
            id: segment.id.uuidString.lowercased(),
            sourceFingerprint: OperationFingerprint.make(
                version: "retrieval-segment-source-v1",
                components: [
                    OperationFingerprint.make(
                        version: "retrieval-segment-text-v1",
                        components: [text]),
                    segment.speakerID?.rawValue.uuidString.lowercased() ?? "",
                    segment.channel.rawValue,
                    language,
                    String(segment.startTime.bitPattern),
                    String(segment.endTime.bitPattern)
                ]),
            sourceCount: 1,
            turnCount: 1)
    }

    private static func correctionRevision(
        for scenario: RetrievalChunkCorrectionScenario
    ) throws -> TranscriptCorrectionRevision {
        let fingerprint = OperationFingerprint.make(
            version: "retrieval-chunk-evidence-correction-v1",
            components: [scenario.rawValue])
        guard let revision = TranscriptCorrectionRevision(rawValue: fingerprint) else {
            throw RetrievalChunkEvidenceError.invalidCorpus
        }
        return revision
    }

    private static func copiedSegment(
        _ source: TranscriptSegment,
        id: UUID,
        text: String,
        startTime: TimeInterval,
        endTime: TimeInterval
    ) -> TranscriptSegment {
        TranscriptSegment(
            id: id,
            meetingID: source.meetingID,
            speakerID: source.speakerID,
            channel: source.channel,
            text: text,
            language: source.language,
            startTime: startTime,
            endTime: endTime,
            confidence: source.confidence,
            isFinal: source.isFinal)
    }

    private static func splitText(_ text: String) throws -> (String, String) {
        let words = text.split(whereSeparator: \.isWhitespace).map(String.init)
        guard words.count >= 2 else {
            throw RetrievalChunkEvidenceError.invalidCorpus
        }
        let middle = max(1, words.count / 2)
        return (
            words[..<middle].joined(separator: " "),
            words[middle...].joined(separator: " "))
    }

    private static func normalizedText(_ text: String) -> String {
        text.precomposedStringWithCanonicalMapping
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    private static func primaryLanguage(_ language: String?) -> String? {
        normalizedLanguage(language)
            .split(separator: "-")
            .first
            .map(String.init)
    }

    private static func normalizedLanguage(_ language: String?) -> String {
        (language ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "_", with: "-")
            .lowercased(with: Locale(identifier: "en_US_POSIX"))
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
            throw RetrievalChunkEvidenceError.invalidCorpus
        }
        return result
    }
}
