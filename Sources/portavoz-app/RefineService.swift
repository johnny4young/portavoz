import AudioCaptureKit
import DiarizationKit
import Foundation
import PortavozCore
import StorageKit
import SwiftUI
import TranscriptionKit

/// Runs quality re-passes OUTSIDE the view hierarchy (field bug, Jul 10):
/// the detail view is recreated when the user switches meetings, so a
/// view-owned refine kept burning the ANE while its draft sheet was lost.
/// State lives here keyed by meeting — navigate freely; the draft waits
/// until its meeting is visited again.
@MainActor
@Observable
final class RefineService {
    enum Phase {
        case running(String)
        case draft(RefineDraft)
        case failed(String)
    }

    private(set) var phases: [MeetingID: Phase] = [:]

    func phase(for meetingID: MeetingID) -> Phase? { phases[meetingID] }

    func clear(_ meetingID: MeetingID) { phases[meetingID] = nil }

    var isRunning: Bool {
        phases.values.contains { if case .running = $0 { return true } else { return false } }
    }

    // The orchestration is legitimately long (audio resolution + two Whisper
    // passes + diarization); splitting further would only scatter it.
    // swiftlint:disable:next function_body_length
    func start(meetingID: MeetingID, detail: MeetingDetail, services: AppServices) {
        if case .running = phases[meetingID] { return }
        // One refine at a time: Whisper and the diarizer are heavy enough
        // that concurrent re-passes would starve each other on the ANE.
        guard !isRunning else {
            phases[meetingID] = .failed(
                L10n.text("Another refine is already running — try again when it finishes."))
            return
        }
        phases[meetingID] = .running(L10n.text("Preparing…"))

        Task {
            do {
                guard let relative = detail.meeting.audioDirectory else {
                    phases[meetingID] = .failed(L10n.text("This meeting does not keep its audio."))
                    return
                }
                let base = RecordingsLocation.shared.resolve(relative)
                let systemURL = MeetingAudioLayout.channelFile(named: "system", in: base)
                let microphoneURL = MeetingAudioLayout.channelFile(named: "microphone", in: base)
                guard systemURL != nil || microphoneURL != nil else {
                    phases[meetingID] = .failed(L10n.text("Could not find the meeting audio."))
                    return
                }

                let whisper = try await services.loadWhisperIfNeeded { [weak self] status in
                    self?.phases[meetingID] = .running(status)
                }
                try await services.loadEnginesIfNeeded()

                let vocabulary = VocabularyPrompt.parse(
                    UserDefaults.standard.string(forKey: "customVocabulary") ?? "")
                let hints = TranscriptionHints(
                    language: SpokenLanguageDetector.transcriptionLanguageHint(
                        for: detail.meeting, segments: detail.segments),
                    vocabulary: vocabulary,
                    meetingID: meetingID)

                var segments: [TranscriptSegment] = []
                if let systemURL {
                    phases[meetingID] = .running(
                        L10n.text("Re-transcribing participants (Whisper)…"))
                    let result = try await whisper.transcribeFile(
                        at: systemURL, hints: hints, channel: .system)
                    segments.append(contentsOf: result.segments)
                }
                if let microphoneURL {
                    phases[meetingID] = .running(
                        L10n.text("Re-transcribing your channel (Whisper)…"))
                    let result = try await whisper.transcribeFile(
                        at: microphoneURL, hints: hints, channel: .microphone)
                    // The mic hears the room through the speakers; whatever
                    // the system channel already says at the same instant is
                    // bleed, not the user (field bug: 52% fake "Me" talk).
                    segments.append(contentsOf: MicBleedFilter.filter(
                        microphone: result.segments, system: segments))
                }
                segments.sort { $0.startTime < $1.startTime }

                var turns: [SpeakerTurn] = []
                if let systemURL, let diarizer = services.diarizer {
                    phases[meetingID] = .running(L10n.text("Identifying speakers…"))
                    turns = (try? await diarizer.diarizeFile(at: systemURL)) ?? []
                }
                let attribution = SpeakerAttributor.attribute(
                    segments: segments, turns: turns, meetingID: meetingID)

                let oldSpeech = detail.segments.reduce(0) { $0 + ($1.endTime - $1.startTime) }
                let meetingSeconds = detail.meeting.endedAt.map {
                    $0.timeIntervalSince(detail.meeting.startedAt)
                }
                phases[meetingID] = .draft(RefineDraft(
                    language: hints.language,
                    speakers: attribution.speakers,
                    segments: attribution.segments,
                    oldSegmentCount: detail.segments.count,
                    oldSpeakerCount: detail.speakers.count,
                    oldSpeechSeconds: oldSpeech,
                    meetingSeconds: meetingSeconds))
            } catch {
                phases[meetingID] = .failed(
                    L10n.format("Refine failed: %@", error.localizedDescription))
            }
            // Refines are one-at-a-time, so this run owning Whisper (and
            // the diarizer) is over either way; give the RAM back after the
            // idle grace periods.
            services.scheduleWhisperRelease()
            services.scheduleRecordingEnginesRelease()
        }
    }
}
