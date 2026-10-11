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
    public func inputDevices() -> [AudioDevice] { devices().filter { $0.inputChannels > 0 } }

    /// Output-capable devices (speakers, headphones, BlackHole as the call's mic).
    public func outputDevices() -> [AudioDevice] { devices().filter { $0.outputChannels > 0 } }

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

    /// Suggested output for the Russian voice in the owner's ears (never BlackHole).
    public func suggestedListenOutput() -> AudioDevice? {
        let all = devices()
        let def = defaultOutput().flatMap { d in all.firstIndex { $0.id == d.id } } ?? -1
        let i = AudioRules.pickListenOutputIndex(kinds: all.map(kind(of:)), outputChannels: all.map(\.outputChannels),
                                                 defaultIndex: def)
        return i >= 0 ? all[i] : nil
    }
}
