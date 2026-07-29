import AVFoundation

public enum MicrophonePermissionState: Equatable, Sendable {
    case authorized
    case denied
    case restricted
    case notDetermined
}

/// AVFoundation adapter for microphone authorization. SwiftUI observes only
/// the stable state and asks the composition root to perform the prompt.
public struct MicrophonePermissionClient: Sendable {
    private let readState: @Sendable () -> MicrophonePermissionState
    private let requestAccess: @Sendable () async -> Bool

    public init() {
        readState = {
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .authorized: .authorized
            case .denied: .denied
            case .restricted: .restricted
            case .notDetermined: .notDetermined
            @unknown default: .denied
            }
        }
        requestAccess = {
            await AVCaptureDevice.requestAccess(for: .audio)
        }
    }

    init(
        state: @escaping @Sendable () -> MicrophonePermissionState,
        request: @escaping @Sendable () async -> Bool
    ) {
        readState = state
        requestAccess = request
    }

    public func state() -> MicrophonePermissionState {
        readState()
    }

    public func request() async -> Bool {
        await requestAccess()
    }

    /// Resolves the capture precondition before any AVAudioEngine input access.
    ///
    /// Recording Start is a user-initiated action, so it may issue the one-time
    /// system prompt when authorization is undetermined. A previously denied
    /// or restricted permission fails closed without touching the audio graph.
    public func authorizeIfNeeded() async -> Bool {
        switch state() {
        case .authorized:
            true
        case .notDetermined:
            await request()
        case .denied, .restricted:
            false
        }
    }
}
