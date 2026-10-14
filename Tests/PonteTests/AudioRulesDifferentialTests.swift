// Owned by the t27 agent. AudioRules (C from Specs/audio_rules.t27 and device_rules.t27) against
// AudioRulesLegacy (the Swift it replaced), function by function, bit for bit.
import Foundation
import Testing
@testable import PonteAudio

private typealias F = AudioRules
private typealias L = AudioRulesLegacy

@Suite("Differential: AudioRules") struct AudioRulesDifferentialTests {

    @Test func constants() {
        let log = DiffLog("AudioRules constants")
        log.check(F.chunkSeconds, L.chunkSeconds, "chunkSeconds")
        log.check(F.fallbackSampleRate, L.fallbackSampleRate, "fallbackSampleRate")
        log.check(F.dBFSFloor, L.dBFSFloor, "dBFSFloor")
        log.check(F.quietThresholdDBFS, L.quietThresholdDBFS, "quietThresholdDBFS")
        log.check(F.conversionSlackFrames, L.conversionSlackFrames, "conversionSlackFrames")
        log.check(F.reconcileDebounceSeconds, L.reconcileDebounceSeconds, "reconcileDebounceSeconds")
        log.check(F.ponteAggregateUIDPrefix, L.ponteAggregateUIDPrefix, "ponteAggregateUIDPrefix")
        log.check(F.micTapBufferFrames, L.micTapBufferFrames, "micTapBufferFrames")
        log.check(F.parentChainMaxDepth, L.parentChainMaxDepth, "parentChainMaxDepth")
        log.check(F.int16FullScale, L.int16FullScale, "int16FullScale")
        log.check(F.int32FullScale, L.int32FullScale, "int32FullScale")
        log.check([F.levelDigitalSilence, F.levelQuiet, F.levelSignal], [L.levelDigitalSilence, L.levelQuiet, L.levelSignal], "level codes")
        log.check([F.convertNone, F.convertDownmix, F.convertResample], [L.convertNone, L.convertDownmix, L.convertResample], "convert codes")
        log.check([F.tapKeep, F.tapWait, F.tapUpdate, F.tapRebuild], [L.tapKeep, L.tapWait, L.tapUpdate, L.tapRebuild], "tap codes")
        log.check([F.micStart, F.micRequestFirst, F.micDenied], [L.micStart, L.micRequestFirst, L.micDenied], "mic codes")
        log.check([F.kindUnknown, F.kindBuiltInSpeaker, F.kindBuiltInHeadphones, F.kindBuiltInMic, F.kindBlackHole,
                   F.kindBluetooth, F.kindUSB, F.kindDisplay, F.kindAirPlay, F.kindAggregate, F.kindPonteAggregate,
                   F.kindVirtual, F.kindContinuity, F.kindOtherWired],
                  [L.kindUnknown, L.kindBuiltInSpeaker, L.kindBuiltInHeadphones, L.kindBuiltInMic, L.kindBlackHole,
                   L.kindBluetooth, L.kindUSB, L.kindDisplay, L.kindAirPlay, L.kindAggregate, L.kindPonteAggregate,
                   L.kindVirtual, L.kindContinuity, L.kindOtherWired], "kind codes")
        log.check([F.transportBuiltIn, F.transportAggregate, F.transportVirtual, F.transportPCI, F.transportUSB,
                   F.transportFireWire, F.transportBluetooth, F.transportBluetoothLE, F.transportHDMI,
                   F.transportDisplayPort, F.transportAirPlay, F.transportAVB, F.transportThunderbolt,
                   F.transportContinuityWired, F.transportContinuityWireless],
                  [L.transportBuiltIn, L.transportAggregate, L.transportVirtual, L.transportPCI, L.transportUSB,
                   L.transportFireWire, L.transportBluetooth, L.transportBluetoothLE, L.transportHDMI,
                   L.transportDisplayPort, L.transportAirPlay, L.transportAVB, L.transportThunderbolt,
                   L.transportContinuityWired, L.transportContinuityWireless], "transport codes")
        log.check([F.echoNone, F.echoSpeaker, F.echoMaybe], [L.echoNone, L.echoSpeaker, L.echoMaybe], "echo codes")
        log.check([F.ownerSelf, F.ownerAppBundlePath, F.ownerResponsible, F.ownerParent, F.ownerBundlePrefix, F.ownerFallback],
                  [L.ownerSelf, L.ownerAppBundlePath, L.ownerResponsible, L.ownerParent, L.ownerBundlePrefix, L.ownerFallback], "owner codes")
        log.check(F.knownCallAppBundleIDs, L.knownCallAppBundleIDs, "knownCallAppBundleIDs")
        log.check(F.knownCallAppLabels, L.knownCallAppLabels, "knownCallAppLabels")
        log.check(F.companionTargetBundleIDs, L.companionTargetBundleIDs, "companionTargetBundleIDs")
        log.check(F.companionProcessBundleIDs, L.companionProcessBundleIDs, "companionProcessBundleIDs")
        log.finish(minimumCases: 23)
    }

    // MARK: Sample conversion and downmix

    @Test func sampleConversion() {
        let log = DiffLog("int16ToFloat, int32ToFloat, framesInBuffer")
        for v in Int16.min...Int16.max { log.check(F.int16ToFloat(v), L.int16ToFloat(v), "int16 \(v)") }
        var r = DiffRandom(seed: 1)
        let edges: [Int32] = [.min, .max, 0, 1, -1, 1 << 24, (1 << 24) + 1, -(1 << 24) - 1, 1 << 30, 16_777_217, 2_147_483_520]
        for v in edges { log.check(F.int32ToFloat(v), L.int32ToFloat(v), "int32 \(v)") }
        for _ in 0..<200_000 {
            let v = Int32(truncatingIfNeeded: r.next())
            log.check(F.int32ToFloat(v), L.int32ToFloat(v), "int32 \(v)")
        }
        for size in stride(from: -50, through: 5_000, by: 7) {
            for channels in -1...9 {
                for bps in -1...9 {
                    log.check(F.framesInBuffer(byteSize: size, channels: channels, bytesPerSample: bps),
                              L.framesInBuffer(byteSize: size, channels: channels, bytesPerSample: bps), describe(size, channels, bps))
                }
            }
        }
        for _ in 0..<50_000 {
            let size = r.int(-1_000_000...1_000_000_000_000), channels = r.int(-3...64), bps = r.int(-3...16)
            log.check(F.framesInBuffer(byteSize: size, channels: channels, bytesPerSample: bps),
                      L.framesInBuffer(byteSize: size, channels: channels, bytesPerSample: bps), describe(size, channels, bps))
        }
        log.finish(minimumCases: 400_000)
    }

    @Test func accumulateScaleAndFactor() {
        let log = DiffLog("accumulateFrames, scale, averageFactor")
        var r = DiffRandom(seed: 2)
        for _ in 0..<400 {
            let channels = r.pick([-1, 0, 1, 1, 2, 2, 3, 4, 6, 8, 16, 64])
            let frames = r.pick([0, 1, 7, 512, 1024, 4096, 4097, 9_001, r.int(-5...3000)])
            let src = r.floats(max(0, channels) * max(0, frames) + 1)
            let start = r.floats(max(0, frames) + 1)
            var a = start, b = start
            src.withUnsafeBufferPointer { s in
                a.withUnsafeMutableBufferPointer { F.accumulateFrames(s.baseAddress!, channels: channels, frames: frames, into: $0.baseAddress!) }
                b.withUnsafeMutableBufferPointer { L.accumulateFrames(s.baseAddress!, channels: channels, frames: frames, into: $0.baseAddress!) }
            }
            log.check(a, b, "accumulate \(channels) × \(frames)")
            let factor = r.pick([1, 0.5, 0.25, 1.0 / 3, -0.0, .nan, .infinity, r.float()] as [Float])
            var c = start, d = start
            c.withUnsafeMutableBufferPointer { F.scale($0.baseAddress!, frames: frames, by: factor) }
            d.withUnsafeMutableBufferPointer { L.scale($0.baseAddress!, frames: frames, by: factor) }
            log.check(c, d, "scale \(frames) by \(factor)")
        }
        for n in -10...70_000 { log.check(F.averageFactor(totalChannels: n), L.averageFactor(totalChannels: n), "factor \(n)") }
        log.finish(minimumCases: 70_000)
    }

    @Test func downmix() {
        let log = DiffLog("downmixInterleaved, downmixPlanar")
        var r = DiffRandom(seed: 3)
        for _ in 0..<500 {
            let channels = r.pick([-1, 0, 1, 2, 2, 3, 4, 5, 8, 16, 63, 64])
            let samples = r.floats(r.pick([0, 1, 5, 4096, 8192, 8193, 9_999, 20_000, r.int(0...300)]))
            log.check(F.downmixInterleaved(samples, channels: channels), L.downmixInterleaved(samples, channels: channels),
                      "interleaved \(samples.count) / \(channels)")
        }
        for _ in 0..<300 {
            let count = r.pick([0, 1, 2, 3, 6, 16, 64, r.int(0...20)])
            let planes = (0..<count).map { _ in r.floats(r.pick([0, 1, 100, 4096, 5000, r.int(0...700)])) }
            log.check(F.downmixPlanar(planes), L.downmixPlanar(planes), "planar \(planes.map(\.count))")
        }
        log.finish(minimumCases: 800)
    }

    @Test func gainAndClamp() {
        let log = DiffLog("clamp, clampUnit, gainClip, applyGain")
        var r = DiffRandom(seed: 4)
        for _ in 0..<300_000 {
            let x = r.float(), lo = r.float(), hi = r.float()
            log.check(F.clamp(x, lo, hi), L.clamp(x, lo, hi), describe(x, lo, hi))
            log.check(F.clampUnit(x), L.clampUnit(x), describe(x))
            log.check(F.gainClip(x, gain: lo), L.gainClip(x, gain: lo), describe(x, lo))
        }
        for _ in 0..<200 {
            let samples = r.floats(r.pick([0, 1, 100, 4096, 4097, 10_000]))
            let gain = r.float()
            log.check(F.applyGain(samples, gain: gain), L.applyGain(samples, gain: gain), "applyGain \(samples.count) × \(gain)")
        }
        log.finish(minimumCases: 900_000)
    }

    // MARK: Levels

    @Test func levels() {
        let log = DiffLog("rmsFromSum, rms, peak, dBFS, levelCode, tapSilenceSuspect")
        var r = DiffRandom(seed: 5)
        for _ in 0..<200_000 {
            let sum = r.double(), count = r.pick([-1, 0, 1, 2, 4096, r.int(-10...100_000)])
            log.check(F.rmsFromSum(sumSquares: sum, count: count), L.rmsFromSum(sumSquares: sum, count: count), describe(sum, count))
            let peak = r.float(), rms = r.float()
            log.check(F.dBFS(peak), L.dBFS(peak), "dBFS \(peak)")
            log.check(F.levelCode(peak: peak, rms: rms), L.levelCode(peak: peak, rms: rms), describe(peak, rms))
            let frames = r.int(-5...5)
            log.check(F.tapSilenceSuspect(totalFrames: frames, peak: peak), L.tapSilenceSuspect(totalFrames: frames, peak: peak), describe(frames, peak))
        }
        var bits: UInt32 = 0
        while bits < 0xFF80_0000 {
            let x = Float(bitPattern: bits)
            log.check(F.dBFS(x), L.dBFS(x), "dBFS bits \(bits)")
            bits &+= 7_919
        }
        for _ in 0..<300 {
            let samples = r.floats(r.pick([0, 1, 2, 4095, 4096, 4097, 12_345, r.int(0...999)]))
            log.check(F.rms(samples), L.rms(samples), "rms \(samples.count)")
            log.check(F.peak(samples), L.peak(samples), "peak \(samples.count)")
            samples.withUnsafeBufferPointer { p in
                log.check(F.rms(p), L.rms(p), "rms pointer \(samples.count)")
                log.check(F.peak(p), L.peak(p), "peak pointer \(samples.count)")
            }
        }
        log.finish(minimumCases: 1_300_000)
    }

    // MARK: Rates, chunks, pacing, conversion

    @Test func ratesChunksPacing() {
        let log = DiffLog("rates, chunks, capacity, pacing, conversion path, tap format")
        var r = DiffRandom(seed: 6)
        for _ in 0..<100_000 {
            let rate = r.double()
            log.check(F.rateOrDefault(rate), L.rateOrDefault(rate), "rateOrDefault \(rate)")
            let a = r.double(), b = r.double()
            log.check(F.needsResample(fromRate: a, toRate: b), L.needsResample(fromRate: a, toRate: b), describe(a, b))
            log.check(F.sessionRate(fixedRate: a, tapRate: b), L.sessionRate(fixedRate: a, tapRate: b), describe(a, b))
            let sampleRate = r.finiteDouble(1e6), seconds = r.finiteDouble(10)
            log.check(F.framesPerChunk(sampleRate: sampleRate, seconds: seconds),
                      L.framesPerChunk(sampleRate: sampleRate, seconds: seconds), describe(sampleRate, seconds))
            let frames = r.int(-1_000_000...1_000_000_000)
            let from = r.pick([0, -1, .nan, 44_100, 48_000, 16_000, abs(r.finiteDouble(400_000))])
            let to = r.pick([0, -1, .nan, 44_100, 48_000, 16_000, abs(r.finiteDouble(400_000))])
            if !(from > 0 && to > 0 && Double(frames) * to / from > 1e15) {
                log.check(F.conversionCapacity(frames: frames, fromRate: from, toRate: to),
                          L.conversionCapacity(frames: frames, fromRate: from, toRate: to), describe(frames, from, to))
            }
            let start = UInt64(r.int(0...1_000_000_000_000_000)), now = UInt64(r.int(0...1_000_000_000_000_000))
            let endFrame = r.int64(-10...1_000_000_000)
            let pace = r.pick([0, -1, .nan, 8_000, 44_100, 48_000, Double(r.int(1...384_000))])
            log.check(F.pacingSleepNanos(startNanos: start, nowNanos: now, endFrame: endFrame, sampleRate: pace),
                      L.pacingSleepNanos(startNanos: start, nowNanos: now, endFrame: endFrame, sampleRate: pace),
                      describe(start, now, endFrame, pace))
        }
        for rate in stride(from: 0.0, through: 400_000, by: 7) {
            log.check(F.framesPerChunk(sampleRate: rate), L.framesPerChunk(sampleRate: rate), "framesPerChunk \(rate)")
        }
        for total in -3...200 {
            for chunk in -2...30 {
                log.check(F.chunkLengths(total: total, chunk: chunk), L.chunkLengths(total: total, chunk: chunk), describe(total, chunk))
            }
        }
        for _ in 0..<500 {
            let total = r.int(0...100_000), chunk = r.int(1...10_000)
            log.check(F.chunkLengths(total: total, chunk: chunk), L.chunkLengths(total: total, chunk: chunk), describe(total, chunk))
        }
        for i in -2...40 {
            for o in -2...40 {
                log.check(F.converterShouldDownmix(inputChannels: i, outputChannels: o), L.converterShouldDownmix(inputChannels: i, outputChannels: o), describe(i, o))
            }
        }
        for sameFormat in [false, true] {
            for sameRate in [false, true] {
                log.check(F.conversionPath(sameFormat: sameFormat, sameRate: sameRate), L.conversionPath(sameFormat: sameFormat, sameRate: sameRate), describe(sameFormat, sameRate))
            }
        }
        for bits in 0..<4 {
            for bitsPerChannel in -1...70 {
                for rate in [0, -1, .nan, .infinity, 1, 48_000] as [Double] {
                    let pcm = bits & 1 == 1, float = bits & 2 == 2
                    log.check(F.isUsableTapFormat(isLinearPCM: pcm, isFloat: float, bitsPerChannel: bitsPerChannel, sampleRate: rate),
                              L.isUsableTapFormat(isLinearPCM: pcm, isFloat: float, bitsPerChannel: bitsPerChannel, sampleRate: rate),
                              describe(pcm, float, bitsPerChannel, rate))
                }
            }
        }
        log.finish(minimumCases: 600_000)
    }

    // MARK: Tap lifecycle and microphone

    @Test func tapAndMic() {
        let log = DiffLog("tapAction, micStartDecision")
        for bits in 0..<16 {
            for desired in -2...5 {
                let attached = bits & 1 == 1, same = bits & 2 == 2, global = bits & 4 == 4, force = bits & 8 == 8
                log.check(F.tapAction(attached: attached, desiredCount: desired, sameSet: same, isGlobal: global, force: force),
                          L.tapAction(attached: attached, desiredCount: desired, sameSet: same, isGlobal: global, force: force),
                          describe(attached, desired, same, global, force))
            }
        }
        var r = DiffRandom(seed: 7)
        for status in -5...10 { log.check(F.micStartDecision(authorizationStatus: status), L.micStartDecision(authorizationStatus: status), "\(status)") }
        for _ in 0..<1000 {
            let status = r.int(Int.min...Int.max)
            log.check(F.micStartDecision(authorizationStatus: status), L.micStartDecision(authorizationStatus: status), "\(status)")
        }
        log.finish(minimumCases: 1100)
    }

    /// restartDelayMs, restartFailed, micTapReady (2026-10-13, after the live crash in MicSource).
    @Test func restartAndMicTap() {
        let log = DiffLog("restartDelayMs, restartFailed, micTapReady")
        log.check([F.restartDelayMs, F.restartMaxDelayMs, F.restartAttempts], [L.restartDelayMs, L.restartMaxDelayMs, L.restartAttempts], "restart constants")
        var r = DiffRandom(seed: 1859)
        var attempts: [Int64] = Array(-100...10_000) + [.min, .min + 1, -1, .max - 1, .max]
        for _ in 0..<20_000 { attempts.append(r.int64(.min ... .max)) }
        for a in attempts {
            log.check(F.restartDelayMs(attempt: a), L.restartDelayMs(attempt: a), "\(a)")
            log.check(F.restartFailed(failures: a), L.restartFailed(failures: a), "\(a)")
        }
        let rates: [Double] = [0, -0.0, 1, -1, 8_000, 16_000, 24_000, 44_100, 48_000, 96_000, 192_000, .leastNonzeroMagnitude,
                               -.leastNonzeroMagnitude, .greatestFiniteMagnitude, .infinity, -.infinity, .nan]
        let channels = [Int.min, -1, 0, 1, 2, 3, 64, Int.max]
        for inRate in rates {
            for inChannels in channels {
                for busRate in rates {
                    for busChannels in channels {
                        log.check(F.micTapReady(inputRate: inRate, inputChannels: inChannels, busRate: busRate, busChannels: busChannels),
                                  L.micTapReady(inputRate: inRate, inputChannels: inChannels, busRate: busRate, busChannels: busChannels),
                                  describe(inRate, inChannels, busRate, busChannels))
                    }
                }
            }
        }
        log.finish(minimumCases: 78_000)
    }

    /// micInputRebuilds, micMaxFrames (2026-10-13, an output-side change stopped the microphone).
    @Test func micInputRules() {
        let log = DiffLog("micInputRebuilds, micMaxFrames, micFailuresAfter")
        log.check([F.micEventDefaultInput, F.micEventAlive, F.micEventFormat, F.micEventRunning, F.micEventRenderFailed],
                  [L.micEventDefaultInput, L.micEventAlive, L.micEventFormat, L.micEventRunning, L.micEventRenderFailed], "events")
        for event in [Int.min, -2, -1, 0, 1, 2, 3, 4, 5, 6, 100, Int.max] {
            for bits in 0..<32 {
                let follows = bits & 1 != 0, same = bits & 2 != 0, alive = bits & 4 != 0, format = bits & 8 != 0, running = bits & 16 != 0
                log.check(F.micInputRebuilds(event: event, followsDefault: follows, sameDevice: same, deviceAlive: alive, sameFormat: format, unitRunning: running),
                          L.micInputRebuilds(event: event, followsDefault: follows, sameDevice: same, deviceAlive: alive, sameFormat: format, unitRunning: running),
                          describe(event, bits))
            }
        }
        var r = DiffRandom(seed: 2314)
        var frames: [Int] = Array(-10...10) + [511, 512, 2047, 2048, 2049, 4096, 8192, 1 << 20, Int.min, Int.max]
        for _ in 0..<2_000 { frames.append(r.int(Int.min...Int.max)) }
        for f in frames { log.check(F.micMaxFrames(ioFrames: f), L.micMaxFrames(ioFrames: f), "\(f)") }
        var counts: [Int64] = Array(-10...20) + [.min, .max, .max - 1]
        for _ in 0..<500 { counts.append(r.int64(.min ... .max)) }
        for event in -1...6 {
            for delivered in [false, true] {
                for c in counts {
                    log.check(F.micFailuresAfter(event: event, delivered: delivered, failures: c),
                              L.micFailuresAfter(event: event, delivered: delivered, failures: c), describe(event, delivered, c))
                }
            }
        }
        log.finish(minimumCases: 10_000)
    }

    /// relayAction, relayTrims (2026-10-13, the own voice).
    @Test func relayRules() {
        let log = DiffLog("relayAction, relayTrims")
        log.check([F.relayTargetMs, F.relayMaxMs, F.relaySlackMs], [L.relayTargetMs, L.relayMaxMs, L.relaySlackMs], "relay ms")
        log.check(F.relayWindow, L.relayWindow, "relayWindow")
        for count in [Int.min, -1, 0, 1, 48, 49, 50, 51, 1000, Int.max] {
            log.check(F.relayWindowEnds(lowCount: count), L.relayWindowEnds(lowCount: count), "\(count)")
        }
        log.check([F.relayKeep, F.relaySend, F.relayDrop, F.relayTrim, F.relayRefill],
                  [L.relayKeep, L.relaySend, L.relayDrop, L.relayTrim, L.relayRefill], "relay actions")
        var r = DiffRandom(seed: 4040)
        var values: [Double] = [0, -0.0, -1, 1, 5, 10, 10.6667, 21.333, 30, 39.999, 40, 40.001, 50, 79.999, 80, 80.001,
                                110, 119.999, 120, 120.001, 200, 1e9, -1e9, .infinity, -.infinity, .nan, .leastNonzeroMagnitude]
        for _ in 0..<60 { values.append(r.double()) }
        let lows: [Double] = [0, 30, 49.999, 50, 50.001, 70, .nan, .infinity]
        let counts = [0, 49, 50, 51]
        for pending in values {
            for queued in values + [nil] as [Double?] {
                for filling in [false, true] {
                    for low in lows {
                        for count in counts {
                            log.check(F.relayAction(filling: filling, pendingMs: pending, queuedMs: queued, lowMs: low, lowCount: count),
                                      L.relayAction(filling: filling, pendingMs: pending, queuedMs: queued, lowMs: low, lowCount: count),
                                      describe(filling, pending, queued as Any, low, count))
                        }
                    }
                }
            }
            for oldest in values {
                log.check(F.relayTrims(pendingMs: pending, oldestMs: oldest), L.relayTrims(pendingMs: pending, oldestMs: oldest), describe(pending, oldest))
            }
        }
        log.finish(minimumCases: 490_000)
    }

    /// playerStep, playerEnqueue, playerCompletion, playerReplays (2026-10-13, phrases cut by engine stops).
    @Test func playerRules() {
        let log = DiffLog("playerStep, playerEnqueue, playerCompletion, playerReplays")
        log.check([F.playerIdle, F.playerRunning, F.playerRebuilding, F.playerFailed],
                  [L.playerIdle, L.playerRunning, L.playerRebuilding, L.playerFailed], "player states")
        log.check([F.playerStarted, F.playerStartFailed, F.playerChange], [L.playerStarted, L.playerStartFailed, L.playerChange], "player events")
        log.check([F.playerNone, F.playerScheduleWaiting, F.playerRetry, F.playerRetryRelease, F.playerCutRetry],
                  [L.playerNone, L.playerScheduleWaiting, L.playerRetry, L.playerRetryRelease, L.playerCutRetry], "player actions")
        log.check([F.playerEnqueueStart, F.playerEnqueueSchedule, F.playerEnqueueWait, F.playerEnqueueRefuse],
                  [L.playerEnqueueStart, L.playerEnqueueSchedule, L.playerEnqueueWait, L.playerEnqueueRefuse], "enqueue codes")
        log.check([F.playerCompletionDone, F.playerCompletionIgnore, F.playerCompletionReplay],
                  [L.playerCompletionDone, L.playerCompletionIgnore, L.playerCompletionReplay], "completion codes")
        log.check([F.playerMaxReplays, F.playerEndToleranceFrames], [L.playerMaxReplays, L.playerEndToleranceFrames], "player constants")
        // Every state (and codes beyond them), event, running flag and failure count around the limit.
        for state in -2...6 {
            log.check(F.playerEnqueue(state: state), L.playerEnqueue(state: state), "\(state)")
            for event in -1...4 {
                for running in [false, true] {
                    for failures: Int64 in [.min, -1, 0, 1, 2, 5, 6, 7, 100, .max] {
                        let f = F.playerStep(state: state, event: event, engineRunning: running, failures: failures)
                        let l = L.playerStep(state: state, event: event, engineRunning: running, failures: failures)
                        log.check([f.state, f.action], [l.state, l.action], describe(state, event, running, failures))
                    }
                }
            }
        }
        var r = DiffRandom(seed: 2026_10_13)
        let limit: Int64 = 1 << 40
        var positions: [Int64] = [0, 1, -1, 4095, 4096, 4097, 47_999, 48_000, 48_001, limit, -limit]
        for _ in 0..<2_000 { positions.append(r.int64(-limit ... limit)) }
        for end in positions.prefix(40) + [0, 1024, 48_000, 96_000] {
            for position in positions.prefix(60) + [end - 4097, end - 4096, end - 4095, end, end + 1] {
                for bits in 0..<8 {
                    let same = bits & 1 == 1, running = bits & 2 == 2, has = bits & 4 == 4
                    let p: Int64? = has ? position : nil
                    log.check(F.playerCompletion(sameGeneration: same, engineRunning: running, position: p, endFrame: end),
                              L.playerCompletion(sameGeneration: same, engineRunning: running, position: p, endFrame: end),
                              describe(same, running, p as Any, end))
                }
            }
        }
        for _ in 0..<20_000 {
            let end = r.int64(-limit ... limit), position = r.int64(-limit ... limit)
            log.check(F.playerCompletion(sameGeneration: true, engineRunning: true, position: position, endFrame: end),
                      L.playerCompletion(sameGeneration: true, engineRunning: true, position: position, endFrame: end),
                      describe(position, end))
        }
        var cuts: [Int64] = Array(-10...100) + [.min, .max]
        for _ in 0..<1_000 { cuts.append(r.int64(.min ... .max)) }
        for c in cuts { log.check(F.playerReplays(cuts: c), L.playerReplays(cuts: c), "\(c)") }
        log.finish(minimumCases: 44_000)
    }

    // MARK: Devices

    private static let names = ["MacBook Pro Speakers", "MacBook Pro Microphone", "External Headphones", "BlackHole 2ch",
                                "BlackHole 16ch", "blackhole 64CH", "My BLACKHOLE", "Black Hole", "S6-L", "AirPods Pro",
                                "USB Audio", "LG HDR 4K", "Studio Display", "Ponte Tap", "Zoom Audio", "Динамики MacBook",
                                "Écouteurs", "", "2ch", "headphone", "HEADPHONES", "Multi-Output Device"]
    private static let uids = ["BuiltInSpeakerDevice", "BuiltInMicrophoneDevice", "BuiltInHeadphoneOutputDevice",
                               "BlackHole2ch_UID", "ai.ponte.tap.123", "ai.ponte.tap.", "ai.ponte.ta", "AI.PONTE.TAP.1",
                               "296C1429", "AppleUSBAudioEngine:x", "", "x-headphone-y"]
    private static let transports: [UInt32] = [AudioRules.transportBuiltIn, AudioRules.transportAggregate, AudioRules.transportVirtual,
                                               AudioRules.transportPCI, AudioRules.transportUSB, AudioRules.transportFireWire,
                                               AudioRules.transportBluetooth, AudioRules.transportBluetoothLE, AudioRules.transportHDMI,
                                               AudioRules.transportDisplayPort, AudioRules.transportAirPlay, AudioRules.transportAVB,
                                               AudioRules.transportThunderbolt, AudioRules.transportContinuityWired,
                                               AudioRules.transportContinuityWireless, 0, 1, 0xFFFF_FFFF]

    @Test func deviceRules() {
        let log = DiffLog("isBlackHole, isPonteAggregate, deviceKind, echoRisk, isExcludedForMonitoring")
        for name in Self.names + Self.uids {
            log.check(F.isBlackHole(name: name), L.isBlackHole(name: name), name)
            log.check(F.isPonteAggregate(uid: name), L.isPonteAggregate(uid: name), name)
        }
        for name in Self.names {
            for uid in Self.uids {
                for transport in Self.transports {
                    for input in -1...2 {
                        for output in -1...2 {
                            log.check(F.deviceKind(name: name, uid: uid, transportType: transport, inputChannels: input, outputChannels: output),
                                      L.deviceKind(name: name, uid: uid, transportType: transport, inputChannels: input, outputChannels: output),
                                      describe(name, uid, transport, input, output))
                        }
                    }
                }
            }
        }
        var r = DiffRandom(seed: 8)
        for _ in 0..<5_000 {
            let name = r.text(maxPieces: 12) + r.pick(["", "BlackHole", "headphone"]) + r.text(maxPieces: 3)
            let uid = r.pick(["", "ai.ponte.tap."]) + r.text(maxPieces: 6)
            let transport = r.bool() ? r.pick(Self.transports) : UInt32(truncatingIfNeeded: r.next())
            let input = r.int(-2...4), output = r.int(-2...4)
            log.check(F.deviceKind(name: name, uid: uid, transportType: transport, inputChannels: input, outputChannels: output),
                      L.deviceKind(name: name, uid: uid, transportType: transport, inputChannels: input, outputChannels: output),
                      describe(name, uid, transport, input, output))
            log.check(F.isBlackHole(name: name), L.isBlackHole(name: name), name)
            log.check(F.isPonteAggregate(uid: uid), L.isPonteAggregate(uid: uid), uid)
        }
        for kind in -3...20 {
            log.check(F.echoRisk(kind: kind), L.echoRisk(kind: kind), "\(kind)")
            log.check(F.isExcludedForMonitoring(kind: kind), L.isExcludedForMonitoring(kind: kind), "\(kind)")
        }
        log.finish(minimumCases: 90_000)
    }

    @Test func devicePicks() {
        let log = DiffLog("pickBlackHoleIndex, pickMicIndex, pickListenOutputIndex, matchDeviceIndex")
        var r = DiffRandom(seed: 9)
        log.check(F.pickBlackHoleIndex(names: [], outputChannels: []), L.pickBlackHoleIndex(names: [], outputChannels: []), "empty")
        log.check(F.pickMicIndex(kinds: [], inputChannels: [], defaultIndex: 0), L.pickMicIndex(kinds: [], inputChannels: [], defaultIndex: 0), "empty")
        for _ in 0..<20_000 {
            let n = r.int(0...14)
            let names = (0..<n).map { _ in r.pick(Self.names) }
            let uids = (0..<n).map { _ in r.pick(Self.uids) }
            let channels = (0..<n).map { _ in r.int(-1...16) }
            let kinds = (0..<n).map { _ in r.int(-1...15) }
            let def = r.int(-2...(n + 1))
            log.check(F.pickBlackHoleIndex(names: names, outputChannels: channels), L.pickBlackHoleIndex(names: names, outputChannels: channels), describe(names, channels))
            log.check(F.pickMicIndex(kinds: kinds, inputChannels: channels, defaultIndex: def), L.pickMicIndex(kinds: kinds, inputChannels: channels, defaultIndex: def), describe(kinds, channels, def))
            log.check(F.pickListenOutputIndex(kinds: kinds, outputChannels: channels, defaultIndex: def), L.pickListenOutputIndex(kinds: kinds, outputChannels: channels, defaultIndex: def), describe(kinds, channels, def))
            let query = r.pick([r.pick(Self.names), r.pick(Self.uids), "macbook", "PRO", "", "2ch", "s6", r.text(maxPieces: 3)])
            log.check(F.matchDeviceIndex(query: query, names: names, uids: uids), L.matchDeviceIndex(query: query, names: names, uids: uids), describe(query, names, uids))
        }
        log.finish(minimumCases: 80_000)
    }

    // MARK: App catalog

    private static let bundleIDs = ["com.apple.FaceTime", "com.apple.Safari", "com.browseros.BrowserClaw", "com.google.Chrome",
                                    "com.microsoft.teams2", "net.whatsapp.WhatsApp", "org.telegram.desktop", "ru.keepcoder.Telegram",
                                    "us.zoom.xos", "com.browseros.BrowserClaw.helper", "com.browseros",
                                    "com.google.Chrome.helper", "com.google.Chrome.helper.Renderer", "com.google", "com.google.ChromeX",
                                    "com.apple.WebKit.GPU", "com.apple.avconferenced", "com.apple.TelephonyUtilities",
                                    "com.apple.Music", "us.zoom.xos.helper", "US.ZOOM.XOS", "", "com", "com."]

    @Test func appCatalog() {
        let log = DiffLog("knownCallAppIndex, companions, tap targets, parentAppIndex, ownerSource, ranks")
        for a in Self.bundleIDs {
            log.check(F.knownCallAppIndex(bundleID: a), L.knownCallAppIndex(bundleID: a), a)
            log.check(F.isKnownCallApp(bundleID: a), L.isKnownCallApp(bundleID: a), a)
            for b in Self.bundleIDs {
                log.check(F.isCompanionProcess(processBundleID: a, targetBundleID: b), L.isCompanionProcess(processBundleID: a, targetBundleID: b), describe(a, b))
                for c in Self.bundleIDs where c.count % 3 == a.count % 3 {
                    for (pid, me) in [(Int32(5), Int32(9)), (9, 9), (-1, -1), (0, 1)] {
                        log.check(F.isTapTargetProcess(processBundleID: a, ownerBundleID: b, targetBundleID: c, pid: pid, selfPID: me),
                                  L.isTapTargetProcess(processBundleID: a, ownerBundleID: b, targetBundleID: c, pid: pid, selfPID: me),
                                  describe(a, b, c, pid, me))
                    }
                }
            }
        }
        var r = DiffRandom(seed: 10)
        for _ in 0..<20_000 {
            let apps = (0..<r.int(0...10)).map { _ in r.pick(Self.bundleIDs) }
            let helper = r.pick(Self.bundleIDs) + r.pick(["", ".", ".helper", ".x.y", "x", r.text(maxPieces: 2)])
            log.check(F.parentAppIndex(helperBundleID: helper, appBundleIDs: apps), L.parentAppIndex(helperBundleID: helper, appBundleIDs: apps), describe(helper, apps))
        }
        for bits in 0..<32 {
            let flags = (0..<5).map { bits & (1 << $0) != 0 }
            log.check(F.ownerSource(selfIsRegularApp: flags[0], hasAppBundlePath: flags[1], hasResponsibleApp: flags[2], hasRegularParentApp: flags[3], hasPrefixParent: flags[4]),
                      L.ownerSource(selfIsRegularApp: flags[0], hasAppBundlePath: flags[1], hasResponsibleApp: flags[2], hasRegularParentApp: flags[3], hasPrefixParent: flags[4]), "\(bits)")
        }
        for pid in Int32(-2)...3 {
            for owner in Int32(-2)...3 {
                for me in Int32(-2)...3 {
                    log.check(F.isSelfProcess(pid: pid, ownerPID: owner, selfPID: me), L.isSelfProcess(pid: pid, ownerPID: owner, selfPID: me), describe(pid, owner, me))
                }
            }
        }
        for bits in 0..<8 {
            let a = bits & 1 == 1, b = bits & 2 == 2, c = bits & 4 == 4
            log.check(F.shouldListApp(isRegularApp: a, isPlaying: b, isKnownCallApp: c), L.shouldListApp(isRegularApp: a, isPlaying: b, isKnownCallApp: c), describe(a, b, c))
            log.check(F.appRank(isKnownCallApp: a, isPlaying: b), L.appRank(isKnownCallApp: a, isPlaying: b), describe(a, b))
        }
        log.finish(minimumCases: 30_000)
    }

    @Test func pathsOrderAndText() {
        let log = DiffLog("outermostAppPathLength, appSortOrder, foldedBytes, containsCI")
        let parts = ["/", "Applications", "Google Chrome.app", "Contents", ".app", "x.app", "My.application", "Téléphone.app",
                     "zoom.us.app", "Frameworks", "Helpers", "Helper.app", "MacOS", "usr", "bin", "afplay", "a", ".", ".app/"]
        var r = DiffRandom(seed: 11)
        for _ in 0..<30_000 {
            var path = r.bool() ? "/" : ""
            for i in 0..<r.int(0...7) { path += (i > 0 ? "/" : "") + r.pick(parts) }
            log.check(F.outermostAppPathLength(path), L.outermostAppPathLength(path), path)
        }
        let appNames = ["notes", "Zoom", "Music", "Notes", "x", "zoom", "Zoom ", "Ätna", "Telegram", "telegram", "", "Safari (Meet)", "A", "a", "B"]
        log.check(F.appSortOrder(ranks: [], names: []), L.appSortOrder(ranks: [], names: []), "empty")
        for _ in 0..<5_000 {
            let n = r.int(0...40)
            let ranks = (0..<n).map { _ in r.int(-1...4) }
            let names = (0..<n).map { _ in r.bool() ? r.pick(appNames) : r.text(maxPieces: 3) }
            log.check(F.appSortOrder(ranks: ranks, names: names), L.appSortOrder(ranks: ranks, names: names), describe(ranks, names))
        }
        for _ in 0..<20_000 {
            let s = r.text(maxPieces: 20)
            log.check(F.foldedBytes(s), L.foldedBytes(s), s)
            let needle = r.pick(["", r.text(maxPieces: 2), String(s.prefix(3)).uppercased(), String(s.suffix(2)), "PRO", "blackhole"])
            log.check(F.containsCI(s, needle), L.containsCI(s, needle), describe(s, needle))
        }
        let long = String(repeating: "Ab Яz", count: 4_000)
        log.check(F.foldedBytes(long), L.foldedBytes(long), "long text")
        log.finish(minimumCases: 75_000)
    }
}
