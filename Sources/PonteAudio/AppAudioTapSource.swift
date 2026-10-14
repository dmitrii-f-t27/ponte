import AVFoundation
import CoreAudio
import Foundation
import PonteCore

/// Captures what one app plays (all of its processes, helpers included) or all system audio except
/// Ponte, through a Core Audio process tap. No driver needed. The host app needs the
/// "System Audio Recording" permission (Info.plist `NSAudioCaptureUsageDescription`); without it
/// macOS delivers silence.
///
/// Pipeline: CATapDescription → AudioHardwareCreateProcessTap → private aggregate device with the
/// tap in `kAudioAggregateDeviceTapListKey` → IOProc block → mono Float32 → handler.
///
/// The source watches the HAL process list: when the target app quits it waits, and when the app
/// (or a new helper process) appears it re-attaches by itself. Buffers are handed to the handler on
/// a private serial queue, never on the HAL real-time thread.
public final class AppAudioTapSource: AudioSource {
    public enum Status: Equatable {
        case idle
        /// Running, but no process of the target is connected to the audio system yet.
        case waitingForApp
        /// Tap is live. `pids` are the tapped processes (empty for "all system audio").
        case capturing(pids: [Int32])
        case failed(String)
    }

    enum Mode: Equatable {
        case target(CaptureTarget)
        case pids([Int32])
    }

    static let aggregateUIDPrefix = AudioRules.ponteAggregateUIDPrefix

    let mode: Mode

    /// Mono Float32 at the tap's native rate. Before `start` it is predicted from the default output
    /// device; `start` fixes it to the real tap format. If a later re-attach yields another rate,
    /// buffers are resampled so this stays true for the whole session.
    public private(set) var outputFormat: AVAudioFormat

    /// Called on the control queue whenever the status changes.
    public var onStatusChange: ((Status) -> Void)?

    public var status: Status { onControl { _status } }

    /// Whether the owner also hears the tapped app on the Mac (AudioRules.tapMuteBehavior). True keeps the app
    /// audible; false mutes it while Ponte reads it (the call app: only the Russian voice is heard). A running
    /// tap takes the new value in place, or is rebuilt when that fails.
    public var hearOriginal: Bool {
        get { onControl { _hearOriginal } }
        set {
            onControl {
                guard newValue != _hearOriginal else { return }
                _hearOriginal = newValue
                applyMuteBehavior()
            }
        }
    }

    /// The tap's own stream format (diagnostics), nil until attached.
    public var tapStreamDescription: AudioStreamBasicDescription? { onControl { tapASBD } }

    private let control = DispatchQueue(label: "ponte.audio.tap.control")
    private let delivery = DispatchQueue(label: "ponte.audio.tap.delivery", qos: .userInteractive)
    private let controlKey = DispatchSpecificKey<Bool>()
    private let deliveryKey = DispatchSpecificKey<Bool>()
    /// Handler and resampler; touched only on the delivery queue.
    private let sink = Sink()

    private final class Sink {
        var handler: PCMHandler?
        var converter: PCM.Converter?
    }

    private var _status: Status = .idle {
        didSet { if _status != oldValue { onStatusChange?(_status) } }
    }
    private var running = false
    private var _hearOriginal = true
    /// Session output rate, fixed at the first attach (0 = not yet).
    private var fixedRate: Double = 0

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var tapASBD: AudioStreamBasicDescription?
    private var attachedObjects: [AudioObjectID] = []

    private var processListListener: AudioObjectPropertyListenerBlock?
    private var tapFormatListener: AudioObjectPropertyListenerBlock?
    private var reconcileGeneration = 0

    public convenience init(target: CaptureTarget) {
        self.init(mode: .target(target))
    }

    /// Taps exactly these processes (by PID). For tests and CLI tools such as `afplay`.
    public convenience init(pids: [Int32]) {
        self.init(mode: .pids(pids))
    }

    init(mode: Mode) {
        self.mode = mode
        let rate = AudioRules.rateOrDefault(HAL.defaultDevice(input: false).flatMap { HAL.nominalSampleRate($0) } ?? 0)
        self.outputFormat = PCM.monoFormat(sampleRate: rate)
        control.setSpecific(key: controlKey, value: true)
        delivery.setSpecific(key: deliveryKey, value: true)
    }

    private func onControl<T>(_ body: () throws -> T) rethrows -> T {
        DispatchQueue.getSpecific(key: controlKey) == true ? try body() : try control.sync(execute: body)
    }

    private func onDelivery(_ body: () -> Void) {
        DispatchQueue.getSpecific(key: deliveryKey) == true ? body() : delivery.sync(execute: body)
    }

    deinit {
        stop()
    }

    // MARK: AudioSource

    public func start(handler: @escaping PCMHandler) throws {
        try onControl {
            guard !running else { throw PonteAudioError.alreadyRunning }
            onDelivery { sink.handler = handler; sink.converter = nil }
            running = true
            fixedRate = 0
            do {
                try addProcessListListener()
                try attachIfPossible()
            } catch {
                teardown()
                removeProcessListListener()
                running = false
                onDelivery { sink.handler = nil }
                _status = .failed(String(describing: error))
                throw error
            }
        }
    }

    /// Stops capture and destroys the IOProc, the aggregate device and the tap. After `stop`
    /// returns the handler is not called again.
    public func stop() {
        onControl {
            guard running else { return }
            running = false
            removeProcessListListener()
            teardown()
            _status = .idle
        }
        onDelivery { sink.handler = nil; sink.converter = nil }
    }

    // MARK: Target resolution

    /// Process objects to put into the tap (or, for system audio, to exclude from it).
    private func desiredObjects() -> [AudioObjectID] {
        switch mode {
        case let .pids(pids):
            return pids.compactMap { HAL.processObject(for: $0) }.sorted()
        case let .target(.app(bundleID)):
            // Never tap ourselves, even if Ponte is attributed to the same app (e.g. a terminal).
            let me = getpid()
            return AudioProcesses.objects(forApp: bundleID, in: AudioProcesses.snapshot())
                .filter { $0.pid != me }.map(\.objectID).sorted()
        case .target(.systemExceptSelf):
            return HAL.processObject(for: getpid()).map { [$0] } ?? []
        }
    }

    private var isGlobal: Bool { mode == .target(.systemExceptSelf) }

    private func attachIfPossible() throws {
        let objects = desiredObjects()
        switch AudioRules.tapAction(attached: false, desiredCount: objects.count, sameSet: false,
                                    isGlobal: isGlobal, force: true) {
        case AudioRules.tapRebuild: try build(objects: objects)
        default: _status = .waitingForApp
        }
    }

    /// Called (debounced) when the HAL process list or the tap format changes.
    /// A changed process set is applied to the live tap in place (no gap in the audio); the whole
    /// tap is rebuilt only when that fails, when the format changed, or after the app was gone.
    private func reconcile(force: Bool = false) {
        guard running else { return }
        let objects = desiredObjects()
        let attached = tapID != kAudioObjectUnknown
        let action = AudioRules.tapAction(attached: attached, desiredCount: objects.count,
                                          sameSet: objects == attachedObjects, isGlobal: isGlobal, force: force)
        switch action {
        case AudioRules.tapKeep:
            return
        case AudioRules.tapWait:
            teardown()
            _status = .waitingForApp
            return
        case AudioRules.tapUpdate where updateTapProcesses(objects):
            return
        default:
            break   // tapRebuild, or tapUpdate that failed
        }
        teardown()
        do {
            try build(objects: objects)
        } catch {
            _status = .failed(String(describing: error))
        }
    }

    /// Swaps the tapped (or excluded) processes of the running tap via kAudioTapPropertyDescription.
    private func updateTapProcesses(_ objects: [AudioObjectID]) -> Bool {
        let tap = AudioHardwareTap(id: tapID)
        do {
            let description = try tap.description
            description.processes = objects
            try tap.setDescription(description)
        } catch {
            return false
        }
        attachedObjects = objects
        let pids: [Int32] = AudioRules.tapListsProcesses(isGlobal: isGlobal) ? objects.compactMap { HAL.pid(ofProcess: $0) }.sorted() : []
        _status = .capturing(pids: pids)
        return true
    }

    private var muteBehavior: CATapMuteBehavior {
        CATapMuteBehavior(rawValue: AudioRules.tapMuteBehavior(isGlobal: isGlobal, hearOriginal: _hearOriginal)) ?? .unmuted
    }

    /// Sets the mute behavior of the running tap via kAudioTapPropertyDescription; rebuilds the tap if that fails.
    private func applyMuteBehavior() {
        guard running, tapID != kAudioObjectUnknown else { return }
        let tap = AudioHardwareTap(id: tapID)
        do {
            let description = try tap.description
            description.muteBehavior = muteBehavior
            try tap.setDescription(description)
        } catch {
            scheduleReconcile(force: true)
        }
    }

    private func scheduleReconcile(force: Bool = false) {
        reconcileGeneration += 1
        let generation = reconcileGeneration
        control.asyncAfter(deadline: .now() + AudioRules.reconcileDebounceSeconds) { [weak self] in
            guard let self, generation == self.reconcileGeneration else { return }
            self.reconcile(force: force)
        }
    }

    // MARK: Build / teardown (control queue only)

    private func build(objects: [AudioObjectID]) throws {
        let description: CATapDescription
        if AudioRules.tapListsProcesses(isGlobal: isGlobal) {
            description = CATapDescription(stereoMixdownOfProcesses: objects)
        } else {
            description = CATapDescription(stereoGlobalTapButExcludeProcesses: objects)
        }
        description.name = "Ponte tap"
        description.uuid = UUID()
        description.muteBehavior = muteBehavior
        description.isPrivate = true

        var newTap = AudioObjectID(kAudioObjectUnknown)
        try HAL.check(AudioHardwareCreateProcessTap(description, &newTap), "AudioHardwareCreateProcessTap")
        tapID = newTap

        guard let tapUID = HAL.string(tapID, HAL.address(kAudioTapPropertyUID)) else {
            throw PonteAudioError.coreAudio(status: -1, what: "tap UID")
        }
        let asbd = try HAL.get(tapID, HAL.address(kAudioTapPropertyFormat), default: AudioStreamBasicDescription())
        guard AudioRules.isUsableTapFormat(isLinearPCM: asbd.mFormatID == kAudioFormatLinearPCM,
                                           isFloat: asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0,
                                           bitsPerChannel: Int(asbd.mBitsPerChannel), sampleRate: asbd.mSampleRate) else {
            throw PonteAudioError.unsupportedFormat("tap format \(PCM.describe(asbd))")
        }
        tapASBD = asbd

        let composition: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Ponte Tap",
            kAudioAggregateDeviceUIDKey: Self.aggregateUIDPrefix + UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: false,
            kAudioAggregateDeviceSubDeviceListKey: [[String: Any]](),
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapUIDKey: tapUID,
                kAudioSubTapDriftCompensationKey: true,
            ] as [String: Any]],
        ]
        var newAggregate = AudioObjectID(kAudioObjectUnknown)
        try HAL.check(AudioHardwareCreateAggregateDevice(composition as CFDictionary, &newAggregate),
                      "AudioHardwareCreateAggregateDevice")
        aggregateID = newAggregate

        // Output format: fixed at the first attach of this session, resampled afterwards if needed.
        let tapMono = PCM.monoFormat(sampleRate: asbd.mSampleRate)
        fixedRate = AudioRules.sessionRate(fixedRate: fixedRate, tapRate: asbd.mSampleRate)
        if outputFormat.sampleRate != fixedRate { outputFormat = PCM.monoFormat(sampleRate: fixedRate) }
        let converter = AudioRules.needsResample(fromRate: asbd.mSampleRate, toRate: fixedRate)
            ? PCM.Converter(from: tapMono, to: outputFormat) : nil
        onDelivery { sink.converter = converter }

        let sampleRate = asbd.mSampleRate
        let delivery = self.delivery
        let sink = self.sink
        var procID: AudioDeviceIOProcID?
        try HAL.check(AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, nil) { _, inInputData, inInputTime, _, _ in
            // HAL real-time thread: downmix, then hand off.
            let frames = Self.frameCount(inInputData)
            guard frames > 0,
                  let buffer = AVAudioPCMBuffer(pcmFormat: tapMono, frameCapacity: AVAudioFrameCount(frames)) else { return }
            let written = PCM.downmixFloat32(inInputData, into: buffer.floatChannelData![0], maxFrames: frames)
            buffer.frameLength = AVAudioFrameCount(written)
            let time = AVAudioTime(audioTimeStamp: inInputTime, sampleRate: sampleRate)
            delivery.async {
                guard let handler = sink.handler else { return }
                if let converter = sink.converter {
                    if let converted = try? converter.convert(buffer), converted.frameLength > 0 {
                        handler(converted, nil)
                    }
                } else {
                    handler(buffer, time)
                }
            }
        }, "AudioDeviceCreateIOProcIDWithBlock")
        ioProcID = procID

        try HAL.check(AudioDeviceStart(aggregateID, ioProcID), "AudioDeviceStart")
        attachedObjects = objects
        try addTapFormatListener()

        let pids: [Int32] = AudioRules.tapListsProcesses(isGlobal: isGlobal) ? objects.compactMap { HAL.pid(ofProcess: $0) }.sorted() : []
        _status = .capturing(pids: pids)
    }

    private func teardown() {
        removeTapFormatListener()
        if aggregateID != kAudioObjectUnknown {
            if let ioProcID {
                AudioDeviceStop(aggregateID, ioProcID)
                AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
        }
        ioProcID = nil
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        tapID = AudioObjectID(kAudioObjectUnknown)
        attachedObjects = []
        tapASBD = nil
    }

    /// Diagnostics: Ponte tap aggregates and process taps that still exist in this process.
    /// Both are 0 shortly after every source was stopped (aggregate destruction is asynchronous).
    public static func liveObjectCounts() -> (aggregates: Int, taps: Int) {
        let aggregates = HAL.deviceIDs().filter {
            AudioRules.isPonteAggregate(uid: HAL.string($0, HAL.address(kAudioDevicePropertyDeviceUID)) ?? "")
        }.count
        let taps = (try? HAL.array(HAL.system, HAL.address(kAudioHardwarePropertyTapList), of: AudioObjectID.self))?.count ?? 0
        return (aggregates, taps)
    }

    static func frameCount(_ abl: UnsafePointer<AudioBufferList>) -> Int {
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: abl))
        for b in buffers where AudioRules.usesBuffer(hasData: b.mData != nil, channels: Int(b.mNumberChannels)) {
            return AudioRules.framesInBuffer(byteSize: Int(b.mDataByteSize), channels: Int(b.mNumberChannels),
                                             bytesPerSample: MemoryLayout<Float>.size)
        }
        return 0
    }

    // MARK: Listeners

    private func addProcessListListener() throws {
        var addr = HAL.address(kAudioHardwarePropertyProcessObjectList)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.scheduleReconcile()
        }
        try HAL.check(AudioObjectAddPropertyListenerBlock(HAL.system, &addr, control, block), "listen process list")
        processListListener = block
    }

    private func removeProcessListListener() {
        guard let block = processListListener else { return }
        var addr = HAL.address(kAudioHardwarePropertyProcessObjectList)
        AudioObjectRemovePropertyListenerBlock(HAL.system, &addr, control, block)
        processListListener = nil
    }

    private func addTapFormatListener() throws {
        guard tapID != kAudioObjectUnknown else { return }
        var addr = HAL.address(kAudioTapPropertyFormat)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.scheduleReconcile(force: true)
        }
        try HAL.check(AudioObjectAddPropertyListenerBlock(tapID, &addr, control, block), "listen tap format")
        tapFormatListener = block
    }

    private func removeTapFormatListener() {
        guard let block = tapFormatListener, tapID != kAudioObjectUnknown else { tapFormatListener = nil; return }
        var addr = HAL.address(kAudioTapPropertyFormat)
        AudioObjectRemovePropertyListenerBlock(tapID, &addr, control, block)
        tapFormatListener = nil
    }
}
