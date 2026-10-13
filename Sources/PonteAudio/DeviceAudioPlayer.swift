import AudioToolbox
import AVFoundation
import CoreAudio
import Foundation
import PonteCore
import PonteObjC

/// Plays PCM to one fixed output device (nil = system default output): headphones, or
/// "BlackHole 2ch" which the call app uses as its microphone.
/// AVAudioEngine + AVAudioPlayerNode; the output unit's current device is set explicitly, and any
/// input format (rate, channels, Int16/Float32) is converted to mono Float32 at the device rate.
/// The mixer spreads mono to every output channel.
///
/// Buffers play in the order their `play` calls start. `play` returns only after its audio has
/// been played out, so to play several buffers without gaps pass them in one call
/// (`play([b1, b2, …])`) instead of awaiting `play` buffer by buffer.
public final class DeviceAudioPlayer: AudioPlayer, @unchecked Sendable {
    public let device: AudioDevice?

    /// Last engine error (device missing, start failure). `play` returns immediately on errors.
    public private(set) var lastError: Error?

    /// Output volume of this player, 0…1.
    public var volume: Float {
        get { player.volume }
        set { player.volume = AudioRules.clampUnit(newValue) }
    }

    private let lock = NSLock()
    // Replaced after a real device change: a reused AVAudioEngine stayed silent after several
    // reconfigurations (seen live 2026-10-13: phrases reached nothing after a device switch).
    private var engine = AVAudioEngine()
    private var player = AVAudioPlayerNode()
    private var needsRebuild = false
    private var attached = false
    private var running = false
    private var playFormat: AVAudioFormat?
    private var converters: [(format: AVAudioFormat, converter: PCM.Converter)] = []
    private var configObserver: NSObjectProtocol?

    // Completion bookkeeping (lock held). A scheduled id is either still playing (`scheduled`),
    // awaited (`waiting`), or done before anyone awaited it (`done`).
    private var scheduled: Set<UUID> = []
    private var waiting: [UUID: CheckedContinuation<Void, Never>] = [:]
    private var done: Set<UUID> = []

    public init(device: AudioDevice?) {
        self.device = device
    }

    deinit {
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
        player.stop()
        engine.stop()
        releaseAll()
    }

    /// Starts the engine on the device now (optional; `play` does it lazily). Throws the reason
    /// the device cannot be used.
    public func prepare() throws {
        lock.lock()
        defer { lock.unlock() }
        try ensureRunning()
    }

    /// Enqueues the buffer and returns when it has actually been played out (or `stopAll` was called).
    public func play(_ buffer: AVAudioPCMBuffer) async {
        await play([buffer])
    }

    /// Enqueues the buffers back to back (gapless) and returns when the last one has been played out.
    public func play(_ buffers: [AVAudioPCMBuffer]) async {
        guard let id = schedule(buffers) else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            if done.remove(id) != nil {
                lock.unlock()
                continuation.resume()
            } else {
                waiting[id] = continuation
                lock.unlock()
            }
        }
    }

    /// Drops everything queued or playing; pending `play` calls return.
    public func stopAll() {
        lock.lock()
        player.stop()
        for (_, c) in converters { c.reset() }
        // A device change may have stopped the engine already; play() on it raises (uncatchable in Swift).
        if running, engine.isRunning { _ = PonteCatchObjC { player.play() } }
        lock.unlock()
        releaseAll()
    }

    // MARK: Scheduling

    /// Converts and schedules atomically, so concurrent callers keep their order. nil = nothing to play.
    private func schedule(_ buffers: [AVAudioPCMBuffer]) -> UUID? {
        lock.lock()
        defer { lock.unlock() }
        var converted: [AVAudioPCMBuffer] = []
        do {
            try ensureRunning()
            let input = buffers.filter { $0.frameLength > 0 }
            for (i, b) in input.enumerated() {
                // The last buffer of a call flushes the resampler, so each call plays out completely.
                let out = try convert(b, final: AudioRules.flushesConverter(index: i, count: input.count, nextFormatDiffers: false))
                if out.frameLength > 0 { converted.append(out) }
            }
        } catch {
            lastError = error
            return nil
        }
        guard !converted.isEmpty else { return nil }
        let id = UUID()
        scheduled.insert(id)
        for (i, b) in converted.enumerated() {
            if i == converted.count - 1 {
                player.scheduleBuffer(b, completionCallbackType: .dataPlayedBack) { [weak self] _ in
                    self?.finish(id)
                }
            } else {
                player.scheduleBuffer(b, completionHandler: nil)
            }
        }
        return id
    }

    private func finish(_ id: UUID) {
        lock.lock()
        guard scheduled.remove(id) != nil else { lock.unlock(); return }
        if let c = waiting.removeValue(forKey: id) {
            lock.unlock()
            c.resume()
        } else {
            done.insert(id)
            lock.unlock()
        }
    }

    /// Completes every outstanding `play` (stop, engine reconfiguration, deinit).
    private func releaseAll() {
        lock.lock()
        let ids = scheduled
        lock.unlock()
        for id in ids { finish(id) }
    }

    // MARK: Engine (lock held)

    private func ensureRunning() throws {
        if running && engine.isRunning { return }
        if needsRebuild {
            if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
            configObserver = nil
            _ = PonteCatchObjC {
                self.player.stop()
                self.engine.stop()
            }
            let volume = player.volume
            engine = AVAudioEngine()
            player = AVAudioPlayerNode()
            player.volume = volume
            attached = false
            playFormat = nil
            converters.removeAll()
            needsRebuild = false
            PonteDiagnostics.log("player \(device?.name ?? "default"): engine rebuilt after a device change")
        }
        if !attached {
            engine.attach(player)
            attached = true
        }
        if let device {
            guard let live = CoreAudioDeviceCatalog().device(uid: device.uid), live.outputChannels > 0 else {
                throw PonteAudioError.deviceNotFound(device.name)
            }
            guard let au = engine.outputNode.audioUnit else { throw PonteAudioError.engine("output node has no audio unit") }
            // Setting the device reconfigures the unit (and AVAudioEngine then reports a change):
            // only set it when the unit is on another device.
            var current = AudioDeviceID(0)
            var size = UInt32(MemoryLayout<AudioDeviceID>.size)
            let read = AudioUnitGetProperty(au, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &current, &size)
            if read != noErr || current != live.id {
                var id = live.id
                try HAL.check(AudioUnitSetProperty(au, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                                   &id, UInt32(MemoryLayout<AudioDeviceID>.size)),
                              "set output device \(device.name)")
            }
        }
        let hw = engine.outputNode.outputFormat(forBus: 0)
        let rate = AudioRules.rateOrDefault(hw.sampleRate)
        if playFormat?.sampleRate != rate {
            let format = PCM.monoFormat(sampleRate: rate)
            engine.disconnectNodeOutput(player)
            engine.connect(player, to: engine.mainMixerNode, format: format)
            playFormat = format
            converters.removeAll()
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            PonteDiagnostics.log("player \(device?.name ?? "default"): start FAILED \(error.localizedDescription)")
            needsRebuild = true
            throw PonteAudioError.engine("start failed on \(device?.name ?? "default output"): \(error.localizedDescription)")
        }
        if let reason = PonteCatchObjC({ player.play() }) {
            throw PonteAudioError.engine("play failed on \(device?.name ?? "default output"): \(reason)")
        }
        running = true
        lastError = nil
        PonteDiagnostics.log("player \(device?.name ?? "default"): running at \(Int(rate)) Hz")

        if configObserver == nil {
            // Device unplugged / rate changed: the engine stops. Release waiters; rebuild on next play.
            // AVAudioEngine also posts this right after its own start while it keeps running: ignore that.
            let observed = engine
            configObserver = NotificationCenter.default.addObserver(
                forName: .AVAudioEngineConfigurationChange, object: observed, queue: nil
            ) { [weak self, weak observed] _ in
                guard let self, let observed else { return }
                if observed.isRunning {
                    PonteDiagnostics.log("player \(self.device?.name ?? "default"): configuration change ignored, engine running")
                    return
                }
                PonteDiagnostics.log("player \(self.device?.name ?? "default"): configuration change, engine stopped")
                self.lock.withLock {
                    self.running = false
                    self.needsRebuild = true
                }
                self.releaseAll()
            }
        }
    }

    /// Converts to the playback format with a per-input-format stateful resampler.
    /// `final` flushes the resampler's tail and resets it for the next call.
    private func convert(_ buffer: AVAudioPCMBuffer, final: Bool) throws -> AVAudioPCMBuffer {
        guard let target = playFormat else { throw PonteAudioError.engine("not prepared") }
        switch AudioRules.conversionPath(sameFormat: buffer.format.isEqual(target),
                                         sameRate: buffer.format.sampleRate == target.sampleRate) {
        case AudioRules.convertNone:
            return buffer
        case AudioRules.convertDownmix:
            guard let mono = PCM.mono(buffer) else { throw PonteAudioError.unsupportedFormat("\(buffer.format)") }
            return mono
        default:
            break   // convertResample
        }
        let converter: PCM.Converter
        if let entry = converters.first(where: { $0.format.isEqual(buffer.format) }) {
            converter = entry.converter
        } else {
            guard let c = PCM.Converter(from: buffer.format, to: target) else {
                throw PonteAudioError.unsupportedFormat("\(buffer.format) → \(target)")
            }
            converters.append((buffer.format, c))
            converter = c
        }
        let out = try converter.convert(buffer, final: final)
        if final { converter.reset() }
        return out
    }
}
