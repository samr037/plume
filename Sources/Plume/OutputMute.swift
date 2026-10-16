import CoreAudio
import Foundation

/// Coupe la sortie audio par défaut pendant la dictée et restaure l'état d'origine (option, désactivée par défaut).
@MainActor
enum OutputMute {
    private static var mutedDevice: AudioObjectID?

    static func engage() {
        guard mutedDevice == nil, let dev = defaultOutput(), let muted = isMuted(dev), !muted else { return }
        if setMute(dev, true) { mutedDevice = dev }
    }

    static func release() {
        guard let dev = mutedDevice else { return }
        _ = setMute(dev, false)
        mutedDevice = nil
    }

    private static func defaultOutput() -> AudioObjectID? {
        var id = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id) == noErr else { return nil }
        return id
    }

    private static func muteAddress() -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyMute, mScope: kAudioDevicePropertyScopeOutput,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    private static func isMuted(_ dev: AudioObjectID) -> Bool? {
        var addr = muteAddress()
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectHasProperty(dev, &addr), AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &value) == noErr else { return nil }
        return value != 0
    }

    private static func setMute(_ dev: AudioObjectID, _ mute: Bool) -> Bool {
        var addr = muteAddress()
        var value: UInt32 = mute ? 1 : 0
        return AudioObjectSetPropertyData(dev, &addr, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value) == noErr
    }
}
