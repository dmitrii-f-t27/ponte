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
///
/// The output stays on and heals itself (live 2026-10-13). Once started (`prepare`, or the first
/// `play`) the engine keeps running between phrases, playing silence. Ponte runs several engines in one
/// process, and whenever any audio device reconfigures AVAudioEngine stops them and posts
/// `AVAudioEngineConfigurationChange`, in bursts. After such a real stop the engine is rebuilt on a
/// private queue after the capture backoff (never inside the notification), and every phrase that had
/// not been heard to its end plays again from its start (at most `AudioRules.playerMaxReplays` times).
/// A player node also calls its completions when it is stopped; the generation of the engine instance
/// and the frames the node has rendered tell real playback from such a flush. Only real playback (or
/// `stopAll`) completes a `play` call. The decisions are in AudioRules (audio_rules.t27); the bookkeeping
/// is `PlayerBook`.
public final class DeviceAudioPlayer: AudioPlayer, @unchecked Sendable {
    public let device: AudioDevice?

    /// Last engine error (device missing, start failure).
    public var lastError: Error? { lock.withLock { _lastError } }

    /// Output volume of this player, 0…1.
    public var volume: Float {
        get { lock.withLock { _volume } }
        set {
            lock.withLock {
                _volume = AudioRules.clampUnit(newValue)
                player?.volume = _volume
            }
        }
    }

    /// A phrase's buffers: as given to `play` until they are converted to the device format, then converted.
    struct Payload {
        var buffers: [AVAudioPCMBuffer]
    }

    private let lock = NSLock()
    /// Rebuilds, configuration changes and completions run here, never on AVAudioEngine's threads.
    private let queue = DispatchQueue(label: "app.ponte.player")
    private let name: String
    // A new engine and player node for every start: a reused AVAudioEngine stayed silent after several
    // reconfigurations (seen live 2026-10-13).
    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private var playFormat: AVAudioFormat?
    private var converters: [(format: AVAudioFormat, converter: PCM.Converter)] = []
    private var configObserver: NSObjectProtocol?
    private var rebuildWork: DispatchWorkItem?
    private var _lastError: Error?
    private var _volume: Float = 1
    private var book = PlayerBook<Payload>()
    // A phrase is either in the book, awaited (`waiting`), or finished before anyone awaited it (`finished`).
    private var waiting: [UInt64: CheckedContinuation<Void, Never>] = [:]
    private var finished: Set<UInt64> = []

    public init(device: AudioDevice?) {
        self.device = device
        self.name = device?.name ?? "default"
    }

    deinit {
        rebuildWork?.cancel()
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
        let player = player, engine = engine
        _ = PonteCatchObjC {
            player?.stop()
            engine?.stop()
        }
    }

    /// Starts the engine on the device now and keeps it running (the call output starts with its lane).
    /// Throws the reason the device cannot be used; the player then keeps retrying with the backoff.
    public func prepare() throws {
        lock.lock()
        var resume = checkEngineAlive()
        var failure: Error?
        if book.state == AudioRules.playerIdle {
            resume += startNow()
        }
        if book.state != AudioRules.playerRunning {
            failure = _lastError ?? PonteAudioError.engine("\(name): output is being rebuilt")
        }
        lock.unlock()
        resume.forEach { $0.resume() }
        if let failure { throw failure }
    }

    /// Enqueues the buffer and returns when it has actually been played out (or `stopAll` was called).
    public func play(_ buffer: AVAudioPCMBuffer) async {
        await play([buffer])
    }

    /// Enqueues the buffers back to back (gapless) and returns when the last one has been played out.
    public func play(_ buffers: [AVAudioPCMBuffer]) async {
        guard let id = enqueue(buffers) else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            if finished.remove(id) != nil {
                lock.unlock()
                continuation.resume()
            } else {
                waiting[id] = continuation
                lock.unlock()
            }
        }
    }

    /// Drops everything queued or playing; pending `play` calls return. The engine keeps running.
    public func stopAll() {
        lock.lock()
        let dropped = book.dropAll()
        for (_, c) in converters { c.reset() }
        // The node's completions that this stop calls belong to the previous generation: ignored.
        if let player, let engine, engine.isRunning {
            _ = PonteCatchObjC {
                player.stop()
                player.play()
            }
        }
        let resume = dropped.compactMap { finish($0.id) }
        lock.unlock()
        resume.forEach { $0.resume() }
    }

    /// For AudioProbe: stops the running engine the way a device change does (AVAudioEngine stops it,
    /// then posts the notification), to check that the phrase playing is not lost.
    @_spi(Probe) public func simulateDeviceStop() {
        let engine = lock.withLock { self.engine }
        guard let engine else { return }
        _ = PonteCatchObjC { engine.stop() }
        NotificationCenter.default.post(name: .AVAudioEngineConfigurationChange, object: engine)
    }

    // MARK: Phrases

    /// Takes a phrase in. nil = nothing to wait for (empty, refused, or it could not be scheduled).
    private func enqueue(_ buffers: [AVAudioPCMBuffer]) -> UInt64? {
        let input = buffers.filter { $0.frameLength > 0 }
        guard !input.isEmpty else { return nil }
        lock.lock()
        var resume = checkEngineAlive()
        let (id, decision) = book.add(Payload(buffers: input))
        var accepted = true
        switch decision {
        case AudioRules.playerEnqueueSchedule:
            if let phrase = book.phrases.last, phrase.id == id { accepted = schedule(phrase) }
        case AudioRules.playerEnqueueStart:
            resume += startNow()   // a started engine schedules the waiting phrase; a failed one retries
        case AudioRules.playerEnqueueWait:
            PonteDiagnostics.log("player \(name): phrase \(id) waits for the rebuild")
        default:
            accepted = false
            PonteDiagnostics.log("player \(name): phrase \(id) refused, output failed")
        }
        if !accepted, book.remove(id) {
            if let c = finish(id) { resume.append(c) }
        }
        let waits = accepted && book.phrases.contains { $0.id == id }
        let alreadyFinished = finished.contains(id)
        lock.unlock()
        resume.forEach { $0.resume() }
        return waits || alreadyFinished ? id : nil
    }

    /// Lock held. Converts the phrase to the device format if needed (keeping the result for replays) and
    /// schedules it gaplessly after what is queued; the last buffer reports back on `queue`. False when it
    /// cannot be scheduled (the caller completes it).
    private func schedule(_ phrase: PlayerBook<Payload>.Phrase) -> Bool {
        guard let engine, let player, let target = playFormat else { return false }
        var buffers = phrase.payload.buffers
        if !buffers.allSatisfy({ $0.format.isEqual(target) }) {
            do {
                buffers = try convert(buffers)
            } catch {
                _lastError = error
                PonteDiagnostics.log("player \(name): phrase \(phrase.id) conversion FAILED \(error.localizedDescription)")
                return false
            }
            book.update(phrase.id, payload: Payload(buffers: buffers))
        }
        guard !buffers.isEmpty else { return false }
        let position = Self.renderedFrames(player)
        let generation = book.generation
        let id = phrase.id
        var frames: Int64 = 0
        for b in buffers { frames += Int64(b.frameLength) }
        let failure = PonteCatchObjC {
            for (i, b) in buffers.enumerated() {
                if i == buffers.count - 1 {
                    player.scheduleBuffer(b, completionCallbackType: .dataPlayedBack) { [weak self, weak engine, weak player] _ in
                        // Never on AVAudioEngine's thread: a stop may call this while we hold the lock.
                        self?.queue.async { self?.lastBufferDone(id, generation: generation, engine: engine, player: player) }
                    }
                } else {
                    player.scheduleBuffer(b, completionHandler: nil)
                }
            }
        }
        if let failure {
            _lastError = PonteAudioError.engine("schedule on \(name): \(failure)")
            PonteDiagnostics.log("player \(name): phrase \(id) schedule FAILED \(failure)")
            return false
        }
        book.scheduled(id, frames: frames, position: position)
        return true
    }

    /// On `queue`: the completion of a phrase's last buffer, scheduled on `generation` of `engine`.
    private func lastBufferDone(_ id: UInt64, generation: UInt64, engine: AVAudioEngine?, player: AVAudioPlayerNode?) {
        let running = engine?.isRunning ?? false
        let position = player.flatMap(Self.renderedFrames)
        lock.lock()
        var resume: [CheckedContinuation<Void, Never>] = []
        let result = book.completed(id, generation: generation, engineRunning: running, position: position)
        if let done = result.done {
            if result.heard {
                PonteDiagnostics.log("player \(name): phrase \(id) played\(done.cuts > 0 ? " after \(done.cuts) replay(s)" : "")")
            } else {
                PonteDiagnostics.log("player \(name): phrase \(id) dropped after \(done.cuts) cuts")
            }
            if let c = finish(id) { resume.append(c) }
        }
        if result.code == AudioRules.playerCompletionIgnore, result.done == nil, book.phrases.contains(where: { $0.id == id }) {
            PonteDiagnostics.log("player \(name): phrase \(id) completion ignored (\(running ? "old engine" : "engine stopped"))")
            // The system stopped the engine (its notification follows); should none come, look again.
            if !running, let engine, engine === self.engine {
                queue.asyncAfter(deadline: .now() + .milliseconds(Int(AudioRules.restartDelayMs(attempt: 0)))) { [weak self] in
                    guard let self else { return }
                    self.lock.lock()
                    let resume = self.checkEngineAlive()
                    self.lock.unlock()
                    resume.forEach { $0.resume() }
                }
            }
        }
        if let replay = result.replay {
            PonteDiagnostics.log("player \(name): phrase \(id) flushed while the engine ran, re-queued (cut \(replay.cuts))")
            if !schedule(replay), book.remove(id), let c = finish(id) { resume.append(c) }
        }
        lock.unlock()
        resume.forEach { $0.resume() }
    }

    /// Lock held. The phrase is finished: the continuation to resume after unlocking, if one waits.
    private func finish(_ id: UInt64) -> CheckedContinuation<Void, Never>? {
        if let c = waiting.removeValue(forKey: id) { return c }
        finished.insert(id)
        return nil
    }

    // MARK: Engine events

    /// Lock held. A stop that no notification reported (yet) is handled like the notification.
    private func checkEngineAlive() -> [CheckedContinuation<Void, Never>] {
        guard book.state == AudioRules.playerRunning, let engine, !engine.isRunning else { return [] }
        PonteDiagnostics.log("player \(name): engine found stopped")
        return carryOut(book.configurationChanged(engineRunning: false))
    }

    /// Lock held. Starts the engine now (first start).
    private func startNow() -> [CheckedContinuation<Void, Never>] {
        do {
            try startEngine()
            return carryOut(book.started())
        } catch {
            _lastError = error
            PonteDiagnostics.log("player \(name): start FAILED \(error.localizedDescription)")
            return carryOut(book.startFailed())
        }
    }

    /// On `queue`: AVAudioEngineConfigurationChange of `changed`.
    private func configurationChanged(of changed: AVAudioEngine) {
        lock.lock()
        guard changed === engine else {
            lock.unlock()
            return
        }
        let running = changed.isRunning
        let effects = book.configurationChanged(engineRunning: running)
        if effects.action == AudioRules.playerNone {
            // AVAudioEngine also posts this right after its own start, while it keeps running.
            PonteDiagnostics.log("player \(name): configuration change ignored, engine \(running ? "running" : "stopped, rebuild already scheduled")")
        } else {
            PonteDiagnostics.log("player \(name): configuration change, engine stopped")
        }
        let resume = carryOut(effects)
        lock.unlock()
        resume.forEach { $0.resume() }
    }

    /// On `queue`, after the backoff: a new engine replaces the stopped one.
    private func rebuild() {
        lock.lock()
        rebuildWork = nil
        guard book.state == AudioRules.playerRebuilding || book.state == AudioRules.playerFailed else {
            lock.unlock()
            return
        }
        let failuresBefore = book.failures
        tearDown()
        let resume: [CheckedContinuation<Void, Never>]
        do {
            try startEngine()
            PonteDiagnostics.log("player \(name): engine rebuilt after \(failuresBefore) failure(s)")
            resume = carryOut(book.started())
        } catch {
            _lastError = error
            PonteDiagnostics.log("player \(name): rebuild \(failuresBefore + 1) FAILED \(error.localizedDescription)")
            resume = carryOut(book.startFailed())
        }
        lock.unlock()
        resume.forEach { $0.resume() }
    }

    /// Lock held. Carries out what the book decided; returns the continuations to resume after unlocking.
    private func carryOut(_ effects: PlayerBook<Payload>.Effects) -> [CheckedContinuation<Void, Never>] {
        var resume: [CheckedContinuation<Void, Never>] = []
        for phrase in effects.released {
            PonteDiagnostics.log("player \(name): phrase \(phrase.id) dropped (\(phrase.cuts) cuts, state \(book.state))")
            if let c = finish(phrase.id) { resume.append(c) }
        }
        for phrase in effects.requeued {
            PonteDiagnostics.log("player \(name): phrase \(phrase.id) cut by the stop, re-queued (cut \(phrase.cuts))")
        }
        for phrase in effects.schedule {
            if !schedule(phrase), book.remove(phrase.id), let c = finish(phrase.id) { resume.append(c) }
        }
        if let ms = effects.rebuildAfterMs {
            rebuildWork?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.rebuild() }
            rebuildWork = work
            queue.asyncAfter(deadline: .now() + .milliseconds(Int(ms)), execute: work)
            PonteDiagnostics.log("player \(name): rebuild scheduled in \(ms) ms (\(book.phrases.count) phrase(s) waiting)")
        }
        return resume
    }

    // MARK: Engine (lock held)

    private func startEngine() throws {
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        player.volume = _volume
        var thrown: Error?
        var rate: Double = 0
        let raised = PonteCatchObjC {
            do {
                engine.attach(player)
                if let device = self.device {
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
                rate = AudioRules.rateOrDefault(engine.outputNode.outputFormat(forBus: 0).sampleRate)
                engine.connect(player, to: engine.mainMixerNode, format: PCM.monoFormat(sampleRate: rate))
                engine.prepare()
                try engine.start()
                player.play()
            } catch {
                thrown = error
            }
        }
        if raised != nil || thrown != nil {
            _ = PonteCatchObjC {
                player.stop()
                engine.stop()
            }
            if let thrown { throw thrown }
            throw PonteAudioError.engine("start on \(name): \(raised ?? "")")
        }
        self.engine = engine
        self.player = player
        playFormat = PCM.monoFormat(sampleRate: rate)
        converters.removeAll()
        _lastError = nil
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { [weak self, weak engine] _ in
            guard let self, let engine else { return }
            // Never rebuild on the posting thread; hop to our queue first.
            self.queue.async { self.configurationChanged(of: engine) }
        }
        PonteDiagnostics.log("player \(name): running at \(Int(rate)) Hz")
    }

    /// Stops and drops the current engine. Completions its node calls now carry an old generation.
    private func tearDown() {
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
        configObserver = nil
        let player = player, engine = engine
        _ = PonteCatchObjC {
            player?.stop()
            engine?.stop()
        }
        self.engine = nil
        self.player = nil
        playFormat = nil
        converters.removeAll()
    }

    /// Frames the node has rendered on its timeline; nil when it reports none (not playing, no render yet).
    private static func renderedFrames(_ player: AVAudioPlayerNode) -> Int64? {
        var frames: Int64?
        _ = PonteCatchObjC {
            guard let now = player.lastRenderTime, let time = player.playerTime(forNodeTime: now), time.isSampleTimeValid else { return }
            frames = time.sampleTime
        }
        return frames
    }

    /// Converts a phrase to the playback format with a per-input-format stateful resampler; the last
    /// buffer flushes the resampler's tail and resets it for the next phrase.
    private func convert(_ buffers: [AVAudioPCMBuffer]) throws -> [AVAudioPCMBuffer] {
        var out: [AVAudioPCMBuffer] = []
        for (i, b) in buffers.enumerated() {
            let converted = try convert(b, final: AudioRules.flushesConverter(index: i, count: buffers.count, nextFormatDiffers: false))
            if converted.frameLength > 0 { out.append(converted) }
        }
        return out
    }

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
