import ApplicationKit
import Foundation
import PortavozCore

/// Audio requests that read the detail state but never change it.
extension MeetingDetailModel {
    func exportAudioClip(
        _ range: ClosedRange<TimeInterval>,
        to destination: URL
    ) async -> Effect {
        guard let relative = state.readModel?.meeting.audioDirectory else {
            return .operationFailed(L10n.text("The meeting has no audio to trim."))
        }
        do {
            try await client.exportMeetingDetailAudioClip(
                ExportMeetingAudioClipRequest(
                    relativeAudioDirectory: relative,
                    range: range,
                    destination: destination,
                    segments: state.readModel?.segments ?? [],
                    clearPlayback: state.playback?.session.clearPlayback ?? true))
            return .audioClipExported(destination)
        } catch {
            return .operationFailed(error.localizedDescription)
        }
    }

    func rememberVoice(_ speakerID: SpeakerID) async -> Effect {
        do {
            switch try await client.rememberMeetingDetailVoice(
                meetingID: meetingID,
                speakerID: speakerID) {
            case .remembered:
                return .voiceRemembered
            case .insufficientAudio:
                return .voiceMemoryInsufficientAudio
            case .suggestions, .canRemember:
                return .operationFailed(L10n.text("Could not remember the voice."))
            }
        } catch {
            return .operationFailed(L10n.format(
                "Could not remember the voice: %@",
                UseCaseErrorMessages.describe(error)))
        }
    }
}
