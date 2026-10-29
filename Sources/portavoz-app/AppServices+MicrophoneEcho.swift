import AudioCaptureKit
import Foundation
import PortavozCore

extension AppServices {
    /// Measures loudspeaker echo off the main actor. Any failure degrades to
    /// nil so transcription keeps the text-only bleed filter.
    nonisolated static func measureMicrophoneEcho(
        microphone: URL,
        system: URL
    ) async -> MicrophoneEchoProfile? {
        let measurement = Task.detached(priority: .utility) {
            try? MicrophoneEchoAnalysis.profile(microphone: microphone, system: system)
        }
        return await withTaskCancellationHandler {
            await measurement.value
        } onCancel: {
            measurement.cancel()
        }
    }
}
