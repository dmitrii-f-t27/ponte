import CoreAudio
import Foundation
import PonteCore

/// Thin, typed wrappers over the Core Audio HAL property API (AudioObjectGetPropertyData & co).
/// Everything here is synchronous and safe to call from any non-real-time thread.
enum HAL {
    static let system = AudioObjectID(kAudioObjectSystemObject)

    static func address(_ selector: AudioObjectPropertySelector,
                        _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                        _ element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }

    static func has(_ object: AudioObjectID, _ addr: AudioObjectPropertyAddress) -> Bool {
        var a = addr
        return AudioObjectHasProperty(object, &a)
    }

    /// Reads a fixed-size scalar/struct property.
    static func get<T>(_ object: AudioObjectID, _ addr: AudioObjectPropertyAddress, default value: T) throws -> T {
        var a = addr
        var result = value
        var size = UInt32(MemoryLayout<T>.size)
        let status = withUnsafeMutablePointer(to: &result) { ptr in
            AudioObjectGetPropertyData(object, &a, 0, nil, &size, ptr)
        }
        try check(status, "get '\(fourCC(addr.mSelector))' on \(object)")
        return result
    }

    /// Reads a fixed-size property using a qualifier (e.g. PID → process object translation).
    static func get<T, Q>(_ object: AudioObjectID, _ addr: AudioObjectPropertyAddress, qualifier: Q, default value: T) throws -> T {
        var a = addr
        var q = qualifier
        var result = value
        var size = UInt32(MemoryLayout<T>.size)
        let status = withUnsafeMutablePointer(to: &q) { qp in
            withUnsafeMutablePointer(to: &result) { rp in
                AudioObjectGetPropertyData(object, &a, UInt32(MemoryLayout<Q>.size), qp, &size, rp)
            }
        }
        try check(status, "get '\(fourCC(addr.mSelector))' on \(object)")
        return result
    }

    /// Reads a variable-length array property such as a list of AudioObjectIDs.
    static func array<T>(_ object: AudioObjectID, _ addr: AudioObjectPropertyAddress, of _: T.Type) throws -> [T] {
        var a = addr
        var size: UInt32 = 0
        try check(AudioObjectGetPropertyDataSize(object, &a, 0, nil, &size), "size '\(fourCC(addr.mSelector))'")
        let count = Int(size) / MemoryLayout<T>.stride
        guard count > 0 else { return [] }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<T>.alignment)
        defer { raw.deallocate() }
        try check(AudioObjectGetPropertyData(object, &a, 0, nil, &size, raw), "get '\(fourCC(addr.mSelector))'")
        let typed = raw.bindMemory(to: T.self, capacity: count)
        return Array(UnsafeBufferPointer(start: typed, count: Int(size) / MemoryLayout<T>.stride))
    }

    /// Reads a CFString property (name, UID, bundle ID). Returns nil when absent or empty.
    static func string(_ object: AudioObjectID, _ addr: AudioObjectPropertyAddress) -> String? {
        guard has(object, addr) else { return nil }
        var a = addr
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var value: Unmanaged<CFString>?
        let status = withUnsafeMutablePointer(to: &value) { ptr in
            AudioObjectGetPropertyData(object, &a, 0, nil, &size, ptr)
        }
        guard status == noErr, let cf = value?.takeRetainedValue() else { return nil }
        let s = cf as String
        return s.isEmpty ? nil : s
    }

    static func set<T>(_ object: AudioObjectID, _ addr: AudioObjectPropertyAddress, _ value: T) throws {
        var a = addr
        var v = value
        let status = withUnsafeMutablePointer(to: &v) { ptr in
            AudioObjectSetPropertyData(object, &a, 0, nil, UInt32(MemoryLayout<T>.size), ptr)
        }
        try check(status, "set '\(fourCC(addr.mSelector))' on \(object)")
    }

    // MARK: Devices

    static func deviceIDs() -> [AudioObjectID] {
        (try? array(system, address(kAudioHardwarePropertyDevices), of: AudioObjectID.self)) ?? []
    }

    static func defaultDevice(input: Bool) -> AudioObjectID? {
        let sel = input ? kAudioHardwarePropertyDefaultInputDevice : kAudioHardwarePropertyDefaultOutputDevice
        guard let id = try? get(system, address(sel), default: AudioObjectID(kAudioObjectUnknown)),
              id != kAudioObjectUnknown else { return nil }
        return id
    }

    /// Total channel count of all streams in one direction, from kAudioDevicePropertyStreamConfiguration.
    static func channelCount(_ device: AudioObjectID, input: Bool) -> Int {
        let addr = address(kAudioDevicePropertyStreamConfiguration,
                           input ? kAudioObjectPropertyScopeInput : kAudioObjectPropertyScopeOutput)
        var a = addr
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &a, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(device, &a, 0, nil, &size, raw) == noErr else { return 0 }
        let abl = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return abl.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    /// kAudioDevicePropertyTransportType as a plain four-char code (0 = unknown).
    static func transportType(_ device: AudioObjectID) -> UInt32 {
        (try? get(device, address(kAudioDevicePropertyTransportType), default: UInt32(0))) ?? 0
    }

    static func nominalSampleRate(_ device: AudioObjectID) -> Double? {
        guard let rate = try? get(device, address(kAudioDevicePropertyNominalSampleRate), default: Float64(0)),
              rate > 0 else { return nil }
        return rate
    }

    static func device(_ id: AudioObjectID) -> AudioDevice? {
        guard let uid = string(id, address(kAudioDevicePropertyDeviceUID)) else { return nil }
        let name = string(id, address(kAudioObjectPropertyName)) ?? uid
        return AudioDevice(id: id, uid: uid, name: name,
                               inputChannels: channelCount(id, input: true),
                               outputChannels: channelCount(id, input: false))
    }

    // MARK: Processes

    static func processObjectIDs() -> [AudioObjectID] {
        listedProcessObjectIDs() ?? []
    }

    /// The HAL client processes; nil when the list cannot be read.
    static func listedProcessObjectIDs() -> [AudioObjectID]? {
        try? array(system, address(kAudioHardwarePropertyProcessObjectList), of: AudioObjectID.self)
    }

    static func processObject(for pid: pid_t) -> AudioObjectID? {
        guard let id = try? get(system, address(kAudioHardwarePropertyTranslatePIDToProcessObject),
                                qualifier: pid, default: AudioObjectID(kAudioObjectUnknown)),
              id != kAudioObjectUnknown else { return nil }
        return id
    }

    static func pid(ofProcess object: AudioObjectID) -> pid_t? {
        try? get(object, address(kAudioProcessPropertyPID), default: pid_t(-1))
    }

    static func bundleID(ofProcess object: AudioObjectID) -> String? {
        string(object, address(kAudioProcessPropertyBundleID))
    }

    static func isRunningOutput(_ object: AudioObjectID) -> Bool {
        ((try? get(object, address(kAudioProcessPropertyIsRunningOutput), default: UInt32(0))) ?? 0) != 0
    }

    static func isRunningInput(_ object: AudioObjectID) -> Bool {
        ((try? get(object, address(kAudioProcessPropertyIsRunningInput), default: UInt32(0))) ?? 0) != 0
    }

    /// Devices a client process uses for input (kAudioProcessPropertyDevices, input scope). The global scope
    /// lists nothing on macOS 26/27 (checked 2026-10-13); the input and output scopes are filled.
    static func inputDevices(ofProcess object: AudioObjectID) -> [AudioObjectID] {
        (try? array(object, address(kAudioProcessPropertyDevices, kAudioObjectPropertyScopeInput), of: AudioObjectID.self)) ?? []
    }

    /// kAudioDevicePropertyDeviceIsRunningSomewhere in one direction: some process does IO on the device.
    static func isRunningSomewhere(_ device: AudioObjectID, input: Bool) -> Bool {
        let scope = input ? kAudioObjectPropertyScopeInput : kAudioObjectPropertyScopeOutput
        return ((try? get(device, address(kAudioDevicePropertyDeviceIsRunningSomewhere, scope), default: UInt32(0))) ?? 0) != 0
    }

    // MARK: Errors

    static func check(_ status: OSStatus, _ what: @autoclosure () -> String) throws {
        guard status == noErr else { throw PonteAudioError.coreAudio(status: status, what: what()) }
    }

    static func fourCC(_ value: UInt32) -> String {
        guard AudioRules.isPrintableFourCC(value) else { return String(value) }
        let bytes = [24, 16, 8, 0].map { UInt8((value >> UInt32($0)) & 0xFF) }
        return String(decoding: bytes, as: UTF8.self)
    }
}
