// Owned by the t27 agent. The app decisions moved into lane_rules.t27, ui_rules.t27 and transcript_rules.t27 on
// 2026-10-11 (from TranslationLane, AppModel, the views, LaunchOptions, Preferences, PushToTalkMonitor,
// PonteMain, Glossary, TranscriptExporter and WAVFileSink), against the Swift expressions they replaced
// (AppRulesLegacy), bit for bit.
import Foundation
import PonteCore
import Testing
@testable import PonteApp

private typealias F = AppRules
private typealias L = AppRulesLegacy

@Suite("Differential: moved app rules") struct AppMovedRulesDifferentialTests {

    @Test func constantsAndCodes() {
        let log = DiffLog("moved app constants and codes")
        log.check([F.directionCode(.incoming), F.directionCode(.outgoing)], [L.DIR_INCOMING, L.DIR_OUTGOING], "direction codes")
        log.check([F.DEFAULT_MODE, F.DEFAULT_PTT_KEY, F.DEFAULT_TRANSLATOR], [L.DEFAULT_MODE, L.DEFAULT_PTT_KEY, L.DEFAULT_TRANSLATOR], "defaults")
        log.check([F.DEFAULT_SPEAK_RUSSIAN, F.DEFAULT_OVERLAY_VISIBLE, F.DEFAULT_HEAR_ORIGINAL],
                  [L.DEFAULT_SPEAK_RUSSIAN, L.DEFAULT_OVERLAY_VISIBLE, L.DEFAULT_HEAR_ORIGINAL], "default flags")
        log.check([F.STOP_SEGMENT_WAIT_MS, F.STOP_TRANSLATE_WAIT_MS, F.POLL_INTERVAL_MS, F.COPIED_FEEDBACK_MS],
                  [L.STOP_SEGMENT_WAIT_MS, L.STOP_TRANSLATE_WAIT_MS, L.POLL_INTERVAL_MS, L.COPIED_FEEDBACK_MS], "times")
        log.check(F.FIRST_ATTEMPT, L.FIRST_ATTEMPT, "FIRST_ATTEMPT")
        log.check([F.SOURCE_SYSTEM_KEY, F.SOURCE_APP_PREFIX], [L.SOURCE_SYSTEM_KEY, L.SOURCE_APP_PREFIX], "source keys")
        // The Swift enums the settings store read the same codes back.
        log.check([CaptureMode(ruleCode: F.DEFAULT_MODE) == .continuous, PTTKey(ruleCode: F.DEFAULT_PTT_KEY) == .rightOption,
                   TranslatorKind(ruleCode: F.DEFAULT_TRANSLATOR) == .apple], [true, true, true], "default enums")
        log.finish(minimumCases: 7)
    }

    @Test func laneRules() {
        let log = DiffLog("lane rules")
        var r = DiffRandom(seed: 301)
        let bools = [false, true]
        for k in -20_000...20_000 {
            let s = Double(k) / 2000
            log.check(F.millis(s), L.millis(s), "\(s)")
        }
        for _ in 0..<100_000 {
            let s = r.finiteDouble(1e7)
            log.check(F.millis(s), L.millis(s), "\(s)")
        }
        for state: Int32 in -3...8 {
            log.check(F.gateRunning(state: state), L.gateRunning(state: state), "\(state)")
            log.check(F.gateCanStart(state: state), L.gateCanStart(state: state), "\(state)")
        }
        let spans: [Int64?] = [nil] + (-10...10).map { Optional($0) } + [100, 1999, 2000, 2001, 5000, 60_000, .max, .min, .min + 1]
        for timed in spans {
            for partial in spans {
                log.check(F.phraseEndChoiceKnown(msSinceTimedEnd: timed, msSincePartial: partial),
                          L.phraseEndChoiceKnown(msSinceTimedEnd: timed, msSincePartial: partial), describe(timed as Any, partial as Any))
            }
        }
        for _ in 0..<100_000 {
            let timed: Int64? = r.bool() ? nil : r.int64(-100_000...100_000)
            let partial: Int64? = r.bool() ? nil : r.int64(-100_000...100_000)
            log.check(F.phraseEndChoiceKnown(msSinceTimedEnd: timed, msSincePartial: partial),
                      L.phraseEndChoiceKnown(msSinceTimedEnd: timed, msSincePartial: partial), describe(timed as Any, partial as Any))
        }
        for bits in 0..<256 {
            let b = (0..<8).map { bits & (1 << $0) != 0 }
            log.check(F.phraseFlags(emptyText: b[0], speakRequested: b[1], generationCurrent: b[2], speechEnabled: b[3],
                                    paused: b[4], hasSynth: b[5], hasPlayer: b[6], hasAudio: b[7]),
                      L.phraseFlags(emptyText: b[0], speakRequested: b[1], generationCurrent: b[2], speechEnabled: b[3],
                                    paused: b[4], hasSynth: b[5], hasPlayer: b[6], hasAudio: b[7]), "\(bits)")
        }
        for a in bools {
            log.check(F.reportsTranslationError(cancelled: a), L.reportsTranslationError(cancelled: a), "\(a)")
            log.check(F.sourceKind(hasTestFile: a), L.sourceKind(hasTestFile: a), "\(a)")
            for b in bools {
                log.check(F.echoMarksTime(wasSpeaking: a, nowSpeaking: b), L.echoMarksTime(wasSpeaking: a, nowSpeaking: b), describe(a, b))
                log.check(F.needsSpeechWorkers(hasSynth: a, hasPlayer: b), L.needsSpeechWorkers(hasSynth: a, hasPlayer: b), describe(a, b))
                log.check(F.intakeForwards(hasSegment: a, echoBlocks: b), L.intakeForwards(hasSegment: a, echoBlocks: b), describe(a, b))
                log.check(F.segmentAppend(started: a, closed: b), L.segmentAppend(started: a, closed: b), describe(a, b))
                log.check(F.segmentClose(started: a, closed: b), L.segmentClose(started: a, closed: b), describe(a, b))
                log.check(F.callOutput(hasSink: a, hasBlackHole: b), L.callOutput(hasSink: a, hasBlackHole: b), describe(a, b))
            }
            for decision in -2...4 {
                log.check(F.requestsMicPermission(micIsLive: a, micDecision: decision),
                          L.requestsMicPermission(micIsLive: a, micDecision: decision), describe(a, decision))
            }
        }
        for backlog: Int32 in -1000...1000 {
            for counted in bools {
                log.check(F.backlogAfterSpeech(backlog, counted: counted), L.backlogAfterSpeech(backlog, counted: counted), describe(backlog, counted))
                log.check(F.speechWaiting(backlog: backlog, counted: counted), L.speechWaiting(backlog: backlog, counted: counted), describe(backlog, counted))
            }
        }
        for _ in 0..<50_000 {
            let backlog = r.int32((Int32.min + 1)...Int32.max), counted = r.bool()
            log.check(F.backlogAfterSpeech(backlog, counted: counted), L.backlogAfterSpeech(backlog, counted: counted), describe(backlog, counted))
            log.check(F.speechWaiting(backlog: backlog, counted: counted), L.speechWaiting(backlog: backlog, counted: counted), describe(backlog, counted))
        }
        for action: Int32 in -3...20 {
            for current in bools {
                log.check(F.playEndReports(action: action, generationCurrent: current), L.playEndReports(action: action, generationCurrent: current),
                          describe(action, current))
            }
        }
        for direction in Direction.allCases {
            let d = F.directionCode(direction)
            for mode: Int32 in -1...3 {
                log.check(F.laneMode(direction: d, outgoingMode: mode), L.laneMode(direction: d, outgoingMode: mode), describe(d, mode))
            }
            for speak in bools {
                log.check(F.laneSpeaks(direction: d, speakRussian: speak), L.laneSpeaks(direction: d, speakRussian: speak), describe(d, speak))
            }
            log.check([F.laneVoicePause(direction: d), F.laneEchoGuarded(direction: d), F.laneEchoSource(direction: d), F.glossarySourceIsPT(direction: d)],
                      [L.laneVoicePause(direction: d), L.laneEchoGuarded(direction: d), L.laneEchoSource(direction: d), L.glossarySourceIsPT(direction: d)],
                      "\(d)")
        }
        for d: Int32 in -3...4 {
            for speaks in bools {
                log.check(F.lanePreparesOutput(direction: d, speaks: speaks), L.lanePreparesOutput(direction: d, speaks: speaks), describe(d, speaks))
            }
            log.check(F.laneVoiceInCall(direction: d), L.laneVoiceInCall(direction: d), "voiceInCall \(d)")
        }
        for scope: Int32 in -3...6 {
            log.check(F.pttLocal(scope: scope), L.pttLocal(scope: scope), "\(scope)")
            log.check(F.pttGlobal(scope: scope), L.pttGlobal(scope: scope), "\(scope)")
        }
        for k in -1000...1000 {
            let left = Double(k) / 10_000
            log.check(F.sinkPaceStep(left: left), L.sinkPaceStep(left: left), "\(left)")
        }
        for _ in 0..<100_000 {
            let left = r.pick([r.double(), 0.05, 0.0499999, 0.0500001])
            log.check(F.sinkPaceStep(left: left), L.sinkPaceStep(left: left), "\(left)")
        }
        log.finish(minimumCases: 400_000)
    }

    @Test func uiRules() {
        let log = DiffLog("ui rules")
        var r = DiffRandom(seed: 302)
        let bools = [false, true]
        for tick: Int64 in -100...20_000 { log.check(F.pollRefreshesCatalogs(tick: tick), L.pollRefreshesCatalogs(tick: tick), "\(tick)") }
        for run: Int32 in -1...5 {
            log.check(F.transcriptHasEnd(runState: run), L.transcriptHasEnd(runState: run), "\(run)")
            for work in bools {
                for peer in bools {
                    log.check(F.quitWaits(runState: run, analysisWork: work, peerOn: peer),
                              L.quitWaits(runState: run, analysisWork: work, peerOn: peer), describe(run, work, peer))
                }
            }
            for ever in bools {
                for started: Int32 in -1...3 {
                    for failed: Int32 in -1...3 {
                        for translators: Int32 in -1...3 {
                            log.check(F.modelsLightAll(runState: run, everStarted: ever, lanesStarted: started, lanesFailed: failed, translatorsFailed: translators),
                                      L.modelsLightAll(runState: run, everStarted: ever, lanesStarted: started, lanesFailed: failed, translatorsFailed: translators),
                                      describe(run, ever, started, failed, translators))
                        }
                    }
                }
            }
            for tap: Int32 in -1...6 {
                for light: Int32 in -1...6 {
                    log.check(F.sourceHelp(runState: run, tapStatus: tap, sourceLight: light), L.sourceHelp(runState: run, tapStatus: tap, sourceLight: light),
                              describe(run, tap, light))
                }
            }
        }
        for light: Int32 in -2...7 {
            log.check(F.showsLevel(light: light), L.showsLevel(light: light), "\(light)")
            log.check(F.captureNeedsSettings(light: light), L.captureNeedsSettings(light: light), "\(light)")
            log.check(F.packRefreshable(light: light), L.packRefreshable(light: light), "\(light)")
            log.check(F.packDownloadEnabled(light: light), L.packDownloadEnabled(light: light), "\(light)")
            for a in bools {
                for b in bools {
                    for c in bools {
                        log.check(F.silenceBanner(sourceLight: light, alreadyWarned: a, errorShown: b, silenceShown: c),
                                  L.silenceBanner(sourceLight: light, alreadyWarned: a, errorShown: b, silenceShown: c),
                                  describe(light, a, b, c))
                    }
                }
            }
        }
        for a in bools {
            log.check(F.accessibilityLight(granted: a), L.accessibilityLight(granted: a), "\(a)")
            for b in bools {
                log.check(F.hasCallOutput(hasBlackHole: a, hasSink: b), L.hasCallOutput(hasBlackHole: a, hasSink: b), describe(a, b))
                log.check(F.deviceChoice(hasSetting: a, found: b), L.deviceChoice(hasSetting: a, found: b), describe(a, b))
                log.check(F.testPhrasePossible(intoCall: a, hasBlackHole: b), L.testPhrasePossible(intoCall: a, hasBlackHole: b), describe(a, b))
                log.check(F.callOutputLabel(hasBlackHole: a, hasSetting: b), L.callOutputLabel(hasBlackHole: a, hasSetting: b), describe(a, b))
                log.check(F.lineState(hasTranslation: a, hasError: b), L.lineState(hasTranslation: a, hasError: b), describe(a, b))
                for c in bools {
                    log.check(F.sourceTitle(isSystem: a, hasRunningName: b, hasLabel: c), L.sourceTitle(isSystem: a, hasRunningName: b, hasLabel: c), describe(a, b, c))
                    log.check(F.translationErrorBanner(missingPacks: a, packsBannerShown: b, sameTextShown: c),
                              L.translationErrorBanner(missingPacks: a, packsBannerShown: b, sameTextShown: c), describe(a, b, c))
                    for d in bools {
                        log.check(F.outgoingStatus(paused: a, speaking: b, running: c, hasBlackHole: d),
                                  L.outgoingStatus(paused: a, speaking: b, running: c, hasBlackHole: d), describe(a, b, c, d))
                        log.check(F.isTestMode(hasIncomingFile: a, hasOutgoingFile: b, hasSink: c, hasTranscriptDir: d),
                                  L.isTestMode(hasIncomingFile: a, hasOutgoingFile: b, hasSink: c, hasTranscriptDir: d), describe(a, b, c, d))
                    }
                }
            }
        }
        for banner: Int32 in -2...10 {
            log.check(F.bannerKind(banner: banner), L.bannerKind(banner: banner), "\(banner)")
            log.check(F.bannerStep(banner: banner), L.bannerStep(banner: banner), "\(banner)")
        }
        for preferred: Int32 in -2...3 {
            log.check(F.probesClaude(preferred: preferred), L.probesClaude(preferred: preferred), "\(preferred)")
            for claude in bools {
                log.check(F.translatorNote(preferred: preferred, claudeAvailable: claude), L.translatorNote(preferred: preferred, claudeAvailable: claude),
                          describe(preferred, claude))
            }
        }
        // Both permission APIs: AVAuthorizationStatus and SFSpeechRecognizerAuthorizationStatus raw values.
        for raw in -5...12 {
            log.check(F.permissionState(raw: raw), L.micPermissionState(raw: raw), "mic \(raw)")
            log.check(F.permissionState(raw: raw), L.speechPermissionState(raw: raw), "speech \(raw)")
        }
        for _ in 0..<20_000 {
            let raw = r.int(-1_000_000...1_000_000)
            log.check(F.permissionState(raw: raw), L.micPermissionState(raw: raw), "mic \(raw)")
        }
        for state: Int32 in 0...3 {
            log.check(F.permissionAction(state: state), L.permissionAction(state: state), "\(state)")
            log.check(F.permissionLight(state: state), L.permissionLight(state: state), "\(state)")
        }
        for status in -3...8 { log.check(F.packLight(status: status), L.packLight(status: status), "\(status)") }
        log.finish(minimumCases: 25_000)
    }

    @Test func textsAndOrder() {
        let log = DiffLog("isYes, source keys, fitsEscapeInput, transcript order")
        var r = DiffRandom(seed: 303)
        let words = ["yes", "true", "1", "YES".lowercased(), "Yes", "y", "no", "0", "", "yes ", " yes", "truee", "1.0", "да", "sí",
                     String(repeating: "yes", count: 30), "t\u{0072}ue", "ye\u{0301}s"]
        for w in words { log.check(F.isYes(utf8: Array(w.lowercased().utf8)), L.isYes(w.lowercased()), w) }
        for _ in 0..<50_000 {
            let w = r.pick([r.text(maxPieces: 4), r.pick(words) + r.text(maxPieces: 1), r.pick(words)]).lowercased()
            log.check(F.isYes(utf8: Array(w.utf8)), L.isYes(w), w)
        }
        // Stored source keys (bundle IDs are reverse-DNS ASCII; other pieces never combine with the ':').
        let keys = ["system", "app:", "app:com.google.Chrome", "app", "ap:x", "APP:x", "app:app:x", "", "app:ação", "app:Я", "xapp:y",
                    String(repeating: "a", count: 5000), "app:" + String(repeating: "b", count: 5000)]
        for k in keys {
            log.check(Self.bundleID(SourceChoice(key: k)), L.sourceBundleID(key: k), k)
            log.check(SourceChoice(key: k).key, L.sourceBundleID(key: k).map { L.SOURCE_APP_PREFIX + $0 } ?? L.SOURCE_SYSTEM_KEY, k)
        }
        for _ in 0..<100_000 {
            let k = r.pick(["app:", "", "system", "ap", "app"]) + r.text(maxPieces: 5)
            log.check(Self.bundleID(SourceChoice(key: k)), L.sourceBundleID(key: k), k)
        }
        for bytes in -5...2100 {
            for size in -1...5 {
                log.check(F.fitsEscapeInput(bytes: bytes, charBytes: size), L.fitsEscapeInput(bytes: bytes, charBytes: size), describe(bytes, size))
            }
        }
        for _ in 0..<5_000 {
            let n = r.int(0...60)
            let at = (0..<n).map { _ in r.pick([0, 1, 1.5, 2, 1e9, -3, Double(r.int(0...10))]) }
            let ordered = at.enumerated().sorted {
                F.lineBefore(atA: $0.element, indexA: $0.offset, atB: $1.element, indexB: $1.offset)
            }.map(\.offset)
            log.check(ordered, L.sortedIndices(at), describe(at))
        }
        log.finish(minimumCases: 100_000)
    }

    private static func bundleID(_ choice: SourceChoice) -> String? {
        switch choice {
        case .system: nil
        case .app(let id): id
        }
    }

    @Test func intakeAndOwnTalk() {
        let log = DiffLog("intakeRoutes, blocksCall, ownVoiceMarks, ownTalking, ownTalkChangeMs, phraseStartMs, phraseDropped, talkLog, backlogAfterQueue, testHoldsKey")
        let bools = [false, true]
        for a in bools { for b in bools { for c in bools {
            log.check(F.intakeRoutes(hasRelay: a, hasPeers: b, callBlocks: c), L.intakeRoutes(hasRelay: a, hasPeers: b, callBlocks: c), "\(a) \(b) \(c)")
            for d in bools {
                log.check(F.phraseDropped(ownTalk: a, ownWindows: b, linkOn: c, peerWindows: d),
                          L.phraseDropped(ownTalk: a, ownWindows: b, linkOn: c, peerWindows: d), "\(a) \(b) \(c) \(d)")
            }
        }
            log.check(F.blocksCall(micBlocks: a, peerAudioBlocks: b), L.blocksCall(micBlocks: a, peerAudioBlocks: b), "\(a) \(b)")
            log.check(F.ownVoiceMarks(voice: a, callBlocks: b), L.ownVoiceMarks(voice: a, callBlocks: b), "\(a) \(b)")
            log.check(F.ownTalking(callBlocks: a, gateOpen: b), L.ownTalking(callBlocks: a, gateOpen: b), "\(a) \(b)")
            log.check(F.talkLogStep(held: a, hasOpen: b), L.talkLogStep(held: a, hasOpen: b), "\(a) \(b)")
            log.check(F.testHoldsKey(running: a, hasTestFile: b), L.testHoldsKey(running: a, hasTestFile: b), "\(a) \(b)")
        } }
        var r = DiffRandom(seed: 0x1D7A)
        let clock: Int64 = 1_760_000_000_000
        for _ in 0..<60_000 {
            let now = clock + r.int64(-100_000...100_000)
            let last: Int64? = r.bool() ? now - r.int64(-5000...20_000) : nil
            let talking = r.bool()
            log.check(F.ownTalkChangeMs(talking: talking, nowMs: now, lastVoiceMs: last),
                      L.ownTalkChangeMs(talking: talking, nowMs: now, lastVoiceMs: last), "\(talking) \(now) \(String(describing: last))")
            let arrived: Int64? = r.bool() ? now : nil
            let a = r.int64(-10_000...600_000), b = r.int64(-10_000...600_000)
            log.check(F.phraseStartMs(endArrivedMs: arrived, audioStartMs: a, audioEndMs: b, endMs: now + 50),
                      L.phraseStartMs(endArrivedMs: arrived, audioStartMs: a, audioEndMs: b, endMs: now + 50), "\(String(describing: arrived)) \(a) \(b)")
        }
        for n in Array(-5...60) + [Int.min / 2, Int.max / 2] { log.check(F.talkLogForget(count: n), L.talkLogForget(count: n), "\(n)") }
        for n in Array(Int32(-5)...Int32(40)) + [Int32.max, Int32.max - 1, Int32.min] {
            log.check(F.backlogAfterQueue(n), L.backlogAfterQueue(n), "\(n)")
        }
        log.finish(minimumCases: 120_000)
    }

    @Test func ownTalkGuard() {
        let log = DiffLog("ownTalkDrops")
        log.check(F.PHRASE_FALLBACK_MS, L.PHRASE_FALLBACK_MS, "PHRASE_FALLBACK_MS")
        var r = DiffRandom(seed: 1410)
        for _ in 0..<50_000 {
            let talkStart = Int64(r.int(0...20_000))
            let talkEnd: Int64 = r.int(0...4) == 0 ? -1 : talkStart + Int64(r.int(0...8_000))
            let phraseStart = Int64(r.int(0...30_000))
            let phraseEnd = phraseStart + Int64(r.int(-500...6_000))
            log.check(F.ownTalkDrops(phraseStartMs: phraseStart, phraseEndMs: phraseEnd, talkStartMs: talkStart, talkEndMs: talkEnd),
                      L.ownTalkDrops(phraseStartMs: phraseStart, phraseEndMs: phraseEnd, talkStartMs: talkStart, talkEndMs: talkEnd),
                      "\(phraseStart)..\(phraseEnd) talk \(talkStart)..\(talkEnd)")
        }
        log.finish(minimumCases: 50_000)
    }

    @Test func peerAudioGuard() {
        let log = DiffLog("outputSealed, peerAudioBlocksCall")
        for a in [false, true] { for b in [false, true] {
            log.check(F.outputSealed(echoRiskNone: a, micIsOutputHeadset: b), L.outputSealed(echoRiskNone: a, micIsOutputHeadset: b), "\(a) \(b)")
            log.check(F.echoOutput(speakerOutput: a, outputSealed: b), L.echoOutput(speakerOutput: a, outputSealed: b), "echo \(a) \(b)")
        } }
        var r = DiffRandom(seed: 1414)
        for _ in 0..<20_000 {
            let sealed = r.int(0...1) == 1
            let ms = Int64(r.int(-2000...3000))
            log.check(F.peerAudioBlocksCall(outputSealed: sealed, msSincePeerAudio: ms),
                      L.peerAudioBlocksCall(outputSealed: sealed, msSincePeerAudio: ms), "\(sealed) \(ms)")
        }
        log.finish(minimumCases: 20_000)
    }

    @Test func uiAndTranscriptMovedOutOfSwift() {
        let log = DiffLog("listenerDismissed, hearPick, peerNotes, transcript start and attempts, millis")
        let bools = [false, true]
        for a in bools { for b in bools { for c in bools {
            log.check(F.peerNotes(peerOn: a, running: b, headphonesLike: c), L.peerNotes(peerOn: a, running: b, headphonesLike: c), "\(a) \(b) \(c)")
            for d in bools {
                log.check(F.listenerDismissed(dismissed: a, gone: b, closed: c, streak: d), L.listenerDismissed(dismissed: a, gone: b, closed: c, streak: d), "\(a) \(b) \(c) \(d)")
            }
        }
            log.check(F.hearPickClearsHeadphones(hasSaved: a), L.hearPickClearsHeadphones(hasSaved: a), "\(a)")
            for n in Array(Int32(-2)...Int32(3)) + [Int32.min, Int32.max] {
                log.check(F.packsBannerClears(shown: a, translatorsFailed: n), L.packsBannerClears(shown: a, translatorsFailed: n), "\(a) \(n)")
            }
            log.check(F.hearPickFailed(systemIsPicked: a), L.hearPickFailed(systemIsPicked: a), "\(a)")
            log.check(F.listenerTickReadsDevices(sheetOpen: a), L.listenerTickReadsDevices(sheetOpen: a), "\(a)")
        } }
        for n in Array(Int32(-5)...Int32(1100)) + [Int32.min, Int32.max, Int32.max - 1] {
            log.check(F.nextAttempt(n), L.nextAttempt(n), "\(n)")
            log.check(F.attemptAllowed(n), L.attemptAllowed(n), "\(n)")
        }
        var r = DiffRandom(seed: 0x7A5C)
        for _ in 0..<40_000 {
            let start: Int64? = r.bool() ? Int64(bitPattern: r.next()) : nil
            let first = Int64(bitPattern: r.next())
            log.check(F.transcriptStartedMs(callStartMs: start, firstLineMs: first), L.transcriptStartedMs(callStartMs: start, firstLineMs: first), "\(String(describing: start)) \(first)")
            let s = r.double()
            log.check(F.millis(s), L.millis(s), "\(s)")
        }
        for s in [Double.nan, .infinity, -.infinity, 1e300, -1e300, 0.0005, -0.0005, 1e12, -1e12] { log.check(F.millis(s), L.millis(s), "\(s)") }
        log.finish(minimumCases: 80_000)
    }
}
