import AppKit
import CoreAudio
import Foundation
import PonteCore

/// One client process reading one input device, with the app it belongs to.
/// From the HAL process objects: kAudioProcessPropertyDevices (input scope) and kAudioProcessPropertyIsRunningInput.
public struct AudioInputReader: Hashable, Sendable {
    public let pid: Int32
    /// The bundle ID the HAL reports for the process (helpers have their own).
    public let bundleID: String?
    /// The app the process belongs to (BrowserOS for its helpers), as for the process taps.
    public let ownerBundleID: String
    /// The known call app's label (AudioRules.knownCallAppLabels), else the app's name.
    public let appName: String
    public let device: AudioDevice
    /// AudioRules.kind* of the device.
    public let deviceKind: Int
    public let isRunningInput: Bool

    public init(pid: Int32, bundleID: String?, ownerBundleID: String, appName: String, device: AudioDevice,
                deviceKind: Int, isRunningInput: Bool) {
        self.pid = pid
        self.bundleID = bundleID
        self.ownerBundleID = ownerBundleID
        self.appName = appName
        self.device = device
        self.deviceKind = deviceKind
        self.isRunningInput = isRunningInput
    }
}

/// Who listens to BlackHole right now (the checklist «Перед звонком» and the call's red banner).
public struct ListenerCheck: Equatable, Sendable {
    /// AudioRules.listen*.
    public let status: Int
    /// The pair the status names (AudioRules.listenIndex): the call app's real microphone, the call app on
    /// BlackHole, or another program on BlackHole.
    public let reader: AudioInputReader?

    public init(status: Int, reader: AudioInputReader?) {
        self.status = status
        self.reader = reader
    }

    public static let unknown = ListenerCheck(status: AudioRules.listenUnknown, reader: nil)
}

/// OS glue for "which apps read which input devices". The decisions are in `AudioRules` (readerRole,
/// readerUse, listenStatus, listenIndex).
public enum AudioInputReaders {
    /// Every (process, input device) pair of the HAL client processes that read an input; nil when the process
    /// list cannot be read. Owners are resolved only for processes with input devices.
    public static func snapshot() -> [AudioInputReader]? {
        guard let objects = HAL.listedProcessObjectIDs() else { return nil }
        var regularApps: [NSRunningApplication]?
        var described: [AudioObjectID: (device: AudioDevice, kind: Int)] = [:]
        var readers: [AudioInputReader] = []
        for object in objects {
            let inputs = HAL.inputDevices(ofProcess: object)
            guard !inputs.isEmpty, let pid = HAL.pid(ofProcess: object), AudioRules.isProcessPID(pid) else { continue }
            let bundleID = HAL.bundleID(ofProcess: object)
            if regularApps == nil {
                regularApps = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
            }
            let owner = AudioProcesses.resolveOwner(pid: pid, halBundleID: bundleID, regularApps: regularApps ?? [])
            let label = AudioRules.knownCallAppIndex(bundleID: owner.bundleID)
            let appName = label >= 0 ? AudioRules.knownCallAppLabels[label] : owner.name
            let running = HAL.isRunningInput(object)
            for id in inputs {
                if described[id] == nil, let fresh = describe(id) { described[id] = fresh }
                guard let entry = described[id] else { continue }
                readers.append(AudioInputReader(pid: pid, bundleID: bundleID, ownerBundleID: owner.bundleID, appName: appName,
                                                device: entry.device, deviceKind: entry.kind, isRunningInput: running))
            }
        }
        return readers
    }

    /// The listener status for a source: `targetBundleID` is the chosen call app (nil: all Mac audio).
    /// `readers` nil: the process list could not be read.
    public static func check(_ readers: [AudioInputReader]?, targetBundleID: String?, blackHolePresent: Bool,
                             selfPID: Int32 = getpid()) -> ListenerCheck {
        let list = readers ?? []
        let uses = list.map { r in
            AudioRules.readerUse(role: AudioRules.readerRole(ownerBundleID: r.ownerBundleID, targetBundleID: targetBundleID,
                                                             pid: r.pid, selfPID: selfPID),
                                 kind: r.deviceKind, runningInput: r.isRunningInput)
        }
        let status = AudioRules.listenStatus(uses: uses, listed: readers != nil, blackHolePresent: blackHolePresent)
        let index = AudioRules.listenIndex(uses: uses)
        return ListenerCheck(status: status, reader: index >= 0 && index < list.count ? list[index] : nil)
    }

    /// Some process does input IO on the device (kAudioDevicePropertyDeviceIsRunningSomewhere). Ponte's own
    /// call output also opens BlackHole for input, so this flag alone cannot tell the call app from Ponte.
    public static func inputRunsSomewhere(_ device: AudioDevice) -> Bool {
        HAL.isRunningSomewhere(device.id, input: true)
    }

    private static func describe(_ id: AudioObjectID) -> (device: AudioDevice, kind: Int)? {
        guard let device = HAL.device(id) else { return nil }
        let kind = AudioRules.deviceKind(name: device.name, uid: device.uid, transportType: HAL.transportType(id),
                                         inputChannels: device.inputChannels, outputChannels: device.outputChannels)
        return (device, kind)
    }
}
