import ApplicationKit
import IntelligenceKit
import PortavozCore
import StorageKit

/// App-edge adapter from current GRDB summaries and commitments into the
/// storage-independent meeting-preparation contract.
struct AppMeetingBriefLibraryReader: MeetingBriefLibraryReading {
    let store: MeetingStore

    func meetingBriefSummaryMarkdowns(
        for meetingIDs: [MeetingID]
    ) async throws -> [MeetingID: String] {
        try await store.meetingBriefSummaryMarkdowns(for: meetingIDs)
    }

    func openMeetingBriefItems(
        limit: Int
    ) async throws -> [MeetingBrief.OpenItem] {
        try await store.openActionItems(limit: limit).map { open in
            MeetingBrief.OpenItem(
                id: open.item.id,
                meetingID: open.meetingID,
                meetingTitle: open.meetingTitle,
                text: open.item.text)
        }
    }
}

/// Optional Foundation Models synthesis stays behind the application port.
/// Invalid model source indexes cannot escape into presentation.
struct AppOnDeviceMeetingBriefSynthesizer: MeetingBriefSynthesizing {
    func synthesizeMeetingBrief(
        eventTitle: String,
        sources: [MeetingBrief.SynthesisSource]
    ) async throws -> [MeetingBrief.SynthesisPoint] {
        guard #available(macOS 26.0, iOS 26.0, *),
              FoundationModelSummaryProvider.unavailabilityReason() == nil
        else { return [] }
        let passages = sources.map {
            RAGPassage(
                meetingID: $0.meetingID,
                meetingTitle: $0.meetingTitle,
                timestamp: 0,
                text: $0.overview)
        }
        return await BriefSynthesizer.whatToKnow(
            eventTitle: eventTitle,
            passages: passages
        ).compactMap { point in
            let sourceIndex = point.passageIndex - 1
            guard sources.indices.contains(sourceIndex) else { return nil }
            return MeetingBrief.SynthesisPoint(
                text: point.text,
                sourceIndex: sourceIndex)
        }
    }
}
