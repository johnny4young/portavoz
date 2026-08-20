import Foundation
import PortavozCore

/// Deterministic, non-overlapping windows of complete actor turns. A window
/// captures a short exchange without pretending its actors are one speaker or
/// repeating one canonical source across multiple retrieval units.
public enum RetrievalConversationWindowChunker {
    public static let version = "conversation-window-v1"
    public static let maximumTurns = 3
    public static let maximumCharacters = RetrievalTurnChunker.maximumCharacters
    public static let maximumDuration = RetrievalTurnChunker.maximumDuration
    public static let maximumGap = RetrievalTurnChunker.maximumGap

    public static func chunks(
        meetingID: MeetingID,
        transcriptRevision: Int,
        correctionRevision: TranscriptCorrectionRevision,
        segments: [TranscriptSegment],
        speakers: [Speaker]
    ) throws -> [RetrievalChunk] {
        let turns = try RetrievalTurnChunker.chunks(
            meetingID: meetingID,
            transcriptRevision: transcriptRevision,
            correctionRevision: correctionRevision,
            segments: segments,
            speakers: speakers)

        var result: [RetrievalChunk] = []
        var draft: Draft?
        for turn in turns {
            let actor = actorIdentity(for: turn)
            if var current = draft,
               current.canAppend(turn, actor: actor) {
                current.append(turn, actor: actor)
                draft = current
            } else {
                if let draft {
                    result.append(makeChunk(
                        from: draft,
                        meetingID: meetingID,
                        transcriptRevision: transcriptRevision,
                        correctionRevision: correctionRevision))
                }
                draft = Draft(turn: turn, actor: actor)
            }
        }
        if let draft {
            result.append(makeChunk(
                from: draft,
                meetingID: meetingID,
                transcriptRevision: transcriptRevision,
                correctionRevision: correctionRevision))
        }
        return result
    }

    private static func actorIdentity(for turn: RetrievalChunk) -> ActorIdentity {
        if turn.personIDs.count == 1, let personID = turn.personIDs.first {
            return .person(personID)
        }
        if turn.speakerIDs.count == 1, let speakerID = turn.speakerIDs.first {
            return .speaker(speakerID)
        }
        if turn.sources.allSatisfy({ $0.channel == .microphone }) {
            return .localMicrophone
        }
        return .isolated(turn.id)
    }

    private static func makeChunk(
        from draft: Draft,
        meetingID: MeetingID,
        transcriptRevision: Int,
        correctionRevision: TranscriptCorrectionRevision
    ) -> RetrievalChunk {
        let text = draft.turns.map(\.text).joined(separator: " ")
        let textFingerprint = OperationFingerprint.make(
            version: "retrieval-chunk-text-v1",
            components: [text])
        let sources = draft.turns.flatMap(\.sources)
        let turnBoundaries = draft.turns.flatMap(\.turns)
        let sourceFingerprint = OperationFingerprint.make(
            version: "retrieval-conversation-window-source-v1",
            components: [
                textFingerprint,
                draft.turns.map {
                    "\($0.id):\($0.sourceFingerprint)"
                }.joined(separator: "|")
            ])
        return RetrievalChunk(
            meetingID: meetingID,
            transcriptRevision: transcriptRevision,
            correctionRevision: correctionRevision,
            sources: sources,
            turns: turnBoundaries,
            text: text,
            normalizedTextFingerprint: textFingerprint,
            sourceFingerprint: sourceFingerprint,
            chunkerVersion: version)
    }

    private enum ActorIdentity: Hashable {
        case person(PersonID)
        case speaker(SpeakerID)
        case localMicrophone
        case isolated(String)
    }

    private struct Draft {
        private(set) var turns: [RetrievalChunk]
        private(set) var lastActor: ActorIdentity
        private(set) var characterCount: Int

        init(turn: RetrievalChunk, actor: ActorIdentity) {
            self.turns = [turn]
            self.lastActor = actor
            self.characterCount = turn.text.count
        }

        func canAppend(
            _ turn: RetrievalChunk,
            actor: ActorIdentity
        ) -> Bool {
            guard actor != lastActor,
                  turns.count < RetrievalConversationWindowChunker.maximumTurns,
                  let first = turns.first,
                  let last = turns.last
            else { return false }
            let gap = turn.startTime - last.endTime
            let duration = turn.endTime - first.startTime
            return gap >= 0
                && gap <= RetrievalConversationWindowChunker.maximumGap
                && duration <= RetrievalConversationWindowChunker.maximumDuration
                && characterCount + 1 + turn.text.count
                    <= RetrievalConversationWindowChunker.maximumCharacters
        }

        mutating func append(
            _ turn: RetrievalChunk,
            actor: ActorIdentity
        ) {
            characterCount += 1 + turn.text.count
            turns.append(turn)
            lastActor = actor
        }
    }
}
