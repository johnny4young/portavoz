import Foundation

/// A passive audio-activity observation for one known meeting app or browser.
public struct ActiveCallSignal: Equatable, Sendable {
    public let bundleID: String
    public let appName: String
    public let isUsingMicrophone: Bool
    public let isPlayingAudio: Bool
    public let isNativeCallApp: Bool

    public init(
        bundleID: String,
        appName: String,
        isUsingMicrophone: Bool,
        isPlayingAudio: Bool,
        isNativeCallApp: Bool
    ) {
        self.bundleID = bundleID
        self.appName = appName
        self.isUsingMicrophone = isUsingMicrophone
        self.isPlayingAudio = isPlayingAudio
        self.isNativeCallApp = isNativeCallApp
    }
}

/// A confirmed active call eligible for a one-click "Record call?" nudge.
public struct ActiveCallNudge: Equatable, Sendable {
    public let bundleID: String
    public let appName: String
    public let detectedAt: Date

    public init(bundleID: String, appName: String, detectedAt: Date) {
        self.bundleID = bundleID
        self.appName = appName
        self.detectedAt = detectedAt
    }
}

/// Pure passive active-call detector. Only apps actively streaming microphone
/// input qualify — output-only media (YouTube, music, notification chimes)
/// never triggers a nudge. Requires sustained input to filter transient probes
/// and suppresses repeat nudges until the call ends or the cooldown expires.
public struct ActiveCallDetector: Equatable, Sendable {
    public static let defaultConfirmationDuration: TimeInterval = 4
    public static let defaultClearAfterQuiet: TimeInterval = 6
    public static let defaultQuietResetDuration: TimeInterval = 30
    public static let defaultSuppressionCooldown: TimeInterval = 30 * 60

    public let confirmationDuration: TimeInterval
    public let clearAfterQuiet: TimeInterval
    public let quietResetDuration: TimeInterval
    public let suppressionCooldown: TimeInterval

    public private(set) var activeNudge: ActiveCallNudge?

    private struct Candidate: Equatable, Sendable {
        let bundleID: String
        let appName: String
        let firstSeenAt: Date
    }

    private var candidate: Candidate?
    private var lastActiveAtByBundle: [String: Date] = [:]
    private var suppressedUntilByBundle: [String: Date] = [:]

    public init(
        confirmationDuration: TimeInterval = defaultConfirmationDuration,
        clearAfterQuiet: TimeInterval = defaultClearAfterQuiet,
        quietResetDuration: TimeInterval = defaultQuietResetDuration,
        suppressionCooldown: TimeInterval = defaultSuppressionCooldown
    ) {
        self.confirmationDuration = max(0, confirmationDuration)
        self.clearAfterQuiet = max(0, clearAfterQuiet)
        self.quietResetDuration = max(0, quietResetDuration)
        self.suppressionCooldown = max(0, suppressionCooldown)
    }

    /// Evaluates the latest active-audio snapshot and returns the currently
    /// visible nudge, if any.
    @discardableResult
    public mutating func observe(
        signals: [ActiveCallSignal],
        isRecording: Bool,
        at now: Date
    ) -> ActiveCallNudge? {
        let liveCalls = signals.filter(\.isUsingMicrophone)
        let activeBundles = Set(liveCalls.map(\.bundleID))
        for bundleID in activeBundles {
            lastActiveAtByBundle[bundleID] = now
        }
        clearExpiredSuppressions(activeBundles: activeBundles, at: now)

        if isRecording {
            activeNudge = nil
            candidate = nil
            for bundleID in activeBundles {
                suppressedUntilByBundle[bundleID] = now.addingTimeInterval(suppressionCooldown)
            }
            return nil
        }

        if let current = activeNudge {
            if !activeBundles.contains(current.bundleID),
               let lastSeen = lastActiveAtByBundle[current.bundleID],
               now.timeIntervalSince(lastSeen) >= clearAfterQuiet {
                activeNudge = nil
            }
            return activeNudge
        }

        guard let primary = selectPrimaryCall(from: liveCalls) else {
            candidate = nil
            return nil
        }

        if let prior = candidate, prior.bundleID == primary.bundleID {
            if now.timeIntervalSince(prior.firstSeenAt) >= confirmationDuration {
                let nudge = ActiveCallNudge(
                    bundleID: primary.bundleID,
                    appName: primary.appName,
                    detectedAt: now)
                activeNudge = nudge
                candidate = nil
                suppressedUntilByBundle[primary.bundleID] = now.addingTimeInterval(suppressionCooldown)
                return nudge
            }
            return nil
        }

        candidate = Candidate(
            bundleID: primary.bundleID,
            appName: primary.appName,
            firstSeenAt: now)
        if confirmationDuration == 0 {
            let nudge = ActiveCallNudge(
                bundleID: primary.bundleID,
                appName: primary.appName,
                detectedAt: now)
            activeNudge = nudge
            candidate = nil
            suppressedUntilByBundle[primary.bundleID] = now.addingTimeInterval(suppressionCooldown)
            return nudge
        }
        return nil
    }

    /// User dismissed the banner; silence this app until the call genuinely ends
    /// or the cooldown expires.
    public mutating func dismiss(at now: Date) {
        if let current = activeNudge {
            suppressedUntilByBundle[current.bundleID] = now.addingTimeInterval(suppressionCooldown)
            lastActiveAtByBundle[current.bundleID] = now
        }
        activeNudge = nil
        candidate = nil
    }

    /// User accepted the nudge and started recording.
    public mutating func recordAccepted(at now: Date) {
        dismiss(at: now)
    }

    private mutating func clearExpiredSuppressions(activeBundles: Set<String>, at now: Date) {
        for (bundleID, until) in suppressedUntilByBundle {
            let cooldownExpired = now >= until
            let callEndedLongAgo = !activeBundles.contains(bundleID)
                && lastActiveAtByBundle[bundleID].map {
                    now.timeIntervalSince($0) >= quietResetDuration
                } == true
            if cooldownExpired || callEndedLongAgo {
                suppressedUntilByBundle.removeValue(forKey: bundleID)
            }
        }
    }

    private func selectPrimaryCall(from liveCalls: [ActiveCallSignal]) -> ActiveCallSignal? {
        let eligible = liveCalls.filter { suppressedUntilByBundle[$0.bundleID] == nil }
        return eligible.first(where: \.isNativeCallApp) ?? eligible.first
    }
}
