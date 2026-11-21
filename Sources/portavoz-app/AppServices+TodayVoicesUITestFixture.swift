import Foundation
import PortavozCore

extension AppServices {
    /// Today's opt-in fixtures: the brief's previous occurrence and today's meetings.
    func seedTodayFixturesIfRequested() async {
        await seedPreviousBriefOccurrenceIfRequested()
        await seedTodayVoicesIfRequested()
    }

    /// `-seed-today-voices`: two meetings earlier today, relative to the clock,
    /// so Today's talk totals and day axis have strips to draw.
    func seedTodayVoicesIfRequested() async {
        guard ProcessInfo.processInfo.arguments.contains("-seed-today-voices") else { return }
        let now = Self.fixtureAgendaStart
        let span = min(now.timeIntervalSince(Calendar.current.startOfDay(for: now)), 4 * 3_600)
        let base = now.addingTimeInterval(-span)
        await seedTodayMeeting(
            "Sprint demo", start: base.addingTimeInterval(span * 0.05), length: span * 0.3,
            voices: [nil, "Marta", "Ilarion", nil],
            turns: [0, 1, 0, 2, 3, 1, 0, 2, 1, 0])
        await seedTodayMeeting(
            "Design review", start: base.addingTimeInterval(span * 0.5), length: span * 0.3,
            voices: [nil, "Marta"],
            turns: [1, 0, 1, 1, 0, 1])
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
                startTime: Double(index) * turn, endTime: Double(index + 1) * turn - 1, isFinal: true)
        })
    }
}
