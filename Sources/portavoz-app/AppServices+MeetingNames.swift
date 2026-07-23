import ApplicationKit
import Foundation
import IntegrationsKit
import IntelligenceKit
import PortavozCore

enum AppMeetingNameSuggestionError: Error, LocalizedError {
    case unavailable

    var errorDescription: String? {
        switch self {
        case .unavailable:
            "Name suggestions require macOS 26."
        }
    }
}

extension AppServices {
    func meetingDetailNameSuggestions(
        _ meetingID: MeetingID
    ) async throws -> [MeetingNameSuggestion] {
        // Same owner identity the Apuntador uses: mentions of that name are
        // people addressing the owner, never another speaker's identity.
        return try await SuggestMeetingSpeakerNames(
            library: .local(store: store),
            candidates: AppCalendarMeetingNameCandidates(),
            proposer: AppMeetingSpeakerNameProposer())
            .execute(.init(
                meetingID: meetingID,
                ownerName: RecordingController.companionOwnerName()))
    }
}

private struct AppCalendarMeetingNameCandidates: MeetingNameCandidateProviding {
    func names(around date: Date) async -> [String] {
        await CalendarAttendeeSource().attendees(around: date)
    }
}

private struct AppMeetingSpeakerNameProposer: MeetingSpeakerNameProposing {
    func proposeNames(
        segments: [TranscriptSegment],
        speakers: [Speaker],
        attendeeCandidates: [String]
    ) async throws -> [MeetingNameProposal] {
        guard #available(macOS 26.0, *) else {
            throw AppMeetingNameSuggestionError.unavailable
        }
        return try await SpeakerNamer().suggestNames(
            segments: segments,
            speakers: speakers,
            attendeeCandidates: attendeeCandidates
        ).map {
            MeetingNameProposal(label: $0.label, name: $0.name)
        }
    }
}
