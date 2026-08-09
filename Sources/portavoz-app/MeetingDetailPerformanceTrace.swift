import ApplicationKit
import OSLog
import PortavozCore

@MainActor
final class MeetingDetailFirstContentTrace {
    private static let signposter = OSSignposter(
        subsystem: "app.portavoz.mac",
        category: "meeting-detail")

    private let interval: OSSignpostIntervalState
    private let workloadSpan: ResourceWorkloadSpan
    private let workloadTelemetry: ResourceWorkloadTelemetry
    private var didFinish = false

    init(workloadTelemetry: ResourceWorkloadTelemetry) {
        self.workloadTelemetry = workloadTelemetry
        interval = Self.signposter.beginInterval("Meeting Detail First Content")
        workloadSpan = workloadTelemetry.begin(
            ResourceWorkloadDescriptor(
                workloadClass: .userInitiated,
                kind: .uiProjection,
                operation: .execute))
    }

    func finish() {
        guard !didFinish else { return }
        didFinish = true
        Self.signposter.endInterval("Meeting Detail First Content", interval)
        workloadTelemetry.finish(workloadSpan, outcome: .completed)
    }
}

/// Content-free signposts used only by the disposable Meeting Detail
/// performance harness. Production launches never opt in, so this does not
/// add a persistent telemetry stream or inspect meeting content.
enum MeetingDetailPerformanceTrace {
    private static let signposter = OSSignposter(
        subsystem: "app.portavoz.mac",
        category: "meeting-detail")

    static var isEnabled: Bool {
        let arguments = ProcessInfo.processInfo.arguments
        return arguments.contains("-use-temp-store")
            && arguments.contains("-seed-scale")
            && arguments.contains("-detail-performance-profile")
    }

    static func beginTranscriptScroll() -> OSSignpostIntervalState? {
        guard isEnabled else { return nil }
        return signposter.beginInterval("Meeting Detail Transcript Scroll")
    }

    static func endTranscriptScroll(_ interval: OSSignpostIntervalState?) {
        guard let interval else { return }
        signposter.endInterval("Meeting Detail Transcript Scroll", interval)
    }

    static func measurePlaybackSeek(_ operation: () -> Void) {
        guard isEnabled else {
            operation()
            return
        }
        let interval = signposter.beginInterval("Meeting Detail Playback Seek")
        operation()
        signposter.endInterval("Meeting Detail Playback Seek", interval)
    }
}
