import AppKit
import Foundation

/// Finds the running apps most likely to be hosting a meeting, so the
/// system-audio capture can tap those processes directly instead of the
/// global device output. A per-process tap reads what the app renders
/// *before* device routing — which keeps working when a Bluetooth output
/// (AirPods) is in the narrowband HFP profile that silences the global tap.
enum MeetingAppDetector {
    /// A running meeting app: its process id and display name.
    struct App {
        let pid: pid_t
        let name: String
        let bundleID: String
    }

    /// Bundle ids of native meeting apps and the browsers that host web
    /// meetings (Google Meet, Whereby, …). Tapping a browser captures all of
    /// its audio, which for a meeting is dominated by the call.
    static let bundleIDs: Set<String> = [
        "us.zoom.xos",  // Zoom
        "com.microsoft.teams", "com.microsoft.teams2",  // Teams (classic + new)
        "com.tinyspeck.slackmacgap",  // Slack huddles
        "com.hnc.Discord",  // Discord
        "com.cisco.webexmeetingsapp", "Cisco-Systems.Spark",  // Webex
        "com.apple.FaceTime",  // FaceTime
        // Browsers — web meetings run inside them.
        "com.google.Chrome", "com.apple.Safari", "company.thebrowser.Browser",
        "com.microsoft.edgemac", "com.brave.Browser", "org.mozilla.firefox"
    ]

    /// The running meeting apps, most-recently-active first so the frontmost
    /// call app is preferred.
    static func running() -> [App] {
        NSWorkspace.shared.runningApplications
            .filter { app in
                guard let id = app.bundleIdentifier else { return false }
                return bundleIDs.contains(id) && app.processIdentifier > 0
            }
            .compactMap { app in
                guard let bundleID = app.bundleIdentifier else { return nil }
                return App(
                    pid: app.processIdentifier,
                    name: app.localizedName ?? "app",
                    bundleID: bundleID)
            }
    }
}
