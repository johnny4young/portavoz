import Foundation
import PortavozCore

extension AppServices {
    /// Builds a deterministic 2-hour/5k-segment meeting only in a disposable
    /// store. It drives XCUITest and the SwiftUI Instruments baseline without
    /// reading or writing the user's library, audio, models, or preferences.
    func seedScaleBenchmarkIfRequested() async {
        let arguments = ProcessInfo.processInfo.arguments
        guard arguments.contains("-use-temp-store"),
              arguments.contains("-seed-scale"),
              ((try? await store.meetings()) ?? []).isEmpty
        else { return }

        let segmentCount = Self.scaleSegmentCount(arguments: arguments)
        let duration: TimeInterval = 2 * 60 * 60
        let meeting = Meeting(
            title: "Scale baseline · 2 h · \(segmentCount) segments",
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            endedAt: Date(timeIntervalSince1970: 1_700_000_000 + duration),
            language: "es")
        let speakers = (0..<4).map {
            Speaker(
                meetingID: meeting.id,
                label: "S\($0 + 1)",
                displayName: "Person \($0 + 1)")
        }
        let stride = duration / Double(segmentCount)
        let segments = (0..<segmentCount).map { index in
            let start = Double(index) * stride
            return TranscriptSegment(
                meetingID: meeting.id,
                speakerID: speakers[index % speakers.count].id,
                channel: index.isMultiple(of: 5) ? .microphone : .system,
                text: "Scale turn \(index): presupuesto, rollout, audio and next steps.",
                startTime: start,
                endTime: min(duration, start + stride * 0.82),
                confidence: 0.94,
                isFinal: true)
        }

        do {
            try await store.save(meeting)
            try await store.save(speakers)
            try await store.save(segments)
            _ = try await store.saveSummary(Self.scaleSummary(
                meetingID: meeting.id,
                revision: 1))
        } catch {
            assertionFailure("Could not seed scale benchmark: \(error)")
            return
        }

        libraryVersion += 1
        pendingRoute = .meeting(meeting.id)
        if arguments.contains("-scale-auto-summary-update") {
            scheduleScaleSummaryUpdate(meetingID: meeting.id)
        }
    }

    private static func scaleSegmentCount(arguments: [String]) -> Int {
        guard let index = arguments.firstIndex(of: "-scale-segments"),
              arguments.indices.contains(index + 1),
              let value = Int(arguments[index + 1])
        else { return 5_000 }
        return min(100_000, max(1, value))
    }

    private static func scaleSummary(
        meetingID: MeetingID,
        revision: Int
    ) -> SummaryDraft {
        SummaryDraft(
            meetingID: meetingID,
            recipeID: Recipe.standup.id,
            language: "es",
            markdown: """
                Scale baseline summary revision \(revision).

                ## Progress
                - The scale fixture is ready.

                ## Blockers
                - None.
                """,
            actionItems: [ActionItem(text: "Review the scale evidence")])
    }

    private func scheduleScaleSummaryUpdate(meetingID: MeetingID) {
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard let self else { return }
            _ = try? await store.saveSummary(Self.scaleSummary(
                meetingID: meetingID,
                revision: 2))
        }
    }
}
