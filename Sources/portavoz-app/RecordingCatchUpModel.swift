import Foundation
import IntelligenceKit
import Observation
import PortavozCore
import TranscriptionKit

/// The on-demand "catch me up" concern, owning its own state so the
/// already-large recording controller only delegates. Pull-based, bounded to
/// the recent past, and honest about capability on every platform.
@MainActor
@Observable
final class RecordingCatchUpModel {
    enum State: Equatable {
        case generating
        case ready(String)
        case unavailable(String)
    }

    private(set) var state: State?
    private var task: Task<Void, Never>?

    /// Recap of the last few minutes of CLOSED captions at interactive
    /// priority. On Sequoia (or without Apple Intelligence) the answer is
    /// the honest capability explanation instead of a hidden control.
    func request(
        captions: [TranscriptSegment],
        meetingID: MeetingID,
        vocabulary: [String],
        isRecording: @escaping @MainActor () -> Bool
    ) {
        guard isRecording(), state != .generating else { return }
        guard #available(macOS 26.0, *),
            FoundationModelSummaryProvider.unavailabilityReason() == nil
        else {
            state = .unavailable(L10n.text(
                // One-line UI copy.
                // swiftlint:disable:next line_length
                "Catch-up needs Apple Intelligence on macOS 26. Summaries at Stop still work with your configured engine."))
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
                let recap = try await provider.catchUp(
                    segments: labeled, speakers: [me, them],
                    targetLanguage: language, glossary: vocabulary,
                    priority: .interactive)
                guard let self, !Task.isCancelled else { return }
                guard isRecording() else {
                    self.state = nil
                    self.task = nil
                    return
                }
                self.state = .ready(recap)
                self.task = nil
            } catch {
                guard let self, !Task.isCancelled else { return }
                guard isRecording() else {
                    self.state = nil
                    self.task = nil
                    return
                }
                self.state = .unavailable(L10n.text(
                    "The catch-up could not be generated. The recording continues untouched."))
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
