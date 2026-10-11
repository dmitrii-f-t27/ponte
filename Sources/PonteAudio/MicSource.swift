import AudioToolbox
import AVFoundation
import CoreAudio
import Foundation
import PonteCore

/// Captures one input device (nil = system default input) with AVAudioEngine and delivers mono
/// Float32 at the device's native rate. The host app needs the Microphone permission
/// (`NSMicrophoneUsageDescription`); without it macOS delivers silence or refuses to start.
public final class MicSource: AudioSource {
    public let device: AudioDevice?

    /// Mono Float32 at the device's native rate. Predicted from the HAL before `start`, exact after.
    public private(set) var outputFormat: AVAudioFormat

    /// Frames per tap callback requested from AVAudioEngine (a hint; the engine may differ).
    public var bufferFrames = AVAudioFrameCount(AudioRules.micTapBufferFrames)

    private let lock = NSLock()
    private var engine: AVAudioEngine?
    private var handler: PCMHandler?
    private var configObserver: NSObjectProtocol?

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
        defer { lock.unlock() }
        guard engine == nil else { throw PonteAudioError.alreadyRunning }
        self.handler = handler
        do {
            try startEngine()
        } catch {
            self.handler = nil
            throw error
        }
    }

    public func stop() {
        lock.lock()
        defer { lock.unlock() }
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
        configObserver = nil
        stopEngine()
        handler = nil
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
        let hwFormat = input.outputFormat(forBus: 0)
        guard hwFormat.sampleRate > 0, hwFormat.channelCount > 0 else {
            throw PonteAudioError.unsupportedFormat("input has no channels (\(hwFormat)); is the device an input?")
        }
        outputFormat = PCM.monoFormat(sampleRate: hwFormat.sampleRate)

        let handler = self.handler
        input.installTap(onBus: 0, bufferSize: bufferFrames, format: hwFormat) { buffer, time in
            guard let handler, let mono = PCM.mono(buffer) else { return }
            handler(mono, time)
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw PonteAudioError.engine("start failed: \(error.localizedDescription)")
        }
        self.engine = engine

        // Device unplugged or its format changed: rebuild the engine on the same device.
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            self.lock.lock()
            defer { self.lock.unlock() }
            guard self.engine != nil else { return }
            if let configObserver = self.configObserver { NotificationCenter.default.removeObserver(configObserver) }
            self.configObserver = nil
            self.stopEngine()
            try? self.startEngine()
        }
    }

    private func stopEngine() {
        guard let engine else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        self.engine = nil
    }
}
