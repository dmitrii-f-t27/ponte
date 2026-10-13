import AudioToolbox
import AVFoundation
import CoreAudio
import Foundation
import PonteCore
import PonteObjC

/// Captures one input device (nil = system default input) with AVAudioEngine and delivers mono
/// Float32 at the device's native rate. The host app needs the Microphone permission
/// (`NSMicrophoneUsageDescription`); without it macOS delivers silence or refuses to start.
///
/// A device change (headphones plugged in, an iPhone's Continuity microphone appearing, a new
/// default device or rate) stops AVAudioEngine and posts `AVAudioEngineConfigurationChange`.
/// The engine is then rebuilt later on a private queue, never inside that notification: rebuilding
/// there installed a tap with a stale format, AVAudioEngine raised an Objective-C exception and the
/// app aborted (live crash 2026-10-13). The wait and the backoff come from AudioRules (audio_rules.t27).
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

    /// Frames per tap callback requested from AVAudioEngine (a hint; the engine may differ).
    public var bufferFrames = AVAudioFrameCount(AudioRules.micTapBufferFrames)

    /// Called on a private queue whenever `status` changes.
    public var onStatusChange: ((Status) -> Void)?

    public var status: Status { lock.withLock { _status } }

    private let lock = NSLock()
    private let restartQueue = DispatchQueue(label: "app.ponte.mic.restart")
    private var engine: AVAudioEngine?
    private var handler: PCMHandler?
    private var configObserver: NSObjectProtocol?
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

    /// `start` refuses to run without permission: with an undecided permission
    /// AVAudioEngine blocks inside `inputNode` until the user answers the prompt, and with a denied
    /// one it records silence. Call `requestPermission()` first.
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
            try startEngine()
        } catch {
            self.handler = nil
            lock.unlock()
            throw error
        }
        running = true
        failures = 0
        let changed = setStatus(.capturing)
        lock.unlock()
        notify(changed)
    }

    public func stop() {
        lock.lock()
        running = false
        restartWork?.cancel()
        restartWork = nil
        stopEngine()
        handler = nil
        failures = 0
        let changed = setStatus(.idle)
        lock.unlock()
        notify(changed)
    }

    // MARK: Device changes

    /// AVAudioEngineConfigurationChange: tear the engine down now, rebuild it later.
    private func configurationChanged(of changedEngine: AVAudioEngine) {
        lock.lock()
        guard running, engine === changedEngine else {
            lock.unlock()
            return
        }
        stopEngine()
        failures = 0
        let changed = setStatus(.restarting(failures: 0))
        scheduleRestart()
        lock.unlock()
        notify(changed)
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
        guard running, engine == nil else {
            lock.unlock()
            return
        }
        restartWork = nil
        let changed: Status?
        do {
            try startEngine()
            failures = 0
            changed = setStatus(.capturing)
        } catch {
            failures += 1
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

    // MARK: Engine (lock held)

    /// Re-resolves the device by UID: device IDs can change after a reconnect.
    private func resolvedDeviceID() throws -> AudioObjectID? {
        guard let device else { return nil }
        if let live = CoreAudioDeviceCatalog().device(uid: device.uid) { return live.id }
        throw PonteAudioError.deviceNotFound(device.name)
    }

    private func startEngine() throws {
        let engine = AVAudioEngine()
        let input = engine.inputNode
        if let id = try resolvedDeviceID() {
            guard let au = input.audioUnit else { throw PonteAudioError.engine("input node has no audio unit") }
            var deviceID = id
            let status = AudioUnitSetProperty(au, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                              &deviceID, UInt32(MemoryLayout<AudioDeviceID>.size))
            try HAL.check(status, "set input device \(device?.name ?? "")")
        }
        // Both sides of the input node need a real format, or installTap raises (an Objective-C
        // exception Swift cannot catch). The tap then takes the bus's own format (format: nil).
        let deviceFormat = input.inputFormat(forBus: 0)
        let busFormat = input.outputFormat(forBus: 0)
        guard AudioRules.micTapReady(inputRate: deviceFormat.sampleRate, inputChannels: Int(deviceFormat.channelCount),
                                     busRate: busFormat.sampleRate, busChannels: Int(busFormat.channelCount)) else {
            throw PonteAudioError.unsupportedFormat("input not ready (device \(deviceFormat), bus \(busFormat))")
        }
        outputFormat = PCM.monoFormat(sampleRate: busFormat.sampleRate)

        let handler = self.handler
        let frames = bufferFrames
        if let reason = PonteCatchObjC({
            input.installTap(onBus: 0, bufferSize: frames, format: nil) { buffer, time in
                guard let handler, let mono = PCM.mono(buffer) else { return }
                handler(mono, time)
            }
        }) {
            throw PonteAudioError.engine("installTap: \(reason)")
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw PonteAudioError.engine("start failed: \(error.localizedDescription)")
        }
        self.engine = engine
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { [weak self, weak engine] _ in
            guard let self, let engine else { return }
            // Never rebuild on the posting thread; hop to our queue first.
            self.restartQueue.async { self.configurationChanged(of: engine) }
        }
    }

    private func stopEngine() {
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
        configObserver = nil
        guard let engine else { return }
        _ = PonteCatchObjC {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        self.engine = nil
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
