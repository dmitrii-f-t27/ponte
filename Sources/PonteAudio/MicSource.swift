import AudioToolbox
import AVFoundation
import CoreAudio
import Foundation
import PonteCore
import Synchronization

/// Captures one input device (nil = system default input) and delivers mono Float32 at the device's
/// native rate. The host app needs the Microphone permission (`NSMicrophoneUsageDescription`); without
/// it macOS delivers silence or refuses to start.
///
/// The capture is an input-only audio unit (AUHAL: input enabled, output disabled) on the device, so it
/// has nothing on the output side. AVAudioEngine always owns an output node on the default output device,
/// and changing the output volume or another engine starting output stopped it (live 2026-10-13: the
/// 0.4 s rebuild cut half a sentence). The unit listens to its input device only: the device going away,
/// its rate or channels changing, the default input moving (when the source follows the default), the
/// unit stopping, a failed render. AudioRules.micInputRebuilds decides; a rebuild runs later on a private
/// queue, never inside the notification, with the wait and backoff of AudioRules (audio_rules.t27).
/// Buffers arrive once per device I/O cycle, on a private delivery queue, in order.
public final class MicSource: AudioSource {
    public enum Status: Equatable, Sendable {
        case idle
        case capturing
        /// Rebuilding after a device change; `failures` rebuilds in a row have failed so far.
        case restarting(failures: Int)
        /// AudioRules.restartFailed: still retrying, but the app should say the microphone is down.
        case failed(String)
    }

    public let device: AudioDevice?

    /// Mono Float32 at the device's native rate. Predicted from the HAL before `start`, exact after.
    public private(set) var outputFormat: AVAudioFormat

    /// The most frames one callback takes (the input unit's slice), unless the device's I/O cycle is longer
    /// (AudioRules.micMaxFrames). Callbacks themselves follow the device's I/O cycle.
    public var bufferFrames = AVAudioFrameCount(AudioRules.micTapBufferFrames)

    /// Called on a private queue whenever `status` changes.
    public var onStatusChange: ((Status) -> Void)?

    public var status: Status { lock.withLock { _status } }

    private let lock = NSLock()
    private let restartQueue = DispatchQueue(label: "app.ponte.mic.restart")
    private let delivery = DispatchQueue(label: "app.ponte.mic.delivery", qos: .userInteractive)
    private var capture: InputCapture?
    private var handler: PCMHandler?
    /// True between `start` and `stop`: only then does a device change lead to a rebuild.
    private var running = false
    private var restartWork: DispatchWorkItem?
    private var failures: Int64 = 0
    private var _status: Status = .idle

    public init(device: AudioDevice?) {
        self.device = device
        let id = device?.id ?? HAL.defaultDevice(input: true)
        let rate = AudioRules.rateOrDefault(id.flatMap { HAL.nominalSampleRate($0) } ?? 0)
        self.outputFormat = PCM.monoFormat(sampleRate: rate)
    }

    deinit { stop() }

    // MARK: Permission

    /// Microphone permission of this process. A tool started from a terminal is attributed to the
    /// terminal app (its "responsible" app), so that app is the one that needs the permission.
    public static var permission: AVAuthorizationStatus {
        AVCaptureDevice.authorizationStatus(for: .audio)
    }

    /// Shows the macOS microphone prompt if the user has not decided yet. Returns true if granted.
    public static func requestPermission() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }

    /// `start` refuses to run without permission: with an undecided permission the system blocks until the
    /// user answers the prompt, and with a denied one it records silence. Call `requestPermission()` first.
    public func start(handler: @escaping PCMHandler) throws {
        switch AudioRules.micStartDecision(authorizationStatus: Self.permission.rawValue) {
        case AudioRules.micStart: break
        case AudioRules.micRequestFirst: throw PonteAudioError.permissionRequired(.microphone)
        default: throw PonteAudioError.permissionDenied(.microphone)
        }
        lock.lock()
        guard !running else {
            lock.unlock()
            throw PonteAudioError.alreadyRunning
        }
        self.handler = handler
        do {
            try startCapture()
        } catch {
            self.handler = nil
            lock.unlock()
            PonteDiagnostics.log("mic start FAILED: \(error.localizedDescription)")
            throw error
        }
        running = true
        failures = 0
        PonteDiagnostics.log("mic start ok device=\(capture?.deviceName ?? "?") format=\(PCM.describe(outputFormat)) input unit")
        let changed = setStatus(.capturing)
        lock.unlock()
        notify(changed)
    }

    public func stop() {
        lock.lock()
        running = false
        restartWork?.cancel()
        restartWork = nil
        stopCapture()
        handler = nil
        failures = 0
        let changed = setStatus(.idle)
        lock.unlock()
        notify(changed)
    }

    // MARK: Device changes

    /// On `restartQueue`: an input-side event of `changed`. AudioRules.micInputRebuilds decides from the facts
    /// read now; a rebuild tears the capture down now and starts it again later.
    private func inputEvent(_ event: Int, of changed: InputCapture) {
        lock.lock()
        guard running, capture === changed else {
            lock.unlock()
            return
        }
        let facts = changed.facts()
        guard AudioRules.micInputRebuilds(event: event, followsDefault: device == nil, sameDevice: facts.sameDevice,
                                          deviceAlive: facts.alive, sameFormat: facts.sameFormat, unitRunning: facts.unitRunning) else {
            lock.unlock()
            PonteDiagnostics.log("mic input event \(event) ignored: capture unchanged")
            return
        }
        stopCapture()
        failures = AudioRules.micFailuresAfter(event: event, delivered: changed.delivered, failures: failures)
        PonteDiagnostics.log("mic input event \(event): alive=\(facts.alive) sameFormat=\(facts.sameFormat) sameDevice=\(facts.sameDevice) running=\(facts.unitRunning) render=\(changed.failedRenderStatus) failures=\(failures), rebuild scheduled")
        let changedStatus = AudioRules.restartFailed(failures: failures)
            ? setStatus(.failed("render \(changed.failedRenderStatus)")) : setStatus(.restarting(failures: Int(failures)))
        scheduleRestart()
        lock.unlock()
        notify(changedStatus)
    }

    /// Lock held. The next rebuild after AudioRules.restartDelayMs for the current failure count.
    private func scheduleRestart() {
        restartWork?.cancel()
        let delay = AudioRules.restartDelayMs(attempt: failures)
        let work = DispatchWorkItem { [weak self] in self?.attemptRestart() }
        restartWork = work
        restartQueue.asyncAfter(deadline: .now() + .milliseconds(Int(delay)), execute: work)
    }

    private func attemptRestart() {
        lock.lock()
        guard running, capture == nil else {
            lock.unlock()
            return
        }
        restartWork = nil
        let changed: Status?
        do {
            try startCapture()
            // The count starts again at the next change once audio flows (AudioRules.micFailuresAfter).
            PonteDiagnostics.log("mic rebuild ok after \(failures) failure(s) device=\(capture?.deviceName ?? "?") format=\(PCM.describe(outputFormat))")
            changed = setStatus(.capturing)
        } catch {
            failures += 1
            PonteDiagnostics.log("mic rebuild \(failures) FAILED: \(error.localizedDescription)")
            if AudioRules.restartFailed(failures: failures) {
                changed = setStatus(.failed(error.localizedDescription))
            } else {
                changed = setStatus(.restarting(failures: Int(failures)))
            }
            scheduleRestart()
        }
        lock.unlock()
        notify(changed)
    }

    // MARK: Capture (lock held)

    /// Re-resolves the device by UID (device IDs can change after a reconnect); nil device = default input.
    private func resolvedDeviceID() throws -> AudioObjectID {
        if let device {
            if let live = CoreAudioDeviceCatalog().device(uid: device.uid) { return live.id }
            throw PonteAudioError.deviceNotFound(device.name)
        }
        guard let id = HAL.defaultDevice(input: true) else { throw PonteAudioError.deviceNotFound("default input") }
        return id
    }

    private func startCapture() throws {
        guard let handler else { throw PonteAudioError.engine("no handler") }
        let id = try resolvedDeviceID()
        let capture = try InputCapture(deviceID: id, followsDefault: device == nil, sliceHint: Int(bufferFrames),
                                       delivery: delivery, handler: handler)
        capture.onEvent = { [weak self, weak capture] event in
            guard let self, let capture else { return }
            // Never rebuild on the notifying thread; hop to our queue first.
            self.restartQueue.async { self.inputEvent(event, of: capture) }
        }
        do {
            try capture.start()
        } catch {
            capture.stop()
            throw error
        }
        outputFormat = capture.monoFormat
        self.capture = capture
    }

    private func stopCapture() {
        capture?.stop()
        capture = nil
    }

    /// Lock held. Returns the new status when it changed, for `notify` after unlocking.
    private func setStatus(_ new: Status) -> Status? {
        guard new != _status else { return nil }
        _status = new
        return new
    }

    private func notify(_ changed: Status?) {
        guard let changed, let onStatusChange else { return }
        restartQueue.async { onStatusChange(changed) }
    }
}

// MARK: - The input-only audio unit

/// One input-only AUHAL on one device: renders every I/O cycle (into the unit's own buffers: a buffer list
/// with our own memory made AudioUnitRender fail with -50), downmixes the device's channels to mono
/// (PCM.downmixFloat32) and hands the buffer to the delivery queue. It reports the
/// input-side events of its device through `onEvent` (on the listener queue, or on the I/O thread for a
/// failed render, once).
private final class InputCapture {
    let deviceID: AudioObjectID
    let deviceName: String
    let followsDefault: Bool
    let monoFormat: AVAudioFormat
    var onEvent: ((Int) -> Void)?

    private let unit: AudioUnit
    private let rate: Double
    private let channels: Int
    private let list: UnsafeMutableAudioBufferListPointer
    private let capacity: AVAudioFrameCount
    private let delivery: DispatchQueue
    private let handler: PCMHandler
    private let renderStatus = Atomic<Int32>(0)
    private let deliveredAny = Atomic<Bool>(false)
    /// The status of the first render that failed (0 = none).
    var failedRenderStatus: OSStatus { renderStatus.load(ordering: .relaxed) }
    /// Whether any audio was delivered since the unit started.
    var delivered: Bool { deliveredAny.load(ordering: .relaxed) }
    private let listenerQueue = DispatchQueue(label: "app.ponte.mic.listen")
    private var started = false
    private var disposed = false
    private var listeners: [(object: AudioObjectID, address: AudioObjectPropertyAddress, block: AudioObjectPropertyListenerBlock)] = []

    init(deviceID: AudioObjectID, followsDefault: Bool, sliceHint: Int, delivery: DispatchQueue, handler: @escaping PCMHandler) throws {
        self.deviceID = deviceID
        self.deviceName = HAL.string(deviceID, HAL.address(kAudioObjectPropertyName)) ?? "device \(deviceID)"
        self.followsDefault = followsDefault
        self.delivery = delivery
        self.handler = handler

        var description = AudioComponentDescription(componentType: kAudioUnitType_Output, componentSubType: kAudioUnitSubType_HALOutput,
                                                    componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0)
        guard let component = AudioComponentFindNext(nil, &description) else { throw PonteAudioError.engine("no HAL audio unit") }
        var instance: AudioUnit?
        try HAL.check(AudioComponentInstanceNew(component, &instance), "new input unit")
        guard let unit = instance else { throw PonteAudioError.engine("no input unit") }
        self.unit = unit
        do {
            // Input on (element 1), output off (element 0): nothing on the output side to be reconfigured.
            var on: UInt32 = 1
            var off: UInt32 = 0
            let flagSize = UInt32(MemoryLayout<UInt32>.size)
            try HAL.check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &on, flagSize), "enable input")
            try HAL.check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &off, flagSize), "disable output")
            var device = deviceID
            try HAL.check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                               &device, UInt32(MemoryLayout<AudioDeviceID>.size)), "set input device \(deviceName)")
            // The device side of the input element; the client side takes the same rate and channels as
            // deinterleaved Float32 (the unit cannot change the input's rate).
            var hardware = AudioStreamBasicDescription()
            var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            try HAL.check(AudioUnitGetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 1, &hardware, &size), "input format")
            guard AudioRules.micTapReady(inputRate: hardware.mSampleRate, inputChannels: Int(hardware.mChannelsPerFrame),
                                         busRate: hardware.mSampleRate, busChannels: Int(hardware.mChannelsPerFrame)) else {
                throw PonteAudioError.unsupportedFormat("input not ready (\(hardware.mSampleRate) Hz, \(hardware.mChannelsPerFrame) ch)")
            }
            rate = hardware.mSampleRate
            channels = Int(hardware.mChannelsPerFrame)
            guard let client = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate,
                                             channels: AVAudioChannelCount(channels), interleaved: false) else {
                throw PonteAudioError.unsupportedFormat("\(rate) Hz, \(channels) ch")
            }
            var clientASBD = client.streamDescription.pointee
            try HAL.check(AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &clientASBD,
                                               UInt32(MemoryLayout<AudioStreamBasicDescription>.size)), "client format")
            let ioFrames = (try? HAL.get(deviceID, HAL.address(kAudioDevicePropertyBufferFrameSize, kAudioObjectPropertyScopeInput),
                                         default: UInt32(0))) ?? 0
            var slice = UInt32(AudioRules.micMaxFrames(ioFrames: max(Int(ioFrames), sliceHint)))
            try HAL.check(AudioUnitSetProperty(unit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0,
                                               &slice, flagSize), "maximum frames")
            capacity = AVAudioFrameCount(slice)
            list = AudioBufferList.allocate(maximumBuffers: channels)
            monoFormat = PCM.monoFormat(sampleRate: rate)
        } catch {
            AudioComponentInstanceDispose(unit)
            throw error
        }
    }

    deinit {
        stop()
        list.unsafeMutablePointer.deallocate()
    }

    /// Installs the render callback and the device listeners, then starts the unit.
    func start() throws {
        var callback = AURenderCallbackStruct(inputProc: micInputProc, inputProcRefCon: Unmanaged.passUnretained(self).toOpaque())
        try HAL.check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0,
                                           &callback, UInt32(MemoryLayout<AURenderCallbackStruct>.size)), "input callback")
        try HAL.check(AudioUnitInitialize(unit), "initialize input unit")
        listen(deviceID, kAudioDevicePropertyDeviceIsAlive, kAudioObjectPropertyScopeGlobal, AudioRules.micEventAlive)
        listen(deviceID, kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal, AudioRules.micEventFormat)
        listen(deviceID, kAudioDevicePropertyStreamConfiguration, kAudioObjectPropertyScopeInput, AudioRules.micEventFormat)
        listen(deviceID, kAudioDevicePropertyDeviceIsRunning, kAudioObjectPropertyScopeGlobal, AudioRules.micEventRunning)
        if followsDefault {
            listen(HAL.system, kAudioHardwarePropertyDefaultInputDevice, kAudioObjectPropertyScopeGlobal, AudioRules.micEventDefaultInput)
        }
        try HAL.check(AudioOutputUnitStart(unit), "start input unit on \(deviceName)")
        started = true
    }

    /// Stops the unit, removes the listeners and disposes of the unit. Safe to call twice.
    func stop() {
        // Removed with the queue they were added with; that queue only hops to MicSource's queue, so
        // removing them from there cannot wait on ourselves.
        for l in listeners {
            var address = l.address
            AudioObjectRemovePropertyListenerBlock(l.object, &address, listenerQueue, l.block)
        }
        listeners.removeAll()
        guard !disposed else { return }
        disposed = true
        if started { AudioOutputUnitStop(unit) }
        AudioUnitUninitialize(unit)
        AudioComponentInstanceDispose(unit)
        started = false
    }

    /// The facts AudioRules.micInputRebuilds takes, read now.
    func facts() -> (alive: Bool, sameFormat: Bool, sameDevice: Bool, unitRunning: Bool) {
        let alive = ((try? HAL.get(deviceID, HAL.address(kAudioDevicePropertyDeviceIsAlive), default: UInt32(0))) ?? 0) != 0
        let sameFormat = HAL.nominalSampleRate(deviceID) == rate && HAL.channelCount(deviceID, input: true) == channels
        let sameDevice = HAL.defaultDevice(input: true) == deviceID
        var running: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let read = AudioUnitGetProperty(unit, kAudioOutputUnitProperty_IsRunning, kAudioUnitScope_Global, 0, &running, &size)
        return (alive, sameFormat, sameDevice, read == noErr && running != 0)
    }

    private func listen(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope, _ event: Int) {
        var address = HAL.address(selector, scope)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.onEvent?(event) }
        if AudioObjectAddPropertyListenerBlock(object, &address, listenerQueue, block) == noErr {
            listeners.append((object, address, block))
        }
    }

    /// The I/O thread: one cycle of input.
    fileprivate func renderInput(_ flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>, _ timeStamp: UnsafePointer<AudioTimeStamp>,
                                 _ bus: UInt32, _ frames: UInt32) -> OSStatus {
        guard frames > 0, frames <= capacity else { return noErr }
        for i in 0..<list.count {
            list[i] = AudioBuffer(mNumberChannels: 1, mDataByteSize: frames * UInt32(MemoryLayout<Float>.size), mData: nil)
        }
        let status = AudioUnitRender(unit, flags, timeStamp, bus, frames, list.unsafeMutablePointer)
        guard status == noErr else {
            // Reported once: the first failure flips the status from 0.
            if renderStatus.compareExchange(expected: 0, desired: status, ordering: .relaxed).exchanged {
                onEvent?(AudioRules.micEventRenderFailed)
            }
            return status
        }
        guard let mono = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: frames) else { return noErr }
        let written = PCM.downmixFloat32(UnsafePointer(list.unsafeMutablePointer), into: mono.floatChannelData![0], maxFrames: Int(frames))
        mono.frameLength = AVAudioFrameCount(written)
        if !deliveredAny.load(ordering: .relaxed) { deliveredAny.store(true, ordering: .relaxed) }
        var stamp = timeStamp.pointee
        let time = AVAudioTime(audioTimeStamp: &stamp, sampleRate: rate)
        let handler = self.handler
        delivery.async { handler(mono, time) }
        return noErr
    }
}

/// The input unit's callback (I/O thread): the refCon is the InputCapture, kept alive by MicSource while the
/// unit runs.
private let micInputProc: AURenderCallback = { refCon, flags, timeStamp, bus, frames, _ in
    Unmanaged<InputCapture>.fromOpaque(refCon).takeUnretainedValue().renderInput(flags, timeStamp, bus, frames)
}
