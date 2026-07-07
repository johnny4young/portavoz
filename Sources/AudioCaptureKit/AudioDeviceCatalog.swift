#if os(macOS)
import AudioToolbox
import CoreAudio
import Foundation

/// An input device (microphone) available on this machine.
public struct AudioInputDevice: Sendable, Identifiable {
    public let id: AudioObjectID
    public let uid: String
    public let name: String
}

/// Enumerates audio input devices via Core Audio.
public enum AudioDeviceCatalog {
    public static func inputDevices() throws -> [AudioInputDevice] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let systemObject = AudioObjectID(kAudioObjectSystemObject)

        var size: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(systemObject, &address, 0, nil, &size)
        guard status == noErr else {
            throw AudioCaptureError.coreAudioError(operation: "kAudioHardwarePropertyDevices size", status: status)
        }

        let count = Int(size) / MemoryLayout<AudioObjectID>.size
        var deviceIDs = [AudioObjectID](repeating: AudioObjectID(kAudioObjectUnknown), count: count)
        status = AudioObjectGetPropertyData(systemObject, &address, 0, nil, &size, &deviceIDs)
        guard status == noErr else {
            throw AudioCaptureError.coreAudioError(operation: "kAudioHardwarePropertyDevices", status: status)
        }

        return deviceIDs.compactMap { deviceID in
            guard inputChannelCount(deviceID) > 0 else { return nil }
            guard
                let name = stringProperty(deviceID, kAudioObjectPropertyName),
                let uid = stringProperty(deviceID, kAudioDevicePropertyDeviceUID)
            else { return nil }
            return AudioInputDevice(id: deviceID, uid: uid, name: name)
        }
    }

    /// Finds a device whose UID or (case-insensitive) name matches `identifier`.
    public static func inputDevice(matching identifier: String) throws -> AudioInputDevice? {
        try inputDevices().first {
            $0.uid == identifier || $0.name.compare(identifier, options: .caseInsensitive) == .orderedSame
        }
    }

    private static func inputChannelCount(_ deviceID: AudioObjectID) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size) == noErr, size > 0 else {
            return 0
        }
        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, raw) == noErr else { return 0 }
        let buffers = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return buffers.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private static func stringProperty(
        _ objectID: AudioObjectID,
        _ selector: AudioObjectPropertySelector
    ) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: CFString?
        var size = UInt32(MemoryLayout<CFString?>.size)
        let status = withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, pointer)
        }
        guard status == noErr, let value else { return nil }
        return value as String
    }
}
#endif
