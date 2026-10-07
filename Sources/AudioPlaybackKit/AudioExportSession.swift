import AVFoundation
import Foundation

/// One AAC export compatibility bridge. Callers still own composition, output
/// replacement, cleanup, verification, and their domain-specific legacy errors.
enum AudioExportSession {
    static func export(
        _ session: AVAssetExportSession,
        to output: URL,
        legacyFailure: (String) -> any Error
    ) async throws {
        if #available(macOS 15.0, iOS 18.0, *) {
            // Preserve native errors and the framework's async cancellation behavior.
            try await session.export(to: output, as: .m4a)
        } else {
            session.outputURL = output
            session.outputFileType = .m4a
            await waitForLegacyCompletion { completion in
                session.exportAsynchronously(completionHandler: completion)
            }
            try requireLegacyCompletion(
                status: session.status,
                error: session.error,
                failure: legacyFailure)
        }
    }

    /// The callback remains the completion owner, including when the waiting
    /// task is cancelled. This extraction does not introduce cancelExport(),
    /// early continuation completion, or an unjoined background export.
    static func waitForLegacyCompletion(
        start: (@escaping @Sendable () -> Void) -> Void
    ) async {
        await withCheckedContinuation { continuation in
            start { continuation.resume() }
        }
    }

    static func requireLegacyCompletion(
        status: AVAssetExportSession.Status,
        error: (any Error)?,
        failure: (String) -> any Error
    ) throws {
        guard status == .completed else {
            throw failure(error?.localizedDescription ?? "unknown")
        }
    }
}
