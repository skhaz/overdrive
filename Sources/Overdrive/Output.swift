import CoreAudio
import Foundation

final class Output {
    private var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    private let listener: AudioObjectPropertyListenerBlock

    init() {
        listener = { _, _ in Output.report("changed") }
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, listener)
        Output.report("start")
    }

    isolated deinit {
        AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, listener)
    }

    nonisolated static func device() -> (id: AudioDeviceID, name: String) {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id) == noErr else { return (0, "") }

        address.mSelector = kAudioObjectPropertyName
        var name: Unmanaged<CFString>?
        size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &name) == noErr, let name else { return (id, "") }

        return (id, name.takeRetainedValue() as String)
    }

    nonisolated private static func report(_ event: String) {
        let device = device()
        Log.player.info("output device", metadata: ["event": "\(event)", "id": "\(device.id)", "name": "\(device.name)"])
    }
}
