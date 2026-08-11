import ApplicationKit
import Foundation
import IntegrationsKit
import IntelligenceKit
import PortavozCore

/// Re-derives a meeting's Companion cards from a transcript, post-hoc — the
/// refine path (D7) re-runs the live Companion pipeline over the CLEAN Whisper
/// transcript so the answer cards improve alongside it, instead of staying the
/// snapshot captured live from garbled captions. Faithful to the live flow
/// (`RecordingController.detectClosedRow`): only the participants' channel,
/// whole interventions (not raw segments), never noise, only real questions or
/// an "asked you" ping, and context drawn from BOTH sides of the conversation.
@available(macOS 26.0, *)
enum CompanionRefresh {
    struct Result {
        let artifacts: [CompanionGenerationArtifact]
        let terminalRuns: [GenerationRun]
        /// False when cancellation or any model call failed. Callers preserve
        /// the previous snapshot rather than replacing it with partial data.
        let completed: Bool
    }

    /// A coalesced participant turn: contiguous system segments of one speaker,
    /// merged so the Companion sees a whole intervention (a stray fragment like
    /// "…, right?" on its own answers badly; the full turn classifies well).
    private struct Turn {
        var text: String
        let startTime: TimeInterval
        var languages: Set<String>
        var segmentIDs: [UUID]

        var language: String? {
            languages.count == 1 ? languages.first : nil
        }
    }

    /// Runs the Companion over one accepted or corrected transcript projection
    /// and returns fresh cards. Generated row identities are retained for the
    /// model operation, then projected to immutable accepted IDs by the shared
    /// provenance factory. Never throws: callers preserve the old snapshot
    /// when the pass is incomplete.
    @MainActor
    static func regenerate(
        from material: MeetingTranscriptGenerationMaterial,
        meetingID: MeetingID,
        workflow: CompanionGenerationWorkflow,
        byok: CompanionBYOKClient?
    ) async -> Result {
        let ownerName = RecordingController.companionOwnerName()
        let companion = ProvenanceCompanion(
            byok: byok,
            egressConsentSource: .companionBYOKSettings)
        let ordered = material.segments
            .filter { $0.endTime > $0.startTime && !$0.text.isEmpty }
            .sorted { $0.startTime < $1.startTime }

        var artifacts: [CompanionGenerationArtifact] = []
        var terminalRuns: [GenerationRun] = []
        var completed = true
        turnLoop: for turn in participantTurns(ordered) {
            if Task.isCancelled {
                completed = false
                break
            }
            // Don't burn a model call on a garbled turn or a non-question.
            guard
                !TranscriptNoiseFilter.isLikelyNoise(text: turn.text, confidence: nil)
            else { continue }
            let mentioned = ownerName.map { QuestionHeuristic.mentions($0, in: turn.text) } ?? false
            guard QuestionHeuristic.looksLikeQuestion(turn.text) || mentioned else { continue }

            // Context = the last lines from BOTH sides before the question, so
            // an answer already given in the room ("The endpoint is …") is
            // found, not hedged away as "not in the context".
            let passages = CompanionTranscriptContext.recentPassages(
                before: turn.startTime,
                from: ordered,
                meetingID: meetingID)
            let result = await companion.generate(CompanionGenerationRequest(
                meetingID: meetingID,
                sourceTranscriptRevision: material.baseTranscriptRevision,
                sourceCorrectionRevision: material.correctionRevision,
                workflow: workflow,
                candidate: turn.text,
                questionSegmentIDs: turn.segmentIDs,
                recentTranscript: passages,
                evidenceSourceIDsByGeneratedID: material.sourceSegmentIDsByGeneratedID,
                ownerName: ownerName,
                outputLanguage: turn.language,
                askedAt: turn.startTime))
            switch result {
            case .artifact(let artifact):
                admit(artifact, into: &artifacts)
            case .terminal(let run):
                terminalRuns.append(run)
                completed = false
                if run.outcome == .cancelled { break turnLoop }
            case .unavailable:
                completed = false
                break turnLoop
            case .noAttempt, .noArtifact:
                break
            }
        }
        return Result(
            artifacts: artifacts,
            terminalRuns: terminalRuns,
            completed: completed)
    }

    private static func admit(
        _ artifact: CompanionGenerationArtifact,
        into artifacts: inout [CompanionGenerationArtifact]
    ) {
        switch CompanionCardAdmission.decision(
            existing: artifacts.map(\.card),
            candidate: artifact.card
        ) {
        case .append:
            artifacts.append(artifact)
        case .replace(let index):
            artifacts[index] = artifact
        case .reject:
            break
        }
    }

}

enum CompanionTranscriptContext {
    /// Returns the bounded prefix immediately before one question. The input
    /// is already start-time sorted by the refresh pipeline, so a lower-bound
    /// search avoids rescanning a long meeting for every eligible question.
    static func recentPassages(
        before startTime: TimeInterval,
        from ordered: [TranscriptSegment],
        meetingID: MeetingID
    ) -> [RAGPassage] {
        var lowerBound = 0
        var upperBound = ordered.count
        while lowerBound < upperBound {
            let midpoint = lowerBound + (upperBound - lowerBound) / 2
            if ordered[midpoint].startTime < startTime {
                lowerBound = midpoint + 1
            } else {
                upperBound = midpoint
            }
        }
        return ordered[..<lowerBound]
            .suffix(14)
            .map { segment in
                RAGPassage(
                    segmentID: segment.id,
                    meetingID: meetingID,
                    meetingTitle: "This meeting",
                    timestamp: segment.startTime,
                    text: (segment.channel == .microphone ? "Me: " : "Them: ") + segment.text)
            }
    }

}

@available(macOS 26.0, *)
private extension CompanionRefresh {

    /// Coalesces the participants' (system-channel) segments into interventions:
    /// a run of the same speaker with no long gap becomes one turn, so the
    /// Companion classifies and answers whole thoughts instead of fragments.
    private static func participantTurns(_ ordered: [TranscriptSegment]) -> [Turn] {
        /// Gap (seconds) that ends a turn even for the same speaker.
        let turnGap: TimeInterval = 4
        var turns: [Turn] = []
        var lastEnd: TimeInterval = -.infinity
        var lastSpeaker: SpeakerID??
        for segment in ordered where segment.channel == .system {
            let sameSpeaker = lastSpeaker == .some(segment.speakerID)
            if !turns.isEmpty, sameSpeaker, segment.startTime - lastEnd < turnGap {
                turns[turns.count - 1].text += " " + segment.text
                turns[turns.count - 1].segmentIDs.append(segment.id)
                if let language = segment.language.flatMap(LanguageCode.init)?.identifier {
                    turns[turns.count - 1].languages.insert(language)
                }
            } else {
                let languages = Set(
                    segment.language.flatMap(LanguageCode.init).map { [$0.identifier] } ?? [])
                turns.append(Turn(
                    text: segment.text,
                    startTime: segment.startTime,
                    languages: languages,
                    segmentIDs: [segment.id]))
            }
            lastEnd = segment.endTime
            lastSpeaker = .some(segment.speakerID)
        }
        return turns
    }
}
