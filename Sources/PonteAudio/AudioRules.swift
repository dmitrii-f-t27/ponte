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
public enum AudioRules {

    // MARK: - Constants

    /// Chunk length for file/test sources and the probe meter window unit.
    public static let chunkSeconds: Double = 0.1
    /// Sample rate used when a device or file reports none.
    public static let fallbackSampleRate: Double = 48_000
    /// Floor of `dBFS` (also the value for a level of exactly 0).
    public static let dBFSFloor: Float = -120
    /// Below this RMS level (dBFS) a signal counts as "quiet" (level code 1).
    public static let quietThresholdDBFS: Float = -60
    /// Extra frames allocated on top of the exact resampled length.
    public static let conversionSlackFrames = 1024
    /// Delay before re-reading the HAL process list after a change notification.
    public static let reconcileDebounceSeconds: Double = 0.05
    /// UID prefix of Ponte's private tap aggregate devices (hidden from device pickers).
    public static let ponteAggregateUIDPrefix = "ai.ponte.tap."
    /// Frames per AVAudioEngine input-tap callback requested by MicSource (a hint).
    public static let micTapBufferFrames = 2048
    /// How many parent processes to walk up when looking for a process's owning app.
    public static let parentChainMaxDepth = 8
    /// Int16 / Int32 PCM full scale.
    public static let int16FullScale: Float = 32_768
    public static let int32FullScale: Float = 2_147_483_648

    // MARK: - Audio math: sample conversion, downmix, gain

    public static func int16ToFloat(_ v: Int16) -> Float { Float(v) / int16FullScale }
    public static func int32ToFloat(_ v: Int32) -> Float { Float(v) / int32FullScale }

    /// Frames in a raw buffer: byteSize / (bytesPerSample * channels); 0 if channels or bytesPerSample ≤ 0.
    public static func framesInBuffer(byteSize: Int, channels: Int, bytesPerSample: Int) -> Int {
        guard channels > 0, bytesPerSample > 0 else { return 0 }
        return byteSize / (bytesPerSample * channels)
    }

    /// Adds the per-frame channel sum of an interleaved block to `dst`:
    /// dst[i] += Σ_{c<channels} src[i*channels + c], for i < frames. A planar channel is channels = 1.
    /// Real-time safe (no allocation).
    public static func accumulateFrames(_ src: UnsafePointer<Float>, channels: Int, frames: Int,
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
    public static func averageFactor(totalChannels: Int) -> Float {
        totalChannels > 1 ? 1 / Float(totalChannels) : 1
    }

    /// dst[i] *= factor for i < frames. Real-time safe.
    public static func scale(_ dst: UnsafeMutablePointer<Float>, frames: Int, by factor: Float) {
        guard factor != 1 else { return }
        for i in 0..<max(0, frames) { dst[i] *= factor }
    }

    /// Mono average of interleaved samples (frames = samples.count / channels, remainder ignored).
    public static func downmixInterleaved(_ samples: [Float], channels: Int) -> [Float] {
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
    public static func downmixPlanar(_ channels: [[Float]]) -> [Float] {
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
    public static func clamp(_ x: Float, _ lo: Float, _ hi: Float) -> Float { min(hi, max(lo, x)) }

    /// Volume / gain setting clamped to 0…1.
    public static func clampUnit(_ x: Float) -> Float { clamp(x, 0, 1) }

    /// One sample with gain, hard-clipped to [-1, 1].
    public static func gainClip(_ sample: Float, gain: Float) -> Float { clamp(sample * gain, -1, 1) }

    public static func applyGain(_ samples: [Float], gain: Float) -> [Float] { samples.map { gainClip($0, gain: gain) } }

    // MARK: - Audio math: levels

    /// sqrt(sumSquares / count) as Float; 0 when count ≤ 0.
    public static func rmsFromSum(sumSquares: Double, count: Int) -> Float {
        count > 0 ? Float((sumSquares / Double(count)).squareRoot()) : 0
    }

    /// Root mean square; squares summed in Double in index order.
    public static func rms(_ samples: UnsafeBufferPointer<Float>) -> Float {
        var sum: Double = 0
        for s in samples { sum += Double(s) * Double(s) }
        return rmsFromSum(sumSquares: sum, count: samples.count)
    }

    public static func rms(_ samples: [Float]) -> Float { samples.withUnsafeBufferPointer { rms($0) } }

    /// Largest absolute sample; 0 for no samples.
    public static func peak(_ samples: UnsafeBufferPointer<Float>) -> Float {
        var p: Float = 0
        for s in samples { p = max(p, abs(s)) }
        return p
    }

    public static func peak(_ samples: [Float]) -> Float { samples.withUnsafeBufferPointer { peak($0) } }

    /// 20·log10(level), floored at `dBFSFloor`; `dBFSFloor` for level ≤ 0.
    public static func dBFS(_ level: Float) -> Float {
        level > 0 ? max(dBFSFloor, 20 * log10(level)) : dBFSFloor
    }

    /// Level codes for status lights and the probe.
    public static let levelDigitalSilence = 0   // every sample exactly 0 (no signal at all / no permission)
    public static let levelQuiet = 1            // signal present but below quietThresholdDBFS
    public static let levelSignal = 2           // audible signal

    public static func levelCode(peak: Float, rms: Float) -> Int {
        if peak == 0 { return levelDigitalSilence }
        return dBFS(rms) < quietThresholdDBFS ? levelQuiet : levelSignal
    }

    /// A process tap that delivered frames but only exact zeros: the usual sign of a missing
    /// System Audio Recording permission (or a silent target).
    public static func tapSilenceSuspect(totalFrames: Int, peak: Float) -> Bool {
        totalFrames > 0 && peak == 0
    }

    // MARK: - Audio math: rates, chunks, pacing

    /// `rate` if positive, else `fallbackSampleRate`.
    public static func rateOrDefault(_ rate: Double) -> Double { rate > 0 ? rate : fallbackSampleRate }

    /// Frames in one chunk: max(1, round(sampleRate · seconds)), rounding half away from zero.
    public static func framesPerChunk(sampleRate: Double, seconds: Double = chunkSeconds) -> Int {
        Int(max(1, (sampleRate * seconds).rounded()))
    }

    /// Lengths of consecutive chunks covering `total` frames; the last may be shorter. [] if total ≤ 0 or chunk ≤ 0.
    public static func chunkLengths(total: Int, chunk: Int) -> [Int] {
        guard total > 0, chunk > 0 else { return [] }
        return stride(from: 0, to: total, by: chunk).map { min(chunk, total - $0) }
    }

    /// Output capacity for converting `frames` from one rate to another: ceil(frames·to/from) + slack.
    public static func conversionCapacity(frames: Int, fromRate: Double, toRate: Double) -> Int {
        guard fromRate > 0, toRate > 0 else { return frames + conversionSlackFrames }
        return Int((Double(frames) * toRate / fromRate).rounded(.up)) + conversionSlackFrames
    }

    public static func needsResample(fromRate: Double, toRate: Double) -> Bool { fromRate != toRate }

    /// The resampler must average channels when it reduces the channel count.
    public static func converterShouldDownmix(inputChannels: Int, outputChannels: Int) -> Bool {
        inputChannels > outputChannels
    }

    /// The session output rate: fixed at the first attach (fixedRate > 0) and kept afterwards.
    public static func sessionRate(fixedRate: Double, tapRate: Double) -> Double { fixedRate > 0 ? fixedRate : tapRate }

    /// Real-time pacing: how long to wait so that a chunk ending at `endFrame` is delivered when its
    /// last sample would have been heard. deadline = start + endFrame/rate seconds; 0 if already past.
    public static func pacingSleepNanos(startNanos: UInt64, nowNanos: UInt64, endFrame: Int64, sampleRate: Double) -> UInt64 {
        guard sampleRate > 0, endFrame > 0 else { return 0 }
        let deadline = startNanos + UInt64(Double(endFrame) / sampleRate * 1e9)
        return deadline > nowNanos ? deadline - nowNanos : 0
    }

    /// Player conversion path codes.
    public static let convertNone = 0       // identical format: schedule as is
    public static let convertDownmix = 1    // same rate: downmix / sample type only
    public static let convertResample = 2   // different rate: stateful resampler

    public static func conversionPath(sameFormat: Bool, sameRate: Bool) -> Int {
        sameFormat ? convertNone : (sameRate ? convertDownmix : convertResample)
    }

    /// A process-tap stream Ponte can read: linear PCM, float, 32-bit, positive rate.
    public static func isUsableTapFormat(isLinearPCM: Bool, isFloat: Bool, bitsPerChannel: Int, sampleRate: Double) -> Bool {
        isLinearPCM && isFloat && bitsPerChannel == 32 && sampleRate > 0
    }

    // MARK: - Process tap lifecycle

    /// What to do after the HAL process list (or the tap format) changed, or at start.
    public static let tapKeep = 0           // nothing changed
    public static let tapWait = 1           // target app gone: destroy the tap (if any) and wait for it
    public static let tapUpdate = 2         // swap the tapped processes on the live tap (no audio gap)
    public static let tapRebuild = 3        // destroy (if any) and build a new tap + aggregate

    /// - attached: a tap exists now. desiredCount: processes to tap (to exclude, for system audio).
    /// - sameSet: desired processes equal the attached ones. isGlobal: "all system audio except Ponte".
    /// - force: the tap format changed, or this is the first attach at start.
    /// If `tapUpdate` fails at run time, the caller falls back to `tapRebuild`.
    public static func tapAction(attached: Bool, desiredCount: Int, sameSet: Bool, isGlobal: Bool, force: Bool) -> Int {
        if !force && attached && sameSet { return tapKeep }
        let nothingToTap = desiredCount == 0 && !isGlobal
        if !force && !attached && nothingToTap { return tapKeep }
        if nothingToTap { return tapWait }
        if !force && attached { return tapUpdate }
        return tapRebuild
    }

    // MARK: - Microphone permission

    /// AVAuthorizationStatus raw values: 0 notDetermined, 1 restricted, 2 denied, 3 authorized.
    public static let micStart = 0          // authorized
    public static let micRequestFirst = 1   // not decided: ask (an undecided permission blocks AVAudioEngine)
    public static let micDenied = 2         // restricted / denied: only System Settings can fix it

    public static func micStartDecision(authorizationStatus: Int) -> Int {
        switch authorizationStatus {
        case 3: return micStart
        case 0: return micRequestFirst
        default: return micDenied
        }
    }

    // MARK: - Devices

    /// Device kind codes.
    public static let kindUnknown = 0
    public static let kindBuiltInSpeaker = 1
    public static let kindBuiltInHeadphones = 2
    public static let kindBuiltInMic = 3
    public static let kindBlackHole = 4          // virtual mic for the call app
    public static let kindBluetooth = 5          // classic and LE
    public static let kindUSB = 6
    public static let kindDisplay = 7            // HDMI / DisplayPort (monitor speakers)
    public static let kindAirPlay = 8
    public static let kindAggregate = 9          // user aggregate / multi-output
    public static let kindPonteAggregate = 10    // Ponte's own private tap aggregate
    public static let kindVirtual = 11           // other virtual drivers (Zoom, Teams, Loopback…)
    public static let kindContinuity = 12        // iPhone as mic (Continuity Capture)
    public static let kindOtherWired = 13        // PCI, FireWire, Thunderbolt, AVB

    /// Core Audio transport type four-char codes (kAudioDeviceTransportType*), as plain UInt32.
    public static let transportBuiltIn: UInt32 = 0x626C_746E      // 'bltn'
    public static let transportAggregate: UInt32 = 0x6772_7570    // 'grup'
    public static let transportVirtual: UInt32 = 0x7669_7274      // 'virt'
    public static let transportPCI: UInt32 = 0x7063_6920          // 'pci '
    public static let transportUSB: UInt32 = 0x7573_6220          // 'usb '
    public static let transportFireWire: UInt32 = 0x3133_3934     // '1394'
    public static let transportBluetooth: UInt32 = 0x626C_7565    // 'blue'
    public static let transportBluetoothLE: UInt32 = 0x626C_6561  // 'blea'
    public static let transportHDMI: UInt32 = 0x6864_6D69         // 'hdmi'
    public static let transportDisplayPort: UInt32 = 0x6470_7274  // 'dprt'
    public static let transportAirPlay: UInt32 = 0x6169_7270      // 'airp'
    public static let transportAVB: UInt32 = 0x6561_7662          // 'eavb'
    public static let transportThunderbolt: UInt32 = 0x7468_756E  // 'thun'
    public static let transportContinuityWired: UInt32 = 0x6363_7764     // 'ccwd'
    public static let transportContinuityWireless: UInt32 = 0x6363_776C  // 'ccwl'

    /// BlackHole by name: contains "blackhole" (ASCII case-insensitive).
    public static func isBlackHole(name: String) -> Bool { containsCI(name, "blackhole") }

    public static func isPonteAggregate(uid: String) -> Bool { uid.utf8.starts(with: ponteAggregateUIDPrefix.utf8) }

    /// Classifies a device. Order: Ponte aggregate (uid prefix) → BlackHole (name) → transport type.
    /// Built-in: "headphone" in uid or name → headphones; else output channels > 0 → speaker; else input → mic.
    public static func deviceKind(name: String, uid: String, transportType: UInt32,
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
    public static let echoNone = 0      // headphones, virtual devices, mics
    public static let echoSpeaker = 1   // a loudspeaker: show "use headphones"
    public static let echoMaybe = 2     // cannot tell (Bluetooth, USB, other wired, unknown)

    public static func echoRisk(kind: Int) -> Int {
        switch kind {
        case kindBuiltInSpeaker, kindDisplay, kindAirPlay: return echoSpeaker
        case kindBluetooth, kindUSB, kindOtherWired, kindUnknown: return echoMaybe
        default: return echoNone
        }
    }

    /// Never use these as "my microphone" or "my headphones": the call's virtual mic and Ponte's own tap.
    public static func isExcludedForMonitoring(kind: Int) -> Bool { kind == kindBlackHole || kind == kindPonteAggregate }

    /// The BlackHole device to play into: among BlackHole devices with output channels, the first whose
    /// name contains "2ch" (ASCII case-insensitive), else the first. -1 if none.
    public static func pickBlackHoleIndex(names: [String], outputChannels: [Int]) -> Int {
        let candidates = names.indices.filter { isBlackHole(name: names[$0]) && outputChannels[$0] > 0 }
        return candidates.first { containsCI(names[$0], "2ch") } ?? candidates.first ?? -1
    }

    /// "My microphone": the default input if it has input channels and is not excluded; else the first
    /// built-in mic; else the first non-excluded device with input channels. -1 if none.
    public static func pickMicIndex(kinds: [Int], inputChannels: [Int], defaultIndex: Int) -> Int {
        let usable = { (i: Int) in inputChannels[i] > 0 && !isExcludedForMonitoring(kind: kinds[i]) }
        if kinds.indices.contains(defaultIndex), usable(defaultIndex) { return defaultIndex }
        if let i = kinds.indices.first(where: { usable($0) && kinds[$0] == kindBuiltInMic }) { return i }
        return kinds.indices.first(where: usable) ?? -1
    }

    /// Where to play the Russian voice for the owner: the default output if usable; else by kind
    /// priority built-in headphones → Bluetooth → USB → built-in speaker → any other usable. -1 if none.
    public static func pickListenOutputIndex(kinds: [Int], outputChannels: [Int], defaultIndex: Int) -> Int {
        let usable = { (i: Int) in outputChannels[i] > 0 && !isExcludedForMonitoring(kind: kinds[i]) }
        if kinds.indices.contains(defaultIndex), usable(defaultIndex) { return defaultIndex }
        for kind in [kindBuiltInHeadphones, kindBluetooth, kindUSB, kindBuiltInSpeaker] {
            if let i = kinds.indices.first(where: { usable($0) && kinds[$0] == kind }) { return i }
        }
        return kinds.indices.first(where: usable) ?? -1
    }

    /// Device lookup: exact UID, then exact name, then name contains query (ASCII case-insensitive). -1 if none.
    public static func matchDeviceIndex(query: String, names: [String], uids: [String]) -> Int {
        if let i = uids.firstIndex(of: query) { return i }
        if let i = names.firstIndex(of: query) { return i }
        return names.firstIndex { containsCI($0, query) } ?? -1
    }

    // MARK: - App catalog

    /// Known call apps, sorted by bundle ID; labels are parallel. Must equal AudioApp.knownCallApps.
    public static let knownCallAppBundleIDs = [
        "com.apple.FaceTime",
        "com.apple.Safari",
        "com.google.Chrome",
        "com.microsoft.teams2",
        "net.whatsapp.WhatsApp",
        "org.telegram.desktop",
        "ru.keepcoder.Telegram",
        "us.zoom.xos",
    ]
    public static let knownCallAppLabels = [
        "FaceTime",
        "Safari (Meet)",
        "Chrome (Meet)",
        "Teams",
        "WhatsApp",
        "Telegram Desktop",
        "Telegram",
        "Zoom",
    ]

    /// Index into `knownCallAppBundleIDs` (exact match), or -1.
    public static func knownCallAppIndex(bundleID: String) -> Int { knownCallAppBundleIDs.firstIndex(of: bundleID) ?? -1 }

    public static func isKnownCallApp(bundleID: String) -> Bool { knownCallAppIndex(bundleID: bundleID) >= 0 }

    /// Processes that carry a call app's audio without belonging to it (parallel arrays: target → process).
    /// FaceTime calls run in avconferenced / callservicesd (TelephonyUtilities). Unverified on a live call.
    public static let companionTargetBundleIDs = ["com.apple.FaceTime", "com.apple.FaceTime"]
    public static let companionProcessBundleIDs = ["com.apple.avconferenced", "com.apple.TelephonyUtilities"]

    public static func isCompanionProcess(processBundleID: String, targetBundleID: String) -> Bool {
        zip(companionTargetBundleIDs, companionProcessBundleIDs).contains { $0 == targetBundleID && $1 == processBundleID }
    }

    /// Does this HAL process belong in a tap of `targetBundleID`? Never Ponte itself.
    /// processBundleID is "" when the HAL reports none.
    public static func isTapTargetProcess(processBundleID: String, ownerBundleID: String, targetBundleID: String,
                                          pid: Int32, selfPID: Int32) -> Bool {
        guard pid != selfPID else { return false }
        return ownerBundleID == targetBundleID
            || (!processBundleID.isEmpty && processBundleID == targetBundleID)
            || isCompanionProcess(processBundleID: processBundleID, targetBundleID: targetBundleID)
    }

    /// Helper → parent app by bundle-ID prefix: the index of the longest `appBundleIDs[i]` such that
    /// helperBundleID starts with appBundleIDs[i] + "." (com.google.Chrome.helper → com.google.Chrome). -1 if none.
    public static func parentAppIndex(helperBundleID: String, appBundleIDs: [String]) -> Int {
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
    public static func outermostAppPathLength(_ path: String) -> Int {
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
    public static let ownerSelf = 1            // the process is itself a regular (Dock) app
    public static let ownerAppBundlePath = 2   // outermost .app in its executable path (Chrome/Electron helpers)
    public static let ownerResponsible = 3     // its responsible process is an app (WebKit.GPU → Safari; CLI → terminal)
    public static let ownerParent = 4          // a regular app among its parent processes
    public static let ownerBundlePrefix = 5    // bundle-ID prefix of a running regular app
    public static let ownerFallback = 6        // itself (its own bundle ID, or "pid.<n>")

    public static func ownerSource(selfIsRegularApp: Bool, hasAppBundlePath: Bool, hasResponsibleApp: Bool,
                                   hasRegularParentApp: Bool, hasPrefixParent: Bool) -> Int {
        if selfIsRegularApp { return ownerSelf }
        if hasAppBundlePath { return ownerAppBundlePath }
        if hasResponsibleApp { return ownerResponsible }
        if hasRegularParentApp { return ownerParent }
        if hasPrefixParent { return ownerBundlePrefix }
        return ownerFallback
    }

    /// Ponte's own process never appears as a source.
    public static func isSelfProcess(pid: Int32, ownerPID: Int32, selfPID: Int32) -> Bool {
        pid == selfPID || ownerPID == selfPID
    }

    /// Show an app in the source picker: a Dock app, anything playing now, or a known call app.
    public static func shouldListApp(isRegularApp: Bool, isPlaying: Bool, isKnownCallApp: Bool) -> Bool {
        isRegularApp || isPlaying || isKnownCallApp
    }

    /// Picker rank: 0 playing call app, 1 other playing app, 2 idle call app, 3 the rest.
    public static func appRank(isKnownCallApp: Bool, isPlaying: Bool) -> Int {
        switch (isKnownCallApp, isPlaying) {
        case (true, true): return 0
        case (false, true): return 1
        case (true, false): return 2
        case (false, false): return 3
        }
    }

    /// Display order: indices sorted by rank, then by name (ASCII case-folded UTF-8 bytes), then by index.
    public static func appSortOrder(ranks: [Int], names: [String]) -> [Int] {
        let keys = names.map(foldedBytes)
        return ranks.indices.sorted { a, b in
            if ranks[a] != ranks[b] { return ranks[a] < ranks[b] }
            if keys[a] != keys[b] { return keys[a].lexicographicallyPrecedes(keys[b]) }
            return a < b
        }
    }

    // MARK: - Text helpers (ASCII case folding on UTF-8 bytes)

    /// UTF-8 bytes with A–Z mapped to a–z; other bytes unchanged.
    public static func foldedBytes(_ s: String) -> [UInt8] {
        s.utf8.map { ($0 >= 65 && $0 <= 90) ? $0 + 32 : $0 }
    }

    /// `haystack` contains `needle`, ASCII case-insensitive. An empty needle matches.
    public static func containsCI(_ haystack: String, _ needle: String) -> Bool {
        let h = foldedBytes(haystack), n = foldedBytes(needle)
        guard !n.isEmpty else { return true }
        guard n.count <= h.count else { return false }
        for i in 0...(h.count - n.count) where h[i] == n[0] {
            if Array(h[i..<(i + n.count)]) == n { return true }
        }
        return false
    }
}
