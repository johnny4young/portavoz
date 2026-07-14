#if os(macOS)
import CoreAudio
import Foundation

/// Finds the processes that are actually rendering OUTPUT audio right now.
///
/// This matters for the per-process system tap: a Chromium browser (Chrome,
/// Brave, Edge, Arc) renders audio in a separate HELPER process, not the
/// app-level process `NSWorkspace` reports — so tapping the app PID captures
/// nothing. Core Audio's process-object list exposes the real audio
/// producers, helpers included.
@available(macOS 14.4, *)
public enum AudioProcessCatalog {
    /// PIDs currently producing output audio whose bundle ID belongs to one
    /// of the explicitly allowed apps, excluding `excludedPID` (Portavoz).
    /// Helper processes are included by bundle-ID prefix (for example,
    /// `com.brave.Browser.helper` belongs to `com.brave.Browser`). This keeps
    /// a per-meeting-app tap from silently widening into music/notifications
    /// from unrelated apps. Empty on any Core Audio error.
    public static func outputProducingPIDs(
        excluding excludedPID: pid_t,
        matchingBundleIDs allowedBundleIDs: Set<String>
    ) -> [pid_t] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let system = AudioObjectID(kAudioObjectSystemObject)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0
        else { return [] }
        let count = Int(size) / MemoryLayout<AudioObjectID>.size
        var objects = [AudioObjectID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &objects) == noErr
        else { return [] }

        return objects.compactMap { object -> pid_t? in
            guard isRunningOutput(object) else { return nil }
            guard let candidateBundleID = processBundleID(object),
                bundleID(candidateBundleID, belongsToAnyOf: allowedBundleIDs)
            else { return nil }
            let pid = processPID(object)
            guard pid > 0, pid != excludedPID else { return nil }
            return pid
        }
    }

    /// Pure matcher kept internal for deterministic tests. A helper's bundle
    /// ID must be the exact app ID or a dot-delimited child — a merely similar
    /// prefix (`com.example.MeetingEvil`) is not accepted.
    static func bundleID(_ candidate: String, belongsToAnyOf allowed: Set<String>) -> Bool {
        let value = candidate.lowercased()
        return allowed.contains { bundleID in
            let root = bundleID.lowercased()
            return value == root || value.hasPrefix(root + ".")
        }
    }

    private static func isRunningOutput(_ object: AudioObjectID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyIsRunningOutput,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var running: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &running) == noErr
        else { return false }
        return running != 0
    }

    private static func processPID(_ object: AudioObjectID) -> pid_t {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyPID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var pid: pid_t = -1
        var size = UInt32(MemoryLayout<pid_t>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &pid) == noErr
        else { return -1 }
        return pid
    }

    private static func processBundleID(_ object: AudioObjectID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyBundleID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: CFString?
        var size = UInt32(MemoryLayout<CFString?>.size)
        let status = withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(object, &address, 0, nil, &size, pointer)
        }
        guard status == noErr, let value else { return nil }
        return value as String
    }
}
#endif
