import CoreAudio
import Foundation
import PonteCore

/// Lists the HAL audio devices. Each call reads the live state (devices come and go).
/// Decisions (kind, echo risk, default picks, name matching) live in `AudioRules`.
public final class CoreAudioDeviceCatalog: AudioDeviceCatalog {
    public init() {}

    public func devices() -> [AudioDevice] {
        HAL.deviceIDs()
            .compactMap { HAL.device($0) }
            .filter { !AudioRules.isPonteAggregate(uid: $0.uid) }
    }

    public func defaultInput() -> AudioDevice? {
        HAL.defaultDevice(input: true).flatMap { HAL.device($0) }
    }

    public func defaultOutput() -> AudioDevice? {
        HAL.defaultDevice(input: false).flatMap { HAL.device($0) }
    }

    /// Input-capable devices (microphones, BlackHole as an input).
    public func inputDevices() -> [AudioDevice] { devices().filter { AudioRules.isInput(channels: $0.inputChannels) } }

    /// Output-capable devices (speakers, headphones, BlackHole as the call's mic).
    public func outputDevices() -> [AudioDevice] { devices().filter { AudioRules.isOutput(channels: $0.outputChannels) } }

    /// Finds a device by UID first, then by exact name, then by case-insensitive name substring.
    public func device(matching query: String) -> AudioDevice? {
        let all = devices()
        let i = AudioRules.matchDeviceIndex(query: query, names: all.map(\.name), uids: all.map(\.uid))
        return i >= 0 ? all[i] : nil
    }

    public func device(uid: String) -> AudioDevice? { devices().first { $0.uid == uid } }

    /// Nominal sample rate of a device, if the HAL reports one.
    public func sampleRate(of device: AudioDevice) -> Double? { HAL.nominalSampleRate(device.id) }

    /// `AudioRules.kind*` code (built-in speaker, headphones, BlackHole, Bluetooth, USB, …).
    public func kind(of device: AudioDevice) -> Int {
        AudioRules.deviceKind(name: device.name, uid: device.uid, transportType: HAL.transportType(device.id),
                              inputChannels: device.inputChannels, outputChannels: device.outputChannels)
    }

    /// `AudioRules.echo*` code: `echoSpeaker` means "ask the owner to use headphones".
    public func echoRisk(of device: AudioDevice) -> Int { AudioRules.echoRisk(kind: kind(of: device)) }

    /// Suggested "my microphone" (never BlackHole or Ponte's tap).
    public func suggestedMic() -> AudioDevice? {
        let all = devices()
        let def = defaultInput().flatMap { d in all.firstIndex { $0.id == d.id } } ?? -1
        let i = AudioRules.pickMicIndex(kinds: all.map(kind(of:)), inputChannels: all.map(\.inputChannels), defaultIndex: def)
        return i >= 0 ? all[i] : nil
    }

    /// Ponte's microphone for «Автоматически» (AudioRules.pickAutoMicIndex): the headset's microphone when
    /// `listening` (the output the owner hears) is a headset, else the built-in microphone.
    public func autoMic(in all: [AudioDevice], listening: AudioDevice?) -> AudioDevice? {
        let output = listening.flatMap { l in all.firstIndex { $0.id == l.id } } ?? -1
        let i = AudioRules.pickAutoMicIndex(names: all.map(\.name), kinds: all.map(kind(of:)),
                                            inputChannels: all.map(\.inputChannels), outputIndex: output)
        return i >= 0 ? all[i] : nil
    }

    /// macOS lets the output become the system output: not hidden (AirPods playing to another device are listed
    /// hidden) and allowed as a default device (AudioRules.isSelectableOutput).
    public func isSelectableOutput(_ device: AudioDevice) -> Bool {
        let hidden = (try? HAL.get(device.id, HAL.address(kAudioDevicePropertyIsHidden), default: UInt32(0))) ?? 0
        let canDefault = (try? HAL.get(device.id, HAL.address(kAudioDevicePropertyDeviceCanBeDefaultDevice,
                                                              kAudioObjectPropertyScopeOutput), default: UInt32(0))) ?? 0
        return AudioRules.isSelectableOutput(hidden: hidden != 0, canBeDefault: canDefault != 0)
    }

    /// The owner's ears when the system output is the call's virtual mic or Ponte's tap (AudioRules.pickRescueOutputIndex).
    public func rescueOutput() -> AudioDevice? {
        let all = devices()
        let i = AudioRules.pickRescueOutputIndex(kinds: all.map(kind(of:)), outputChannels: all.map(\.outputChannels),
                                                 selectable: all.map(isSelectableOutput))
        return i >= 0 ? all[i] : nil
    }

    /// Calls `handler` on the main queue whenever the Mac's system output changes. Keep the returned token;
    /// pass it to `stopObserving` to stop.
    public func observeDefaultOutput(_ handler: @escaping () -> Void) -> AnyObject? {
        var addr = HAL.address(kAudioHardwarePropertyDefaultOutputDevice)
        let block: AudioObjectPropertyListenerBlock = { _, _ in handler() }
        guard AudioObjectAddPropertyListenerBlock(HAL.system, &addr, DispatchQueue.main, block) == noErr else { return nil }
        return block as AnyObject
    }

    public func stopObserving(_ token: AnyObject) {
        guard let block = token as? AudioObjectPropertyListenerBlock else { return }
        var addr = HAL.address(kAudioHardwarePropertyDefaultOutputDevice)
        AudioObjectRemovePropertyListenerBlock(HAL.system, &addr, DispatchQueue.main, block)
    }

    /// Makes the device the Mac's system output, as the Sound menu does: Ponte's Russian voice and the call app follow it.
    public func setDefaultOutput(_ device: AudioDevice) throws {
        try HAL.set(HAL.system, HAL.address(kAudioHardwarePropertyDefaultOutputDevice), AudioObjectID(device.id))
    }

    /// Suggested output for the Russian voice in the owner's ears (never BlackHole).
    public func suggestedListenOutput() -> AudioDevice? {
        let all = devices()
        let def = defaultOutput().flatMap { d in all.firstIndex { $0.id == d.id } } ?? -1
        let i = AudioRules.pickListenOutputIndex(kinds: all.map(kind(of:)), outputChannels: all.map(\.outputChannels),
                                                 defaultIndex: def)
        return i >= 0 ? all[i] : nil
    }
}
