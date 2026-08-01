import Foundation
import PortavozCore

/// One derived, rebuildable unit for semantic retrieval. The transcript stays
/// authoritative: every chunk retains its exact ordered source identities and
/// never becomes evidence without resolving those rows again.
public struct RetrievalChunk: Equatable, Sendable, Identifiable {
    public struct Source: Equatable, Sendable {
        public let segmentID: UUID
        public let speakerID: SpeakerID?
        public let personID: PersonID?
        public let channel: AudioChannel
        public let language: String?
        public let startTime: TimeInterval
        public let endTime: TimeInterval

        public init(
            segmentID: UUID,
            speakerID: SpeakerID?,
            personID: PersonID?,
            channel: AudioChannel,
            language: String?,
            startTime: TimeInterval,
            endTime: TimeInterval
        ) {
            self.segmentID = segmentID
            self.speakerID = speakerID
            self.personID = personID
            self.channel = channel
            self.language = language
            self.startTime = startTime
            self.endTime = endTime
        }
    }

    /// Stable across text-only corrections while source membership and the
    /// chunker version remain unchanged.
    public let id: String
    public let meetingID: MeetingID
    /// Latest authoritative revision observed while deriving this value. It is
    /// a publication fence, not part of chunk identity or rebuild admission.
    public let transcriptRevision: Int
    public let sources: [Source]
    public let startTime: TimeInterval
    public let endTime: TimeInterval
    /// Spoken text only. Chunking never translates or rewrites vocabulary.
    public let text: String
    /// Whitespace- and Unicode-normalized text identity used to avoid needless
    /// embedding work after representation-only edits.
    public let normalizedTextFingerprint: String
    /// Complete source identity excluding the meeting-wide revision. A changed
    /// value means this chunk alone must be republished.
    public let sourceFingerprint: String
    public let chunkerVersion: String

    public var sourceSegmentIDs: [UUID] {
        sources.map(\.segmentID)
    }

    public var speakerIDs: [SpeakerID] {
        Self.uniqued(sources.compactMap(\.speakerID))
    }

    public var personIDs: [PersonID] {
        Self.uniqued(sources.compactMap(\.personID))
    }

    public var spokenLanguages: [String] {
        Self.uniqued(sources.compactMap(\.language))
    }

    init(
        meetingID: MeetingID,
        transcriptRevision: Int,
        sources: [Source],
        text: String,
        normalizedTextFingerprint: String,
        sourceFingerprint: String,
        chunkerVersion: String
    ) {
        self.id = OperationFingerprint.make(
            version: "retrieval-chunk-id-v1",
            components: [
                chunkerVersion,
                meetingID.rawValue.uuidString.lowercased(),
                sources.map { $0.segmentID.uuidString.lowercased() }
                    .joined(separator: ",")
            ])
        self.meetingID = meetingID
        self.transcriptRevision = transcriptRevision
        self.sources = sources
        self.startTime = sources.first?.startTime ?? 0
        self.endTime = sources.last?.endTime ?? 0
        self.text = text
        self.normalizedTextFingerprint = normalizedTextFingerprint
        self.sourceFingerprint = sourceFingerprint
        self.chunkerVersion = chunkerVersion
    }

    private static func uniqued<Value: Hashable>(_ values: [Value]) -> [Value] {
        var seen: Set<Value> = []
        return values.filter { seen.insert($0).inserted }
    }
}

public enum RetrievalChunkingError: Error, Equatable, LocalizedError {
    case invalidTranscriptRevision
    case duplicateSegmentID(UUID)
    case duplicateSpeakerID(SpeakerID)
    case mixedMeeting
    case invalidTimeline(UUID)
    case unknownSpeaker(UUID)

    public var errorDescription: String? {
        switch self {
        case .invalidTranscriptRevision:
            "retrieval chunks require a nonnegative transcript revision"
        case .duplicateSegmentID:
            "retrieval chunks require unique source segment identities"
        case .duplicateSpeakerID:
            "retrieval chunks require unique meeting-local speaker identities"
        case .mixedMeeting:
            "retrieval chunks cannot combine different meetings"
        case .invalidTimeline:
            "retrieval chunks require finite, nonnegative, ordered timestamps"
        case .unknownSpeaker:
            "retrieval chunks cannot publish an unresolved speaker reference"
        }
    }
}

/// Deterministic single-actor turn chunking. Different people are never joined
/// to make text longer; anonymous remote/room rows remain isolated because a
/// missing diarization label is not proof of shared identity.
public enum RetrievalTurnChunker {
    public static let version = "speaker-turn-v1"
    public static let maximumCharacters = 900
    public static let maximumDuration: TimeInterval = 45
    public static let maximumGap: TimeInterval = 2.5

    public static func chunks(
        meetingID: MeetingID,
        transcriptRevision: Int,
        segments: [TranscriptSegment],
        speakers: [Speaker]
    ) throws -> [RetrievalChunk] {
        guard transcriptRevision >= 0 else {
            throw RetrievalChunkingError.invalidTranscriptRevision
        }
        let speakerByID = try validatedSpeakers(speakers, meetingID: meetingID)
        let ordered = try validatedSegments(segments, meetingID: meetingID)

        var result: [RetrievalChunk] = []
        var draft: Draft?
        for segment in ordered {
            let normalized = normalizedText(segment.text)
            guard !normalized.isEmpty else { continue }
            let speaker = try resolvedSpeaker(
                for: segment,
                speakerByID: speakerByID)
            let actor = actorIdentity(for: segment, speaker: speaker)
            let candidate = ChunkSource(
                segment: segment,
                speaker: speaker,
                normalizedText: normalized)

            if var current = draft,
               current.canAppend(candidate, actor: actor) {
                current.append(candidate)
                draft = current
            } else {
                if let draft {
                    result.append(makeChunk(
                        from: draft,
                        meetingID: meetingID,
                        transcriptRevision: transcriptRevision))
                }
                draft = Draft(actor: actor, source: candidate)
            }
        }
        if let draft {
            result.append(makeChunk(
                from: draft,
                meetingID: meetingID,
                transcriptRevision: transcriptRevision))
        }
        return result
    }

    private static func validatedSpeakers(
        _ speakers: [Speaker],
        meetingID: MeetingID
    ) throws -> [SpeakerID: Speaker] {
        var result: [SpeakerID: Speaker] = [:]
        for speaker in speakers {
            guard speaker.meetingID == meetingID else {
                throw RetrievalChunkingError.mixedMeeting
            }
            guard result.updateValue(speaker, forKey: speaker.id) == nil else {
                throw RetrievalChunkingError.duplicateSpeakerID(speaker.id)
            }
        }
        return result
    }

    private static func validatedSegments(
        _ segments: [TranscriptSegment],
        meetingID: MeetingID
    ) throws -> [TranscriptSegment] {
        var seen: Set<UUID> = []
        for segment in segments {
            guard segment.meetingID == meetingID else {
                throw RetrievalChunkingError.mixedMeeting
            }
            guard seen.insert(segment.id).inserted else {
                throw RetrievalChunkingError.duplicateSegmentID(segment.id)
            }
            guard segment.startTime.isFinite,
                  segment.endTime.isFinite,
                  segment.startTime >= 0,
                  segment.endTime >= segment.startTime
            else {
                throw RetrievalChunkingError.invalidTimeline(segment.id)
            }
        }
        return segments.sorted {
            ($0.startTime, $0.endTime, $0.id.uuidString)
                < ($1.startTime, $1.endTime, $1.id.uuidString)
        }
    }

    private static func resolvedSpeaker(
        for segment: TranscriptSegment,
        speakerByID: [SpeakerID: Speaker]
    ) throws -> Speaker? {
        guard let speakerID = segment.speakerID else { return nil }
        guard let speaker = speakerByID[speakerID] else {
            throw RetrievalChunkingError.unknownSpeaker(segment.id)
        }
        return speaker
    }

    private static func actorIdentity(
        for segment: TranscriptSegment,
        speaker: Speaker?
    ) -> ActorIdentity {
        if let personID = speaker?.personID {
            return .person(personID)
        }
        if let speakerID = speaker?.id {
            return .speaker(speakerID)
        }
        if segment.channel == .microphone {
            return .localMicrophone
        }
        return .isolated(segment.id)
    }

    private static func makeChunk(
        from draft: Draft,
        meetingID: MeetingID,
        transcriptRevision: Int
    ) -> RetrievalChunk {
        let text = draft.sources.map(\.normalizedText).joined(separator: " ")
        let textFingerprint = OperationFingerprint.make(
            version: "retrieval-chunk-text-v1",
            components: [text])
        let sources = draft.sources.map { source in
            RetrievalChunk.Source(
                segmentID: source.segment.id,
                speakerID: source.speaker?.id,
                personID: source.speaker?.personID,
                channel: source.segment.channel,
                language: normalizedLanguage(source.segment.language),
                startTime: source.segment.startTime,
                endTime: source.segment.endTime)
        }
        let sourceFingerprint = OperationFingerprint.make(
            version: "retrieval-chunk-source-v1",
            components: [
                textFingerprint,
                zip(sources, draft.sources).map { source, draftSource in
                    sourceIdentity(
                        source,
                        normalizedText: draftSource.normalizedText)
                }.joined(separator: "|")
            ])
        return RetrievalChunk(
            meetingID: meetingID,
            transcriptRevision: transcriptRevision,
            sources: sources,
            text: text,
            normalizedTextFingerprint: textFingerprint,
            sourceFingerprint: sourceFingerprint,
            chunkerVersion: version)
    }

    private static func sourceIdentity(
        _ source: RetrievalChunk.Source,
        normalizedText: String
    ) -> String {
        [
            source.segmentID.uuidString.lowercased(),
            OperationFingerprint.make(
                version: "retrieval-chunk-source-text-v1",
                components: [normalizedText]),
            source.speakerID?.rawValue.uuidString.lowercased() ?? "",
            source.personID?.rawValue.uuidString.lowercased() ?? "",
            source.channel.rawValue,
            source.language ?? "",
            String(source.startTime.bitPattern),
            String(source.endTime.bitPattern)
        ].joined(separator: ":")
    }

    private static func normalizedText(_ value: String) -> String {
        value.precomposedStringWithCanonicalMapping
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    private static func normalizedLanguage(_ value: String?) -> String? {
        let normalized = (value ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "_", with: "-")
            .lowercased(with: Locale(identifier: "en_US_POSIX"))
        return normalized.isEmpty || normalized == "und" ? nil : normalized
    }

    private enum ActorIdentity: Hashable {
        case person(PersonID)
        case speaker(SpeakerID)
        case localMicrophone
        case isolated(UUID)
    }

    private struct ChunkSource {
        let segment: TranscriptSegment
        let speaker: Speaker?
        let normalizedText: String
    }

    private struct Draft {
        let actor: ActorIdentity
        private(set) var sources: [ChunkSource]
        private(set) var characterCount: Int

        init(actor: ActorIdentity, source: ChunkSource) {
            self.actor = actor
            self.sources = [source]
            self.characterCount = source.normalizedText.count
        }

        func canAppend(
            _ source: ChunkSource,
            actor nextActor: ActorIdentity
        ) -> Bool {
            guard actor == nextActor,
                  let first = sources.first,
                  let last = sources.last
            else { return false }
            let gap = source.segment.startTime - last.segment.endTime
            let duration = source.segment.endTime - first.segment.startTime
            return gap >= 0
                && gap <= RetrievalTurnChunker.maximumGap
                && duration <= RetrievalTurnChunker.maximumDuration
                && characterCount + 1 + source.normalizedText.count
                    <= RetrievalTurnChunker.maximumCharacters
        }

        mutating func append(_ source: ChunkSource) {
            characterCount += 1 + source.normalizedText.count
            sources.append(source)
        }
    }
}

/// Pure derived-state comparison. A meeting-wide revision increment does not
/// force unrelated chunks to rebuild; only changed source membership, text,
/// actor/language metadata, or timestamps enter `upserts`.
public struct RetrievalChunkDelta: Equatable, Sendable {
    public let retained: [RetrievalChunk]
    public let upserts: [RetrievalChunk]
    public let removedChunkIDs: [String]

    public init(
        retained: [RetrievalChunk],
        upserts: [RetrievalChunk],
        removedChunkIDs: [String]
    ) {
        self.retained = retained
        self.upserts = upserts
        self.removedChunkIDs = removedChunkIDs
    }

    public static func between(
        previous: [RetrievalChunk],
        current: [RetrievalChunk]
    ) -> RetrievalChunkDelta {
        let previousByID = Dictionary(
            previous.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first })
        let currentIDs = Set(current.map(\.id))
        var retained: [RetrievalChunk] = []
        var upserts: [RetrievalChunk] = []
        for chunk in current {
            if previousByID[chunk.id]?.sourceFingerprint == chunk.sourceFingerprint {
                retained.append(chunk)
            } else {
                upserts.append(chunk)
            }
        }
        let removed = previous.compactMap { chunk in
            currentIDs.contains(chunk.id) ? nil : chunk.id
        }
        return RetrievalChunkDelta(
            retained: retained,
            upserts: upserts,
            removedChunkIDs: removed)
    }
}
