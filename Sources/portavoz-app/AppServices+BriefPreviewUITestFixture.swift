import ApplicationKit
import Foundation
import PortavozCore

extension AppServices {
    /// `-seed-brief-previous`: an earlier occurrence recorded from the
    /// `-seed-brief` event and renamed since, so Today's brief card finds it by
    /// the event's identifier alone.
    func seedPreviousBriefOccurrenceIfRequested() async {
        guard ProcessInfo.processInfo.arguments.contains("-seed-brief-previous") else { return }
        let start = Self.fixtureAgendaStart.addingTimeInterval(-2 * 86_400)
        let meeting = Meeting(
            title: "Rollout budget kickoff", startedAt: start,
            endedAt: start.addingTimeInterval(30 * 60), language: "en")
        try? await store.save(meeting)
        try? await store.linkCalendarEvent(Self.fixtureBriefEvent.id, to: meeting.id)
        let me = Speaker(meetingID: meeting.id, label: "Me", isMe: true)
        let ana = Speaker(meetingID: meeting.id, label: "S1", displayName: "Ana")
        try? await store.save([me, ana])
        let quote = TranscriptSegment(
            meetingID: meeting.id, speakerID: ana.id, channel: .system,
            text: "The rollout budget still has no confirmed owner.",
            startTime: 95, endTime: 110, isFinal: true)
        let promise = TranscriptSegment(
            meetingID: meeting.id, speakerID: me.id, channel: .microphone,
            text: "I will prepare the budget proposal by Thursday.",
            startTime: 150, endTime: 160, isFinal: true)
        try? await store.save([quote, promise])
        let item = ActionItem(text: "Prepare the budget proposal", ownerSpeakerID: me.id)
        _ = try? await store.saveSummary(SummaryDraft(
            meetingID: meeting.id, recipeID: Recipe.general.id, language: "en",
            markdown: "Rollout budget.", actionItems: [item],
            actionItemEvidence: [
                SummaryActionItemEvidence(actionItemID: item.id, evidenceSegmentIDs: [promise.id])
            ]))
    }
}
