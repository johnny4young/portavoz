import Foundation

/// One-shot accelerator degradation for model loading: try the default
/// compute units, and on failure retry exactly once on CPU. Accelerator
/// context creation (ANE/GPU contention, stale Metal contexts held by a
/// crashed process) is a recurring field failure class in local-Whisper
/// apps; slow-but-working refine beats failing outright. Pure over closures
/// so the policy is tested without CoreML.
public enum AcceleratorFallback {
    public static func run<T: Sendable>(
        primary: () async throws -> T,
        cpuFallback: () async throws -> T
    ) async throws -> T {
        do {
            return try await primary()
        } catch is CancellationError {
            // A user cancel must never trigger a second, slower load.
            throw CancellationError()
        } catch let primaryError {
            try Task.checkCancellation()
            do {
                return try await cpuFallback()
            } catch is CancellationError {
                throw CancellationError()
            } catch let fallbackError {
                throw AcceleratorFallbackError(
                    primary: primaryError, fallback: fallbackError)
            }
        }
    }
}

/// Both attempts failed: carry both causes so diagnostics can tell an
/// accelerator-only failure from a broken model directory.
public struct AcceleratorFallbackError: Error, LocalizedError, Sendable {
    public let primary: any Error
    public let fallback: any Error

    public var errorDescription: String? {
        "The speech model failed to load on the accelerator and on the CPU. "
            + "Accelerator: \(primary.localizedDescription) "
            + "CPU: \(fallback.localizedDescription)"
    }
}
