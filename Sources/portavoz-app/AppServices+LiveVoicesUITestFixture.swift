import ApplicationKit
import DiarizationKit
import Foundation
import PortavozCore

/// A call twelve minutes in with you and eleven remote voices, so the live
/// Voices table shows recency, shares and the Others fold. Remote rows are
/// named through the live labeler exactly as diarizer turns would name them.
enum LiveVoicesUITestScript {
    struct Row {
        /// Nil for your microphone.
        let label: String?
        let start: TimeInterval
        let end: TimeInterval
    }

    /// Seconds into the call when the last row arrives.
    static let elapsed: TimeInterval = 724

    static let rows: [Row] = [
        Row(label: nil, start: 2, end: 16), Row(label: "S1", start: 24, end: 60),
        Row(label: "S6", start: 68, end: 90), Row(label: "S2", start: 98, end: 140),
        Row(label: nil, start: 142, end: 160), Row(label: "S7", start: 168, end: 190),
        Row(label: "S3", start: 198, end: 230), Row(label: "S8", start: 238, end: 262),
        Row(label: nil, start: 264, end: 280), Row(label: "S9", start: 288, end: 300),
        Row(label: "S10", start: 308, end: 322), Row(label: "S11", start: 330, end: 340),
        Row(label: "S6", start: 348, end: 372), Row(label: "S2", start: 380, end: 410),
        Row(label: "S5", start: 418, end: 424), Row(label: nil, start: 426, end: 450),
        Row(label: "S1", start: 458, end: 500), Row(label: "S4", start: 508, end: 544),
        Row(label: nil, start: 546, end: 560), Row(label: "S2", start: 568, end: 590),
        Row(label: "S3", start: 598, end: 604), Row(label: nil, start: 606, end: 620),
        Row(label: "S2", start: 628, end: 680), Row(label: "S1", start: 688, end: 704),
        // Your turn is still open, so you lead the table while the test looks.
        Row(label: nil, start: 704, end: 800)
    ]

    static func label(forRowStartingAt start: TimeInterval) -> String? {
        rows.first { $0.start == start }?.label
    }
}

struct UITestLiveVoicesRuntime: StartRecordingRuntime {
    func prepare(
        preferences: StartRecordingPreferencesSnapshot
    ) async throws -> StartRecordingPreparedRuntime {
        StartRecordingPreparedRuntime(
            channels: [.microphone, .system],
            tappedMeetingApps: ["Meet"],
            liveTranscriptionAvailable: true)
    }

    func startCapture(
        _ request: StartRecordingCaptureRequest
    ) async throws -> any StartRecordingSession {
        request.callbacks.liveTranscription(.available)
        Task {
            try? await Task.sleep(for: .milliseconds(100))
            for (index, row) in LiveVoicesUITestScript.rows.enumerated() {
                // Distinct wording, so the echo filter never takes your rows for remote bleed.
                let text = row.label.map { "Line \(index + 1) of the scripted call, from \($0)." }
                    ?? "Sounds good, I will send my notes on item \(index + 1) tonight."
                await request.callbacks.caption(TranscriptSegment(
                    meetingID: request.meetingID,
                    channel: row.label == nil ? .microphone : .system,
                    text: text,
                    language: "en",
                    startTime: row.start,
                    endTime: row.end,
                    isFinal: true))
                try? await Task.sleep(for: .milliseconds(10))
            }
        }
        return UITestSystemCaptureStallSession()
    }

    func cancelPreparation() async {}
    func scheduleIdleRelease() async {}
}

extension LiveAssistUITestFixture {
    private static let playsLiveVoices = ProcessInfo.processInfo.arguments.contains("-simulate-live-voices")

    func receiveLiveVoice(in controller: RecordingController) {
        guard Self.playsLiveVoices, let row = controller.captions.last else { return }
        // A row can land before the start commit sets the clock; backdate whenever it is short.
        if Date().timeIntervalSince(controller.startedAt) < LiveVoicesUITestScript.elapsed - 5 {
            controller.backdateStartForUITestFixture(elapsed: LiveVoicesUITestScript.elapsed)
        }
        guard row.channel == .system,
              let label = LiveVoicesUITestScript.label(forRowStartingAt: row.startTime)
        else { return }
        controller.receiveLiveSpeakerTurn(
            SpeakerTurn(voiceLabel: label, startTime: row.startTime, endTime: row.endTime))
    }
}
