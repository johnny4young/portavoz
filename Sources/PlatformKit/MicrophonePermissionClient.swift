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
    public init() {}

    public func state() -> MicrophonePermissionState {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: .authorized
        case .denied: .denied
        case .restricted: .restricted
        case .notDetermined: .notDetermined
        @unknown default: .denied
        }
    }

    public func request() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }
}
