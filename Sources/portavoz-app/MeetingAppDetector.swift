import AppKit
import AudioCaptureKit
import Foundation
import PortavozCore

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

    /// Dedicated native call apps (preferred over browsers when both are active).
    static let nativeCallBundleIDs: Set<String> = [
        "us.zoom.xos",  // Zoom
        "com.microsoft.teams", "com.microsoft.teams2",  // Teams (classic + new)
        "com.tinyspeck.slackmacgap",  // Slack huddles
        "com.hnc.Discord",  // Discord
        "com.cisco.webexmeetingsapp", "Cisco-Systems.Spark",  // Webex
        "com.apple.FaceTime"  // FaceTime
    ]

    /// Browsers that host web meetings (Google Meet, Whereby, Teams Web…).
    static let browserBundleIDs: Set<String> = [
        "com.google.Chrome", "com.apple.Safari", "company.thebrowser.Browser",
        "com.microsoft.edgemac", "com.brave.Browser", "org.mozilla.firefox"
    ]

    /// Bundle ids of native meeting apps and the browsers that host web
    /// meetings (Google Meet, Whereby, …). Tapping a browser captures all of
    /// its audio, which for a meeting is dominated by the call.
    static let bundleIDs: Set<String> = nativeCallBundleIDs.union(browserBundleIDs)

    private static let fallbackNamesByBundleID: [String: String] = [
        "us.zoom.xos": "Zoom",
        "com.microsoft.teams": "Microsoft Teams",
        "com.microsoft.teams2": "Microsoft Teams",
        "com.tinyspeck.slackmacgap": "Slack",
        "com.hnc.Discord": "Discord",
        "com.cisco.webexmeetingsapp": "Webex",
        "Cisco-Systems.Spark": "Webex",
        "com.apple.FaceTime": "FaceTime",
        "com.google.Chrome": "Google Chrome",
        "com.apple.Safari": "Safari",
        "company.thebrowser.Browser": "Arc",
        "com.microsoft.edgemac": "Microsoft Edge",
        "com.brave.Browser": "Brave",
        "org.mozilla.firefox": "Firefox"
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

    /// Passive Core Audio snapshot of meeting apps and browsers currently
    /// streaming audio, normalized to canonical parent app bundle IDs.
    static func activeCallSignals() -> [ActiveCallSignal] {
        let processes = AudioProcessCatalog.activeAudioProcesses(
            excluding: getpid(),
            matchingBundleIDs: bundleIDs)
        let runningNames = Dictionary(
            running().map { ($0.bundleID.lowercased(), $0.name) },
            uniquingKeysWith: { first, _ in first })
        return activeCallSignals(from: processes, runningNames: runningNames)
    }

    static func activeCallSignals(
        from processes: [ActiveAudioProcess],
        runningNames: [String: String]
    ) -> [ActiveCallSignal] {
        var byCanonical: [String: ActiveCallSignal] = [:]
        for process in processes {
            guard let canonical = canonicalBundleID(for: process.bundleID) else { continue }
            let appName = runningNames[canonical.lowercased()]
                ?? fallbackNamesByBundleID[canonical]
                ?? canonical
            let isNative = nativeCallBundleIDs.contains(canonical)
            if let existing = byCanonical[canonical] {
                byCanonical[canonical] = ActiveCallSignal(
                    bundleID: canonical,
                    appName: existing.appName,
                    isUsingMicrophone: existing.isUsingMicrophone || process.isRunningInput,
                    isPlayingAudio: existing.isPlayingAudio || process.isRunningOutput,
                    isNativeCallApp: isNative)
            } else {
                byCanonical[canonical] = ActiveCallSignal(
                    bundleID: canonical,
                    appName: appName,
                    isUsingMicrophone: process.isRunningInput,
                    isPlayingAudio: process.isRunningOutput,
                    isNativeCallApp: isNative)
            }
        }
        return byCanonical.values.sorted { lhs, rhs in
            if lhs.isNativeCallApp != rhs.isNativeCallApp {
                return lhs.isNativeCallApp
            }
            return lhs.appName < rhs.appName
        }
    }

    static func canonicalBundleID(for processBundleID: String) -> String? {
        let lowered = processBundleID.lowercased()
        return bundleIDs.first { candidate in
            let root = candidate.lowercased()
            return lowered == root || lowered.hasPrefix(root + ".")
        }
    }
}
