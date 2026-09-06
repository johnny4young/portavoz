import Foundation

/// Classifies the user's recording, including startup and final persistence,
/// independently of window visibility. It does not prevent idle system sleep.
@MainActor
final class RecordingProcessActivity {
    typealias Begin = (ProcessInfo.ActivityOptions, String) -> any NSObjectProtocol
    typealias End = (any NSObjectProtocol) -> Void

    private let begin: Begin
    private let end: End
    private var token: (any NSObjectProtocol)?

    init(
        begin: @escaping Begin = { options, reason in
            ProcessInfo.processInfo.beginActivity(options: options, reason: reason)
        },
        end: @escaping End = { ProcessInfo.processInfo.endActivity($0) }
    ) {
        self.begin = begin
        self.end = end
    }

    isolated deinit {
        if let token { end(token) }
    }

    func update(for phase: RecordingPhase) {
        switch phase {
        case .preparing, .recording, .processing:
            guard token == nil else { return }
            token = begin(
                .userInitiatedAllowingIdleSystemSleep,
                "Recording and saving a meeting")
        case .idle, .done, .failed:
            guard let token else { return }
            self.token = nil
            end(token)
        }
    }
}
