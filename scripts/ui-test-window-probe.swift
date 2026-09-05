#!/usr/bin/env swift

import CoreGraphics
import Carbon.HIToolbox
import Darwin
import Foundation

private struct BlockingWindowCounts: Encodable {
    let notificationCenter: Int
    let securityAgent: Int
    let secureInput: Bool
}

private func failClosed(_ message: String) -> Never {
    FileHandle.standardError.write(Data("\(message)\n".utf8))
    exit(EXIT_FAILURE)
}

private let rawWindows = CGWindowListCopyWindowInfo(
    [.optionOnScreenOnly, .excludeDesktopElements],
    kCGNullWindowID
)
guard let windows = rawWindows as? [[String: Any]] else {
    failClosed("blocking-window inventory unavailable")
}

private var notificationCenterCount = 0
private var securityAgentCount = 0

for window in windows {
    guard let owner = window[kCGWindowOwnerName as String] as? String else {
        continue
    }

    switch owner {
    case "Notification Center", "UserNotificationCenter":
        guard let layer = window[kCGWindowLayer as String] as? Int else {
            failClosed("blocking-window layer unavailable")
        }
        if layer >= 0 {
            notificationCenterCount += 1
        }
    case "SecurityAgent":
        guard let layer = window[kCGWindowLayer as String] as? Int else {
            failClosed("blocking-window layer unavailable")
        }
        if layer >= 0 {
            securityAgentCount += 1
        }
    default:
        continue
    }
}

private let result = BlockingWindowCounts(
    notificationCenter: notificationCenterCount,
    securityAgent: securityAgentCount,
    secureInput: IsSecureEventInputEnabled()
)
private let data = try JSONEncoder().encode(result)
FileHandle.standardOutput.write(data)
FileHandle.standardOutput.write(Data("\n".utf8))
