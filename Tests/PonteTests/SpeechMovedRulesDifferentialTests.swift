// Owned by the t27 agent. The PonteSpeech decisions moved into segment_rules.t27, context_rules.t27 and
// voice_rules.t27 on 2026-10-11 (from AppleTranscriber, VoiceActivity, AudioConversion, the translators and the
// synthesizer), against the Swift expressions they replaced (SpeechRulesLegacy), bit for bit.
import AVFoundation
import Foundation
import PonteCore
import Testing
import Translation
@testable import PonteSpeech

private typealias F = SpeechRules
private typealias L = SpeechRulesLegacy

/// VoiceActivity as it was, assembled from the legacy oracles (one window per `add`).
private struct LegacyActivity {
    var silence: Double?
    var voice: Double?
    var floorMilli = 0
    var hasFloor = false
    var segments: [ClosedRange<Double>] = []
    var lastEnd = 0.0

    mutating func add(level: Int, start: Double, duration: Double) -> Bool {
        let isVoice = L.isVoice(level: level, floorMilli: floorMilli)
        let step = L.activity(voice: isVoice, silenceStart: silence, voiceStart: voice, start: start)
        if let closed = step.closed {
            segments.append(closed)
            segments.removeFirst(L.segmentsToDrop(count: segments.count))
        }
        silence = step.silenceStart
        voice = step.voiceStart
        lastEnd = start + duration
        floorMilli = L.nextNoiseFloor(floorMilli: floorMilli, hasFloor: hasFloor, level: level, durationMs: L.millis(duration))
        hasFloor = true
        return isVoice
    }

    func voiceDuration(in range: ClosedRange<Double>) -> Double {
        var all = segments
        if let v = voice { all.append(v...L.openSegmentEnd(voiceStart: v, silenceStart: silence, lastEnd: lastEnd)) }
        return all.reduce(0) { $0 + L.overlapSeconds(lower: $1.lowerBound, upper: $1.upperBound,
                                                     rangeLower: range.lowerBound, rangeUpper: range.upperBound) }
    }
}

@Suite("Differential: moved speech rules") struct SpeechMovedRulesDifferentialTests {

    @Test func constantsAndCodes() {
        let log = DiffLog("moved speech constants and codes")
        log.check([F.langCode(.ptBR), F.langCode(.ru)], [0, 1], "langCode")
        for lang in Lang.allCases {
            log.check(F.transcriberKind(lang), L.transcriberKind(language: F.langCode(lang)), lang.rawValue)
            log.check(F.preferredVoiceNames(lang), L.preferredVoiceNames(language: F.langCode(lang)), lang.rawValue)
        }
        log.check([F.moduleSpeech, F.moduleDictation], [0, 1], "module codes")
        log.check([F.fastResultsDefault, F.ownCutsDefault], [L.fastResultsDefault, L.ownCutsDefault], "defaults")
        log.check(F.flushFrames, L.flushFrames, "flushFrames")
        log.check([F.inputHaveData, F.inputNoDataNow, F.inputEndOfStream],
                  [AVAudioConverterInputStatus.haveData, .noDataNow, .endOfStream].map(\.rawValue), "AVAudioConverterInputStatus")
        log.check([F.eventNone, F.eventFinal, F.eventDiscard], [0, 1, 2], "event codes")
        log.check([F.kindOther, F.kindTimeout, F.kindAssetsMissing, F.kindUnsupported, F.kindCloudRequest, F.kindKeyMissing,
                   F.kindRefused, F.kindEmpty, F.kindURL], Array(0...8), "error kinds")
        log.check([F.availInstalled, F.availSupported, F.availUnsupported, F.availUnknown], [0, 1, 2, 3], "avail codes")
        log.check([AppleTranslator.availabilityCode(.installed), AppleTranslator.availabilityCode(.supported),
                   AppleTranslator.availabilityCode(.unsupported)], [F.availInstalled, F.availSupported, F.availUnsupported],
                  "LanguageAvailability.Status")
        log.check([F.packReady, F.packMissing, F.packUnavailable], [0, 1, 2], "pack codes")
        log.check([F.voiceSourceSaved, F.voiceSourceBest, F.voiceSourceLanguage], [0, 1, 2], "voice source codes")
        log.finish(minimumCases: 15)
    }

    @Test func timeAndLevel() {
        let log = DiffLog("millis, level, meterWindowFrames, stallSilenceFrames")
        var r = DiffRandom(seed: 201)
        for k in -20_000...20_000 {
            let s = Double(k) / 2000   // every half millisecond: the rounding ties
            log.check(F.millis(s), L.millis(s), "\(s)")
        }
        for _ in 0..<200_000 {
            let s = r.pick([r.finiteDouble(1e6), r.finiteDouble(10), Double(r.int(-100_000...100_000)) / 1000 + 0.0005])
            log.check(F.millis(s), L.millis(s), "\(s)")
        }
        for _ in 0..<300_000 {
            let x = r.pick([Float(r.int(0...100_000)) / 100_000, Float(r.int(-1_000_000...1_000_000)) / 1e9,
                            Float(r.int(0...1_000_000)) / 1e6 * Float(r.int(1...1000))])
            log.check(F.level(rms: x), L.level(rms: x), "\(x)")
        }
        for x in [Float(0), -0.0, 1, 0.000005, 0.000015, 0.000025, 1e-9, .leastNonzeroMagnitude, 1e9] {
            log.check(F.level(rms: x), L.level(rms: x), "\(x)")
        }
        for rate in 0...200_000 where rate % 7 == 0 || rate % 1000 == 0 {
            let d = Double(rate)
            log.check(F.meterWindowFrames(sampleRate: d), L.meterWindowFrames(sampleRate: d), "\(d)")
            log.check(F.stallSilenceFrames(sampleRate: d), L.stallSilenceFrames(sampleRate: d), "\(d)")
        }
        for _ in 0..<50_000 {
            let d = r.pick([r.finiteDouble(400_000), Double(r.int(-10...400_000)) + 0.5, r.finiteDouble(1e12)])
            log.check(F.meterWindowFrames(sampleRate: d), L.meterWindowFrames(sampleRate: d), "\(d)")
            log.check(F.stallSilenceFrames(sampleRate: d), L.stallSilenceFrames(sampleRate: d), "\(d)")
        }
        log.finish(minimumCases: 690_000)
    }

    @Test func arrivalsAndMeasures() {
        let log = DiffLog("arrivals, measure, finalizeFlags, lastCutAgoMs, cutTime")
        var r = DiffRandom(seed: 202)
        for c in -10...6000 {
            log.check(F.trimsArrivals(count: c), L.trimsArrivals(count: c), "\(c)")
            log.check(F.trimsTimings(count: c), L.trimsTimings(count: c), "\(c)")
            log.check(F.segmentsToDrop(count: c), L.segmentsToDrop(count: c), "\(c)")
        }
        let grid: [Double] = [0, 0.0005, 0.001, 0.05, 0.0499, 0.0501, 1, 1.0005, 119.9995, 120, 120.0005, 240, -1]
        for a in grid {
            for b in grid {
                log.check(F.keepsArrival(audioEnd: a, end: b), L.keepsArrival(audioEnd: a, end: b), describe(a, b))
                log.check(F.arrivalCovers(audioEnd: a, t: b), L.arrivalCovers(audioEnd: a, t: b), describe(a, b))
            }
        }
        for _ in 0..<200_000 {
            let a = r.double(), b = r.pick([r.double(), a + 120, a + 0.0005, a])
            log.check(F.keepsArrival(audioEnd: a, end: b), L.keepsArrival(audioEnd: a, end: b), describe(a, b))
            log.check(F.arrivalCovers(audioEnd: a, t: b), L.arrivalCovers(audioEnd: a, t: b), describe(a, b))
        }
        let times: [Double] = [0, 0.02, 0.5, 1, 1.5, 2, 2.0, 3.25, 10]
        let optional: [Double?] = [nil] + times.map { Optional($0) }
        for now in times {
            for phrase in times {
                for voice in optional {
                    for silence in optional {
                        let old = L.measure(now: now, phraseStart: phrase, voiceStart: voice, silence: silence)
                        let start = F.measureStart(phraseStart: phrase, voiceStart: voice)
                        log.check(start, old.start, describe(now, phrase, voice as Any, silence as Any))
                        log.check(F.measurePause(now: now, start: start, silence: silence), old.pause, describe(now, phrase, voice as Any, silence as Any))
                        log.check(F.measureSpeech(now: now, start: start, silence: silence), old.speech, describe(now, phrase, voice as Any, silence as Any))
                    }
                }
            }
        }
        for _ in 0..<200_000 {
            let now = r.double(), phrase = r.pick([r.double(), now - 1, now])
            let voice: Double? = r.bool() ? nil : r.pick([r.double(), phrase, phrase + 0.5])
            let silence: Double? = r.bool() ? nil : r.pick([r.double(), now - 0.3, phrase])
            let old = L.measure(now: now, phraseStart: phrase, voiceStart: voice, silence: silence)
            let start = F.measureStart(phraseStart: phrase, voiceStart: voice)
            log.check(start, old.start, describe(now, phrase))
            log.check(F.measurePause(now: now, start: start, silence: silence), old.pause, describe(now, phrase))
            log.check(F.measureSpeech(now: now, start: start, silence: silence), old.speech, describe(now, phrase))
            let text = r.bool(), lastVoice = r.pick([r.double(), phrase + 0.05, phrase + 0.0501, phrase])
            let finishing = r.bool(), cuts = r.bool()
            log.check(F.finalizeFlags(hasVolatileText: text, lastVoiceEnd: lastVoice, phraseStart: phrase, finishing: finishing, cutsEnabled: cuts),
                      L.finalizeFlags(hasVolatileText: text, lastVoiceEnd: lastVoice, phraseStart: phrase, finishing: finishing, cutsEnabled: cuts),
                      describe(text, lastVoice, phrase, finishing, cuts))
            let finiteNow = r.finiteDouble(1e6)
            let lastCut: Double? = r.bool() ? nil : r.pick([r.finiteDouble(1e6), finiteNow - 0.0005, finiteNow])
            log.check(F.lastCutAgoMs(now: finiteNow, lastCut: lastCut), L.lastCutAgoMs(now: finiteNow, lastCut: lastCut),
                      describe(finiteNow, lastCut as Any))
            let action = r.int(-1...5), pause = r.int(-100...20_000)
            log.check(F.cutTime(now: now, action: action, pauseMs: pause), L.cutTime(now: now, action: action, pauseMs: pause),
                      describe(now, action, pause))
        }
        log.finish(minimumCases: 1_500_000)
    }

    @Test func cutsEventsAndTimings() {
        let log = DiffLog("stallCut, cutInPhrase, events, advancePhraseStart, timing, range checks")
        var r = DiffRandom(seed: 203)
        let bools = [false, true]
        let spans: [Int?] = [nil, -1, 0, 1, 99, 100, 101, 999, 1000, 1001, 5000, .max, .min]
        for a in bools {
            for b in bools {
                for c in bools {
                    for since in spans {
                        for fed in spans {
                            log.check(F.stallCut(finishing: a, cutsEnabled: b, hasVolatileText: c, msSinceAppend: since, msFedSinceCut: fed),
                                      L.stallCut(finishing: a, cutsEnabled: b, hasVolatileText: c, msSinceAppend: since, msFedSinceCut: fed),
                                      describe(a, b, c, since as Any, fed as Any))
                        }
                    }
                }
                log.check(F.finalEvent(keep: a, partialShown: b), L.finalEvent(keep: a, partialShown: b), describe(a, b))
                log.check(F.partialEvent(keep: a, changed: b), L.partialEvent(keep: a, changed: b), describe(a, b))
            }
        }
        for _ in 0..<300_000 {
            let phrase = r.double()
            let cut: Double? = r.bool() ? nil : r.pick([r.double(), phrase, phrase + 1e-9])
            log.check(F.cutInPhrase(lastCut: cut, phraseStart: phrase), L.cutInPhrase(lastCut: cut, phraseStart: phrase),
                      describe(cut as Any, phrase))
            let t = r.double()
            log.check(F.advancePhraseStart(phrase, to: t), L.advancePhraseStart(phrase, to: t), describe(phrase, t))
            let first: Double? = r.bool() ? nil : r.double()
            let lastStart = r.double(), lastEnd = r.pick([r.double(), lastStart + 0.3])
            let lastWord: (start: Double, end: Double)? = first == nil ? nil : (lastStart, lastEnd)
            let rangeEnd = r.double(), voiceEnd = r.pick([r.double(), lastStart + 0.1, lastEnd, lastStart])
            let old = L.timing(firstWordStart: first, lastWord: lastWord, rangeEnd: rangeEnd, phraseStart: phrase, lastVoiceEnd: voiceEnd)
            let start = F.timingStart(firstWordStart: first, phraseStart: phrase)
            log.check(start, old.start, describe(first as Any, phrase))
            log.check(F.timingEnd(lastWordStart: lastWord?.start, lastWordEnd: lastWord?.end ?? 0, rangeEnd: rangeEnd,
                                  audioStart: start, lastVoiceEnd: voiceEnd), old.end,
                      describe(first as Any, lastStart, lastEnd, rangeEnd, voiceEnd))
            let a = r.double(), b = r.pick([r.double(), a, a + 1])
            log.check(F.rangeMeasurable(start: a, end: b), L.rangeMeasurable(start: a, end: b), describe(a, b))
            let bytes = r.int(-2...3)
            log.check(F.timedWord(start: a, end: b, wordBytes: bytes), L.timedWord(start: a, end: b, wordBytes: bytes), describe(a, b, bytes))
        }
        log.finish(minimumCases: 1_800_000)
    }

    @Test func voiceActivity() {
        let log = DiffLog("VoiceActivity (activityStep, segmentsToDrop, openSegmentEnd, overlapSeconds)")
        var r = DiffRandom(seed: 204)
        // One step from every small state.
        let times: [Double?] = [nil, 0, 0.5, 0.94, 0.95, 0.96, 1]
        for voice in [false, true] {
            for silence in times {
                for start in times.compactMap({ $0 }) {
                    for voiceAt in times {
                        // A real meter never has a voice start after its silence start, or a window before it.
                        if let v = voiceAt, let s0 = silence, v > s0 { continue }
                        if let s0 = silence, start < s0 { continue }
                        let old = L.activity(voice: voice, silenceStart: silence, voiceStart: voiceAt, start: start)
                        var newSilence = silence, newVoice = voiceAt
                        switch F.activityStep(voice: voice, silenceStart: silence, hasVoice: voiceAt != nil, start: start) {
                        case F.activitySegmentCloses: newVoice = start; newSilence = nil
                        case F.activitySilenceEnds: newSilence = nil
                        case F.activitySilenceEndsVoiceStarts: newSilence = nil; newVoice = start
                        case F.activityVoiceStarts: newVoice = start
                        case F.activitySilenceStarts: newSilence = start
                        default: break
                        }
                        log.check([newSilence, newVoice], [old.silenceStart, old.voiceStart], describe(voice, silence as Any, start, voiceAt as Any))
                    }
                }
            }
        }
        // The real meter against the legacy one over long random streams (more than 256 segments).
        for run in 0..<12 {
            var meter = VoiceActivity()
            var legacy = LegacyActivity()
            var t = Double(r.int(0...1000)) / 100
            let windows = run < 3 ? 9000 : r.int(1...3000)
            var loud = false
            for _ in 0..<windows {
                if r.int(0...7) == 0 { loud.toggle() }
                let level = loud ? r.int(500...30_000) : r.pick([0, r.int(0...900), r.int(0...3)])
                let duration = r.pick([0.02, 0.02, 0.01, Double(r.int(1...100)) / 1000])
                log.check(meter.add(level: level, start: t, duration: duration), legacy.add(level: level, start: t, duration: duration),
                          describe(run, t, level))
                t += r.int(0...20) == 0 ? duration + Double(r.int(1...500)) / 1000 : duration
            }
            log.check([meter.silenceStart, meter.voiceStart], [legacy.silence, legacy.voice], "state \(run)")
            log.check(meter.floorMilli, legacy.floorMilli, "floor \(run)")
            log.check(meter.voiceSegments, legacy.segments, "segments \(run)")
            for _ in 0..<500 {
                let a = Double(r.int(0...Int(t * 100))) / 100, b = a + Double(r.int(0...2000)) / 100
                log.check(meter.voiceDuration(in: a...b), legacy.voiceDuration(in: a...b), describe(run, a, b))
            }
        }
        for _ in 0..<200_000 {
            let v = r.double(), s: Double? = r.bool() ? nil : r.double(), e = r.double()
            log.check(F.openSegmentEnd(voiceStart: v, silenceStart: s, lastEnd: e), L.openSegmentEnd(voiceStart: v, silenceStart: s, lastEnd: e),
                      describe(v, s as Any, e))
            let lo = r.double(), hi = r.pick([r.double(), lo + 1]), rl = r.pick([r.double(), lo]), ru = r.pick([r.double(), hi])
            log.check(F.overlapSeconds(lower: lo, upper: hi, rangeLower: rl, rangeUpper: ru),
                      L.overlapSeconds(lower: lo, upper: hi, rangeLower: rl, rangeUpper: ru), describe(lo, hi, rl, ru))
        }
        log.finish(minimumCases: 440_000)
    }

    @Test func conversion() {
        let log = DiffLog("conversionCapacity, converterInput, windowCount, int16/int32, sumSquares + rms")
        var r = DiffRandom(seed: 205)
        let rates: [Double] = [8_000, 11_025, 16_000, 22_050, 24_000, 32_000, 44_100, 48_000, 88_200, 96_000, 192_000]
        for from in rates {
            for to in rates {
                for frames in [0, 1, 2, 3, 160, 320, 441, 480, 512, 1024, 4096, 4800, 44_100, 48_000, 1_000_000] {
                    log.check(F.conversionCapacity(frames: frames, fromRate: from, toRate: to),
                              L.conversionCapacity(frames: frames, fromRate: from, toRate: to), describe(frames, from, to))
                }
            }
        }
        for _ in 0..<100_000 {
            let frames = r.int(0...2_000_000), from = r.pick(rates + [Double(r.int(1_000...200_000))]), to = r.pick(rates)
            log.check(F.conversionCapacity(frames: frames, fromRate: from, toRate: to),
                      L.conversionCapacity(frames: frames, fromRate: from, toRate: to), describe(frames, from, to))
        }
        for fed in [false, true] {
            for final in [false, true] { log.check(F.converterInput(fed: fed, final: final), L.converterInput(fed: fed, final: final), describe(fed, final)) }
        }
        let counts: [Int?] = [nil] + (-5...40).map { Optional($0) }
        for from in -5...40 {
            for count in counts {
                for length in -5...40 {
                    log.check(F.windowCount(from: from, count: count, frameLength: length),
                              L.windowCount(from: from, count: count, frameLength: length), describe(from, count as Any, length))
                }
            }
        }
        for _ in 0..<50_000 {
            let from = r.int(-1_000_000...1_000_000), length = r.int(-1_000_000...1_000_000)
            let count: Int? = r.bool() ? nil : r.int(-1_000_000...1_000_000)
            log.check(F.windowCount(from: from, count: count, frameLength: length),
                      L.windowCount(from: from, count: count, frameLength: length), describe(from, count as Any, length))
        }
        for v in Int16.min...Int16.max { log.check(F.int16ToFloat(v), L.int16ToFloat(v), "\(v)") }
        for _ in 0..<200_000 {
            let v = Int32(truncatingIfNeeded: r.next())
            log.check(F.int32ToFloat(v), L.int32ToFloat(v), "\(v)")
        }
        for v: Int32 in [.min, .max, 0, -1, 1] { log.check(F.int32ToFloat(v), L.int32ToFloat(v), "\(v)") }
        for _ in 0..<1_500 {
            let n = r.pick([r.int(1...400), r.int(4090...4100), r.int(1...12_000), 8192, 1])
            let samples = (0..<n).map { _ in r.pick([r.float(), Float(r.int(-32768...32767)) / 32768]) }
            log.check(F.rms(sumOfSquares: F.sumSquares(samples), count: n), L.rms(samples), "n \(n)")
        }
        log.finish(minimumCases: 400_000)
    }

    @Test func translatorsAndVoices() {
        let log = DiffLog("translator and voice rules")
        var r = DiffRandom(seed: 206)
        for code in -10...10 { log.check(F.effortName(code: code), L.effortName(code: code), "\(code)") }
        for code in [Int.min, Int.max] { log.check(F.effortName(code: code), L.effortName(code: code), "\(code)") }
        for status in -10...1000 { log.check(F.httpSuccess(status: status), L.httpSuccess(status: status), "\(status)") }
        for _ in 0..<20_000 {
            let status = r.int(-1_000_000_000...1_000_000_000)
            log.check(F.httpSuccess(status: status), L.httpSuccess(status: status), "\(status)")
        }
        let bools = [false, true]
        for a in bools {
            log.check(F.preferredEngine(preferClaude: a), L.preferredEngine(preferClaude: a), "\(a)")
            for b in bools {
                log.check(F.rethrowsClaudeError(appleFailed: a, hasApple: b), L.rethrowsClaudeError(appleFailed: a, hasApple: b), describe(a, b))
                log.check(F.emptyTranslation(resultEmpty: a, inputEmpty: b), L.emptyTranslation(resultEmpty: a, inputEmpty: b), describe(a, b))
                log.check(F.voiceSource(hasSaved: a, hasBest: b), L.voiceSource(hasSaved: a, hasBest: b), describe(a, b))
            }
        }
        for engine in -2...5 {
            for code in -2...12 {
                log.check(F.forgetsAppleReady(engine: engine, errorCode: code), L.forgetsAppleReady(engine: engine, errorCode: code), describe(engine, code))
            }
        }
        for ms in -1000...1000 { log.check(F.hasTimeout(ms: ms), L.hasTimeout(ms: ms), "\(ms)") }
        for kind in -3...12 {
            for status in 0...700 {
                log.check(F.errorCode(kind: kind, httpStatus: status), L.errorCode(kind: kind, httpStatus: status), describe(kind, status))
            }
        }
        for status in -5...12 { log.check(F.packResult(status: status), L.packResult(status: status), "\(status)") }
        // Voice order: keys and names drawn from a small pool so that ties happen; names include canonical
        // equivalents (é / e + U+0301) that Swift's String treats as equal.
        let names = ["Luciana", "Felipe", "Felipe (Enhanced)", "Ana", "Älva", "Café", "Cafe\u{301}", "Milena", "Юрий", "", "luciana"]
        let ids = ["com.apple.voice.compact.pt-BR.Luciana", "com.apple.eloquence.pt-BR.Eddy", "a", "b", "é", "e\u{301}", ""]
        for _ in 0..<300_000 {
            let keyA = r.pick([10_000, 11_000, 21_100, 31_001, r.int(-50_000...50_000)]), keyB = r.pick([keyA, 21_100, r.int(-50_000...50_000)])
            let nameA = r.pick(names), nameB = r.pick(names), idA = r.pick(ids), idB = r.pick(ids)
            log.check(F.voiceBefore(keyA: keyA, keyB: keyB, nameOrder: VoiceRanking.order(nameA, nameB), idOrder: VoiceRanking.order(idA, idB)),
                      L.voiceBefore(keyA: keyA, keyB: keyB, nameA: nameA, nameB: nameB, idA: idA, idB: idB),
                      describe(keyA, keyB, nameA, nameB, idA, idB))
        }
        for percent in -10...400 {
            for rate: Float? in [nil, 0, 0.5, 0.4995, 0.5005, 1, 0.123456] {
                log.check(F.setsRate(rate: rate, ratePercent: percent), L.setsRate(rate: rate, ratePercent: percent), describe(rate as Any, percent))
            }
        }
        log.check(F.baseRateMilli(rate: nil), L.baseRateMilli(rate: nil), "nil")
        for _ in 0..<300_000 {
            let rate = r.pick([Float(r.int(0...1_000_000)) / 1_000_000, Float(r.int(-2000...2000)) / 2000, r.pick([Float(0.0005), 0.0015, 0.4995])])
            log.check(F.baseRateMilli(rate: rate), L.baseRateMilli(rate: rate), "\(rate)")
        }
        for milli in -100_000...100_000 { log.check(F.utteranceRate(milli: milli), L.utteranceRate(milli: milli), "\(milli)") }
        for _ in 0..<100_000 {
            let milli = r.int(Int.min / 2...Int.max / 2)
            log.check(F.utteranceRate(milli: milli), L.utteranceRate(milli: milli), "\(milli)")
        }
        log.finish(minimumCases: 930_000)
    }

    @Test func voiceAndSegmentMovedOutOfSwift() {
        let log = DiffLog("genderReadsStored, phraseVoiceStart, arrivalFallback, flushesVolatile, copiesBuffer, converterDownmixes")
        for a in [false, true] {
            log.check(F.genderReadsStored(storedEmpty: a), L.genderReadsStored(storedEmpty: a), "\(a)")
            log.check(F.arrivalFallback(hasMarks: a), L.arrivalFallback(hasMarks: a), "\(a)")
            log.check(F.flushesVolatile(hasVolatile: a), L.flushesVolatile(hasVolatile: a), "\(a)")
            log.check(F.copiesBuffer(sameFormat: a), L.copiesBuffer(sameFormat: a), "\(a)")
        }
        var r = DiffRandom(seed: 0x5E6)
        for _ in 0..<20_000 {
            let start: Double? = r.bool() ? r.double() : nil
            let window = r.double()
            log.check(F.phraseVoiceStart(start: start, windowStart: window), L.phraseVoiceStart(start: start, windowStart: window), "\(String(describing: start)) \(window)")
        }
        for i in -2...9 { for o in -2...9 { log.check(F.converterDownmixes(inputChannels: i, outputChannels: o), L.converterDownmixes(inputChannels: i, outputChannels: o), "\(i) \(o)") } }
        log.finish(minimumCases: 20_000)
    }
}
