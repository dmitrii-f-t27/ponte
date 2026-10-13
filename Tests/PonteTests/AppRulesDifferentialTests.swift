// Owned by the t27 agent. AppRules (C from Specs/lane_rules.t27, ui_rules.t27, transcript_rules.t27)
// against AppRulesLegacy (the Swift it replaced), function by function, bit for bit.
import Foundation
import Testing
@testable import PonteApp

private typealias F = AppRules
private typealias L = AppRulesLegacy

@Suite("Differential: AppRules") struct AppRulesDifferentialTests {

    @Test func constants() {
        let log = DiffLog("AppRules constants")
        let codes: [(Int32, Int32, String)] = [
            (F.MODE_CONTINUOUS, L.MODE_CONTINUOUS, "MODE_CONTINUOUS"), (F.MODE_PUSH_TO_TALK, L.MODE_PUSH_TO_TALK, "MODE_PUSH_TO_TALK"),
            (F.GATE_STOPPED, L.GATE_STOPPED, "GATE_STOPPED"), (F.GATE_STARTING, L.GATE_STARTING, "GATE_STARTING"),
            (F.GATE_CLOSED, L.GATE_CLOSED, "GATE_CLOSED"), (F.GATE_OPEN, L.GATE_OPEN, "GATE_OPEN"),
            (F.GEV_START, L.GEV_START, "GEV_START"), (F.GEV_STARTED, L.GEV_STARTED, "GEV_STARTED"),
            (F.GEV_START_FAILED, L.GEV_START_FAILED, "GEV_START_FAILED"), (F.GEV_STOP, L.GEV_STOP, "GEV_STOP"),
            (F.GEV_KEY, L.GEV_KEY, "GEV_KEY"), (F.GEV_PAUSE, L.GEV_PAUSE, "GEV_PAUSE"), (F.GEV_MODE, L.GEV_MODE, "GEV_MODE"),
            (F.GACT_NONE, L.GACT_NONE, "GACT_NONE"), (F.GACT_OPEN_SEGMENT, L.GACT_OPEN_SEGMENT, "GACT_OPEN_SEGMENT"),
            (F.GACT_CLOSE_SEGMENT, L.GACT_CLOSE_SEGMENT, "GACT_CLOSE_SEGMENT"),
            (F.PH_LISTENING, L.PH_LISTENING, "PH_LISTENING"), (F.PH_TRANSLATING, L.PH_TRANSLATING, "PH_TRANSLATING"),
            (F.PH_SYNTH_QUEUED, L.PH_SYNTH_QUEUED, "PH_SYNTH_QUEUED"), (F.PH_PLAY_QUEUED, L.PH_PLAY_QUEUED, "PH_PLAY_QUEUED"),
            (F.PH_PLAYING, L.PH_PLAYING, "PH_PLAYING"), (F.PH_SHOWN, L.PH_SHOWN, "PH_SHOWN"), (F.PH_SPOKEN, L.PH_SPOKEN, "PH_SPOKEN"),
            (F.PH_DROPPED, L.PH_DROPPED, "PH_DROPPED"), (F.PEV_PARTIAL, L.PEV_PARTIAL, "PEV_PARTIAL"), (F.PEV_FINAL, L.PEV_FINAL, "PEV_FINAL"),
            (F.PEV_TRANSLATED, L.PEV_TRANSLATED, "PEV_TRANSLATED"), (F.PEV_TRANSLATE_FAILED, L.PEV_TRANSLATE_FAILED, "PEV_TRANSLATE_FAILED"),
            (F.PEV_SYNTH_DEQUEUED, L.PEV_SYNTH_DEQUEUED, "PEV_SYNTH_DEQUEUED"), (F.PEV_SYNTHESIZED, L.PEV_SYNTHESIZED, "PEV_SYNTHESIZED"),
            (F.PEV_SYNTH_FAILED, L.PEV_SYNTH_FAILED, "PEV_SYNTH_FAILED"), (F.PEV_PLAY_DEQUEUED, L.PEV_PLAY_DEQUEUED, "PEV_PLAY_DEQUEUED"),
            (F.PEV_PLAYED, L.PEV_PLAYED, "PEV_PLAYED"), (F.PACT_NONE, L.PACT_NONE, "PACT_NONE"),
            (F.PACT_SHOW_PARTIAL, L.PACT_SHOW_PARTIAL, "PACT_SHOW_PARTIAL"), (F.PACT_TRANSLATE, L.PACT_TRANSLATE, "PACT_TRANSLATE"),
            (F.PACT_SHOW_ONLY, L.PACT_SHOW_ONLY, "PACT_SHOW_ONLY"), (F.PACT_SYNTHESIZE, L.PACT_SYNTHESIZE, "PACT_SYNTHESIZE"),
            (F.PACT_RUN_SYNTH, L.PACT_RUN_SYNTH, "PACT_RUN_SYNTH"), (F.PACT_ENQUEUE_PLAY, L.PACT_ENQUEUE_PLAY, "PACT_ENQUEUE_PLAY"),
            (F.PACT_PLAY, L.PACT_PLAY, "PACT_PLAY"), (F.PACT_DROP, L.PACT_DROP, "PACT_DROP"), (F.PACT_FINISH, L.PACT_FINISH, "PACT_FINISH"),
            (F.PF_EMPTY_TEXT, L.PF_EMPTY_TEXT, "PF_EMPTY_TEXT"), (F.PF_SPEAK_REQUESTED, L.PF_SPEAK_REQUESTED, "PF_SPEAK_REQUESTED"),
            (F.PF_GENERATION_CURRENT, L.PF_GENERATION_CURRENT, "PF_GENERATION_CURRENT"),
            (F.PF_SPEECH_ENABLED, L.PF_SPEECH_ENABLED, "PF_SPEECH_ENABLED"), (F.PF_PAUSED, L.PF_PAUSED, "PF_PAUSED"),
            (F.PF_HAS_SYNTH, L.PF_HAS_SYNTH, "PF_HAS_SYNTH"), (F.PF_HAS_PLAYER, L.PF_HAS_PLAYER, "PF_HAS_PLAYER"),
            (F.PF_HAS_AUDIO, L.PF_HAS_AUDIO, "PF_HAS_AUDIO"), (F.SCE_PAUSE, L.SCE_PAUSE, "SCE_PAUSE"), (F.SCE_VOICE, L.SCE_VOICE, "SCE_VOICE"),
            (F.SCE_STOP, L.SCE_STOP, "SCE_STOP"), (F.RPL_NONE, L.RPL_NONE, "RPL_NONE"), (F.RPL_AUDIO, L.RPL_AUDIO, "RPL_AUDIO"),
            (F.RPL_SYNTH, L.RPL_SYNTH, "RPL_SYNTH"), (F.END_NOW, L.END_NOW, "END_NOW"), (F.END_LAST_PARTIAL, L.END_LAST_PARTIAL, "END_LAST_PARTIAL"),
            (F.END_TRANSCRIBER, L.END_TRANSCRIBER, "END_TRANSCRIBER"), (F.CONTEXT_PHRASES, L.CONTEXT_PHRASES, "CONTEXT_PHRASES"),
            (F.RUN_IDLE, L.RUN_IDLE, "RUN_IDLE"), (F.RUN_STARTING, L.RUN_STARTING, "RUN_STARTING"), (F.RUN_RUNNING, L.RUN_RUNNING, "RUN_RUNNING"),
            (F.RUN_STOPPING, L.RUN_STOPPING, "RUN_STOPPING"), (F.TOGGLE_NONE, L.TOGGLE_NONE, "TOGGLE_NONE"),
            (F.TOGGLE_START, L.TOGGLE_START, "TOGGLE_START"), (F.TOGGLE_STOP, L.TOGGLE_STOP, "TOGGLE_STOP"),
            (F.BAN_NONE, L.BAN_NONE, "BAN_NONE"), (F.BAN_FAILED_PACKS, L.BAN_FAILED_PACKS, "BAN_FAILED_PACKS"),
            (F.BAN_FAILED_OTHER, L.BAN_FAILED_OTHER, "BAN_FAILED_OTHER"), (F.BAN_NO_BLACKHOLE, L.BAN_NO_BLACKHOLE, "BAN_NO_BLACKHOLE"),
            (F.BAN_SPEAKERS, L.BAN_SPEAKERS, "BAN_SPEAKERS"), (F.BAN_NO_PACKS, L.BAN_NO_PACKS, "BAN_NO_PACKS"),
            (F.BAN_NO_TRANSLATOR, L.BAN_NO_TRANSLATOR, "BAN_NO_TRANSLATOR"),
            (F.BTN_START_STOP, L.BTN_START_STOP, "BTN_START_STOP"), (F.BTN_SOURCE, L.BTN_SOURCE, "BTN_SOURCE"),
            (F.BTN_REPLAY_INCOMING, L.BTN_REPLAY_INCOMING, "BTN_REPLAY_INCOMING"), (F.BTN_REPLAY_OUTGOING, L.BTN_REPLAY_OUTGOING, "BTN_REPLAY_OUTGOING"),
            (F.BTN_SAVE_TRANSCRIPT, L.BTN_SAVE_TRANSCRIPT, "BTN_SAVE_TRANSCRIPT"), (F.BTN_PAUSE_VOICE, L.BTN_PAUSE_VOICE, "BTN_PAUSE_VOICE"),
            (F.BTN_MODE, L.BTN_MODE, "BTN_MODE"), (F.BTN_TALK_PAD, L.BTN_TALK_PAD, "BTN_TALK_PAD"), (F.BTN_TEST_CALL, L.BTN_TEST_CALL, "BTN_TEST_CALL"),
            (F.BTN_TEST_HEADPHONES, L.BTN_TEST_HEADPHONES, "BTN_TEST_HEADPHONES"), (F.BTN_VOICE_TOGGLE, L.BTN_VOICE_TOGGLE, "BTN_VOICE_TOGGLE"),
            (F.LIGHT_UNKNOWN, L.LIGHT_UNKNOWN, "LIGHT_UNKNOWN"), (F.LIGHT_OK, L.LIGHT_OK, "LIGHT_OK"), (F.LIGHT_BAD, L.LIGHT_BAD, "LIGHT_BAD"),
            (F.LIGHT_BUSY, L.LIGHT_BUSY, "LIGHT_BUSY"), (F.LIGHT_WARN, L.LIGHT_WARN, "LIGHT_WARN"),
            (F.TAP_NONE, L.TAP_NONE, "TAP_NONE"), (F.TAP_WAITING, L.TAP_WAITING, "TAP_WAITING"), (F.TAP_CAPTURING, L.TAP_CAPTURING, "TAP_CAPTURING"),
            (F.TAP_FAILED, L.TAP_FAILED, "TAP_FAILED"), (F.TAP_IDLE, L.TAP_IDLE, "TAP_IDLE"),
            (F.LAT_NONE, L.LAT_NONE, "LAT_NONE"), (F.LAT_GOOD, L.LAT_GOOD, "LAT_GOOD"), (F.LAT_SLOW, L.LAT_SLOW, "LAT_SLOW"), (F.LAT_BAD, L.LAT_BAD, "LAT_BAD"),
            (F.SRC_CALLS, L.SRC_CALLS, "SRC_CALLS"), (F.SRC_PLAYING, L.SRC_PLAYING, "SRC_PLAYING"), (F.SRC_OTHER, L.SRC_OTHER, "SRC_OTHER"),
            (F.TR_APPLE, L.TR_APPLE, "TR_APPLE"), (F.TR_CLAUDE, L.TR_CLAUDE, "TR_CLAUDE"),
            (F.PTT_RIGHT_OPTION, L.PTT_RIGHT_OPTION, "PTT_RIGHT_OPTION"), (F.PTT_RIGHT_COMMAND, L.PTT_RIGHT_COMMAND, "PTT_RIGHT_COMMAND"),
            (F.PTT_RIGHT_SHIFT, L.PTT_RIGHT_SHIFT, "PTT_RIGHT_SHIFT"), (F.PTT_RIGHT_CONTROL, L.PTT_RIGHT_CONTROL, "PTT_RIGHT_CONTROL"),
            (F.PTT_FN, L.PTT_FN, "PTT_FN"), (F.PTT_SCOPE_NONE, L.PTT_SCOPE_NONE, "PTT_SCOPE_NONE"),
            (F.PTT_SCOPE_WINDOW, L.PTT_SCOPE_WINDOW, "PTT_SCOPE_WINDOW"), (F.PTT_SCOPE_GLOBAL, L.PTT_SCOPE_GLOBAL, "PTT_SCOPE_GLOBAL"),
            (F.WZ_PERMISSIONS, L.WZ_PERMISSIONS, "WZ_PERMISSIONS"), (F.WZ_MODELS, L.WZ_MODELS, "WZ_MODELS"), (F.WZ_PACKS, L.WZ_PACKS, "WZ_PACKS"),
            (F.WZ_BLACKHOLE, L.WZ_BLACKHOLE, "WZ_BLACKHOLE"), (F.WZ_CALL_APPS, L.WZ_CALL_APPS, "WZ_CALL_APPS"), (F.WZ_DONE, L.WZ_DONE, "WZ_DONE"),
            (F.WZ_NONE, L.WZ_NONE, "WZ_NONE"), (F.MARK_NONE, L.MARK_NONE, "MARK_NONE"), (F.MARK_DONE, L.MARK_DONE, "MARK_DONE"),
            (F.MARK_WARN, L.MARK_WARN, "MARK_WARN"), (F.FONT_DEFAULT_PT, L.FONT_DEFAULT_PT, "FONT_DEFAULT_PT"),
            (F.FONT_MIN_PT, L.FONT_MIN_PT, "FONT_MIN_PT"), (F.FONT_MAX_PT, L.FONT_MAX_PT, "FONT_MAX_PT"),
            (F.OVERLAY_MAX_LINES, L.OVERLAY_MAX_LINES, "OVERLAY_MAX_LINES"), (F.OVERLAY_PADDING_PT, L.OVERLAY_PADDING_PT, "OVERLAY_PADDING_PT"),
            (F.MD_ESCAPE_MAX_INPUT, L.MD_ESCAPE_MAX_INPUT, "MD_ESCAPE_MAX_INPUT"),
        ]
        for (f, l, name) in codes { log.check(f, l, name) }
        let times: [(Int64, Int64, String)] = [
            (F.ECHO_TAIL_MS, L.ECHO_TAIL_MS, "ECHO_TAIL_MS"), (F.PREPARE_RETRY_MS, L.PREPARE_RETRY_MS, "PREPARE_RETRY_MS"),
            (F.AUDIO_FRESH_MS, L.AUDIO_FRESH_MS, "AUDIO_FRESH_MS"), (F.AUDIO_WARMUP_MS, L.AUDIO_WARMUP_MS, "AUDIO_WARMUP_MS"),
            (F.SILENCE_SUSPECT_MS, L.SILENCE_SUSPECT_MS, "SILENCE_SUSPECT_MS"), (F.CAPTURE_CHECK_MS, L.CAPTURE_CHECK_MS, "CAPTURE_CHECK_MS"),
            (F.LAT_GOOD_MS, L.LAT_GOOD_MS, "LAT_GOOD_MS"), (F.LAT_SLOW_MS, L.LAT_SLOW_MS, "LAT_SLOW_MS"),
        ]
        for (f, l, name) in times { log.check(f, l, name) }
        log.finish(minimumCases: 137)
    }

    @Test func packingGateAndPhrase() {
        let log = DiffLog("pack, stepState, stepAction, gateWantsOpen, gateStep, phraseStep, speakRequested")
        var r = DiffRandom(seed: 31)
        for _ in 0..<200_000 {
            let a = Int32(truncatingIfNeeded: r.next()), b = Int32(truncatingIfNeeded: r.next())
            log.check(F.pack(a, b), L.pack(a, b), describe(a, b))
            log.check(F.stepState(a), L.stepState(a), "\(a)")
            log.check(F.stepAction(a), L.stepAction(a), "\(a)")
        }
        for s in Int32(-1)...5 {
            for a in Int32(-1)...300 { log.check(F.pack(s, a), L.pack(s, a), describe(s, a)) }
        }
        for mode in Int32(-1)...2 {
            for bits in 0..<4 {
                let key = bits & 1 == 1, paused = bits & 2 == 2
                log.check(F.gateWantsOpen(mode: mode, keyHeld: key, paused: paused), L.gateWantsOpen(mode: mode, keyHeld: key, paused: paused), describe(mode, key, paused))
                for state in Int32(-1)...5 {
                    for event in Int32(-1)...9 {
                        log.check(F.gateStep(state: state, event: event, mode: mode, keyHeld: key, paused: paused),
                                  L.gateStep(state: state, event: event, mode: mode, keyHeld: key, paused: paused), describe(state, event, mode, key, paused))
                    }
                }
            }
        }
        for stage in Int32(-1)...9 {
            for event in Int32(-1)...11 {
                for flags in Int32(0)...255 {
                    log.check(F.phraseStep(stage: stage, event: event, flags: flags), L.phraseStep(stage: stage, event: event, flags: flags), describe(stage, event, flags))
                }
                for _ in 0..<20 {
                    let flags = Int32(truncatingIfNeeded: r.next())
                    log.check(F.phraseStep(stage: stage, event: event, flags: flags), L.phraseStep(stage: stage, event: event, flags: flags), describe(stage, event, flags))
                }
            }
        }
        for bits in 0..<4 {
            log.check(F.speakRequested(speechEnabled: bits & 1 == 1, paused: bits & 2 == 2), L.speakRequested(speechEnabled: bits & 1 == 1, paused: bits & 2 == 2), "\(bits)")
        }
        log.finish(minimumCases: 640_000)
    }

    @Test func speechControlAndTiming() {
        let log = DiffLog("cancelsSpeech, replayAction, speechRatePercent, echo guard, phraseEndChoice, latency, context, prepare retry")
        var r = DiffRandom(seed: 32)
        for event in Int32(-1)...5 {
            for value in [false, true] { log.check(F.cancelsSpeech(event: event, value: value), L.cancelsSpeech(event: event, value: value), describe(event, value)) }
        }
        for bits in 0..<8 {
            let a = bits & 1 == 1, b = bits & 2 == 2, c = bits & 4 == 4
            log.check(F.replayAction(hasCachedAudio: a, hasLastTranslation: b, hasPlayer: c), L.replayAction(hasCachedAudio: a, hasLastTranslation: b, hasPlayer: c), "\(bits)")
        }
        for waiting in Int32(-1_000)...1_000 { log.check(F.speechRatePercent(waiting: waiting), L.speechRatePercent(waiting: waiting), "\(waiting)") }
        for waiting in [Int32.min, Int32.max] { log.check(F.speechRatePercent(waiting: waiting), L.speechRatePercent(waiting: waiting), "\(waiting)") }
        for _ in 0..<200_000 {
            let ms = r.pick([-1, 0, 699, 700, Int64(r.int(-1_000_000...1_000_000_000_000))])
            let ms2 = r.pick([-1, 0, 4_999, 5_000, Int64(r.int(-1_000_000...1_000_000_000_000))])
            let a = r.bool(), b = r.bool()
            log.check(F.echoGuardBlocksMic(speakerOutput: a, incomingSpeaking: b, msSinceSpeech: ms), L.echoGuardBlocksMic(speakerOutput: a, incomingSpeaking: b, msSinceSpeech: ms), describe(a, b, ms))
            log.check(F.echoGuardApplies(speakerOutput: a, micIsLive: b), L.echoGuardApplies(speakerOutput: a, micIsLive: b), describe(a, b))
            log.check(F.phraseEndChoice(msSinceTimedEnd: ms, msSincePartial: ms2), L.phraseEndChoice(msSinceTimedEnd: ms, msSincePartial: ms2), describe(ms, ms2))
            log.check(F.latencyMs(endMs: ms, readyMs: ms2), L.latencyMs(endMs: ms, readyMs: ms2), describe(ms, ms2))
            log.check(F.retryTranslatorPrepare(prepared: a, msSinceAttempt: ms2), L.retryTranslatorPrepare(prepared: a, msSinceAttempt: ms2), describe(a, ms2))
        }
        for count in Int32(-1_000)...1_000 { log.check(F.contextOverflow(count: count), L.contextOverflow(count: count), "\(count)") }
        log.check(F.contextOverflow(count: .max), L.contextOverflow(count: .max), "max")
        log.finish(minimumCases: 1_000_000)
    }

    @Test func runButtonsLights() {
        let log = DiffLog("run state, banners, buttons, lights, latency colour, sources, translator")
        for state in Int32(-1)...5 {
            log.check(F.toggleRun(runState: state), L.toggleRun(runState: state), "\(state)")
            log.check(F.runStateAfterStart(lanesStarted: state), L.runStateAfterStart(lanesStarted: state), "\(state)")
            log.check(F.autosaveOnStop(lines: state), L.autosaveOnStop(lines: state), "\(state)")
            log.check(F.blackHoleLight(found: state > 2), L.blackHoleLight(found: state > 2), "\(state)")
        }
        for failed in Int32(-1)...3 {
            for translators in Int32(-1)...3 {
                for bits in 0..<8 {
                    let packs = bits & 1 == 1, bh = bits & 2 == 2, speakers = bits & 4 == 4
                    log.check(F.startBanner(lanesFailed: failed, packsMissing: packs, hasBlackHole: bh, speakerOutput: speakers),
                              L.startBanner(lanesFailed: failed, packsMissing: packs, hasBlackHole: bh, speakerOutput: speakers), describe(failed, bits))
                    log.check(F.startBannerAfterStart(lanesFailed: failed, translatorsFailed: translators, packsMissing: packs, hasBlackHole: bh, speakerOutput: speakers),
                              L.startBannerAfterStart(lanesFailed: failed, translatorsFailed: translators, packsMissing: packs, hasBlackHole: bh, speakerOutput: speakers),
                              describe(failed, translators, bits))
                }
            }
        }
        for button in Int32(-1)...13 {
            for state in Int32(-1)...5 {
                for incoming in Int32(-1)...2 {
                    for outgoing in Int32(-1)...2 {
                        for bits in 0..<4 {
                            log.check(F.buttonEnabled(button: button, runState: state, incomingLines: incoming, outgoingLines: outgoing, hasBlackHole: bits & 1 == 1, busy: bits & 2 == 2),
                                      L.buttonEnabled(button: button, runState: state, incomingLines: incoming, outgoingLines: outgoing, hasBlackHole: bits & 1 == 1, busy: bits & 2 == 2),
                                      describe(button, state, incoming, outgoing, bits))
                        }
                    }
                }
            }
        }
        let msValues: [Int64] = [-5, -1, 0, 1, 1_999, 2_000, 2_001, 3_999, 4_000, 4_001, 7_999, 8_000, 8_001, 100_000]
        for state in Int32(-1)...4 {
            for active in [false, true] {
                for start in msValues {
                    for buffer in msValues {
                        log.check(F.audioLight(runState: state, laneActive: active, msSinceStart: start, msSinceBuffer: buffer),
                                  L.audioLight(runState: state, laneActive: active, msSinceStart: start, msSinceBuffer: buffer), describe(state, active, start, buffer))
                        for tap in Int32(-1)...5 {
                            for signal in [Int64(-1), 0, 5_000] {
                                log.check(F.sourceLight(runState: state, laneActive: active, tapStatus: tap, msSinceStart: start, msSinceBuffer: buffer, msSinceSignal: signal),
                                          L.sourceLight(runState: state, laneActive: active, tapStatus: tap, msSinceStart: start, msSinceBuffer: buffer, msSinceSignal: signal),
                                          describe(state, active, tap, start, buffer, signal))
                            }
                        }
                    }
                }
                for ever in [false, true] {
                    for started in Int32(-1)...2 {
                        for failed in Int32(-1)...2 {
                            log.check(F.modelsLight(runState: state, everStarted: ever, lanesStarted: started, lanesFailed: failed),
                                      L.modelsLight(runState: state, everStarted: ever, lanesStarted: started, lanesFailed: failed), describe(state, ever, started, failed))
                        }
                    }
                }
            }
        }
        for tap in Int32(-1)...5 {
            for bits in 0..<4 {
                log.check(F.captureCheckLight(tapStatus: tap, framesSeen: bits & 1 == 1, signalSeen: bits & 2 == 2),
                          L.captureCheckLight(tapStatus: tap, framesSeen: bits & 1 == 1, signalSeen: bits & 2 == 2), describe(tap, bits))
            }
        }
        for ms in Int64(-10)...10_000 { log.check(F.latencyColor(ms: ms), L.latencyColor(ms: ms), "\(ms)") }
        for ms in [Int64.min, .max] { log.check(F.latencyColor(ms: ms), L.latencyColor(ms: ms), "\(ms)") }
        for bits in 0..<4 {
            log.check(F.sourceSection(isKnownCallApp: bits & 1 == 1, isPlayingAudio: bits & 2 == 2), L.sourceSection(isKnownCallApp: bits & 1 == 1, isPlayingAudio: bits & 2 == 2), "\(bits)")
        }
        for preferred in Int32(-1)...3 {
            for available in [false, true] {
                log.check(F.translatorChoice(preferred: preferred, claudeAvailable: available), L.translatorChoice(preferred: preferred, claudeAvailable: available), describe(preferred, available))
            }
        }
        log.finish(minimumCases: 69_000)
    }

    /// micLight and micShowsLevel (2026-10-13): every run state, both lane flags, the threshold edges of the
    /// three times (and the Int64 extremes), every light code; then seeded random times.
    @Test func micLight() {
        let log = DiffLog("micLight, micShowsLevel")
        var r = DiffRandom(seed: 1013)
        let msValues: [Int64] = [.min, -5, -1, 0, 1, 1_999, 2_000, 2_001, 3_999, 4_000, 4_001, 7_999, 8_000, 13_999, 14_000, 100_000, .max]
        for state in Int32(-1)...5 {
            for active in [false, true] {
                for start in msValues {
                    for listen in msValues {
                        for buffer in msValues {
                            log.check(F.micLight(runState: state, laneActive: active, msSinceStart: start, msSinceListen: listen, msSinceBuffer: buffer),
                                      L.micLight(runState: state, laneActive: active, msSinceStart: start, msSinceListen: listen, msSinceBuffer: buffer),
                                      describe(state, active, start, listen, buffer))
                        }
                    }
                }
            }
        }
        for light in Int32(-2)...7 {
            for buffer in msValues {
                log.check(F.micShowsLevel(light: light, msSinceBuffer: buffer), L.micShowsLevel(light: light, msSinceBuffer: buffer), describe(light, buffer))
            }
        }
        for _ in 0..<50_000 {
            let state = r.int32(-1...5)
            let active = r.bool()
            let start = r.int64(-1_000...200_000)
            let listen = r.int64(-1_000...200_000)
            let buffer = r.int64(-1_000...200_000)
            let light = F.micLight(runState: state, laneActive: active, msSinceStart: start, msSinceListen: listen, msSinceBuffer: buffer)
            log.check(light, L.micLight(runState: state, laneActive: active, msSinceStart: start, msSinceListen: listen, msSinceBuffer: buffer),
                      describe(state, active, start, listen, buffer))
            log.check(F.micShowsLevel(light: light, msSinceBuffer: buffer), L.micShowsLevel(light: light, msSinceBuffer: buffer), describe(light, buffer))
        }
        log.finish(minimumCases: 168_000)
    }

    @Test func pushToTalkWizardText() {
        let log = DiffLog("pttKeyDown, pttScope, wizard, font size, overlay")
        var r = DiffRandom(seed: 33)
        for key in Int32(-1)...6 {
            for bit in 0..<64 { log.check(F.pttKeyDown(key: key, flags: 1 << UInt64(bit)), L.pttKeyDown(key: key, flags: 1 << UInt64(bit)), describe(key, bit)) }
            for _ in 0..<2_000 {
                let flags = r.next()
                log.check(F.pttKeyDown(key: key, flags: flags), L.pttKeyDown(key: key, flags: flags), describe(key, flags))
            }
        }
        for mode in Int32(-1)...2 {
            for bits in 0..<4 {
                log.check(F.pttScope(running: bits & 1 == 1, mode: mode, accessibilityGranted: bits & 2 == 2),
                          L.pttScope(running: bits & 1 == 1, mode: mode, accessibilityGranted: bits & 2 == 2), describe(mode, bits))
            }
        }
        for step in Int32(-3)...8 {
            log.check(F.wizardNext(step: step), L.wizardNext(step: step), "\(step)")
            log.check(F.wizardPrevious(step: step), L.wizardPrevious(step: step), "\(step)")
            for bits in 0..<16 {
                for models in Int32(-1)...3 {
                    for packs in Int32(-1)...3 {
                        log.check(F.wizardStepMark(step: step, micGranted: bits & 1 == 1, speechGranted: bits & 2 == 2, modelsReady: models,
                                                   packsReady: packs, blackHoleFound: bits & 4 == 4, testPhraseOK: bits & 8 == 8),
                                  L.wizardStepMark(step: step, micGranted: bits & 1 == 1, speechGranted: bits & 2 == 2, modelsReady: models,
                                                   packsReady: packs, blackHoleFound: bits & 4 == 4, testPhraseOK: bits & 8 == 8), describe(step, bits, models, packs))
                    }
                }
                log.check(F.wizardShowOnLaunch(setupCompleted: bits & 1 == 1, forcedStep: step), L.wizardShowOnLaunch(setupCompleted: bits & 1 == 1, forcedStep: step), describe(step, bits))
                log.check(F.wizardShowOnLaunchInMode(setupCompleted: bits & 1 == 1, forcedStep: step, testMode: bits & 2 == 2),
                          L.wizardShowOnLaunchInMode(setupCompleted: bits & 1 == 1, forcedStep: step, testMode: bits & 2 == 2), describe(step, bits))
                log.check(F.wizardCompletedAfterClose(wasCompleted: bits & 1 == 1, finished: bits & 2 == 2),
                          L.wizardCompletedAfterClose(wasCompleted: bits & 1 == 1, finished: bits & 2 == 2), "\(bits)")
            }
        }
        for stored in Int32(-200)...300 { log.check(F.translationFontSize(stored: stored), L.translationFontSize(stored: stored), "\(stored)") }
        for stored in [Int32.min, .max] { log.check(F.translationFontSize(stored: stored), L.translationFontSize(stored: stored), "\(stored)") }
        for available in Int32(-1)...6 {
            for height in stride(from: Int32(-10), through: 400, by: 3) {
                for font in Int32(-5)...60 {
                    log.check(F.overlayLineCount(available: available, panelHeight: height, fontSize: font),
                              L.overlayLineCount(available: available, panelHeight: height, fontSize: font), describe(available, height, font))
                }
            }
        }
        log.finish(minimumCases: 94_000)
    }

    @Test func transcript() {
        let log = DiffLog("transcriptFileName, markdownEscape, isMarkdownSpecial")
        var r = DiffRandom(seed: 34)
        for b in 0...255 { log.check(F.isMarkdownSpecial(UInt8(b)), L.isMarkdownSpecial(UInt8(b)), "\(b)") }
        for _ in 0..<50_000 {
            let parts = (0..<6).map { _ in r.pick([Int32(0), 1, 2, 9, 10, 12, 23, 59, 2026, -5, 12_345, Int32.max, Int32.min, r.int32(-100...3000)]) }
            log.check(F.transcriptFileName(year: parts[0], month: parts[1], day: parts[2], hour: parts[3], minute: parts[4], attempt: parts[5]),
                      L.transcriptFileName(year: parts[0], month: parts[1], day: parts[2], hour: parts[3], minute: parts[4], attempt: parts[5]), "\(parts)")
        }
        for _ in 0..<60_000 {
            var input = r.bool() ? Array(r.text(maxPieces: 40).utf8) : r.bytes(maxCount: 80)
            if input.count > 2_048 { input = Array(input.prefix(2_048)) }
            log.check(F.markdownEscape(input), L.markdownEscape(input), "\(input)")
        }
        let worst = [UInt8](repeating: 0x2A, count: 2_048)
        log.check(F.markdownEscape(worst), L.markdownEscape(worst), "2048 specials")
        let lines = Array(String(repeating: "1. - x\r\n", count: 256).utf8)
        log.check(F.markdownEscape(lines), L.markdownEscape(lines), "2048 bytes of list lines")
        log.finish(minimumCases: 110_000)
    }
}
