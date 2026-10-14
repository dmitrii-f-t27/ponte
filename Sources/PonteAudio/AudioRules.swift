import CoreAudio
import Foundation
import PonteSpecs

/// Every pure decision and computation of PonteAudio, in one place.
///
/// The decisions are written in t27 (`Specs/audio_rules.t27`, `Specs/device_rules.t27`) and compiled to C
/// (`Sources/PonteSpecs`). This facade only marshals: it copies Float buffers into the fixed blocks the C
/// takes (`AU_BLOCK_FRAMES` mono samples, `AU_BLOCK_SAMPLES` interleaved or planar samples), packs strings
/// into one UTF-8 buffer with offset/length tables (`DV_TEXT_MAX` bytes, `DV_LIST_MAX` entries), and turns
/// the C codes back into Swift values. Constants come from the C `#define`s. The Swift that used to be
/// here is the test oracle `AudioRulesLegacy` (Tests/PonteTests/Oracles); the differential tests compare
/// both bit for bit.
///
/// Domains: a planar downmix takes at most `AU_PLANAR_MAX_CHANNELS` channels; strings and lists that do not
/// fit the text buffer are cut (device names, UIDs, bundle IDs and paths fit by far).
public enum AudioRules {

    // MARK: - Constants

    /// Chunk length for file/test sources and the probe meter window unit.
    public static let chunkSeconds: Double = AU_CHUNK_SECONDS
    /// Sample rate used when a device or file reports none.
    public static let fallbackSampleRate: Double = AU_FALLBACK_SAMPLE_RATE
    /// Floor of `dBFS` (also the value for a level of exactly 0).
    public static let dBFSFloor = Float(AU_DBFS_FLOOR)
    /// Below this RMS level (dBFS) a signal counts as "quiet" (level code 1).
    public static let quietThresholdDBFS = Float(AU_QUIET_THRESHOLD_DBFS)
    /// Extra frames allocated on top of the exact resampled length.
    public static let conversionSlackFrames = Int(AU_CONVERSION_SLACK_FRAMES)
    /// Delay before re-reading the HAL process list after a change notification.
    public static let reconcileDebounceSeconds: Double = AU_RECONCILE_DEBOUNCE_SECONDS
    /// UID prefix of Ponte's private tap aggregate devices (hidden from device pickers).
    public static let ponteAggregateUIDPrefix = DeviceText.row(Int64(DV_ROW_PONTE_PREFIX))
    /// The most frames one MicSource callback takes, unless the device's I/O cycle is longer.
    public static let micTapBufferFrames = Int(AU_MIC_TAP_BUFFER_FRAMES)
    /// How many parent processes to walk up when looking for a process's owning app.
    public static let parentChainMaxDepth = Int(DV_PARENT_CHAIN_MAX_DEPTH)
    /// Int16 / Int32 PCM full scale.
    public static let int16FullScale = Float(AU_INT16_FULL_SCALE)
    public static let int32FullScale = Float(AU_INT32_FULL_SCALE)

    private static let blockFrames = Int(AU_BLOCK_FRAMES)
    private static let blockSamples = Int(AU_BLOCK_SAMPLES)
    private static let planarMaxChannels = Int(AU_PLANAR_MAX_CHANNELS)

    // MARK: - Audio math: sample conversion, downmix, gain

    public static func int16ToFloat(_ v: Int16) -> Float { au_int16_to_float(v) }
    public static func int32ToFloat(_ v: Int32) -> Float { au_int32_to_float(v) }

    /// Frames in a raw buffer: byteSize / (bytesPerSample * channels); 0 if channels or bytesPerSample ≤ 0.
    public static func framesInBuffer(byteSize: Int, channels: Int, bytesPerSample: Int) -> Int {
        Int(au_frames_in_buffer(Int64(byteSize), Int64(channels), Int64(bytesPerSample)))
    }

    /// Adds the per-frame channel sum of an interleaved block to `dst`:
    /// dst[i] += Σ_{c<channels} src[i*channels + c], for i < frames. A planar channel is channels = 1.
    public static func accumulateFrames(_ src: UnsafePointer<Float>, channels: Int, frames: Int,
                                        into dst: UnsafeMutablePointer<Float>) {
        var srcBlock = [Float](repeating: 0, count: blockSamples)
        var dstBlock = [Float](repeating: 0, count: blockFrames)
        var done = 0
        while true {
            let n = Int(au_block_frames_for(Int64(channels), Int64(frames - done)))
            if n <= 0 { return }
            srcBlock.withUnsafeMutableBufferPointer { $0.baseAddress!.update(from: src + done * channels, count: n * channels) }
            dstBlock.withUnsafeMutableBufferPointer { $0.baseAddress!.update(from: dst + done, count: n) }
            _ = au_accumulate_frames(&srcBlock, Int64(channels), Int64(n), &dstBlock)
            dstBlock.withUnsafeBufferPointer { (dst + done).update(from: $0.baseAddress!, count: n) }
            done += n
        }
    }

    /// Weight that turns a channel sum into an average: 1 / totalChannels (1 when totalChannels ≤ 1).
    public static func averageFactor(totalChannels: Int) -> Float {
        au_average_factor(Int64(totalChannels))
    }

    /// dst[i] *= factor for i < frames.
    public static func scale(_ dst: UnsafeMutablePointer<Float>, frames: Int, by factor: Float) {
        var block = [Float](repeating: 0, count: blockFrames)
        var done = 0
        while true {
            let n = Int(au_fit(Int64(frames - done), Int64(blockFrames)))
            if n <= 0 { return }
            block.withUnsafeMutableBufferPointer { $0.baseAddress!.update(from: dst + done, count: n) }
            if au_scale(&block, Int64(n), factor) == 0 { return }   // factor 1: nothing changes
            block.withUnsafeBufferPointer { (dst + done).update(from: $0.baseAddress!, count: n) }
            done += n
        }
    }

    /// Mono average of interleaved samples (frames = samples.count / channels, remainder ignored).
    public static func downmixInterleaved(_ samples: [Float], channels: Int) -> [Float] {
        let frames = Int(au_interleaved_frames(Int64(samples.count), Int64(channels)))
        var out = [Float](repeating: 0, count: frames)
        var input = [Float](repeating: 0, count: blockSamples)
        var output = [Float](repeating: 0, count: blockFrames)
        var done = 0
        while true {
            let n = Int(au_block_frames_for(Int64(channels), Int64(frames - done)))
            if n <= 0 { break }
            let start = done * channels
            input.replaceSubrange(0..<(n * channels), with: samples[start..<(start + n * channels)])
            let written = Int(au_downmix_interleaved(&input, Int64(n * channels), Int64(channels), &output))
            out.replaceSubrange(done..<(done + written), with: output[0..<written])
            done += n
        }
        return out
    }

    /// Mono average of planar channels (frames = shortest channel).
    public static func downmixPlanar(_ channels: [[Float]]) -> [Float] {
        var lengths = [Int64](repeating: 0, count: planarMaxChannels)
        for (c, ch) in channels.prefix(planarMaxChannels).enumerated() { lengths[c] = Int64(ch.count) }
        let frames = Int(au_planar_frames(&lengths, Int64(channels.count)))
        var out = [Float](repeating: 0, count: frames)
        var planar = [Float](repeating: 0, count: blockSamples)
        var output = [Float](repeating: 0, count: blockFrames)
        var done = 0
        while true {
            let n = Int(au_block_frames_for(Int64(channels.count), Int64(frames - done)))
            if n <= 0 { break }
            var blockLengths = [Int64](repeating: 0, count: planarMaxChannels)
            for (c, ch) in channels.enumerated() {
                planar.replaceSubrange((c * n)..<((c + 1) * n), with: ch[done..<(done + n)])
                blockLengths[c] = Int64(n)
            }
            let written = Int(au_downmix_planar(&planar, &blockLengths, Int64(channels.count), &output))
            out.replaceSubrange(done..<(done + written), with: output[0..<written])
            done += n
        }
        return out
    }

    /// Clamps to [lo, hi].
    public static func clamp(_ x: Float, _ lo: Float, _ hi: Float) -> Float { au_clamp(x, lo, hi) }

    /// Volume / gain setting clamped to 0…1.
    public static func clampUnit(_ x: Float) -> Float { au_clamp_unit(x) }

    /// One sample with gain, hard-clipped to [-1, 1].
    public static func gainClip(_ sample: Float, gain: Float) -> Float { au_gain_clip(sample, gain) }

    public static func applyGain(_ samples: [Float], gain: Float) -> [Float] {
        var out = samples
        var block = [Float](repeating: 0, count: blockFrames)
        var done = 0
        while true {
            let n = Int(au_fit(Int64(samples.count - done), Int64(blockFrames)))
            if n <= 0 { break }
            block.replaceSubrange(0..<n, with: samples[done..<(done + n)])
            _ = au_apply_gain(&block, Int64(n), gain)
            out.replaceSubrange(done..<(done + n), with: block[0..<n])
            done += n
        }
        return out
    }

    // MARK: - Audio math: levels

    /// sqrt(sumSquares / count) as Float; 0 when count ≤ 0.
    public static func rmsFromSum(sumSquares: Double, count: Int) -> Float {
        au_rms_from_sum(sumSquares, Int64(count))
    }

    /// Root mean square; squares summed in Double in index order.
    public static func rms(_ samples: UnsafeBufferPointer<Float>) -> Float {
        var block = [Float](repeating: 0, count: blockFrames)
        var sum: Double = 0
        var done = 0
        while let base = samples.baseAddress {
            let n = Int(au_fit(Int64(samples.count - done), Int64(blockFrames)))
            if n <= 0 { break }
            block.withUnsafeMutableBufferPointer { $0.baseAddress!.update(from: base + done, count: n) }
            sum = au_sum_squares_continue(&block, Int64(n), sum)
            done += n
        }
        return au_rms_from_sum(sum, Int64(samples.count))
    }

    public static func rms(_ samples: [Float]) -> Float { samples.withUnsafeBufferPointer { rms($0) } }

    /// Largest absolute sample; 0 for no samples.
    public static func peak(_ samples: UnsafeBufferPointer<Float>) -> Float {
        var block = [Float](repeating: 0, count: blockFrames)
        var p = au_peak(&block, 0)
        var done = 0
        while let base = samples.baseAddress {
            let n = Int(au_fit(Int64(samples.count - done), Int64(blockFrames)))
            if n <= 0 { break }
            block.withUnsafeMutableBufferPointer { $0.baseAddress!.update(from: base + done, count: n) }
            p = au_peak_continue(&block, Int64(n), p)
            done += n
        }
        return p
    }

    public static func peak(_ samples: [Float]) -> Float { samples.withUnsafeBufferPointer { peak($0) } }

    /// 20·log10(level), floored at `dBFSFloor`; `dBFSFloor` for level ≤ 0.
    public static func dBFS(_ level: Float) -> Float { au_dbfs(level) }

    /// Level codes for status lights and the probe.
    public static let levelDigitalSilence = Int(AU_LEVEL_DIGITAL_SILENCE)   // every sample exactly 0
    public static let levelQuiet = Int(AU_LEVEL_QUIET)                      // below quietThresholdDBFS
    public static let levelSignal = Int(AU_LEVEL_SIGNAL)                    // audible signal

    public static func levelCode(peak: Float, rms: Float) -> Int { Int(au_level_code(peak, rms)) }

    /// A process tap that delivered frames but only exact zeros: the usual sign of a missing
    /// System Audio Recording permission (or a silent target).
    public static func tapSilenceSuspect(totalFrames: Int, peak: Float) -> Bool {
        au_tap_silence_suspect(Int64(totalFrames), peak)
    }

    // MARK: - Audio math: rates, chunks, pacing

    /// `rate` if positive, else `fallbackSampleRate`.
    public static func rateOrDefault(_ rate: Double) -> Double { au_rate_or_default(rate) }

    /// Frames in one chunk: max(1, round(sampleRate · seconds)), rounding half away from zero.
    public static func framesPerChunk(sampleRate: Double, seconds: Double = chunkSeconds) -> Int {
        Int(au_frames_per_chunk(sampleRate, seconds))
    }

    /// Lengths of consecutive chunks covering `total` frames; the last may be shorter. [] if total ≤ 0 or chunk ≤ 0.
    public static func chunkLengths(total: Int, chunk: Int) -> [Int] {
        let count = au_chunk_count(Int64(total), Int64(chunk))
        return (0..<count).map { Int(au_chunk_length(Int64(total), Int64(chunk), $0)) }
    }

    /// Output capacity for converting `frames` from one rate to another: ceil(frames·to/from) + slack.
    public static func conversionCapacity(frames: Int, fromRate: Double, toRate: Double) -> Int {
        Int(au_conversion_capacity(Int64(frames), fromRate, toRate))
    }

    public static func needsResample(fromRate: Double, toRate: Double) -> Bool { au_needs_resample(fromRate, toRate) }

    /// The resampler must average channels when it reduces the channel count.
    public static func converterShouldDownmix(inputChannels: Int, outputChannels: Int) -> Bool {
        au_converter_should_downmix(Int64(inputChannels), Int64(outputChannels))
    }

    /// The session output rate: fixed at the first attach (fixedRate > 0) and kept afterwards.
    public static func sessionRate(fixedRate: Double, tapRate: Double) -> Double { au_session_rate(fixedRate, tapRate) }

    /// Real-time pacing: how long to wait so that a chunk ending at `endFrame` is delivered when its
    /// last sample would have been heard. deadline = start + endFrame/rate seconds; 0 if already past.
    public static func pacingSleepNanos(startNanos: UInt64, nowNanos: UInt64, endFrame: Int64, sampleRate: Double) -> UInt64 {
        au_pacing_sleep_nanos(startNanos, nowNanos, endFrame, sampleRate)
    }

    /// Player conversion path codes.
    public static let convertNone = Int(AU_CONVERT_NONE)           // identical format: schedule as is
    public static let convertDownmix = Int(AU_CONVERT_DOWNMIX)     // same rate: downmix / sample type only
    public static let convertResample = Int(AU_CONVERT_RESAMPLE)   // different rate: stateful resampler

    public static func conversionPath(sameFormat: Bool, sameRate: Bool) -> Int {
        Int(au_conversion_path(sameFormat, sameRate))
    }

    /// A process-tap stream Ponte can read: linear PCM, float, 32-bit, positive rate.
    public static func isUsableTapFormat(isLinearPCM: Bool, isFloat: Bool, bitsPerChannel: Int, sampleRate: Double) -> Bool {
        au_is_usable_tap_format(isLinearPCM, isFloat, Int64(bitsPerChannel), sampleRate)
    }

    // MARK: - Process tap lifecycle

    /// What to do after the HAL process list (or the tap format) changed, or at start.
    public static let tapKeep = Int(AU_TAP_KEEP)           // nothing changed
    public static let tapWait = Int(AU_TAP_WAIT)           // target app gone: destroy the tap (if any) and wait
    public static let tapUpdate = Int(AU_TAP_UPDATE)       // swap the tapped processes on the live tap
    public static let tapRebuild = Int(AU_TAP_REBUILD)     // destroy (if any) and build a new tap + aggregate

    /// If `tapUpdate` fails at run time, the caller falls back to `tapRebuild`.
    public static func tapAction(attached: Bool, desiredCount: Int, sameSet: Bool, isGlobal: Bool, force: Bool) -> Int {
        Int(au_tap_action(attached, Int64(desiredCount), sameSet, isGlobal, force))
    }

    // MARK: - Microphone permission

    /// AVAuthorizationStatus raw values: 0 notDetermined, 1 restricted, 2 denied, 3 authorized.
    public static let micStart = Int(AU_MIC_START)                 // authorized
    public static let micRequestFirst = Int(AU_MIC_REQUEST_FIRST)  // not decided: ask first
    public static let micDenied = Int(AU_MIC_DENIED)               // restricted / denied

    public static func micStartDecision(authorizationStatus: Int) -> Int {
        Int(au_mic_start_decision(Int64(authorizationStatus)))
    }

    // MARK: - Rebuilding a capture after a device change

    /// First wait after a configuration change, and the longest wait of the backoff.
    public static let restartDelayMs = Int64(AU_RESTART_DELAY_MS)
    public static let restartMaxDelayMs = Int64(AU_RESTART_MAX_DELAY_MS)
    /// Failed rebuilds in a row after which a source reports itself failed (it keeps retrying).
    public static let restartAttempts = Int64(AU_RESTART_ATTEMPTS)

    /// Wait before rebuild number `attempt` (0 = the first after the change).
    public static func restartDelayMs(attempt: Int64) -> Int64 { au_restart_delay_ms(attempt) }

    /// After `failures` failed rebuilds in a row the source reports failed.
    public static func restartFailed(failures: Int64) -> Bool { au_restart_failed(failures) }

    /// A microphone tap goes in only when the device side and the tap's bus both have a rate and channels.
    public static func micTapReady(inputRate: Double, inputChannels: Int, busRate: Double, busChannels: Int) -> Bool {
        au_mic_tap_ready(inputRate, Int64(inputChannels), busRate, Int64(busChannels))
    }

    // MARK: - The microphone listens to its input device only (MicSource)

    /// What MicSource hears: the default input, the device's alive flag, its format, the unit's running flag
    /// changed; a render failed.
    public static let micEventDefaultInput = Int(AU_MEV_DEFAULT_INPUT)
    public static let micEventAlive = Int(AU_MEV_ALIVE)
    public static let micEventFormat = Int(AU_MEV_FORMAT)
    public static let micEventRunning = Int(AU_MEV_RUNNING)
    public static let micEventRenderFailed = Int(AU_MEV_RENDER_FAILED)

    /// Whether an input-side event rebuilds the capture (output-side changes never reach MicSource).
    public static func micInputRebuilds(event: Int, followsDefault: Bool, sameDevice: Bool, deviceAlive: Bool,
                                        sameFormat: Bool, unitRunning: Bool) -> Bool {
        au_mic_input_rebuilds(Int64(event), followsDefault, sameDevice, deviceAlive, sameFormat, unitRunning)
    }

    /// The failure count after an input event that rebuilds: a render that failed before any audio was
    /// delivered is one more failed start; anything else starts again from 0.
    public static func micFailuresAfter(event: Int, delivered: Bool, failures: Int64) -> Int64 {
        au_mic_failures_after(Int64(event), delivered, failures)
    }

    /// The input unit's slice: the larger of micTapBufferFrames and the device's I/O buffer.
    public static func micMaxFrames(ioFrames: Int) -> Int { Int(au_mic_max_frames(Int64(ioFrames))) }

    // MARK: - Own voice: the microphone straight into the call (LiveRelay)

    /// The jitter buffer filled before forwarding starts, and the most the output may still have to play.
    public static let relayTargetMs: Double = AU_RELAY_TARGET_MS
    public static let relayMaxMs: Double = AU_RELAY_MAX_MS
    /// A queue that stayed above relayTargetMs + relaySlackMs for relayWindow buffers loses one buffer.
    public static let relaySlackMs: Double = AU_RELAY_SLACK_MS
    public static let relayWindow = Int(AU_RELAY_WINDOW)
    /// Relay actions: keep in the jitter buffer, send everything kept, drop this buffer, keep only the newest
    /// relayTargetMs, fill the jitter buffer again.
    public static let relayKeep = Int(AU_RLA_KEEP)
    public static let relaySend = Int(AU_RLA_SEND)
    public static let relayDrop = Int(AU_RLA_DROP)
    public static let relayTrim = Int(AU_RLA_TRIM)
    public static let relayRefill = Int(AU_RLA_REFILL)

    /// What the relay does with a new buffer (`pendingMs` includes it; `queuedMs`: what the output still has
    /// to play, nil when the output is not running; `lowMs`, `lowCount`: the lowest queuedMs of the current
    /// window and the buffers it has seen).
    public static func relayAction(filling: Bool, pendingMs: Double, queuedMs: Double?, lowMs: Double, lowCount: Int) -> Int {
        Int(au_relay_action(filling, pendingMs, queuedMs ?? 0, queuedMs != nil, lowMs, Int64(lowCount)))
    }

    /// A window of relayWindow buffers is complete.
    public static func relayWindowEnds(lowCount: Int) -> Bool { au_relay_window_ends(Int64(lowCount)) }

    /// While trimming, the oldest buffer goes as long as relayTargetMs stay without it.
    public static func relayTrims(pendingMs: Double, oldestMs: Double) -> Bool { au_relay_trims(pendingMs, oldestMs) }

    // MARK: - The call output heals itself (DeviceAudioPlayer)

    /// Player states: no engine yet, running, stopped with a rebuild scheduled, rebuilds failing.
    public static let playerIdle = Int(AU_PL_IDLE)
    public static let playerRunning = Int(AU_PL_RUNNING)
    public static let playerRebuilding = Int(AU_PL_REBUILDING)
    public static let playerFailed = Int(AU_PL_FAILED)
    /// Player events: the engine started, a start failed, a configuration change arrived.
    public static let playerStarted = Int(AU_PLE_STARTED)
    public static let playerStartFailed = Int(AU_PLE_START_FAILED)
    public static let playerChange = Int(AU_PLE_CHANGE)
    /// Player actions.
    public static let playerNone = Int(AU_PLA_NONE)
    public static let playerScheduleWaiting = Int(AU_PLA_SCHEDULE_WAITING)   // the engine runs: schedule the waiting phrases
    public static let playerRetry = Int(AU_PLA_RETRY)                        // rebuild after restartDelayMs(failures)
    public static let playerRetryRelease = Int(AU_PLA_RETRY_RELEASE)         // the same, and complete the waiting phrases
    public static let playerCutRetry = Int(AU_PLA_CUT_RETRY)                 // cut what is scheduled, then rebuild
    /// What a new phrase does.
    public static let playerEnqueueStart = Int(AU_PLQ_START)
    public static let playerEnqueueSchedule = Int(AU_PLQ_SCHEDULE)
    public static let playerEnqueueWait = Int(AU_PLQ_WAIT)
    public static let playerEnqueueRefuse = Int(AU_PLQ_REFUSE)
    /// What the completion of a phrase's last buffer means: heard; from an engine that is gone or stopped
    /// (the cut and the rebuild take care of it); flushed on its own running engine (replay it now).
    public static let playerCompletionDone = Int(AU_PLC_DONE)
    public static let playerCompletionIgnore = Int(AU_PLC_IGNORE)
    public static let playerCompletionReplay = Int(AU_PLC_REPLAY)
    /// A cut phrase is played again from its start at most this many times.
    public static let playerMaxReplays = Int64(AU_PLAYER_MAX_REPLAYS)
    /// Frames short of a phrase's end that still count as played back.
    public static let playerEndToleranceFrames = Int64(AU_PLAYER_END_TOLERANCE_FRAMES)

    /// The state and the action after `event` (`failures`: failed starts in a row including this one;
    /// `engineRunning`: the engine's isRunning when a configuration change arrived).
    public static func playerStep(state: Int, event: Int, engineRunning: Bool, failures: Int64) -> (state: Int, action: Int) {
        let step = au_player_step(Int64(state), Int64(event), engineRunning, failures)
        return (Int(au_player_step_state(step)), Int(au_player_step_action(step)))
    }

    /// What a new phrase does in `state`.
    public static func playerEnqueue(state: Int) -> Int { Int(au_player_enqueue(Int64(state))) }

    /// What the completion of a phrase's last buffer means (`position`: frames the player node has rendered,
    /// nil when it reports none; `endFrame`: where the phrase ends on the node's timeline).
    public static func playerCompletion(sameGeneration: Bool, engineRunning: Bool, position: Int64?, endFrame: Int64) -> Int {
        Int(au_player_completion(sameGeneration, engineRunning, position != nil, position ?? 0, endFrame))
    }

    /// A phrase cut `cuts` times (this one included) is played again from its start.
    public static func playerReplays(cuts: Int64) -> Bool { au_player_replays(cuts) }

    // MARK: - Devices

    /// Device kind codes.
    public static let kindUnknown = Int(DV_KIND_UNKNOWN)
    public static let kindBuiltInSpeaker = Int(DV_KIND_BUILT_IN_SPEAKER)
    public static let kindBuiltInHeadphones = Int(DV_KIND_BUILT_IN_HEADPHONES)
    public static let kindBuiltInMic = Int(DV_KIND_BUILT_IN_MIC)
    public static let kindBlackHole = Int(DV_KIND_BLACKHOLE)                // virtual mic for the call app
    public static let kindBluetooth = Int(DV_KIND_BLUETOOTH)                // classic and LE
    public static let kindUSB = Int(DV_KIND_USB)
    public static let kindDisplay = Int(DV_KIND_DISPLAY)                    // HDMI / DisplayPort
    public static let kindAirPlay = Int(DV_KIND_AIRPLAY)
    public static let kindAggregate = Int(DV_KIND_AGGREGATE)                // user aggregate / multi-output
    public static let kindPonteAggregate = Int(DV_KIND_PONTE_AGGREGATE)     // Ponte's own tap aggregate
    public static let kindVirtual = Int(DV_KIND_VIRTUAL)                    // other virtual drivers
    public static let kindContinuity = Int(DV_KIND_CONTINUITY)              // iPhone as mic
    public static let kindOtherWired = Int(DV_KIND_OTHER_WIRED)             // PCI, FireWire, Thunderbolt, AVB

    /// Core Audio transport type four-char codes (kAudioDeviceTransportType*), as plain UInt32.
    public static let transportBuiltIn = UInt32(DV_TRANSPORT_BUILT_IN)
    public static let transportAggregate = UInt32(DV_TRANSPORT_AGGREGATE)
    public static let transportVirtual = UInt32(DV_TRANSPORT_VIRTUAL)
    public static let transportPCI = UInt32(DV_TRANSPORT_PCI)
    public static let transportUSB = UInt32(DV_TRANSPORT_USB)
    public static let transportFireWire = UInt32(DV_TRANSPORT_FIREWIRE)
    public static let transportBluetooth = UInt32(DV_TRANSPORT_BLUETOOTH)
    public static let transportBluetoothLE = UInt32(DV_TRANSPORT_BLUETOOTH_LE)
    public static let transportHDMI = UInt32(DV_TRANSPORT_HDMI)
    public static let transportDisplayPort = UInt32(DV_TRANSPORT_DISPLAYPORT)
    public static let transportAirPlay = UInt32(DV_TRANSPORT_AIRPLAY)
    public static let transportAVB = UInt32(DV_TRANSPORT_AVB)
    public static let transportThunderbolt = UInt32(DV_TRANSPORT_THUNDERBOLT)
    public static let transportContinuityWired = UInt32(DV_TRANSPORT_CONTINUITY_WIRED)
    public static let transportContinuityWireless = UInt32(DV_TRANSPORT_CONTINUITY_WIRELESS)

    /// BlackHole by name: contains "blackhole" (ASCII case-insensitive).
    public static func isBlackHole(name: String) -> Bool {
        var t = DeviceText([name])
        return dv_is_blackhole(&t.bytes, t.off(0), t.len(0))
    }

    public static func isPonteAggregate(uid: String) -> Bool {
        var t = DeviceText([uid])
        return dv_is_ponte_aggregate(&t.bytes, t.off(0), t.len(0))
    }

    /// Classifies a device. Order: Ponte aggregate (uid prefix) → BlackHole (name) → transport type.
    /// Built-in: "headphone" in uid or name → headphones; else output channels > 0 → speaker; else input → mic.
    public static func deviceKind(name: String, uid: String, transportType: UInt32,
                                  inputChannels: Int, outputChannels: Int) -> Int {
        var t = DeviceText([name, uid])
        return Int(dv_device_kind(&t.bytes, t.off(0), t.len(0), t.off(1), t.len(1), transportType,
                                  Int64(inputChannels), Int64(outputChannels)))
    }

    /// Echo risk of playing the other side's voice on this output (the mic would hear it again).
    public static let echoNone = Int(DV_ECHO_NONE)          // headphones, virtual devices, mics
    public static let echoSpeaker = Int(DV_ECHO_SPEAKER)    // a loudspeaker: show "use headphones"
    public static let echoMaybe = Int(DV_ECHO_MAYBE)        // cannot tell (Bluetooth, USB, other wired, unknown)

    public static func echoRisk(kind: Int) -> Int { Int(dv_echo_risk(Int64(kind))) }

    /// Never use these as "my microphone" or "my headphones": the call's virtual mic and Ponte's own tap.
    public static func isExcludedForMonitoring(kind: Int) -> Bool { dv_is_excluded_for_monitoring(Int64(kind)) }

    /// The BlackHole device to play into: among BlackHole devices with output channels, the first whose
    /// name contains "2ch" (ASCII case-insensitive), else the first. -1 if none.
    public static func pickBlackHoleIndex(names: [String], outputChannels: [Int]) -> Int {
        var t = DeviceText(names)
        var outputs = DeviceText.list(outputChannels)
        return Int(dv_pick_blackhole_index(&t.bytes, &t.offsets, &t.lengths, &outputs, t.count))
    }

    /// "My microphone": the default input if it has input channels and is not excluded; else the first
    /// built-in mic; else the first non-excluded device with input channels. -1 if none.
    public static func pickMicIndex(kinds: [Int], inputChannels: [Int], defaultIndex: Int) -> Int {
        var k = DeviceText.list(kinds)
        var inputs = DeviceText.list(inputChannels)
        return Int(dv_pick_mic_index(&k, &inputs, DeviceText.listCount(kinds.count), Int64(defaultIndex)))
    }

    /// Where to play the Russian voice for the owner: the default output if usable; else by kind
    /// priority built-in headphones → Bluetooth → USB → built-in speaker → any other usable. -1 if none.
    public static func pickListenOutputIndex(kinds: [Int], outputChannels: [Int], defaultIndex: Int) -> Int {
        var k = DeviceText.list(kinds)
        var outputs = DeviceText.list(outputChannels)
        return Int(dv_pick_listen_output_index(&k, &outputs, DeviceText.listCount(kinds.count), Int64(defaultIndex)))
    }

    /// Device lookup: exact UID, then exact name, then name contains query (ASCII case-insensitive). -1 if none.
    public static func matchDeviceIndex(query: String, names: [String], uids: [String]) -> Int {
        var t = DeviceText([query] + names + uids)
        let n = names.count
        var nameOffsets = DeviceText.slots(t.offsets, from: 1, count: n)
        var nameLengths = DeviceText.slots(t.lengths, from: 1, count: n)
        var uidOffsets = DeviceText.slots(t.offsets, from: 1 + n, count: uids.count)
        var uidLengths = DeviceText.slots(t.lengths, from: 1 + n, count: uids.count)
        return Int(dv_match_device_index(&t.bytes, t.off(0), t.len(0), &nameOffsets, &nameLengths,
                                         &uidOffsets, &uidLengths, DeviceText.listCount(n)))
    }

    // MARK: - App catalog

    /// Known call apps, sorted by bundle ID; labels are parallel. Must equal AudioApp.knownCallApps.
    public static let knownCallAppBundleIDs: [String] = (0..<Int64(DV_CALL_APPS)).map { i in
        DeviceText.bytes { dv_call_app_bundle_id(i, $0) }
    }
    public static let knownCallAppLabels: [String] = (0..<Int64(DV_CALL_APPS)).map { i in
        DeviceText.bytes { dv_call_app_label(i, $0) }
    }

    /// Index into `knownCallAppBundleIDs` (exact match), or -1.
    public static func knownCallAppIndex(bundleID: String) -> Int {
        var t = DeviceText([bundleID])
        return Int(dv_known_call_app_index(&t.bytes, t.off(0), t.len(0)))
    }

    public static func isKnownCallApp(bundleID: String) -> Bool {
        var t = DeviceText([bundleID])
        return dv_is_known_call_app(&t.bytes, t.off(0), t.len(0))
    }

    /// Processes that carry a call app's audio without belonging to it (parallel arrays: target → process).
    /// FaceTime calls run in avconferenced / callservicesd (TelephonyUtilities). Unverified on a live call.
    public static let companionTargetBundleIDs: [String] = (0..<Int64(DV_COMPANIONS)).map { i in
        DeviceText.row(Int64(DV_ROW_FIRST_COMPANION_TARGET) + i)
    }
    public static let companionProcessBundleIDs: [String] = (0..<Int64(DV_COMPANIONS)).map { i in
        DeviceText.row(Int64(DV_ROW_FIRST_COMPANION_PROCESS) + i)
    }

    public static func isCompanionProcess(processBundleID: String, targetBundleID: String) -> Bool {
        var t = DeviceText([processBundleID, targetBundleID])
        return dv_is_companion_process(&t.bytes, t.off(0), t.len(0), t.off(1), t.len(1))
    }

    /// Does this HAL process belong in a tap of `targetBundleID`? Never Ponte itself.
    /// processBundleID is "" when the HAL reports none.
    public static func isTapTargetProcess(processBundleID: String, ownerBundleID: String, targetBundleID: String,
                                          pid: Int32, selfPID: Int32) -> Bool {
        var t = DeviceText([processBundleID, ownerBundleID, targetBundleID])
        return dv_is_tap_target_process(&t.bytes, t.off(0), t.len(0), t.off(1), t.len(1), t.off(2), t.len(2), pid, selfPID)
    }

    /// Helper → parent app by bundle-ID prefix: the index of the longest `appBundleIDs[i]` such that
    /// helperBundleID starts with appBundleIDs[i] + "." (com.google.Chrome.helper → com.google.Chrome). -1 if none.
    public static func parentAppIndex(helperBundleID: String, appBundleIDs: [String]) -> Int {
        var t = DeviceText([helperBundleID] + appBundleIDs)
        var offsets = DeviceText.slots(t.offsets, from: 1, count: appBundleIDs.count)
        var lengths = DeviceText.slots(t.lengths, from: 1, count: appBundleIDs.count)
        return Int(dv_parent_app_index(&t.bytes, t.off(0), t.len(0), &offsets, &lengths,
                                       DeviceText.listCount(appBundleIDs.count)))
    }

    /// Byte length (UTF-8) of the path up to and including the first component that ends in ".app",
    /// e.g. "/Applications/Google Chrome.app/Contents/…/Helper.app/…" → length of "/Applications/Google Chrome.app".
    /// -1 if no component ends in ".app".
    public static func outermostAppPathLength(_ path: String) -> Int {
        var t = DeviceText([path])
        return Int(dv_outermost_app_path_length(&t.bytes, t.off(0), t.len(0)))
    }

    /// Where a process's owning app comes from (first true wins, in this order).
    public static let ownerSelf = Int(DV_OWNER_SELF)                    // itself a regular (Dock) app
    public static let ownerAppBundlePath = Int(DV_OWNER_APP_BUNDLE_PATH) // outermost .app in its executable path
    public static let ownerResponsible = Int(DV_OWNER_RESPONSIBLE)      // its responsible process is an app
    public static let ownerParent = Int(DV_OWNER_PARENT)                // a regular app among its parents
    public static let ownerBundlePrefix = Int(DV_OWNER_BUNDLE_PREFIX)   // bundle-ID prefix of a running app
    public static let ownerFallback = Int(DV_OWNER_FALLBACK)            // itself

    public static func ownerSource(selfIsRegularApp: Bool, hasAppBundlePath: Bool, hasResponsibleApp: Bool,
                                   hasRegularParentApp: Bool, hasPrefixParent: Bool) -> Int {
        Int(dv_owner_source(selfIsRegularApp, hasAppBundlePath, hasResponsibleApp, hasRegularParentApp, hasPrefixParent))
    }

    /// Ponte's own process never appears as a source.
    public static func isSelfProcess(pid: Int32, ownerPID: Int32, selfPID: Int32) -> Bool {
        dv_is_self_process(pid, ownerPID, selfPID)
    }

    /// Show an app in the source picker: a Dock app, anything playing now, or a known call app.
    public static func shouldListApp(isRegularApp: Bool, isPlaying: Bool, isKnownCallApp: Bool) -> Bool {
        dv_should_list_app(isRegularApp, isPlaying, isKnownCallApp)
    }

    /// Picker rank: 0 playing call app, 1 other playing app, 2 idle call app, 3 the rest.
    public static func appRank(isKnownCallApp: Bool, isPlaying: Bool) -> Int {
        Int(dv_app_rank(isKnownCallApp, isPlaying))
    }

    /// Display order: indices sorted by rank, then by name (ASCII case-folded UTF-8 bytes), then by index.
    public static func appSortOrder(ranks: [Int], names: [String]) -> [Int] {
        var r = DeviceText.list(ranks)
        var t = DeviceText(names)
        var order = [Int64](repeating: 0, count: DeviceText.listMax)
        let n = Int(dv_app_sort_order(&r, &t.bytes, &t.offsets, &t.lengths, DeviceText.listCount(ranks.count), &order))
        return order[0..<n].map { Int($0) }
    }

    // MARK: - Text helpers (ASCII case folding on UTF-8 bytes)

    /// UTF-8 bytes with A–Z mapped to a–z; other bytes unchanged.
    public static func foldedBytes(_ s: String) -> [UInt8] {
        let all = Array(s.utf8)
        var result: [UInt8] = []
        result.reserveCapacity(all.count)
        var block = [UInt8](repeating: 0, count: DeviceText.textMax)
        var out = [UInt8](repeating: 0, count: DeviceText.textMax)
        var done = 0
        while done < all.count {
            let n = min(all.count - done, DeviceText.textMax)
            block.replaceSubrange(0..<n, with: all[done..<(done + n)])
            let written = Int(dv_folded_bytes(&block, 0, Int64(n), &out))
            result += out[0..<written]
            done += n
        }
        return result
    }

    /// `haystack` contains `needle`, ASCII case-insensitive. An empty needle matches.
    public static func containsCI(_ haystack: String, _ needle: String) -> Bool {
        var t = DeviceText([haystack, needle])
        return dv_contains_ci(&t.bytes, t.off(0), t.len(0), t.off(1), t.len(1))
    }

    // MARK: - Rules moved here from the rest of PonteAudio and the app

    /// AVAudioCommonFormat raw values the PCM rules tell apart.
    public static let formatOther = Int(AU_FORMAT_OTHER)
    public static let formatFloat32 = Int(AU_FORMAT_FLOAT32)
    public static let formatFloat64 = Int(AU_FORMAT_FLOAT64)
    public static let formatInt16 = Int(AU_FORMAT_INT16)
    public static let formatInt32 = Int(AU_FORMAT_INT32)
    /// AVAudioConverterInputStatus raw values.
    public static let inputHaveData = Int(AU_INPUT_HAVE_DATA)
    public static let inputNoDataNow = Int(AU_INPUT_NO_DATA_NOW)
    public static let inputEndOfStream = Int(AU_INPUT_END_OF_STREAM)

    /// A buffer with any non-zero sample (lanes, the wizard's capture check).
    public static func hasSignal(peak: Float, rms: Float) -> Bool { au_has_signal(peak, rms) }

    /// A tap of one app lists (mixes down) its processes; the global tap excludes them and reports no PIDs.
    public static func tapListsProcesses(isGlobal: Bool) -> Bool { au_tap_lists_processes(isGlobal) }

    /// CATapMuteBehavior raw value for the tap: muted while tapped for one app unless the owner wants to hear it.
    public static let tapMuteUnmuted = Int(AU_TAP_MUTE_UNMUTED)
    public static let tapMuteWhenTapped = Int(AU_TAP_MUTE_WHEN_TAPPED)
    public static func tapMuteBehavior(isGlobal: Bool, hearOriginal: Bool) -> Int {
        Int(au_tap_mute_behavior(isGlobal, hearOriginal))
    }

    /// The resampler flushes at the last buffer of a play call or before a buffer of another format.
    public static func flushesConverter(index: Int, count: Int, nextFormatDiffers: Bool) -> Bool {
        au_flushes_converter(Int64(index), Int64(count), nextFormatDiffers)
    }

    /// A buffer of an AudioBufferList takes part in the downmix.
    public static func usesBuffer(hasData: Bool, channels: Int) -> Bool { au_uses_buffer(hasData, Int64(channels)) }

    /// Frames of the downmix of the buffers that take part (at most `AU_BUFFER_LIST_MAX` of them).
    public static func bufferListFrames(byteSizes: [Int], channels: [Int], maxFrames: Int) -> Int {
        var sizes = bufferList(byteSizes)
        var counts = bufferList(channels)
        return Int(au_buffer_list_frames(&sizes, &counts, Int64(min(byteSizes.count, channels.count)), Int64(maxFrames)))
    }

    /// All channels of the buffers that take part.
    public static func bufferListChannels(_ channels: [Int]) -> Int {
        var counts = bufferList(channels)
        return Int(au_buffer_list_channels(&counts, Int64(channels.count)))
    }

    /// The downmix shape (frames, channels) of a raw AudioBufferList, read in place. Real-time safe: the
    /// tables live on the stack and only the first `AU_BUFFER_LIST_MAX` buffers that take part count.
    static func bufferListShape(_ buffers: UnsafeMutableAudioBufferListPointer, maxFrames: Int) -> (frames: Int, channels: Int) {
        let capacity = Int(AU_BUFFER_LIST_MAX)
        return withUnsafeTemporaryAllocation(of: Int64.self, capacity: capacity) { sizes in
            withUnsafeTemporaryAllocation(of: Int64.self, capacity: capacity) { counts in
                sizes.initialize(repeating: 0)
                counts.initialize(repeating: 0)
                var n = 0
                for b in buffers where n < capacity && usesBuffer(hasData: b.mData != nil, channels: Int(b.mNumberChannels)) {
                    sizes[n] = Int64(b.mDataByteSize)
                    counts[n] = Int64(b.mNumberChannels)
                    n += 1
                }
                let frames = au_buffer_list_frames(sizes.baseAddress!, counts.baseAddress!, Int64(n), Int64(maxFrames))
                let channels = au_buffer_list_channels(counts.baseAddress!, Int64(n))
                return (Int(frames), Int(channels))
            }
        }
    }

    /// The most buffers of one AudioBufferList the downmix reads.
    static let bufferListMax = Int(AU_BUFFER_LIST_MAX)

    private static func bufferList(_ values: [Int]) -> [Int64] {
        var out = [Int64](repeating: 0, count: Int(AU_BUFFER_LIST_MAX))
        for (i, v) in values.prefix(out.count).enumerated() { out[i] = Int64(v) }
        return out
    }

    /// PCM.mono: blocks of interleaved (one) or planar (one per channel) data, and channels per block.
    public static func monoBlocks(interleaved: Bool, channels: Int) -> Int { Int(au_mono_blocks(interleaved, Int64(channels))) }
    public static func monoPerBlock(interleaved: Bool, channels: Int) -> Int { Int(au_mono_per_block(interleaved, Int64(channels))) }

    /// PCM.mono reads these sample formats (AVAudioCommonFormat raw values).
    public static func monoSupported(format: Int) -> Bool { au_mono_supported(Int64(format)) }

    public static func isMonoFloat32(format: Int, channels: Int) -> Bool { au_is_mono_float32(Int64(format), Int64(channels)) }

    /// A deinterleaved mono Float32 buffer is read as it is; anything else through the downmix.
    public static func isPlainMono(format: Int, channels: Int, interleaved: Bool) -> Bool {
        au_is_plain_mono(Int64(format), Int64(channels), interleaved)
    }

    /// PCM.Converter input status (AVAudioConverterInputStatus raw value).
    public static func converterInput(supplied: Bool, final: Bool) -> Int { Int(au_converter_input(supplied, final)) }

    /// A four-char code shown as text: every byte printable ASCII.
    public static func isPrintableFourCC(_ code: UInt32) -> Bool { au_fourcc_printable(code) }

    /// The level meter's fill for an RMS level: -60…0 dBFS mapped to 0…1.
    public static func meterFraction(level: Float) -> Float { au_meter_fraction(level) }

    /// Owner ID of a process without a bundle ID: this prefix and the PID.
    public static let pidOwnerPrefix = DeviceText.row(Int64(DV_ROW_PID_PREFIX))

    public static func isRegularApp(policyRegular: Bool, hasBundleID: Bool) -> Bool { dv_is_regular_app(policyRegular, hasBundleID) }
    public static func isProcessPID(_ pid: Int32) -> Bool { dv_process_pid_valid(pid) }
    public static func responsibleUsable(responsiblePID: Int32, pid: Int32) -> Bool { dv_responsible_usable(responsiblePID, pid) }
    public static func parentContinues(parentPID: Int32, current: Int32) -> Bool { dv_parent_continues(parentPID, current) }

    /// Where a process's owner ID comes from.
    public static let ownerIDFromHAL = Int(DV_ID_HAL)
    public static let ownerIDFromApp = Int(DV_ID_APP)
    public static let ownerIDFromPID = Int(DV_ID_PID)
    public static func ownerIDSource(hasHALBundleID: Bool, hasAppBundleID: Bool) -> Int {
        Int(dv_owner_id_source(hasHALBundleID, hasAppBundleID))
    }

    /// Where a process owner's name comes from.
    public static let ownerNameFromApp = Int(DV_NAME_APP)
    public static let ownerNameFromPath = Int(DV_NAME_PATH)
    public static let ownerNameFromID = Int(DV_NAME_ID)
    public static func ownerNameSource(hasAppName: Bool, hasPath: Bool) -> Int { Int(dv_owner_name_source(hasAppName, hasPath)) }

    /// The name of an app found by its bundle path.
    public static let bundleNameRunning = Int(DV_BUNDLE_NAME_RUNNING)
    public static let bundleNameDisplay = Int(DV_BUNDLE_NAME_DISPLAY)
    public static let bundleNameBundle = Int(DV_BUNDLE_NAME_BUNDLE)
    public static let bundleNameFile = Int(DV_BUNDLE_NAME_FILE)
    public static func bundleNameSource(hasRunningName: Bool, hasDisplayName: Bool, hasBundleName: Bool) -> Int {
        Int(dv_bundle_name_source(hasRunningName, hasDisplayName, hasBundleName))
    }

    public static func pathOwnerIsRegular(hasRunning: Bool, runningRegular: Bool, hasSelf: Bool, selfRegular: Bool) -> Bool {
        dv_path_owner_regular(hasRunning, runningRegular, hasSelf, selfRegular)
    }

    public static func appPlaying(alreadyPlaying: Bool, processPlaying: Bool) -> Bool { dv_app_playing(alreadyPlaying, processPlaying) }
    public static func prefersOwner(candidateRegular: Bool, currentRegular: Bool) -> Bool { dv_prefers_owner(candidateRegular, currentRegular) }

    /// Listening on a loudspeaker: show «наденьте наушники».
    public static func needsHeadphones(kind: Int) -> Bool { dv_needs_headphones(Int64(kind)) }

    // MARK: - The checklist «Перед звонком»: who listens to BlackHole, headphones, Ponte's microphone

    /// The role of a process that reads an input device.
    public static let readerPonte = Int(DV_READER_PONTE)      // this process, or any instance of Ponte
    public static let readerCall = Int(DV_READER_CALL)        // the call app (the chosen source)
    public static let readerOther = Int(DV_READER_OTHER)

    /// What one (process, input device) pair means for the call.
    public static let useNone = Int(DV_USE_NONE)
    public static let useCallBlackHole = Int(DV_USE_CALL_BLACKHOLE)
    public static let useOtherBlackHole = Int(DV_USE_OTHER_BLACKHOLE)
    public static let useCallRealMic = Int(DV_USE_CALL_REAL_MIC)

    /// Who listens to BlackHole.
    public static let listenUnknown = Int(DV_LISTEN_UNKNOWN)          // the process list could not be read
    public static let listenOK = Int(DV_LISTEN_OK)                    // a program other than Ponte reads BlackHole
    public static let listenNobody = Int(DV_LISTEN_NOBODY)
    public static let listenRealMic = Int(DV_LISTEN_REAL_MIC)         // the call app reads a real mic, not BlackHole
    public static let listenBoth = Int(DV_LISTEN_BOTH)                // the call app reads BlackHole and a real mic
    public static let listenNoBlackHole = Int(DV_LISTEN_NO_BLACKHOLE) // BlackHole is not installed

    /// Ponte's own bundle ID (exact bytes).
    public static func isPonteID(_ bundleID: String) -> Bool {
        var t = DeviceText([bundleID])
        return dv_is_ponte_id(&t.bytes, t.off(0), t.len(0))
    }

    /// The role of a process reading an input. `targetBundleID` nil: all Mac audio is the source.
    public static func readerRole(ownerBundleID: String, targetBundleID: String?, pid: Int32, selfPID: Int32) -> Int {
        var t = DeviceText([ownerBundleID, targetBundleID ?? ""])
        return Int(dv_reader_role(&t.bytes, t.off(0), t.len(0), t.off(1), t.len(1), targetBundleID != nil, pid, selfPID))
    }

    /// A device a person speaks into (not BlackHole, Ponte's tap, other virtual drivers or aggregates).
    public static func isRealMicKind(_ kind: Int) -> Bool { dv_is_real_mic_kind(Int64(kind)) }

    public static func readerUse(role: Int, kind: Int, runningInput: Bool) -> Int {
        Int(dv_reader_use(Int64(role), Int64(kind), runningInput))
    }

    /// `listed`: the HAL process list was read.
    public static func listenStatus(uses: [Int], listed: Bool, blackHolePresent: Bool) -> Int {
        var u = DeviceText.list(uses)
        return Int(dv_listen_status(&u, DeviceText.listCount(uses.count), listed, blackHolePresent))
    }

    /// The pair the status names (the call app's real mic; the call app on BlackHole; another program on it), or -1.
    public static func listenIndex(uses: [Int]) -> Int {
        var u = DeviceText.list(uses)
        return Int(dv_listen_index(&u, DeviceText.listCount(uses.count)))
    }

    /// Headphones or a headset: the headphone jack, Bluetooth, USB.
    public static func isHeadphonesLike(kind: Int) -> Bool { dv_is_headphones_like(Int64(kind)) }

    /// «Звук Meet»: an output the owner can pick to hear the call and the Russian voice. `selectable`: macOS lets
    /// it become the system output (CoreAudioDeviceCatalog.isSelectableOutput).
    public static func isHearOutput(kind: Int, outputChannels: Int, selectable: Bool) -> Bool {
        dv_is_hear_output(Int64(kind), Int64(outputChannels), selectable)
    }

    /// Ponte's microphone when the settings say «Автоматически»: the headset's own microphone when the listening
    /// output (`outputIndex`, -1 for none) is one, else the built-in microphone, else the first real one; never
    /// BlackHole, Ponte's tap or an iPhone. -1 if none.
    public static func pickAutoMicIndex(names: [String], kinds: [Int], inputChannels: [Int], outputIndex: Int) -> Int {
        var t = DeviceText(names)
        var k = DeviceText.list(kinds)
        var inputs = DeviceText.list(inputChannels)
        return Int(dv_pick_auto_mic_index(&t.bytes, &t.offsets, &t.lengths, &k, &inputs, t.count, Int64(outputIndex)))
    }
}

/// Strings packed for `device_rules`: one UTF-8 buffer of `DV_TEXT_MAX` bytes and offset/length tables of
/// `DV_LIST_MAX` entries. Strings past the buffer are cut; the C reads a slice outside it as empty.
struct DeviceText {
    static let textMax = Int(DV_TEXT_MAX)
    static let listMax = Int(DV_LIST_MAX)

    var bytes = [UInt8](repeating: 0, count: textMax)
    var offsets = [UInt32](repeating: 0, count: listMax)
    var lengths = [UInt32](repeating: 0, count: listMax)
    private(set) var count: Int64 = 0

    init(_ strings: [String]) {
        var at = 0
        for (i, s) in strings.enumerated() {
            let u = Array(s.utf8)
            let n = min(u.count, Self.textMax - at)
            bytes.replaceSubrange(at..<(at + n), with: u[0..<n])
            if i < Self.listMax {
                offsets[i] = UInt32(at)
                lengths[i] = UInt32(n)
            }
            at += n
        }
        count = Self.listCount(strings.count)
    }

    func off(_ i: Int) -> Int64 { Int64(offsets[i]) }
    func len(_ i: Int) -> Int64 { Int64(lengths[i]) }

    /// `count` offset (or length) entries starting at `from`, in a table of `DV_LIST_MAX`.
    static func slots(_ table: [UInt32], from: Int, count: Int) -> [UInt32] {
        var out = [UInt32](repeating: 0, count: listMax)
        let n = max(0, min(count, listMax - from))
        if n > 0 { out.replaceSubrange(0..<n, with: table[from..<(from + n)]) }
        return out
    }

    /// An Int list as the C table of `DV_LIST_MAX` Int64 values.
    static func list(_ values: [Int]) -> [Int64] {
        var out = [Int64](repeating: 0, count: listMax)
        for (i, v) in values.prefix(listMax).enumerated() { out[i] = Int64(v) }
        return out
    }

    static func listCount(_ n: Int) -> Int64 { Int64(min(n, listMax)) }

    /// The string a C function writes into a `DV_TEXT_MAX` buffer (it returns the length).
    static func bytes(_ write: (UnsafeMutablePointer<UInt8>) -> Int64) -> String {
        var out = [UInt8](repeating: 0, count: textMax)
        let n = out.withUnsafeMutableBufferPointer { Int(write($0.baseAddress!)) }
        return String(decoding: out[0..<n], as: UTF8.self)
    }

    /// Row `row` of the device word table.
    static func row(_ row: Int64) -> String { bytes { dv_row_bytes(row, $0) } }
}
