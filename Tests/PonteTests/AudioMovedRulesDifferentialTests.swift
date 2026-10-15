// Owned by the t27 agent. The PonteAudio decisions moved into audio_rules.t27 / device_rules.t27 on 2026-10-11
// (from PCM, HAL, AppAudioTapSource, AudioProcesses, RunningAudioAppCatalog, DeviceAudioPlayer, WAVFileSink and
// the app), against the Swift expressions they replaced (AudioRulesLegacy), bit for bit.
import AVFoundation
import CoreAudio
import Foundation
import Testing
@testable import PonteAudio

private typealias F = AudioRules
private typealias L = AudioRulesLegacy

@Suite("Differential: moved audio rules") struct AudioMovedRulesDifferentialTests {

    @Test func osCodes() {
        let log = DiffLog("audio OS codes")
        log.check([F.formatOther, F.formatFloat32, F.formatFloat64, F.formatInt16, F.formatInt32],
                  [AVAudioCommonFormat.otherFormat, .pcmFormatFloat32, .pcmFormatFloat64, .pcmFormatInt16, .pcmFormatInt32]
                      .map { Int($0.rawValue) }, "AVAudioCommonFormat")
        log.check([F.inputHaveData, F.inputNoDataNow, F.inputEndOfStream],
                  [AVAudioConverterInputStatus.haveData, .noDataNow, .endOfStream].map(\.rawValue), "AVAudioConverterInputStatus")
        log.check(F.pidOwnerPrefix, L.pidOwnerPrefix, "pidOwnerPrefix")
        log.finish(minimumCases: 3)
    }

    @Test func signalTapAndFlush() {
        let log = DiffLog("hasSignal, tapListsProcesses, flushesConverter, converterInput")
        var r = DiffRandom(seed: 101)
        let edges = DiffRandom.floatEdges
        for p in edges { for q in edges { log.check(F.hasSignal(peak: p, rms: q), L.hasSignal(peak: p, rms: q), describe(p, q)) } }
        for _ in 0..<300_000 {
            let p = r.float(), q = r.float()
            log.check(F.hasSignal(peak: p, rms: q), L.hasSignal(peak: p, rms: q), describe(p, q))
        }
        for g in [false, true] { log.check(F.tapListsProcesses(isGlobal: g), L.tapListsProcesses(isGlobal: g), "\(g)") }
        for g in [false, true] {
            for h in [false, true] {
                log.check(F.tapMuteBehavior(isGlobal: g, hearOriginal: h), L.tapMuteBehavior(isGlobal: g, hearOriginal: h), "mute \(g) \(h)")
            }
        }
        for i in -3...40 {
            for n in -3...40 {
                for d in [false, true] {
                    log.check(F.flushesConverter(index: i, count: n, nextFormatDiffers: d),
                              L.flushesConverter(index: i, count: n, nextFormatDiffers: d), describe(i, n, d))
                }
            }
        }
        for _ in 0..<50_000 {
            let i = r.int(-1_000_000_000...1_000_000_000), n = r.pick([i + 1, r.int(-1_000_000_000...1_000_000_000)]), d = r.bool()
            log.check(F.flushesConverter(index: i, count: n, nextFormatDiffers: d),
                      L.flushesConverter(index: i, count: n, nextFormatDiffers: d), describe(i, n, d))
        }
        for s in [false, true] {
            for f in [false, true] { log.check(F.converterInput(supplied: s, final: f), L.converterInput(supplied: s, final: f), describe(s, f)) }
        }
        log.finish(minimumCases: 350_000)
    }

    @Test func bufferLists() {
        let log = DiffLog("usesBuffer, bufferListFrames, bufferListChannels, bufferListShape")
        var r = DiffRandom(seed: 102)
        for d in [false, true] {
            for c in -5...70 { log.check(F.usesBuffer(hasData: d, channels: c), L.usesBuffer(hasData: d, channels: c), describe(d, c)) }
        }
        log.check(F.bufferListFrames(byteSizes: [], channels: [], maxFrames: 100), L.bufferListFrames(byteSizes: [], channels: [], maxFrames: 100), "empty")
        log.check(F.bufferListChannels([]), L.bufferListChannels([]), "empty")
        for _ in 0..<60_000 {
            let n = r.int(0...64)
            let sizes = (0..<n).map { _ in r.pick([r.int(-100...100), r.int(0...10_000_000), 0, 4, 8]) }
            let channels = (0..<n).map { _ in r.int(-2...8) }
            let maxFrames = r.pick([r.int(-10...100_000), Int.max, 0, 4096])
            log.check(F.bufferListFrames(byteSizes: sizes, channels: channels, maxFrames: maxFrames),
                      L.bufferListFrames(byteSizes: sizes, channels: channels, maxFrames: maxFrames), describe(sizes, channels, maxFrames))
            log.check(F.bufferListChannels(channels), L.bufferListChannels(channels), describe(channels))
        }
        // The real-time variant reads an AudioBufferList in place: same answers as the legacy downmix shape.
        let data = UnsafeMutableRawPointer.allocate(byteCount: 16, alignment: 16)
        defer { data.deallocate() }
        for _ in 0..<40_000 {
            let n = r.int(0...20)
            let abl = AudioBufferList.allocate(maximumBuffers: max(n, 1))
            defer { free(abl.unsafeMutablePointer) }
            abl.count = n
            var sizes: [Int] = [], channels: [Int] = [], hasData: [Bool] = []
            for i in 0..<n {
                let size = r.pick([r.int(0...100), r.int(0...4_000_000), 0, 8])
                let c = r.int(0...6)
                let has = r.int(0...5) > 0
                abl[i] = AudioBuffer(mNumberChannels: UInt32(c), mDataByteSize: UInt32(size), mData: has ? data : nil)
                sizes.append(size); channels.append(c); hasData.append(has)
            }
            let maxFrames = r.pick([r.int(0...100_000), 4096, 0])
            let used = (0..<n).filter { L.usesBuffer(hasData: hasData[$0], channels: channels[$0]) }
            let shape = F.bufferListShape(abl, maxFrames: maxFrames)
            log.check(shape.frames, L.bufferListFrames(byteSizes: used.map { sizes[$0] }, channels: used.map { channels[$0] },
                                                      maxFrames: maxFrames), describe(sizes, channels, hasData, maxFrames))
            log.check(shape.channels, L.bufferListChannels(used.map { channels[$0] }), describe(channels, hasData))
        }
        log.finish(minimumCases: 200_000)
    }

    @Test func monoAndFormats() {
        let log = DiffLog("monoBlocks, monoPerBlock, monoSupported, isMonoFloat32, isPlainMono")
        var r = DiffRandom(seed: 103)
        for i in [false, true] {
            for c in -5...300 {
                log.check(F.monoBlocks(interleaved: i, channels: c), L.monoBlocks(interleaved: i, channels: c), describe(i, c))
                log.check(F.monoPerBlock(interleaved: i, channels: c), L.monoPerBlock(interleaved: i, channels: c), describe(i, c))
            }
        }
        for f in -5...20 {
            log.check(F.monoSupported(format: f), L.monoSupported(format: f), "\(f)")
            for c in -2...4 {
                log.check(F.isMonoFloat32(format: f, channels: c), L.isMonoFloat32(format: f, channels: c), describe(f, c))
                for i in [false, true] {
                    log.check(F.isPlainMono(format: f, channels: c, interleaved: i), L.isPlainMono(format: f, channels: c, interleaved: i),
                              describe(f, c, i))
                }
            }
        }
        for _ in 0..<20_000 {
            let f = r.int(-1_000_000...1_000_000), c = r.int(-1_000_000...1_000_000), i = r.bool()
            log.check(F.monoSupported(format: f), L.monoSupported(format: f), "\(f)")
            log.check(F.isPlainMono(format: f, channels: c, interleaved: i), L.isPlainMono(format: f, channels: c, interleaved: i), describe(f, c, i))
            log.check(F.monoBlocks(interleaved: i, channels: c), L.monoBlocks(interleaved: i, channels: c), describe(i, c))
        }
        log.finish(minimumCases: 60_000)
    }

    @Test func fourCCAndMeter() {
        let log = DiffLog("isPrintableFourCC, meterFraction")
        var r = DiffRandom(seed: 104)
        // Every value of each byte with the other three printable or not.
        for shift in [0, 8, 16, 24] {
            for b in 0...255 {
                for base: UInt32 in [0x2020_2020, 0x6C70_636D, 0x0000_0000, 0x7F7F_7F7F] {
                    let mask = ~(UInt32(0xFF) << UInt32(shift))
                    let v = (base & mask) | (UInt32(b) << UInt32(shift))
                    log.check(F.isPrintableFourCC(v), L.isPrintableFourCC(v), "\(v)")
                }
            }
        }
        for _ in 0..<300_000 {
            let v = UInt32(truncatingIfNeeded: r.next())
            log.check(F.isPrintableFourCC(v), L.isPrintableFourCC(v), "\(v)")
        }
        for x in DiffRandom.floatEdges { log.check(F.meterFraction(level: x), L.meterFraction(level: x), "\(x)") }
        for _ in 0..<300_000 {
            let x = r.pick([r.float(), Float(r.int(0...1_000_000)) / 1_000_000, Float(r.int(0...1000)) / 1e7])
            log.check(F.meterFraction(level: x), L.meterFraction(level: x), "\(x)")
        }
        log.finish(minimumCases: 600_000)
    }

    @Test func processOwners() {
        let log = DiffLog("process and owner rules")
        var r = DiffRandom(seed: 105)
        let pids: [Int32] = Array(-5...5) + [.min, .max, 100, 501, -100]
        for a in pids {
            log.check(F.isProcessPID(a), L.isProcessPID(a), "\(a)")
            for b in pids {
                log.check(F.responsibleUsable(responsiblePID: a, pid: b), L.responsibleUsable(responsiblePID: a, pid: b), describe(a, b))
                log.check(F.parentContinues(parentPID: a, current: b), L.parentContinues(parentPID: a, current: b), describe(a, b))
            }
        }
        for _ in 0..<100_000 {
            let a = Int32(truncatingIfNeeded: r.next()), b = r.pick([a, Int32(truncatingIfNeeded: r.next()), 1])
            log.check(F.isProcessPID(a), L.isProcessPID(a), "\(a)")
            log.check(F.responsibleUsable(responsiblePID: a, pid: b), L.responsibleUsable(responsiblePID: a, pid: b), describe(a, b))
            log.check(F.parentContinues(parentPID: a, current: b), L.parentContinues(parentPID: a, current: b), describe(a, b))
        }
        let bools = [false, true]
        for a in bools {
            for b in bools {
                log.check(F.isRegularApp(policyRegular: a, hasBundleID: b), L.isRegularApp(policyRegular: a, hasBundleID: b), describe(a, b))
                log.check(F.ownerIDSource(hasHALBundleID: a, hasAppBundleID: b), L.ownerIDSource(hasHALBundleID: a, hasAppBundleID: b), describe(a, b))
                log.check(F.ownerNameSource(hasAppName: a, hasPath: b), L.ownerNameSource(hasAppName: a, hasPath: b), describe(a, b))
                log.check(F.appPlaying(alreadyPlaying: a, processPlaying: b), L.appPlaying(alreadyPlaying: a, processPlaying: b), describe(a, b))
                log.check(F.prefersOwner(candidateRegular: a, currentRegular: b), L.prefersOwner(candidateRegular: a, currentRegular: b), describe(a, b))
                for c in bools {
                    log.check(F.bundleNameSource(hasRunningName: a, hasDisplayName: b, hasBundleName: c),
                              L.bundleNameSource(hasRunningName: a, hasDisplayName: b, hasBundleName: c), describe(a, b, c))
                    for d in bools {
                        log.check(F.pathOwnerIsRegular(hasRunning: a, runningRegular: b, hasSelf: c, selfRegular: d),
                                  L.pathOwnerIsRegular(hasRunning: a, runningRegular: b, hasSelf: c, selfRegular: d), describe(a, b, c, d))
                    }
                }
            }
        }
        for k in -5...30 { log.check(F.needsHeadphones(kind: k), L.needsHeadphones(kind: k), "\(k)") }
        for _ in 0..<10_000 {
            let k = r.int(-1_000_000...1_000_000)
            log.check(F.needsHeadphones(kind: k), L.needsHeadphones(kind: k), "\(k)")
        }
        log.finish(minimumCases: 300_000)
    }

    @Test func movedOutOfSwift() {
        let log = DiffLog("relay transitions, output placement, player, mic slice and cycle, tap rebuild")
        let bools = [false, true]
        for a in bools { for b in bools {
            log.check(F.relaySamplesLow(filling: a, hasQueued: b), L.relaySamplesLow(filling: a, hasQueued: b), "\(a) \(b)")
            for action in -1...6 {
                log.check(F.relayFillingAfter(action: action, sent: a, filling: b), L.relayFillingAfter(action: action, sent: a, filling: b), "\(action) \(a) \(b)")
                log.check(F.tapRebuilds(action: action, updated: a), L.tapRebuilds(action: action, updated: a), "\(action) \(a)")
            }
            for c in bools { for d in bools { for e in bools {
                log.check(F.playerRechecks(ignored: a, finished: b, stillPending: c, engineRunning: d, sameEngine: e),
                          L.playerRechecks(ignored: a, finished: b, stillPending: c, engineRunning: d, sameEngine: e), "\(a) \(b) \(c) \(d) \(e)")
            } } }
        } }
        for n in Array(-3...10) + [Int.min, Int.max] {
            log.check(F.relayCanTrim(count: n), L.relayCanTrim(count: n), "\(n)")
            log.check(F.playerCanRebuild(state: n), L.playerCanRebuild(state: n), "\(n)")
        }
        let devices: [Int?] = [nil, 0, 1, 72, 90, Int(Int32.max)]
        for unit in devices { for ours in [0, 72, 90] {
            log.check(F.unitBindsBeforeStart(unitDevice: unit, ourDevice: ours), L.unitBindsBeforeStart(unitDevice: unit, ourDevice: ours), "\(String(describing: unit)) \(ours)")
            log.check(F.unitRebindsAfterStart(unitDevice: unit, ourDevice: ours), L.unitRebindsAfterStart(unitDevice: unit, ourDevice: ours), "\(String(describing: unit)) \(ours)")
            for ms: Int64 in [-1, 0, 999, 1000, 60_000] { for outputs in [0, 1, 3] { for includes in bools {
                log.check(F.outputMisplaced(unitDevice: unit, ourDevice: ours, msSinceStart: ms, outputs: outputs, outputsIncludeOurs: includes),
                          L.outputMisplaced(unitDevice: unit, ourDevice: ours, msSinceStart: ms, outputs: outputs, outputsIncludeOurs: includes),
                          "\(String(describing: unit)) \(ours) \(ms) \(outputs) \(includes)")
            } } }
        } }
        var r = DiffRandom(seed: 0xA0D10)
        for _ in 0..<40_000 {
            let end = Int64(r.int(0...10_000_000)), position = Int64(r.int(0...10_000_000)), frames = Int64(r.int(0...48_000))
            log.check(F.streamEnd(end, position: position, frames: frames), L.streamEnd(end, position: position, frames: frames), "\(end) \(position) \(frames)")
            let failures = r.bool() ? Int64(r.int(-5...100)) : Int64(bitPattern: r.next())
            log.check(F.rebuildFailuresNext(failures), L.rebuildFailuresNext(failures), "\(failures)")
            let io = r.int(-100...20_000), hint = r.int(-100...20_000)
            log.check(F.micSliceFrames(ioFrames: io, hintFrames: hint), L.micSliceFrames(ioFrames: io, hintFrames: hint), "\(io) \(hint)")
            let frames2 = r.int(-10...9000), capacity = r.int(-10...9000)
            log.check(F.micCycleFits(frames: frames2, capacity: capacity), L.micCycleFits(frames: frames2, capacity: capacity), "\(frames2) \(capacity)")
        }
        log.finish(minimumCases: 160_000)
    }
}
