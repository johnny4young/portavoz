import Foundation
import PortavozCore

extension AppServices {
    /// Today's opt-in fixtures: the brief's previous occurrence and today's meetings.
    func seedTodayFixturesIfRequested(demoMeetingID: MeetingID) async {
        await seedPreviousBriefOccurrenceIfRequested()
        await seedTodayVoicesIfRequested()
        await seedPickUpPositionIfRequested(meetingID: demoMeetingID)
    }

    /// `-seed-pick-up`: listening to the demo meeting stopped at 3:20.
    private func seedPickUpPositionIfRequested(meetingID: MeetingID) async {
        guard ProcessInfo.processInfo.arguments.contains("-seed-pick-up") else { return }
        try? await store.savePlaybackPosition(MeetingPlaybackPosition(
            meetingID: meetingID, seconds: 200, isHeard: false, updatedAt: Self.fixtureAgendaStart))
    }

    /// `-seed-today-voices`: two meetings earlier today, relative to the clock,
    /// so Today's talk totals and day axis have strips to draw.
    func seedTodayVoicesIfRequested() async {
        guard ProcessInfo.processInfo.arguments.contains("-seed-today-voices") else { return }
        let now = Self.fixtureAgendaStart
        let justEnded = ProcessInfo.processInfo.arguments.contains("-seed-just-ended")
        let dayStart = Calendar.current.startOfDay(for: now)
        let window = Self.todayVoicesWindow(sinceMidnight: now.timeIntervalSince(dayStart), justEnded: justEnded)
        let quiet = window.quiet, span = window.span
        let base = now.addingTimeInterval(-quiet - span)
        await seedTodayMeeting(
            "Sprint demo", start: base.addingTimeInterval(span * 0.05), length: span * 0.3,
            voices: [nil, "Marta", "Ilarion", nil],
            turns: [0, 1, 0, 2, 3, 1, 0, 2, 1, 0])
        await seedTodayMeeting(
            "Design review", start: base.addingTimeInterval(span * 0.5), length: span * 0.3,
            voices: [nil, "Marta"],
            turns: [1, 0, 1, 1, 0, 1])
        // `-seed-just-ended`: a meeting that ended two minutes ago, under the now pill.
        guard justEnded else { return }
        let lead = min(12 * 60, quiet)
        await seedTodayMeeting(
            "Roadmap check-in", start: now.addingTimeInterval(-lead), length: lead * 5 / 6,
            voices: [nil, "Ilarion"],
            turns: [0, 1, 0, 1])
    }

    /// The quiet gap before now (room for the just-ended title) and the span holding
    /// the two meetings, both inside today; early in the day they shrink instead of
    /// collapsing to zero.
    nonisolated static func todayVoicesWindow(
        sinceMidnight: TimeInterval, justEnded: Bool
    ) -> (quiet: TimeInterval, span: TimeInterval) {
        let quiet = justEnded ? min(90 * 60, sinceMidnight / 2) : 0
        return (quiet, min(sinceMidnight - quiet, 4 * 3_600))
    }

    /// Voice 0 is you; `turns` split the meeting into equal turns by voice.
    private func seedTodayMeeting(
        _ title: String, start: Date, length: TimeInterval, voices: [String?], turns: [Int]
    ) async {
        let meeting = Meeting(
            title: title, startedAt: start, endedAt: start.addingTimeInterval(length), language: "en")
        try? await store.save(meeting)
        let speakers = voices.enumerated().map { index, name in
            Speaker(
                meetingID: meeting.id, label: index == 0 ? "Me" : "S\(index)",
                displayName: name, isMe: index == 0)
        }
        try? await store.save(speakers)
        let turn = length / Double(turns.count)
        try? await store.save(turns.enumerated().map { index, voice in
            TranscriptSegment(
                meetingID: meeting.id, speakerID: speakers[voice].id,
                channel: voice == 0 ? .microphone : .system,
                text: "Turn \(index + 1) of \(title).",
                startTime: Double(index) * turn, endTime: (Double(index) + 0.9) * turn, isFinal: true)
        })
    }
}
