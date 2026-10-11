// Owned by the t27 agent. SpeechRules (C from Specs/segment_rules.t27, context_rules.t27, voice_rules.t27)
// against SpeechRulesLegacy (the Swift it replaced), function by function, bit for bit.
import Foundation
import Testing
@testable import PonteSpeech

private typealias F = SpeechRules
private typealias L = SpeechRulesLegacy

@Suite("Differential: SpeechRules") struct SpeechRulesDifferentialTests {

    @Test func constants() {
        let log = DiffLog("SpeechRules constants")
        let pairs: [(Int, Int, String)] = [
            (F.meterWindowMs, L.meterWindowMs, "meterWindowMs"), (F.voiceThresholdLevel, L.voiceThresholdLevel, "voiceThresholdLevel"),
            (F.noiseFloorFactorNumerator, L.noiseFloorFactorNumerator, "numerator"),
            (F.noiseFloorFactorDenominator, L.noiseFloorFactorDenominator, "denominator"),
            (F.noiseFloorRiseMs, L.noiseFloorRiseMs, "noiseFloorRiseMs"), (F.minRecordedPauseMs, L.minRecordedPauseMs, "minRecordedPauseMs"),
            (F.endOfPhrasePauseMs, L.endOfPhrasePauseMs, "endOfPhrasePauseMs"), (F.trailingMarginMs, L.trailingMarginMs, "trailingMarginMs"),
            (F.maxPhraseMs, L.maxPhraseMs, "maxPhraseMs"), (F.minPauseMs, L.minPauseMs, "minPauseMs"),
            (F.shortPauseMs, L.shortPauseMs, "shortPauseMs"), (F.hardLimitMs, L.hardLimitMs, "hardLimitMs"),
            (F.absoluteLimitMs, L.absoluteLimitMs, "absoluteLimitMs"), (F.minCutSpacingMs, L.minCutSpacingMs, "minCutSpacingMs"),
            (F.stallTimeoutMs, L.stallTimeoutMs, "stallTimeoutMs"), (F.watchdogPeriodMs, L.watchdogPeriodMs, "watchdogPeriodMs"),
            (F.stallFlushSilenceMs, L.stallFlushSilenceMs, "stallFlushSilenceMs"),
            (F.actionWait, L.actionWait, "actionWait"), (F.actionEndOfPhrase, L.actionEndOfPhrase, "actionEndOfPhrase"),
            (F.actionMonologuePause, L.actionMonologuePause, "actionMonologuePause"),
            (F.actionMonologueForced, L.actionMonologueForced, "actionMonologueForced"),
            (F.flagHasContent, L.flagHasContent, "flagHasContent"), (F.flagFinishing, L.flagFinishing, "flagFinishing"),
            (F.flagCutsDisabled, L.flagCutsDisabled, "flagCutsDisabled"),
            (F.punctuationNone, L.punctuationNone, "punctuationNone"), (F.punctuationClause, L.punctuationClause, "punctuationClause"),
            (F.punctuationSentence, L.punctuationSentence, "punctuationSentence"), (F.minPhraseBytes, L.minPhraseBytes, "minPhraseBytes"),
            (F.hallucinationMaxWords, L.hallucinationMaxWords, "hallucinationMaxWords"),
            (F.hallucinationMinVoiceMs, L.hallucinationMinVoiceMs, "hallucinationMinVoiceMs"),
            (F.phraseKeep, L.phraseKeep, "phraseKeep"), (F.phraseDropHallucination, L.phraseDropHallucination, "phraseDropHallucination"),
            (F.phraseDropNoContent, L.phraseDropNoContent, "phraseDropNoContent"),
            (F.speechChunkMaxBytes, L.speechChunkMaxBytes, "speechChunkMaxBytes"), (F.speechChunkMinBytes, L.speechChunkMinBytes, "speechChunkMinBytes"),
            (F.contextMaxPhrases, L.contextMaxPhrases, "contextMaxPhrases"), (F.contextMaxBytes, L.contextMaxBytes, "contextMaxBytes"),
            (F.engineNone, L.engineNone, "engineNone"), (F.engineApple, L.engineApple, "engineApple"), (F.engineClaude, L.engineClaude, "engineClaude"),
            (F.errorTimeout, L.errorTimeout, "errorTimeout"), (F.errorNetwork, L.errorNetwork, "errorNetwork"),
            (F.errorOverloaded, L.errorOverloaded, "errorOverloaded"), (F.errorRejected, L.errorRejected, "errorRejected"),
            (F.errorAssetsMissing, L.errorAssetsMissing, "errorAssetsMissing"), (F.errorUnsupported, L.errorUnsupported, "errorUnsupported"),
            (F.errorRefused, L.errorRefused, "errorRefused"), (F.errorEmpty, L.errorEmpty, "errorEmpty"), (F.errorOther, L.errorOther, "errorOther"),
            (F.maxTranslationAttempts, L.maxTranslationAttempts, "maxTranslationAttempts"),
            (F.retryGiveUp, L.retryGiveUp, "retryGiveUp"), (F.retrySame, L.retrySame, "retrySame"), (F.retrySwitch, L.retrySwitch, "retrySwitch"),
            (F.claudeMaxTokens, L.claudeMaxTokens, "claudeMaxTokens"), (F.claudeEffortCode, L.claudeEffortCode, "claudeEffortCode"),
            (F.claudeRequestTimeoutMs, L.claudeRequestTimeoutMs, "claudeRequestTimeoutMs"),
            (F.qualityCompact, L.qualityCompact, "qualityCompact"), (F.qualityEnhanced, L.qualityEnhanced, "qualityEnhanced"),
            (F.qualityPremium, L.qualityPremium, "qualityPremium"), (F.synthesisEndGraceMs, L.synthesisEndGraceMs, "synthesisEndGraceMs"),
            (F.defaultUtteranceRateMilli, L.defaultUtteranceRateMilli, "defaultUtteranceRateMilli"),
            (F.utteranceRateMilliPer10Percent, L.utteranceRateMilliPer10Percent, "utteranceRateMilliPer10Percent"),
        ]
        for (f, l, name) in pairs { log.check(f, l, name) }
        log.check(F.claudeModelID(), L.claudeModelID(), "claudeModelID")
        log.check(F.anthropicVersion(), L.anthropicVersion(), "anthropicVersion")
        log.finish(minimumCases: 60)
    }

    @Test func voiceActivity() {
        let log = DiffLog("effectiveThreshold, isVoice, nextNoiseFloor")
        var r = DiffRandom(seed: 21)
        for floor in stride(from: -10_000, through: 2_000_000, by: 333) {
            log.check(F.effectiveThreshold(floorMilli: floor), L.effectiveThreshold(floorMilli: floor), "\(floor)")
        }
        for _ in 0..<200_000 {
            let floor = r.int(-1_000_000_000_000...1_000_000_000_000), level = r.int(-1_000_000...1_000_000_000)
            log.check(F.effectiveThreshold(floorMilli: floor), L.effectiveThreshold(floorMilli: floor), "\(floor)")
            log.check(F.isVoice(level: level, floorMilli: floor), L.isVoice(level: level, floorMilli: floor), describe(level, floor))
            let f = r.int(0...1_000_000_000), l = r.int(0...1_000_000), d = r.pick([20, 0, -5, 60_000, 90_000, r.int(-100_000...1_000_000)])
            let has = r.bool()
            log.check(F.nextNoiseFloor(floorMilli: f, hasFloor: has, level: l, durationMs: d),
                      L.nextNoiseFloor(floorMilli: f, hasFloor: has, level: l, durationMs: d), describe(f, has, l, d))
        }
        log.finish(minimumCases: 600_000)
    }

    @Test func finalization() {
        let log = DiffLog("finalizeAction, cutBackoffMs")
        let lastCuts = [Int.max, 0, 99, 100, 550, 551, 5_000, -1]
        let ages = [0, 449, 450, 451, 60_000]
        for pause in stride(from: -20, through: 1_000, by: 10) {
            for speech in stride(from: 0, through: 13_000, by: 250) {
                for punctuation in -1...3 {
                    for flags in 0...7 {
                        for lastCut in lastCuts {
                            for age in ages {
                                log.check(F.finalizeAction(pauseMs: pause, speechMs: speech, punctuation: punctuation, lastCutAgoMs: lastCut, phraseAgeMs: age, flags: flags),
                                          L.finalizeAction(pauseMs: pause, speechMs: speech, punctuation: punctuation, lastCutAgoMs: lastCut, phraseAgeMs: age, flags: flags),
                                          describe(pause, speech, punctuation, lastCut, age, flags))
                            }
                        }
                    }
                }
            }
        }
        for action in -1...4 {
            for pause in -1_000...2_000 {
                log.check(F.cutBackoffMs(action: action, pauseMs: pause), L.cutBackoffMs(action: action, pauseMs: pause), describe(action, pause))
            }
        }
        log.finish(minimumCases: 4_000_000)
    }

    @Test func textRules() {
        let log = DiffLog("isSpace, punctuationCode, wordCount, hasSpeechContent, phraseAction")
        for b in 0...255 { log.check(F.isSpace(UInt8(b)), L.isSpace(UInt8(b)), "\(b)") }
        var r = DiffRandom(seed: 22)
        for _ in 0..<60_000 {
            let utf8 = r.bool() ? Array(r.text(maxPieces: 14).utf8) : r.bytes(maxCount: 24)
            log.check(F.punctuationCode(utf8: utf8), L.punctuationCode(utf8: utf8), "\(utf8)")
            log.check(F.wordCount(utf8: utf8), L.wordCount(utf8: utf8), "\(utf8)")
            log.check(F.hasSpeechContent(utf8: utf8), L.hasSpeechContent(utf8: utf8), "\(utf8)")
            let voice = r.pick([0, 99, 100, 400, r.int(-1_000...10_000)])
            log.check(F.phraseAction(utf8: utf8, voiceMs: voice), L.phraseAction(utf8: utf8, voiceMs: voice), describe(utf8, voice))
        }
        let long = Array((String(repeating: "palavra ", count: 1_500) + "fim.»  ").utf8)
        log.check(F.punctuationCode(utf8: long), L.punctuationCode(utf8: long), "long text")
        log.finish(minimumCases: 240_000)
    }

    @Test func cutIndex() {
        let log = DiffLog("cutByteIndex")
        var r = DiffRandom(seed: 23)
        for _ in 0..<40_000 {
            let utf8 = r.bool() ? Array(r.text(maxPieces: 120).utf8) : r.bytes(maxCount: 300)
            let maxBytes = r.pick([0, -1, 1, 24, 30, 40, 200, r.int(1...320)]), minBytes = r.pick([0, 5, 8, 24, r.int(-5...60)])
            log.check(F.cutByteIndex(utf8: utf8, maxBytes: maxBytes, minBytes: minBytes),
                      L.cutByteIndex(utf8: utf8, maxBytes: maxBytes, minBytes: minBytes), describe(utf8, maxBytes, minBytes))
        }
        let long = Array(String(repeating: "Ж. ", count: 4_000).utf8)
        for maxBytes in [10, 200, 8_000, 8_189, 20_000] {
            log.check(F.cutByteIndex(utf8: long, maxBytes: maxBytes, minBytes: 24), L.cutByteIndex(utf8: long, maxBytes: maxBytes, minBytes: 24), "long \(maxBytes)")
        }
        log.finish(minimumCases: 40_000)
    }

    @Test func contextAndEngines() {
        let log = DiffLog("contextCount, engines, timeouts, errorCode, retryAction")
        var r = DiffRandom(seed: 24)
        log.check(F.contextCount(byteLengths: []), L.contextCount(byteLengths: []), "empty")
        for _ in 0..<50_000 {
            let lengths = (0..<r.int(0...14)).map { _ in r.pick([0, 10, 50, 500, 501, 600, 700, r.int(0...800)]) }
            log.check(F.contextCount(byteLengths: lengths), L.contextCount(byteLengths: lengths), "\(lengths)")
        }
        for engine in -1...4 {
            for bits in 0..<4 {
                let apple = bits & 1 == 1, claude = bits & 2 == 2
                log.check(F.primaryEngine(preferred: engine, appleReady: apple, claudeAvailable: claude),
                          L.primaryEngine(preferred: engine, appleReady: apple, claudeAvailable: claude), describe(engine, apple, claude))
                log.check(F.fallbackEngine(failed: engine, appleReady: apple, claudeAvailable: claude),
                          L.fallbackEngine(failed: engine, appleReady: apple, claudeAvailable: claude), describe(engine, apple, claude))
            }
            log.check(F.translationTimeoutMs(engine: engine), L.translationTimeoutMs(engine: engine), "\(engine)")
        }
        for status in -10...1_000 { log.check(F.errorCode(httpStatus: status), L.errorCode(httpStatus: status), "\(status)") }
        for error in -1...10 {
            for attempt in -3...4 {
                for fallback in -1...3 {
                    log.check(F.retryAction(errorCode: error, attempt: attempt, fallback: fallback),
                              L.retryAction(errorCode: error, attempt: attempt, fallback: fallback), describe(error, attempt, fallback))
                }
            }
        }
        log.finish(minimumCases: 51_000)
    }

    @Test func voicesAndSynthesis() {
        let log = DiffLog("voiceQualityCode, isNoveltyVoice, voiceRankKey, synthesisTimeoutMs, utteranceRateMilli")
        var r = DiffRandom(seed: 25)
        for raw in -5...10 { log.check(F.voiceQualityCode(avQualityRaw: raw), L.voiceQualityCode(avQualityRaw: raw), "\(raw)") }
        for _ in 0..<1_000 {
            let raw = r.int(Int.min...Int.max)
            log.check(F.voiceQualityCode(avQualityRaw: raw), L.voiceQualityCode(avQualityRaw: raw), "\(raw)")
        }
        let ids = ["com.apple.eloquence.pt-BR.Eddy", "com.apple.speech.synthesis.voice.Bells", "com.apple.voice.compact.pt-BR.Luciana",
                   "com.apple.voice.premium.ru-RU.Milena", "", ".eloquence.", ".eloquence", "eloquence.", ".speech.synthesis.voice.",
                   ".speech.synthesis.voice", "x.ELOQUENCE.y", "com.apple.eloquence"]
        for id in ids { log.check(F.isNoveltyVoice(identifierUTF8: Array(id.utf8)), L.isNoveltyVoice(identifierUTF8: Array(id.utf8)), id) }
        for _ in 0..<20_000 {
            let id = Array((r.pick(ids) + r.text(maxPieces: 4) + r.pick(ids)).utf8)
            log.check(F.isNoveltyVoice(identifierUTF8: id), L.isNoveltyVoice(identifierUTF8: id), "\(id)")
        }
        for quality in -1...4 {
            for novelty in [false, true] {
                for index in -3...150 {
                    log.check(F.voiceRankKey(qualityCode: quality, isNovelty: novelty, preferredIndex: index),
                              L.voiceRankKey(qualityCode: quality, isNovelty: novelty, preferredIndex: index), describe(quality, novelty, index))
                }
            }
        }
        for bytes in -1_000...3_000 { log.check(F.synthesisTimeoutMs(textBytes: bytes), L.synthesisTimeoutMs(textBytes: bytes), "\(bytes)") }
        for _ in 0..<10_000 {
            let bytes = r.int(-1_000_000_000...1_000_000_000)
            log.check(F.synthesisTimeoutMs(textBytes: bytes), L.synthesisTimeoutMs(textBytes: bytes), "\(bytes)")
        }
        for percent in -100...400 {
            for base in stride(from: -100, through: 1_200, by: 13) {
                log.check(F.utteranceRateMilli(ratePercent: percent, baseRateMilli: base),
                          L.utteranceRateMilli(ratePercent: percent, baseRateMilli: base), describe(percent, base))
            }
        }
        log.finish(minimumCases: 85_000)
    }
}
