import DiarizationKit
import Foundation
import PortavozCore
import StorageKit
import TranscriptionKit

/// The durable payloads Stop installs, and the asset reconciliation that binds
/// them to what actually reached disk. Split from `StopRecording` so the use
/// case keeps its outcome ladder and this file keeps the snapshot shapes that
/// ladder degrades through.
extension StopRecording {
    func capturedSnapshot(
        _ request: StopRecordingRequest,
        meeting: Meeting,
        assets: [AudioAsset],
        attribution: SpeakerAttributor.Attribution
    ) -> CapturedMeetingSnapshot {
        let generatedCardIDs = Set(request.companionArtifacts.map(\.card.id))
        return CapturedMeetingSnapshot(
            meeting: meeting,
            assets: assets,
            speakers: attribution.speakers,
            segments: attribution.segments,
            contextItems: request.contextItems,
            companionCards: request.companionCards.filter {
                !generatedCardIDs.contains($0.id)
            },
            companionArtifacts: request.companionArtifacts,
            companionTerminalRuns: request.companionTerminalRuns)
    }

    /// Keeps the user's live transcript, notes, and non-generated Companion
    /// cards while removing generated payloads that can fail their provenance
    /// fence. A generated card is never silently downgraded to provenance-free.
    func capturedCoreSnapshot(
        _ request: StopRecordingRequest,
        meeting: Meeting,
        assets: [AudioAsset],
        attribution: SpeakerAttributor.Attribution
    ) -> CapturedMeetingSnapshot {
        let generatedCardIDs = Set(request.companionArtifacts.map(\.card.id))
        return CapturedMeetingSnapshot(
            meeting: meeting,
            assets: assets,
            speakers: attribution.speakers,
            segments: attribution.segments,
            contextItems: request.contextItems,
            companionCards: request.companionCards.filter {
                !generatedCardIDs.contains($0.id)
            })
    }

    /// Last resumable projection: validated audio plus optional user notes.
    /// The durable transcription job rebuilds every spoken row from the CAFs.
    func capturedAudioSnapshot(
        _ request: StopRecordingRequest,
        meeting: Meeting,
        assets: [AudioAsset],
        includeContext: Bool
    ) -> CapturedMeetingSnapshot {
        CapturedMeetingSnapshot(
            meeting: meeting,
            assets: assets,
            speakers: [],
            segments: [],
            contextItems: includeContext ? request.contextItems : [],
            companionCards: [])
    }
}
