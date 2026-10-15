// Test oracle, owned by the t27 agent. The Swift AudioRules as it was before its bodies called the C generated from Specs/*.t27.
// Kept verbatim (only renamed) as the reference the differential tests compare the C-backed
// facade with, function by function, bit for bit.

import AVFoundation
import CoreAudio
import Foundation

/// Every pure decision and computation of PonteAudio, in one place.
///
/// Rules for this file (it is mirrored one to one by t27 specs compiled to C; at integration the
/// bodies call the generated C and these Swift versions stay as test oracles):
/// - Only scalars, strings, arrays and raw Float buffers (pointer + count) in and out.
///   No Core Audio / AVFoundation types.
/// - Decisions return Int codes (constants below), not strings.
/// - Deterministic: no clocks, no locale, no randomness. Text matching is ASCII case-folding on UTF-8 bytes.
/// - Floating point: sums of squares accumulate in Double in index order; everything else is Float.
enum AudioRulesLegacy {

    // MARK: - Constants

    /// Chunk length for file/test sources and the probe meter window unit.
    static let chunkSeconds: Double = 0.1
    /// Sample rate used when a device or file reports none.
    static let fallbackSampleRate: Double = 48_000
    /// Floor of `dBFS` (also the value for a level of exactly 0).
    static let dBFSFloor: Float = -120
    /// Below this RMS level (dBFS) a signal counts as "quiet" (level code 1).
    static let quietThresholdDBFS: Float = -60
    /// Extra frames allocated on top of the exact resampled length.
    static let conversionSlackFrames = 1024
    /// Delay before re-reading the HAL process list after a change notification.
    static let reconcileDebounceSeconds: Double = 0.05
    /// UID prefix of Ponte's private tap aggregate devices (hidden from device pickers).
    static let ponteAggregateUIDPrefix = "ai.ponte.tap."
    /// Frames per AVAudioEngine input-tap callback requested by MicSource (a hint); since 2026-10-13 the most
    /// frames one input-unit callback takes, unless the device's I/O cycle is longer.
    static let micTapBufferFrames = 2048
    /// How many parent processes to walk up when looking for a process's owning app.
    static let parentChainMaxDepth = 8
    /// Int16 / Int32 PCM full scale.
    static let int16FullScale: Float = 32_768
    static let int32FullScale: Float = 2_147_483_648

    // MARK: - Audio math: sample conversion, downmix, gain

    static func int16ToFloat(_ v: Int16) -> Float { Float(v) / int16FullScale }
    static func int32ToFloat(_ v: Int32) -> Float { Float(v) / int32FullScale }

    /// Frames in a raw buffer: byteSize / (bytesPerSample * channels); 0 if channels or bytesPerSample ≤ 0.
    static func framesInBuffer(byteSize: Int, channels: Int, bytesPerSample: Int) -> Int {
        guard channels > 0, bytesPerSample > 0 else { return 0 }
        return byteSize / (bytesPerSample * channels)
    }

    /// Adds the per-frame channel sum of an interleaved block to `dst`:
    /// dst[i] += Σ_{c<channels} src[i*channels + c], for i < frames. A planar channel is channels = 1.
    /// Real-time safe (no allocation).
    static func accumulateFrames(_ src: UnsafePointer<Float>, channels: Int, frames: Int,
                                        into dst: UnsafeMutablePointer<Float>) {
        guard channels > 0, frames > 0 else { return }
        if channels == 1 {
            for i in 0..<frames { dst[i] += src[i] }
            return
        }
        for i in 0..<frames {
            var s: Float = 0
            let base = i * channels
            for c in 0..<channels { s += src[base + c] }
            dst[i] += s
        }
    }

    /// Weight that turns a channel sum into an average: 1 / totalChannels (1 when totalChannels ≤ 1).
    static func averageFactor(totalChannels: Int) -> Float {
        totalChannels > 1 ? 1 / Float(totalChannels) : 1
    }

    /// dst[i] *= factor for i < frames. Real-time safe.
    static func scale(_ dst: UnsafeMutablePointer<Float>, frames: Int, by factor: Float) {
        guard factor != 1 else { return }
        for i in 0..<max(0, frames) { dst[i] *= factor }
    }

    /// Mono average of interleaved samples (frames = samples.count / channels, remainder ignored).
    static func downmixInterleaved(_ samples: [Float], channels: Int) -> [Float] {
        guard channels > 0 else { return [] }
        let frames = samples.count / channels
        var out = [Float](repeating: 0, count: frames)
        samples.withUnsafeBufferPointer { src in
            out.withUnsafeMutableBufferPointer { dst in
                guard let s = src.baseAddress, let d = dst.baseAddress else { return }
                accumulateFrames(s, channels: channels, frames: frames, into: d)
                scale(d, frames: frames, by: averageFactor(totalChannels: channels))
            }
        }
        return out
    }

    /// Mono average of planar channels (frames = shortest channel).
    static func downmixPlanar(_ channels: [[Float]]) -> [Float] {
        guard let frames = channels.map(\.count).min(), frames > 0 else { return [] }
        var out = [Float](repeating: 0, count: frames)
        out.withUnsafeMutableBufferPointer { dst in
            for ch in channels {
                ch.withUnsafeBufferPointer { src in accumulateFrames(src.baseAddress!, channels: 1, frames: frames, into: dst.baseAddress!) }
            }
            scale(dst.baseAddress!, frames: frames, by: averageFactor(totalChannels: channels.count))
        }
        return out
    }

    /// Clamps to [lo, hi].
    static func clamp(_ x: Float, _ lo: Float, _ hi: Float) -> Float { min(hi, max(lo, x)) }

    /// Volume / gain setting clamped to 0…1.
    static func clampUnit(_ x: Float) -> Float { clamp(x, 0, 1) }

    /// One sample with gain, hard-clipped to [-1, 1].
    static func gainClip(_ sample: Float, gain: Float) -> Float { clamp(sample * gain, -1, 1) }

    static func applyGain(_ samples: [Float], gain: Float) -> [Float] { samples.map { gainClip($0, gain: gain) } }

    // MARK: - Audio math: levels

    /// sqrt(sumSquares / count) as Float; 0 when count ≤ 0.
    static func rmsFromSum(sumSquares: Double, count: Int) -> Float {
        count > 0 ? Float((sumSquares / Double(count)).squareRoot()) : 0
    }

    /// Root mean square; squares summed in Double in index order.
    static func rms(_ samples: UnsafeBufferPointer<Float>) -> Float {
        var sum: Double = 0
        for s in samples { sum += Double(s) * Double(s) }
        return rmsFromSum(sumSquares: sum, count: samples.count)
    }

    static func rms(_ samples: [Float]) -> Float { samples.withUnsafeBufferPointer { rms($0) } }

    /// Largest absolute sample; 0 for no samples.
    static func peak(_ samples: UnsafeBufferPointer<Float>) -> Float {
        var p: Float = 0
        for s in samples { p = max(p, abs(s)) }
        return p
    }

    static func peak(_ samples: [Float]) -> Float { samples.withUnsafeBufferPointer { peak($0) } }

    /// 20·log10(level), floored at `dBFSFloor`; `dBFSFloor` for level ≤ 0.
    static func dBFS(_ level: Float) -> Float {
        level > 0 ? max(dBFSFloor, 20 * log10(level)) : dBFSFloor
    }

    /// Level codes for status lights and the probe.
    static let levelDigitalSilence = 0   // every sample exactly 0 (no signal at all / no permission)
    static let levelQuiet = 1            // signal present but below quietThresholdDBFS
    static let levelSignal = 2           // audible signal

    static func levelCode(peak: Float, rms: Float) -> Int {
        if peak == 0 { return levelDigitalSilence }
        return dBFS(rms) < quietThresholdDBFS ? levelQuiet : levelSignal
    }

    /// A process tap that delivered frames but only exact zeros: the usual sign of a missing
    /// System Audio Recording permission (or a silent target).
    static func tapSilenceSuspect(totalFrames: Int, peak: Float) -> Bool {
        totalFrames > 0 && peak == 0
    }

    // MARK: - Audio math: rates, chunks, pacing

    /// `rate` if positive, else `fallbackSampleRate`.
    static func rateOrDefault(_ rate: Double) -> Double { rate > 0 ? rate : fallbackSampleRate }

    /// Frames in one chunk: max(1, round(sampleRate · seconds)), rounding half away from zero.
    static func framesPerChunk(sampleRate: Double, seconds: Double = chunkSeconds) -> Int {
        Int(max(1, (sampleRate * seconds).rounded()))
    }

    /// Lengths of consecutive chunks covering `total` frames; the last may be shorter. [] if total ≤ 0 or chunk ≤ 0.
    static func chunkLengths(total: Int, chunk: Int) -> [Int] {
        guard total > 0, chunk > 0 else { return [] }
        return stride(from: 0, to: total, by: chunk).map { min(chunk, total - $0) }
    }

    /// Output capacity for converting `frames` from one rate to another: ceil(frames·to/from) + slack.
    static func conversionCapacity(frames: Int, fromRate: Double, toRate: Double) -> Int {
        guard fromRate > 0, toRate > 0 else { return frames + conversionSlackFrames }
        return Int((Double(frames) * toRate / fromRate).rounded(.up)) + conversionSlackFrames
    }

    static func needsResample(fromRate: Double, toRate: Double) -> Bool { fromRate != toRate }

    /// The resampler must average channels when it reduces the channel count.
    static func converterShouldDownmix(inputChannels: Int, outputChannels: Int) -> Bool {
        inputChannels > outputChannels
    }

    /// The session output rate: fixed at the first attach (fixedRate > 0) and kept afterwards.
    static func sessionRate(fixedRate: Double, tapRate: Double) -> Double { fixedRate > 0 ? fixedRate : tapRate }

    /// Real-time pacing: how long to wait so that a chunk ending at `endFrame` is delivered when its
    /// last sample would have been heard. deadline = start + endFrame/rate seconds; 0 if already past.
    static func pacingSleepNanos(startNanos: UInt64, nowNanos: UInt64, endFrame: Int64, sampleRate: Double) -> UInt64 {
        guard sampleRate > 0, endFrame > 0 else { return 0 }
        let deadline = startNanos + UInt64(Double(endFrame) / sampleRate * 1e9)
        return deadline > nowNanos ? deadline - nowNanos : 0
    }

    /// Player conversion path codes.
    static let convertNone = 0       // identical format: schedule as is
    static let convertDownmix = 1    // same rate: downmix / sample type only
    static let convertResample = 2   // different rate: stateful resampler

    static func conversionPath(sameFormat: Bool, sameRate: Bool) -> Int {
        sameFormat ? convertNone : (sameRate ? convertDownmix : convertResample)
    }

    /// A process-tap stream Ponte can read: linear PCM, float, 32-bit, positive rate.
    static func isUsableTapFormat(isLinearPCM: Bool, isFloat: Bool, bitsPerChannel: Int, sampleRate: Double) -> Bool {
        isLinearPCM && isFloat && bitsPerChannel == 32 && sampleRate > 0
    }

    // MARK: - Process tap lifecycle

    /// What to do after the HAL process list (or the tap format) changed, or at start.
    static let tapKeep = 0           // nothing changed
    static let tapWait = 1           // target app gone: destroy the tap (if any) and wait for it
    static let tapUpdate = 2         // swap the tapped processes on the live tap (no audio gap)
    static let tapRebuild = 3        // destroy (if any) and build a new tap + aggregate

    /// - attached: a tap exists now. desiredCount: processes to tap (to exclude, for system audio).
    /// - sameSet: desired processes equal the attached ones. isGlobal: "all system audio except Ponte".
    /// - force: the tap format changed, or this is the first attach at start.
    /// If `tapUpdate` fails at run time, the caller falls back to `tapRebuild`.
    static func tapAction(attached: Bool, desiredCount: Int, sameSet: Bool, isGlobal: Bool, force: Bool) -> Int {
        if !force && attached && sameSet { return tapKeep }
        let nothingToTap = desiredCount == 0 && !isGlobal
        if !force && !attached && nothingToTap { return tapKeep }
        if nothingToTap { return tapWait }
        if !force && attached { return tapUpdate }
        return tapRebuild
    }

    // MARK: - Microphone permission

    /// AVAuthorizationStatus raw values: 0 notDetermined, 1 restricted, 2 denied, 3 authorized.
    static let micStart = 0          // authorized
    static let micRequestFirst = 1   // not decided: ask (an undecided permission blocks AVAudioEngine)
    static let micDenied = 2         // restricted / denied: only System Settings can fix it

    static func micStartDecision(authorizationStatus: Int) -> Int {
        switch authorizationStatus {
        case 3: return micStart
        case 0: return micRequestFirst
        default: return micDenied
        }
    }

    // MARK: - Rebuilding a capture after a device change (2026-10-13, after the live crash)

    /// MicSource rebuilt its engine inside the configuration-change notification and aborted on a stale
    /// tap format. Now: wait 300 ms, double after each failed rebuild, at most 5 s, retry while running;
    /// after 6 failures in a row report failed.
    static let restartDelayMs: Int64 = 300
    static let restartMaxDelayMs: Int64 = 5_000
    static let restartAttempts: Int64 = 6

    static func restartDelayMs(attempt: Int64) -> Int64 {
        guard attempt > 0 else { return restartDelayMs }
        guard attempt < 5 else { return restartMaxDelayMs }   // 300 << 5 = 9600 > cap
        return min(restartDelayMs << attempt, restartMaxDelayMs)
    }

    static func restartFailed(failures: Int64) -> Bool { failures >= restartAttempts }

    /// installTap(format: nil) takes the bus's format; both it and the device side need a rate and channels.
    static func micTapReady(inputRate: Double, inputChannels: Int, busRate: Double, busChannels: Int) -> Bool {
        inputRate > 0 && inputChannels > 0 && busRate > 0 && busChannels > 0
    }

    // MARK: - The microphone listens to its input device only (2026-10-13, an output change stopped it)

    /// MicSource rebuilt on every AVAudioEngineConfigurationChange that left the engine stopped, and output-side
    /// changes stopped it. Now an input-only unit rebuilds on a failed render, a dead device, a stopped unit, a
    /// changed format, or a new default input it follows.
    static let micEventDefaultInput = 0, micEventAlive = 1, micEventFormat = 2, micEventRunning = 3, micEventRenderFailed = 4

    static func micInputRebuilds(event: Int, followsDefault: Bool, sameDevice: Bool, deviceAlive: Bool,
                                 sameFormat: Bool, unitRunning: Bool) -> Bool {
        guard (micEventDefaultInput...micEventRenderFailed).contains(event) else { return false }
        if event == micEventRenderFailed || !deviceAlive || !unitRunning { return true }
        return event == micEventDefaultInput ? followsDefault && !sameDevice : !sameFormat
    }

    static func micMaxFrames(ioFrames: Int) -> Int { max(ioFrames, micTapBufferFrames) }

    /// MicSource reset its failure count on every change; a render failing before any audio now counts on.
    static func micFailuresAfter(event: Int, delivered: Bool, failures: Int64) -> Int64 {
        guard event == micEventRenderFailed, !delivered else { return 0 }
        return min(max(failures, 0), restartAttempts - 1) + 1
    }

    // MARK: - Own voice (2026-10-13: the microphone straight into the call)

    /// No relay existed. Fill 40 ms, then send as it comes; never more than 80 ms queued ahead of the output;
    /// refill after the output ran dry; while the output is down keep only the newest 40 ms.
    /// A queue that stayed above 50 ms for 50 buffers in a row loses one buffer.
    static let relayTargetMs = 40.0, relayMaxMs = 80.0, relaySlackMs = 10.0, relayWindow = 50
    static let relayKeep = 0, relaySend = 1, relayDrop = 2, relayTrim = 3, relayRefill = 4

    static func relayAction(filling: Bool, pendingMs: Double, queuedMs: Double?, lowMs: Double, lowCount: Int) -> Int {
        guard let queued = queuedMs else { return pendingMs > relayTargetMs ? relayTrim : relayKeep }
        if filling { return pendingMs >= relayTargetMs ? relaySend : relayKeep }
        if queued <= 0 { return relayRefill }
        if queued + pendingMs > relayMaxMs { return relayDrop }
        return relayWindowEnds(lowCount: lowCount) && lowMs > relayTargetMs + relaySlackMs ? relayDrop : relaySend
    }

    static func relayWindowEnds(lowCount: Int) -> Bool { lowCount >= relayWindow }

    static func relayTrims(pendingMs: Double, oldestMs: Double) -> Bool { pendingMs - oldestMs >= relayTargetMs }

    // MARK: - The call output heals itself (2026-10-13, phrases cut by engine stops)

    /// DeviceAudioPlayer rebuilt lazily on the next phrase and completed a phrase cut by a stop as played.
    /// Now: idle → running on a start; a failed start retries with the capture backoff and, after
    /// restartAttempts in a row, completes the waiting phrases; a stop of a running engine cuts what is
    /// scheduled and rebuilds; any other configuration change changes nothing.
    static let playerIdle = 0, playerRunning = 1, playerRebuilding = 2, playerFailed = 3
    static let playerStarted = 0, playerStartFailed = 1, playerChange = 2
    static let playerNone = 0, playerScheduleWaiting = 1, playerRetry = 2, playerRetryRelease = 3, playerCutRetry = 4
    static let playerEnqueueStart = 0, playerEnqueueSchedule = 1, playerEnqueueWait = 2, playerEnqueueRefuse = 3
    static let playerCompletionDone = 0, playerCompletionIgnore = 1, playerCompletionReplay = 2
    static let playerMaxReplays: Int64 = 3
    static let playerEndToleranceFrames: Int64 = 4096

    static func playerStep(state: Int, event: Int, engineRunning: Bool, failures: Int64) -> (state: Int, action: Int) {
        switch event {
        case playerStarted:
            return (playerRunning, playerScheduleWaiting)
        case playerStartFailed:
            return restartFailed(failures: failures) ? (playerFailed, playerRetryRelease) : (playerRebuilding, playerRetry)
        case playerChange where !engineRunning && state == playerRunning:
            return (playerRebuilding, playerCutRetry)
        default:
            return (state, playerNone)
        }
    }

    static func playerEnqueue(state: Int) -> Int {
        switch state {
        case playerRunning: return playerEnqueueSchedule
        case playerRebuilding: return playerEnqueueWait
        case playerFailed: return playerEnqueueRefuse
        default: return playerEnqueueStart
        }
    }

    /// A completion is also called when the node is stopped: heard only from the phrase's own running engine
    /// rendered up to its end; flushed on its own running engine → replay; any other engine → ignore.
    static func playerCompletion(sameGeneration: Bool, engineRunning: Bool, position: Int64?, endFrame: Int64) -> Int {
        guard sameGeneration, engineRunning else { return playerCompletionIgnore }
        guard let position else { return playerCompletionDone }
        return position >= endFrame - playerEndToleranceFrames ? playerCompletionDone : playerCompletionReplay
    }

    static func playerReplays(cuts: Int64) -> Bool { cuts <= playerMaxReplays }

    // MARK: - Devices

    /// Device kind codes.
    static let kindUnknown = 0
    static let kindBuiltInSpeaker = 1
    static let kindBuiltInHeadphones = 2
    static let kindBuiltInMic = 3
    static let kindBlackHole = 4          // virtual mic for the call app
    static let kindBluetooth = 5          // classic and LE
    static let kindUSB = 6
    static let kindDisplay = 7            // HDMI / DisplayPort (monitor speakers)
    static let kindAirPlay = 8
    static let kindAggregate = 9          // user aggregate / multi-output
    static let kindPonteAggregate = 10    // Ponte's own private tap aggregate
    static let kindVirtual = 11           // other virtual drivers (Zoom, Teams, Loopback…)
    static let kindContinuity = 12        // iPhone as mic (Continuity Capture)
    static let kindOtherWired = 13        // PCI, FireWire, Thunderbolt, AVB

    /// Core Audio transport type four-char codes (kAudioDeviceTransportType*), as plain UInt32.
    static let transportBuiltIn: UInt32 = 0x626C_746E      // 'bltn'
    static let transportAggregate: UInt32 = 0x6772_7570    // 'grup'
    static let transportVirtual: UInt32 = 0x7669_7274      // 'virt'
    static let transportPCI: UInt32 = 0x7063_6920          // 'pci '
    static let transportUSB: UInt32 = 0x7573_6220          // 'usb '
    static let transportFireWire: UInt32 = 0x3133_3934     // '1394'
    static let transportBluetooth: UInt32 = 0x626C_7565    // 'blue'
    static let transportBluetoothLE: UInt32 = 0x626C_6561  // 'blea'
    static let transportHDMI: UInt32 = 0x6864_6D69         // 'hdmi'
    static let transportDisplayPort: UInt32 = 0x6470_7274  // 'dprt'
    static let transportAirPlay: UInt32 = 0x6169_7270      // 'airp'
    static let transportAVB: UInt32 = 0x6561_7662          // 'eavb'
    static let transportThunderbolt: UInt32 = 0x7468_756E  // 'thun'
    static let transportContinuityWired: UInt32 = 0x6363_7764     // 'ccwd'
    static let transportContinuityWireless: UInt32 = 0x6363_776C  // 'ccwl'

    /// BlackHole by name: contains "blackhole" (ASCII case-insensitive).
    static func isBlackHole(name: String) -> Bool { containsCI(name, "blackhole") }

    static func isPonteAggregate(uid: String) -> Bool { uid.utf8.starts(with: ponteAggregateUIDPrefix.utf8) }

    /// Classifies a device. Order: Ponte aggregate (uid prefix) → BlackHole (name) → transport type.
    /// Built-in: "headphone" in uid or name → headphones; else output channels > 0 → speaker; else input → mic.
    static func deviceKind(name: String, uid: String, transportType: UInt32,
                                  inputChannels: Int, outputChannels: Int) -> Int {
        if isPonteAggregate(uid: uid) { return kindPonteAggregate }
        if isBlackHole(name: name) { return kindBlackHole }
        switch transportType {
        case transportBuiltIn:
            if containsCI(uid, "headphone") || containsCI(name, "headphone") { return kindBuiltInHeadphones }
            if outputChannels > 0 { return kindBuiltInSpeaker }
            return inputChannels > 0 ? kindBuiltInMic : kindUnknown
        case transportBluetooth, transportBluetoothLE: return kindBluetooth
        case transportUSB: return kindUSB
        case transportHDMI, transportDisplayPort: return kindDisplay
        case transportAirPlay: return kindAirPlay
        case transportAggregate: return kindAggregate
        case transportVirtual: return kindVirtual
        case transportContinuityWired, transportContinuityWireless: return kindContinuity
        case transportPCI, transportFireWire, transportThunderbolt, transportAVB: return kindOtherWired
        default: return kindUnknown
        }
    }

    /// Echo risk of playing the other side's voice on this output (the mic would hear it again).
    static let echoNone = 0      // headphones, virtual devices, mics
    static let echoSpeaker = 1   // a loudspeaker: show "use headphones"
    static let echoMaybe = 2     // cannot tell (Bluetooth, USB, other wired, unknown)

    static func echoRisk(kind: Int) -> Int {
        switch kind {
        case kindBuiltInSpeaker, kindDisplay, kindAirPlay: return echoSpeaker
        case kindBluetooth, kindUSB, kindOtherWired, kindUnknown: return echoMaybe
        default: return echoNone
        }
    }

    /// Never use these as "my microphone" or "my headphones": the call's virtual mic and Ponte's own tap.
    static func isExcludedForMonitoring(kind: Int) -> Bool { kind == kindBlackHole || kind == kindPonteAggregate }

    /// The BlackHole device to play into: among BlackHole devices with output channels, the first whose
    /// name contains "2ch" (ASCII case-insensitive), else the first. -1 if none.
    static func pickBlackHoleIndex(names: [String], outputChannels: [Int]) -> Int {
        let candidates = names.indices.filter { isBlackHole(name: names[$0]) && outputChannels[$0] > 0 }
        return candidates.first { containsCI(names[$0], "2ch") } ?? candidates.first ?? -1
    }

    /// "My microphone": the default input if it has input channels and is not excluded; else the first
    /// built-in mic; else the first non-excluded device with input channels. -1 if none.
    static func pickMicIndex(kinds: [Int], inputChannels: [Int], defaultIndex: Int) -> Int {
        let usable = { (i: Int) in inputChannels[i] > 0 && !isExcludedForMonitoring(kind: kinds[i]) }
        if kinds.indices.contains(defaultIndex), usable(defaultIndex) { return defaultIndex }
        if let i = kinds.indices.first(where: { usable($0) && kinds[$0] == kindBuiltInMic }) { return i }
        return kinds.indices.first(where: usable) ?? -1
    }

    /// Where to play the Russian voice for the owner: the default output if usable; else by kind
    /// priority built-in headphones → Bluetooth → USB → built-in speaker → any other usable. -1 if none.
    static func pickListenOutputIndex(kinds: [Int], outputChannels: [Int], defaultIndex: Int) -> Int {
        let usable = { (i: Int) in outputChannels[i] > 0 && !isExcludedForMonitoring(kind: kinds[i]) }
        if kinds.indices.contains(defaultIndex), usable(defaultIndex) { return defaultIndex }
        for kind in [kindBuiltInHeadphones, kindBluetooth, kindUSB, kindBuiltInSpeaker] {
            if let i = kinds.indices.first(where: { usable($0) && kinds[$0] == kind }) { return i }
        }
        return kinds.indices.first(where: usable) ?? -1
    }

    /// Device lookup: exact UID, then exact name, then name contains query (ASCII case-insensitive). -1 if none.
    static func matchDeviceIndex(query: String, names: [String], uids: [String]) -> Int {
        if let i = uids.firstIndex(of: query) { return i }
        if let i = names.firstIndex(of: query) { return i }
        return names.firstIndex { containsCI($0, query) } ?? -1
    }

    // MARK: - App catalog

    /// Known call apps, sorted by bundle ID; labels are parallel. The app reads only this table.
    static let knownCallAppBundleIDs = [
        "com.apple.FaceTime",
        "com.apple.Safari",
        "com.browseros.BrowserClaw",
        "com.google.Chrome",
        "com.microsoft.teams2",
        "net.whatsapp.WhatsApp",
        "org.telegram.desktop",
        "ru.keepcoder.Telegram",
        "us.zoom.xos",
    ]
    static let knownCallAppLabels = [
        "FaceTime",
        "Safari (Meet)",
        "BrowserOS (Meet)",
        "Chrome (Meet)",
        "Teams",
        "WhatsApp",
        "Telegram Desktop",
        "Telegram",
        "Zoom",
    ]

    /// Index into `knownCallAppBundleIDs` (exact match), or -1.
    static func knownCallAppIndex(bundleID: String) -> Int { knownCallAppBundleIDs.firstIndex(of: bundleID) ?? -1 }

    static func isKnownCallApp(bundleID: String) -> Bool { knownCallAppIndex(bundleID: bundleID) >= 0 }

    /// Processes that carry a call app's audio without belonging to it (parallel arrays: target → process).
    /// FaceTime calls run in avconferenced / callservicesd (TelephonyUtilities). Unverified on a live call.
    static let companionTargetBundleIDs = ["com.apple.FaceTime", "com.apple.FaceTime"]
    static let companionProcessBundleIDs = ["com.apple.avconferenced", "com.apple.TelephonyUtilities"]

    static func isCompanionProcess(processBundleID: String, targetBundleID: String) -> Bool {
        zip(companionTargetBundleIDs, companionProcessBundleIDs).contains { $0 == targetBundleID && $1 == processBundleID }
    }

    /// Does this HAL process belong in a tap of `targetBundleID`? Never Ponte itself.
    /// processBundleID is "" when the HAL reports none.
    static func isTapTargetProcess(processBundleID: String, ownerBundleID: String, targetBundleID: String,
                                          pid: Int32, selfPID: Int32) -> Bool {
        guard pid != selfPID else { return false }
        return ownerBundleID == targetBundleID
            || (!processBundleID.isEmpty && processBundleID == targetBundleID)
            || isCompanionProcess(processBundleID: processBundleID, targetBundleID: targetBundleID)
    }

    /// Helper → parent app by bundle-ID prefix: the index of the longest `appBundleIDs[i]` such that
    /// helperBundleID starts with appBundleIDs[i] + "." (com.google.Chrome.helper → com.google.Chrome). -1 if none.
    static func parentAppIndex(helperBundleID: String, appBundleIDs: [String]) -> Int {
        var best = -1
        var bestLength = -1
        for (i, app) in appBundleIDs.enumerated() where !app.isEmpty {
            let prefix = Array(app.utf8) + [UInt8(ascii: ".")]
            if helperBundleID.utf8.starts(with: prefix), prefix.count > bestLength {
                best = i
                bestLength = prefix.count
            }
        }
        return best
    }

    /// Byte length (UTF-8) of the path up to and including the first component that ends in ".app",
    /// e.g. "/Applications/Google Chrome.app/Contents/…/Helper.app/…" → length of "/Applications/Google Chrome.app".
    /// -1 if no component ends in ".app".
    static func outermostAppPathLength(_ path: String) -> Int {
        let bytes = Array(path.utf8)
        let suffix = Array(".app".utf8)
        var i = 0
        while i + suffix.count <= bytes.count {
            if Array(bytes[i..<(i + suffix.count)]) == suffix {
                let end = i + suffix.count
                let componentStart = bytes[..<i].lastIndex(of: UInt8(ascii: "/")).map { $0 + 1 } ?? 0
                if (end == bytes.count || bytes[end] == UInt8(ascii: "/")) && i > componentStart { return end }
            }
            i += 1
        }
        return -1
    }

    /// Where a process's owning app comes from (first true wins, in this order).
    static let ownerSelf = 1            // the process is itself a regular (Dock) app
    static let ownerAppBundlePath = 2   // outermost .app in its executable path (Chrome/Electron helpers)
    static let ownerResponsible = 3     // its responsible process is an app (WebKit.GPU → Safari; CLI → terminal)
    static let ownerParent = 4          // a regular app among its parent processes
    static let ownerBundlePrefix = 5    // bundle-ID prefix of a running regular app
    static let ownerFallback = 6        // itself (its own bundle ID, or "pid.<n>")

    static func ownerSource(selfIsRegularApp: Bool, hasAppBundlePath: Bool, hasResponsibleApp: Bool,
                                   hasRegularParentApp: Bool, hasPrefixParent: Bool) -> Int {
        if selfIsRegularApp { return ownerSelf }
        if hasAppBundlePath { return ownerAppBundlePath }
        if hasResponsibleApp { return ownerResponsible }
        if hasRegularParentApp { return ownerParent }
        if hasPrefixParent { return ownerBundlePrefix }
        return ownerFallback
    }

    /// Ponte's own process never appears as a source.
    static func isSelfProcess(pid: Int32, ownerPID: Int32, selfPID: Int32) -> Bool {
        pid == selfPID || ownerPID == selfPID
    }

    /// Show an app in the source picker: a Dock app, anything playing now, or a known call app.
    static func shouldListApp(isRegularApp: Bool, isPlaying: Bool, isKnownCallApp: Bool) -> Bool {
        isRegularApp || isPlaying || isKnownCallApp
    }

    /// Picker rank: 0 playing call app, 1 other playing app, 2 idle call app, 3 the rest.
    static func appRank(isKnownCallApp: Bool, isPlaying: Bool) -> Int {
        switch (isKnownCallApp, isPlaying) {
        case (true, true): return 0
        case (false, true): return 1
        case (true, false): return 2
        case (false, false): return 3
        }
    }

    /// Display order: indices sorted by rank, then by name (ASCII case-folded UTF-8 bytes), then by index.
    static func appSortOrder(ranks: [Int], names: [String]) -> [Int] {
        let keys = names.map(foldedBytes)
        return ranks.indices.sorted { a, b in
            if ranks[a] != ranks[b] { return ranks[a] < ranks[b] }
            if keys[a] != keys[b] { return keys[a].lexicographicallyPrecedes(keys[b]) }
            return a < b
        }
    }

    // MARK: - Text helpers (ASCII case folding on UTF-8 bytes)

    /// UTF-8 bytes with A–Z mapped to a–z; other bytes unchanged.
    static func foldedBytes(_ s: String) -> [UInt8] {
        s.utf8.map { ($0 >= 65 && $0 <= 90) ? $0 + 32 : $0 }
    }

    /// `haystack` contains `needle`, ASCII case-insensitive. An empty needle matches.
    static func containsCI(_ haystack: String, _ needle: String) -> Bool {
        let h = foldedBytes(haystack), n = foldedBytes(needle)
        guard !n.isEmpty else { return true }
        guard n.count <= h.count else { return false }
        for i in 0...(h.count - n.count) where h[i] == n[0] {
            if Array(h[i..<(i + n.count)]) == n { return true }
        }
        return false
    }
}

// MARK: - Decisions extracted unchanged from PonteAudio and PonteApp before they moved to t27 (2026-10-11)

extension AudioRulesLegacy {
    /// TranslationLane AudioIntake.handle, SetupWizardView CaptureMeter.add.
    static func hasSignal(peak: Float, rms: Float) -> Bool { levelCode(peak: peak, rms: rms) != levelDigitalSilence }

    /// AppAudioTapSource.build / updateTapProcesses: `isGlobal ? [] : pids`, mixdown unless global.
    static func tapListsProcesses(isGlobal: Bool) -> Bool { !isGlobal }
    /// AppAudioTapSource.build: `.unmuted` for all Mac audio or when the owner hears them, else `.mutedWhenTapped`.
    static func tapMuteBehavior(isGlobal: Bool, hearOriginal: Bool) -> Int {
        isGlobal || hearOriginal ? CATapMuteBehavior.unmuted.rawValue : CATapMuteBehavior.mutedWhenTapped.rawValue
    }

    /// WAVFileSink.play `i == input.count - 1 || nextDiffers`; DeviceAudioPlayer.schedule `i == input.count - 1`.
    static func flushesConverter(index: Int, count: Int, nextFormatDiffers: Bool) -> Bool { index == count - 1 || nextFormatDiffers }

    /// PCM.downmixFloat32: `b.mData != nil && b.mNumberChannels > 0`.
    static func usesBuffer(hasData: Bool, channels: Int) -> Bool { hasData && channels > 0 }

    /// PCM.downmixFloat32: frames of the buffers that take part, capped at maxFrames.
    static func bufferListFrames(byteSizes: [Int], channels: [Int], maxFrames: Int) -> Int {
        var frames = Int.max
        var totalChannels = 0
        for (size, c) in zip(byteSizes, channels) {
            frames = min(frames, framesInBuffer(byteSize: size, channels: c, bytesPerSample: MemoryLayout<Float>.size))
            totalChannels += c
        }
        guard totalChannels > 0, frames != Int.max else { return 0 }
        return min(frames, maxFrames)
    }

    static func bufferListChannels(_ channels: [Int]) -> Int { channels.reduce(0, +) }

    /// PCM.mono.
    static func monoBlocks(interleaved: Bool, channels: Int) -> Int { interleaved ? 1 : channels }
    static func monoPerBlock(interleaved: Bool, channels: Int) -> Int { interleaved ? channels : 1 }
    static func monoSupported(format: Int) -> Bool {
        guard format >= 0, let f = AVAudioCommonFormat(rawValue: UInt(format)) else { return false }
        switch f {
        case .pcmFormatFloat32, .pcmFormatInt16, .pcmFormatInt32: return true
        default: return false
        }
    }

    /// PCM.isMonoFloat32 and PCM.samples.
    static func isMonoFloat32(format: Int, channels: Int) -> Bool { format == Int(AVAudioCommonFormat.pcmFormatFloat32.rawValue) && channels == 1 }
    static func isPlainMono(format: Int, channels: Int, interleaved: Bool) -> Bool { isMonoFloat32(format: format, channels: channels) && !interleaved }

    /// PCM.Converter.convert input block.
    static func converterInput(supplied: Bool, final: Bool) -> Int {
        (supplied ? (final ? AVAudioConverterInputStatus.endOfStream : .noDataNow) : .haveData).rawValue
    }

    /// HAL.fourCC.
    static func isPrintableFourCC(_ value: UInt32) -> Bool {
        let bytes = [24, 16, 8, 0].map { UInt8((value >> UInt32($0)) & 0xFF) }
        return bytes.allSatisfy { $0 >= 32 && $0 < 127 }
    }

    /// Components.LevelMeter (before the CGFloat conversion).
    static func meterFraction(level: Float) -> Float { min(1, max(0, (20 * log10(max(level, 1e-5)) + 60) / 60)) }

    /// AudioProcesses.resolveOwner: `"pid.\(pid)"`.
    static let pidOwnerPrefix = "pid."
    static func isRegularApp(policyRegular: Bool, hasBundleID: Bool) -> Bool { policyRegular && hasBundleID }
    static func isProcessPID(_ pid: Int32) -> Bool { pid > 0 }
    static func responsibleUsable(responsiblePID rpid: Int32, pid: Int32) -> Bool { rpid != pid && rpid > 1 }
    static func parentContinues(parentPID ppid: Int32, current: Int32) -> Bool { ppid > 1 && ppid != current }
    /// `halBundleID ?? selfApp?.bundleIdentifier ?? "pid.<n>"`.
    static func ownerIDSource(hasHALBundleID: Bool, hasAppBundleID: Bool) -> Int { hasHALBundleID ? 0 : (hasAppBundleID ? 1 : 2) }
    /// `selfApp?.localizedName ?? path?.lastPathComponent ?? bid`.
    static func ownerNameSource(hasAppName: Bool, hasPath: Bool) -> Int { hasAppName ? 0 : (hasPath ? 1 : 2) }
    /// `running?.localizedName ?? CFBundleDisplayName ?? CFBundleName ?? file name`.
    static func bundleNameSource(hasRunningName: Bool, hasDisplayName: Bool, hasBundleName: Bool) -> Int {
        hasRunningName ? 0 : (hasDisplayName ? 1 : (hasBundleName ? 2 : 3))
    }
    /// `(running?.activationPolicy ?? selfApp?.activationPolicy) == .regular`.
    static func pathOwnerIsRegular(hasRunning: Bool, runningRegular: Bool, hasSelf: Bool, selfRegular: Bool) -> Bool {
        hasRunning ? runningRegular : (hasSelf ? selfRegular : false)
    }
    /// RunningAudioAppCatalog.group.
    static func appPlaying(alreadyPlaying: Bool, processPlaying: Bool) -> Bool { alreadyPlaying || processPlaying }
    static func prefersOwner(candidateRegular: Bool, currentRegular: Bool) -> Bool { candidateRegular && !currentRegular }
    /// AppModel.refreshSpeakerWarning: `echoRisk == echoSpeaker`.
    static func needsHeadphones(kind: Int) -> Bool { echoRisk(kind: kind) == echoSpeaker }

    // MARK: - The checklist «Перед звонком» (2026-10-13; written for device_rules.t27, mirrored here)

    static let readerPonte = 0
    static let readerCall = 1
    static let readerOther = 2
    static let useNone = 0
    static let useCallBlackHole = 1
    static let useOtherBlackHole = 2
    static let useCallRealMic = 3
    static let listenUnknown = 0
    static let listenOK = 1
    static let listenNobody = 2
    static let listenRealMic = 3
    static let listenBoth = 4
    static let listenNoBlackHole = 5
    static let ponteBundleID = "app.ponte.translator"

    private static func sameBytes(_ a: String, _ b: String) -> Bool { Array(a.utf8) == Array(b.utf8) }

    static func isPonteID(_ bundleID: String) -> Bool { sameBytes(bundleID, ponteBundleID) }

    /// Ponte (this process or any Ponte); with a chosen app, its own processes and companions; with all Mac
    /// audio, any known call app; else another program.
    static func readerRole(ownerBundleID: String, targetBundleID: String?, pid: Int32, selfPID: Int32) -> Int {
        if pid == selfPID || isPonteID(ownerBundleID) { return readerPonte }
        if let target = targetBundleID {
            let companion = zip(companionTargetBundleIDs, companionProcessBundleIDs).contains {
                sameBytes($0, target) && sameBytes($1, ownerBundleID)
            }
            return sameBytes(ownerBundleID, target) || companion ? readerCall : readerOther
        }
        return knownCallAppBundleIDs.contains { sameBytes($0, ownerBundleID) } ? readerCall : readerOther
    }

    static func isRealMicKind(_ kind: Int) -> Bool {
        ![kindBlackHole, kindPonteAggregate, kindVirtual, kindAggregate].contains(kind)
    }

    static func readerUse(role: Int, kind: Int, runningInput: Bool) -> Int {
        guard runningInput, role != readerPonte else { return useNone }
        if kind == kindBlackHole { return role == readerCall ? useCallBlackHole : useOtherBlackHole }
        return role == readerCall && isRealMicKind(kind) ? useCallRealMic : useNone
    }

    static func listenStatus(uses: [Int], listed: Bool, blackHolePresent: Bool) -> Int {
        guard blackHolePresent else { return listenNoBlackHole }
        guard listed else { return listenUnknown }
        let callBlackHole = uses.contains(useCallBlackHole)
        if uses.contains(useCallRealMic) { return callBlackHole ? listenBoth : listenRealMic }
        return callBlackHole || uses.contains(useOtherBlackHole) ? listenOK : listenNobody
    }

    static func listenIndex(uses: [Int]) -> Int {
        uses.firstIndex(of: useCallRealMic) ?? uses.firstIndex(of: useCallBlackHole) ?? uses.firstIndex(of: useOtherBlackHole) ?? -1
    }

    static func isHeadphonesLike(kind: Int) -> Bool { [kindBuiltInHeadphones, kindBluetooth, kindUSB].contains(kind) }
    /// The mic is the listening headset's own: same kind and (jack, or same name), on a headphones-like output.
    static func micIsOutputHeadset(names: [String], kinds: [Int], micIndex: Int, outputIndex: Int) -> Bool {
        let n = min(kinds.count, 256)
        guard micIndex >= 0, outputIndex >= 0, micIndex < n, outputIndex < n, isHeadphonesLike(kind: kinds[outputIndex]) else { return false }
        if micIndex == outputIndex { return true }
        guard kinds[micIndex] == kinds[outputIndex] else { return false }
        if kinds[micIndex] == kindBuiltInHeadphones { return true }
        return names[micIndex] == names[outputIndex]
    }
    /// Never the call's virtual mic or Ponte's tap.
    static func outputNeedsRescue(kind: Int) -> Bool { kind == kindBlackHole || kind == kindPonteAggregate }
    static func pickRescueOutputIndex(kinds: [Int], outputChannels: [Int], selectable: [Bool]) -> Int {
        func usable(_ i: Int) -> Bool { outputChannels[i] > 0 && !outputNeedsRescue(kind: kinds[i]) && selectable[i] }
        for kind in [kindBuiltInHeadphones, kindBluetooth, kindUSB, kindBuiltInSpeaker] {
            if let i = kinds.indices.first(where: { kinds[$0] == kind && usable($0) }) { return i }
        }
        return kinds.indices.first(where: usable) ?? -1
    }

    /// «Звук Meet»: a selectable output with channels, never BlackHole or Ponte's tap.
    static func isHearOutput(kind: Int, outputChannels: Int, selectable: Bool) -> Bool {
        selectable && outputChannels > 0 && kind != kindBlackHole && kind != kindPonteAggregate
    }

    /// The headset's own microphone when the listening output is headphones-like; else the built-in microphone;
    /// else the first real one. Never BlackHole, Ponte's tap or an iPhone.
    static func pickAutoMicIndex(names: [String], kinds: [Int], inputChannels: [Int], outputIndex: Int) -> Int {
        let allowed = { (i: Int) in inputChannels[i] > 0 && !isExcludedForMonitoring(kind: kinds[i]) && kinds[i] != kindContinuity }
        if kinds.indices.contains(outputIndex), isHeadphonesLike(kind: kinds[outputIndex]) {
            let headset = kinds.indices.first { i in
                allowed(i) && (i == outputIndex || (kinds[i] == kinds[outputIndex]
                    && (kinds[i] == kindBuiltInHeadphones || sameBytes(names[i], names[outputIndex]))))
            }
            if let headset { return headset }
        }
        if let i = kinds.indices.first(where: { allowed($0) && kinds[$0] == kindBuiltInMic }) { return i }
        return kinds.indices.first { allowed($0) && isRealMicKind(kinds[$0]) } ?? -1
    }

    // MARK: Moved out of Swift 2026-10-15 (LiveRelay, DeviceAudioPlayer, MicSource, AppAudioTapSource)

    /// `if !filling, let queued { lowMs = min; lowCount += 1 } else { reset }`.
    static func relaySamplesLow(filling: Bool, hasQueued: Bool) -> Bool { !filling && hasQueued }
    /// send: `filling = false` / `true` when refused; trim, refill: `filling = true`.
    static func relayFillingAfter(action: Int, sent: Bool, filling: Bool) -> Bool {
        switch action {
        case 1: return !sent
        case 3, 4: return true
        default: return filling
        }
    }
    static func relayCanTrim(count: Int) -> Bool { count > 1 }
    /// wrongOutputDevice: `read == noErr, current != 0, current != live.id`, then after 1 s
    /// `!outputs.isEmpty, !outputs.contains(device)`.
    static func outputMisplaced(unitDevice: Int?, ourDevice: Int, msSinceStart: Int64, outputs: Int, outputsIncludeOurs: Bool) -> Int {
        if let current = unitDevice, current != 0, current != ourDevice { return 1 }
        if msSinceStart >= 1000, outputs > 0, !outputsIncludeOurs { return 2 }
        return 0
    }
    static func unitBindsBeforeStart(unitDevice: Int?, ourDevice: Int) -> Bool { unitDevice.map { $0 != ourDevice } ?? true }
    static func unitRebindsAfterStart(unitDevice: Int?, ourDevice: Int) -> Bool { unitDevice.map { $0 != ourDevice } ?? false }
    static func streamEnd(_ streamEnd: Int64, position: Int64, frames: Int64) -> Int64 { max(streamEnd, position) + frames }
    static func playerCanRebuild(state: Int) -> Bool { state == 2 || state == 3 }
    static func playerRechecks(ignored: Bool, finished: Bool, stillPending: Bool, engineRunning: Bool, sameEngine: Bool) -> Bool {
        ignored && !finished && stillPending && !engineRunning && sameEngine
    }
    static func rebuildFailuresNext(_ failures: Int64) -> Int64 { failures < 0 ? 1 : (failures >= 1 << 62 ? failures : failures + 1) }
    static func micSliceFrames(ioFrames: Int, hintFrames: Int) -> Int { micMaxFrames(ioFrames: max(ioFrames, hintFrames)) }
    static func micCycleFits(frames: Int, capacity: Int) -> Bool { frames > 0 && frames <= capacity }
    /// `case tapUpdate where updateTapProcesses(..): return; default: rebuild`.
    static func tapRebuilds(action: Int, updated: Bool) -> Bool { action == 3 || (action == 2 && !updated) }

    // MARK: Devices moved out of Swift 2026-10-15 (AppModel, CoreAudioDeviceCatalog)

    /// `headphonesDevice ?? defaultOutput`: 0 the headphones, 1 the system output.
    static func ears(headphonesConnected: Bool) -> Int { headphonesConnected ? 0 : 1 }
    static func isInput(channels: Int) -> Bool { channels > 0 }
    static func isOutput(channels: Int) -> Bool { channels > 0 }
    /// `inputChannels > 0 && !isBlackHole(name:)`.
    static func isMicChoice(inputChannels: Int, isBlackHole: Bool) -> Bool { inputChannels > 0 && !isBlackHole }
}
