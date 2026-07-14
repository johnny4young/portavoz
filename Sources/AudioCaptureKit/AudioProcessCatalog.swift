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
    /// PIDs of processes currently producing output audio, excluding
    /// `excludedPID` (Portavoz itself). Empty on any Core Audio error.
    public static func outputProducingPIDs(excluding excludedPID: pid_t) -> [pid_t] {
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
            let pid = processPID(object)
            guard pid > 0, pid != excludedPID else { return nil }
            return pid
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
}
#endif
