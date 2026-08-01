import ApplicationKit
import Foundation
import PortavozCore
import SwiftUI
import TranscriptionKit

/// Route-scoped composition for one Meeting Detail window destination.
///
/// This is the only Meeting Detail presentation type allowed to know the app
/// composition root. The child view receives a route-owned model, immutable
/// presentation values, and explicit meeting-scoped actions.
@MainActor
struct MeetingDetailScene: View {
    let services: AppServices
    let meetingID: MeetingID
    @Binding var route: Route?

    @Environment(\.locale) private var locale
    @Environment(\.openSettings) private var openSettings
    @Environment(\.timeZone) private var timeZone
    @State private var model: MeetingDetailModel
    @State private var flow = MeetingDetailFlowState()

    init(
        services: AppServices,
        meetingID: MeetingID,
        route: Binding<Route?>
    ) {
        self.services = services
        self.meetingID = meetingID
        _route = route
        _model = State(initialValue: services.makeMeetingDetailModel(meetingID))
    }

    var body: some View {
        MeetingDetailView(
            meetingID: meetingID,
            route: $route,
            model: model,
            flow: flow,
            presentation: MeetingDetailPresentation(
                locale: locale,
                timeZone: timeZone),
            sceneValues: sceneValues,
            sceneActions: sceneActions)
    }

    private var sceneValues: MeetingDetailSceneValues {
        MeetingDetailSceneValues(
            refinePhase: services.refines.phase(for: meetingID),
            pendingSeek: services.pendingMeetingSeek,
            justRecorded: services.justRecorded,
            summaryEngine: services.summaryEngine,
            ollamaModel: services.ollamaModel,
            appleSummaryAvailable: services.appleSummaryAvailable,
            mlxDownloaded: services.mlxDownloaded,
            performanceProfile: services.meetingDetailPerformanceProfile)
    }

    private var sceneActions: MeetingDetailSceneActions {
        MeetingDetailSceneActions(
            openSettings: { category in
                services.pendingSettingsCategory = category
                openSettings()
            },
            exportBundle: { includeAudio in
                try await services.exportMeetingBundle(
                    meetingID: meetingID,
                    includeAudio: includeAudio)
            },
            regenerateSummary: { request in
                await services.regenerateSummary.execute(request)
            },
            enhanceNotes: { request in
                await services.enhanceMeetingNotes.execute(request)
            },
            clearRefine: {
                services.refines.clear(meetingID)
            },
            cancelRefine: {
                services.refines.cancel(meetingID)
            },
            startRefine: { detail, languagePolicy in
                services.refines.start(
                    meetingID: meetingID,
                    meeting: detail.meeting,
                    speakers: detail.speakers,
                    segments: detail.segments,
                    useCase: services.refineMeeting.draft,
                    languagePolicy: languagePolicy)
            },
            applyRefine: { request in
                try await services.applyMeetingDetailRefine(request)
            },
            averageMyShare: {
                await services.averageMyShare(excluding: meetingID)
            },
            consumePendingSeek: {
                guard let request = services.pendingMeetingSeek,
                      request.meetingID == meetingID
                else { return nil }
                services.pendingMeetingSeek = nil
                return request
            },
            clearJustRecorded: {
                services.justRecorded = nil
            })
    }
}

/// Observable process values projected by the scene for one selected meeting.
/// This stays data-only; mutations travel through `MeetingDetailSceneActions`.
struct MeetingDetailSceneValues {
    let refinePhase: RefineService.Phase?
    let pendingSeek: MeetingSeekRequest?
    let justRecorded: MeetingID?
    let summaryEngine: SummaryEngine
    let ollamaModel: String?
    let appleSummaryAvailable: Bool
    let mlxDownloaded: Bool
    let performanceProfile: MeetingDetailPerformanceProfile
}

/// Explicit route-level capabilities used to compose Meeting Detail sections.
/// Child sections receive only the relevant closure from this boundary.
struct MeetingDetailSceneActions {
    let openSettings: @MainActor (SettingsCategory) -> Void
    let exportBundle: @MainActor (Bool) async throws -> Data
    let regenerateSummary:
        @MainActor (RegenerateSummaryRequest) async -> SummaryRegenerationResult
    let enhanceNotes:
        @MainActor (EnhanceMeetingNotesRequest) async -> EnhanceMeetingNotesResult
    let clearRefine: @MainActor () -> Void
    let cancelRefine: @MainActor () -> Void
    let startRefine:
        @MainActor (MeetingReviewReadModel, TranscriptLanguagePolicy?) -> Void
    let applyRefine:
        @MainActor (ApplyRefinedMeetingRequest) async throws -> ApplyRefinedMeetingResult
    let averageMyShare: @MainActor () async -> Double?
    let consumePendingSeek: @MainActor () -> MeetingSeekRequest?
    let clearJustRecorded: @MainActor () -> Void
}
