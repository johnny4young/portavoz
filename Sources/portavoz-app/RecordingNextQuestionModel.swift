import Foundation
import IntelligenceKit
import Observation
import PortavozCore
import TranscriptionKit

/// The on-demand "what should I ask next?" concern, the exact
/// sibling of `RecordingCatchUpModel`: pull-based, bounded to the recent
/// past, honest about capability, and stale-fenced on every exit path.
/// Pending objectives ride along so a suggestion can steer the meeting
/// back to what it set out to do.
@MainActor
@Observable
final class RecordingNextQuestionModel {
    enum State: Equatable {
        case generating
        case ready(String)
        case unavailable(String)
    }

    private(set) var state: State?
    private var task: Task<Void, Never>?

    func request(
        captions: [TranscriptSegment],
        meetingID: MeetingID,
        pendingObjectives: [String],
        vocabulary: [String],
        isRecording: @escaping @MainActor () -> Bool
    ) {
        guard isRecording(), state != .generating else { return }
        guard #available(macOS 26.0, *),
            FoundationModelSummaryProvider.unavailabilityReason() == nil
        else {
            state = .unavailable(L10n.text(
                "Question suggestions need Apple Intelligence on macOS 26. The recording continues untouched."))
            return
        }
        let clip = CatchUpPolicy.clip(captions)
        guard !clip.isEmpty else {
            state = .unavailable(L10n.text(
                "Not enough conversation yet — try again in a minute."))
            return
        }
        let me = Speaker(meetingID: meetingID, label: "Me", isMe: true)
        let them = Speaker(meetingID: meetingID, label: "Them")
        let labeled = clip.map { segment -> TranscriptSegment in
            var copy = segment
            copy.speakerID = segment.channel == .microphone ? me.id : them.id
            return copy
        }
        let spokenLanguage = SpokenLanguageDetector.homogeneousLanguage(in: labeled)
        let language = MeetingLanguagePreferences.resolvedSummaryLanguage(
            spokenLanguage: spokenLanguage).identifier
        state = .generating
        task = Task { @MainActor [weak self] in
            let provider = FoundationModelSummaryProvider()
            do {
                let suggestion = try await provider.suggestNextQuestion(
                    segments: labeled, speakers: [me, them],
                    pendingObjectives: pendingObjectives,
                    targetLanguage: language, glossary: vocabulary,
                    priority: .interactive)
                guard let self, !Task.isCancelled else { return }
                guard isRecording() else {
                    self.state = nil
                    self.task = nil
                    return
                }
                self.state = .ready(suggestion)
                self.task = nil
            } catch {
                guard let self, !Task.isCancelled else { return }
                guard isRecording() else {
                    self.state = nil
                    self.task = nil
                    return
                }
                self.state = .unavailable(L10n.text(
                    "No suggestion this time. The recording continues untouched."))
                self.task = nil
            }
        }
    }

    func dismiss() {
        task?.cancel()
        task = nil
        state = nil
    }
}
