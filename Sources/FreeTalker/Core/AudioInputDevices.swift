import CoreAudio
import Foundation

enum AudioInputDevices {
    struct Device: Identifiable, Equatable {
        let id: AudioDeviceID
        let uid: String
        let name: String
    }

    /// Returns every currently connected device that exposes at least one input channel.
    /// Requires no permissions — this only reads device topology, not audio.
    static func enumerate() -> [Device] {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr, size > 0 else {
            return []
        }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr else {
            return []
        }

        return ids.compactMap { deviceID in
            guard inputChannelCount(deviceID) > 0 else { return nil }
            guard let uid = stringProperty(deviceID, selector: kAudioDevicePropertyDeviceUID) else { return nil }
            let name = stringProperty(deviceID, selector: kAudioObjectPropertyName) ?? uid
            return Device(id: deviceID, uid: uid, name: name)
        }
    }

    /// Resolves a persisted UID to its current AudioDeviceID. Returns nil if no connected
    /// input device has that UID (e.g. the configured mic was unplugged) so the caller can fall
    /// back to the system default input.
    static func resolveID(forUID uid: String) -> AudioDeviceID? {
        enumerate().first(where: { $0.uid == uid })?.id
    }

    private static func inputChannelCount(_ deviceID: AudioDeviceID) -> Int {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &addr, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let buf = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { buf.deallocate() }
        guard AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, buf) == noErr else { return 0 }
        let abl = buf.assumingMemoryBound(to: AudioBufferList.self)
        return UnsafeMutableAudioBufferListPointer(abl).reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private static func stringProperty(_ deviceID: AudioDeviceID, selector: AudioObjectPropertySelector) -> String? {
        var addr = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var value: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        let status = withUnsafeMutablePointer(to: &value) { ptr in
            AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, ptr)
        }
        guard status == noErr else { return nil }
        return value as String
    }
}
