import Foundation
import ModelStoreKit
import Observation

/// Presentation-only state for explicit onboarding preparation. AppServices
/// continues to own shared model loads, leases, and idle release on every exit.
@MainActor
@Observable
final class OnboardingModelPreparation {
    enum Failure: Equatable {
        case network
        case storage
        case cancelled
        case unavailable

        var message: String {
            switch self {
            case .network:
                L10n.text("Models could not be downloaded. Check your connection and try again.")
            case .storage:
                L10n.text("Models could not be saved. Check available disk space and try again.")
            case .cancelled:
                L10n.text("Model preparation was interrupted. You can try again.")
            case .unavailable:
                L10n.text("Models could not be prepared. Try again, or continue setup and download them later.")
            }
        }

        static func classify(_ error: any Error) -> Self {
            if error is CancellationError { return .cancelled }
            // ModelStore wraps every transfer failure with a stringified
            // cause, so the URLError never reaches this classifier in production.
            if let storeError = error as? ModelStore.ModelStoreError,
               case .downloadFailed = storeError {
                return .network
            }
            if let error = error as? URLError {
                switch error.code {
                case .cancelled:
                    return .cancelled
                case .timedOut, .cannotFindHost, .cannotConnectToHost,
                     .networkConnectionLost, .dnsLookupFailed, .notConnectedToInternet,
                     .secureConnectionFailed, .dataNotAllowed, .internationalRoamingOff:
                    return .network
                default:
                    return .unavailable
                }
            }
            if isOutOfSpace(error as NSError) { return .storage }
            // Never render arbitrary error descriptions, model paths or URLs.
            return .unavailable
        }

        private static func isOutOfSpace(_ error: NSError) -> Bool {
            if error.domain == NSCocoaErrorDomain, error.code == NSFileWriteOutOfSpaceError {
                return true
            }
            if error.domain == NSPOSIXErrorDomain,
               error.code == Int(ENOSPC) || error.code == Int(EDQUOT) {
                return true
            }
            guard let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError else { return false }
            return isOutOfSpace(underlying)
        }
    }

    enum Phase: Equatable {
        case idle
        case preparing
        case ready
        case failed(Failure)
    }

    private(set) var phase: Phase = .idle
    private(set) var attempt = 0

    func prepare(using load: @MainActor () async throws -> Void) async {
        guard phase != .preparing, phase != .ready else { return }
        phase = .preparing
        attempt += 1
        do {
            try await load()
            phase = .ready
        } catch {
            phase = .failed(Failure.classify(error))
        }
    }

    /// Only the disposable UI-test store may replace model preparation. The
    /// fixture never starts a model download, even on its successful retry.
    static func disposableFixtureResult(
        arguments: [String], attempt: Int
    ) -> Result<Void, Error>? {
        guard arguments.contains("-use-temp-store"),
              arguments.contains("-simulate-onboarding-model-recovery") else { return nil }
        return attempt == 1 ? .failure(URLError(.notConnectedToInternet)) : .success(())
    }
}
