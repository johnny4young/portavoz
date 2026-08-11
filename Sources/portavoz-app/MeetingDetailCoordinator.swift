import AppKit
import ApplicationKit
import PortavozCore

/// Route-level effects for one Meeting Detail destination.
///
/// The coordinator is a short-lived value projected by `MeetingDetailView`.
/// It owns no observation or presentation state: `MeetingDetailModel` remains
/// the read/effect owner, while `MeetingDetailFlowState` remains scene-owned.
/// Feature-specific operations live in focused extensions; presentation
/// sections never receive this coordinator or its model dependency.
@MainActor
struct MeetingDetailCoordinator {
    let meetingID: MeetingID
    let model: MeetingDetailModel
    let flow: MeetingDetailFlowState
    let sceneValues: MeetingDetailSceneValues
    let sceneActions: MeetingDetailSceneActions

    func deleteMeeting() async -> Bool {
        if case .meetingDeleted = await model.send(.deleteMeeting) {
            return true
        }
        return false
    }

    func retryProcessing() async {
        await model.send(.retryProcessing)
    }

    func loadPresentationSuggestions() async {
        await model.send(.loadMetadataSuggestions)
        guard !Task.isCancelled else { return }
        await model.send(.loadVoiceSuggestions)
    }

    func loadPlayback() async {
        await model.send(.loadPlayback)
    }

    func exportClip(
        _ range: ClosedRange<TimeInterval>,
        to destination: URL
    ) async -> String? {
        let effect = await model.send(.exportAudioClip(range, to: destination))
        guard case .operationFailed(let message) = effect else { return nil }
        return message
    }

    func compressAudio() async {
        await model.send(.compressAudio)
    }

    func correctTranscript(
        _ original: MeetingTranscriptContent.Row,
        text: String,
        speakerID: SpeakerID?,
        revision: Int
    ) async -> String? {
        let effect = await model.send(.correctTranscript(
            CorrectMeetingTranscriptRequest(
                meetingID: meetingID,
                baseTranscriptRevision: revision,
                original: original,
                correctedText: text,
                correctedSpeakerID: speakerID)))
        guard case .operationFailed(let message) = effect else { return nil }
        return message
    }

    func restructureTranscript(
        accepted: MeetingTranscriptContent,
        revision: Int,
        operation: TranscriptStructuralCorrectionOperation
    ) async -> String? {
        let effect = await model.send(.restructureTranscript(
            RestructureMeetingTranscriptRequest(
                meetingID: meetingID,
                baseTranscriptRevision: revision,
                accepted: accepted,
                operation: operation)))
        guard case .operationFailed(let message) = effect else { return nil }
        return message
    }

    func removeCompanionCard(_ id: UUID) async {
        await model.send(.removeCompanionCard(id))
    }

    func refreshCompanionCards(_ detail: MeetingReviewReadModel) {
        guard !flow.isRefreshingCompanion else { return }
        flow.isRefreshingCompanion = true
        flow.operationError = nil
        Task {
            defer { flow.isRefreshingCompanion = false }
            let result = await sceneActions.regenerateCompanionCards(
                RegenerateCompanionCardsRequest(
                    meetingID: meetingID,
                    material: detail.transcriptGenerationMaterial()))
            switch result {
            case .replaced:
                break
            case .unavailable(.requiresMacOS26):
                flow.operationError = L10n.text(
                    "Re-checking Apuntador answers requires macOS 26 and Apple Intelligence.")
            case .unavailable(.appleOnDevice(let reason)):
                flow.operationError = L10n.format(
                    "Apuntador is unavailable: %@",
                    reason)
            case .preserved:
                flow.operationError = L10n.text(
                    "Apuntador could not finish re-checking. Your previous answers were kept.")
            case .persistenceFailed:
                flow.operationError = L10n.text(
                    "The refreshed Apuntador answers could not be saved. Your previous answers were kept.")
            }
        }
    }

    func copyAnswer(_ answer: String) {
        copyText(answer)
    }

    func copyText(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func openURL(_ url: URL) {
        NSWorkspace.shared.open(url)
    }
}
