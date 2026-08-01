import OSLog

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
