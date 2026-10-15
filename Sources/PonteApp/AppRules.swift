import PonteCore
import PonteSpecs

// Every pure decision of Ponte's app layer, in one place.
//
// The decisions are written in t27 (Specs/lane_rules.t27, ui_rules.t27, transcript_rules.t27) and
// compiled to C (Sources/PonteSpecs). This facade only marshals: Int32 codes and Int64 milliseconds pass
// straight through, byte strings go into the fixed buffers the C takes, and constants come from the C
// #defines. The Swift that used to be here is the test oracle AppRulesLegacy (Tests/PonteTests/Oracles);
// the differential tests compare both bit for bit.
//
// A function that returns "next state + action" packs them as (next << 8) | action,
// read back with stepState(_:) and stepAction(_:).
//
// Swift keeps: views and Russian texts, system calls, Unicode work (lowercasing,
// word boundaries for the glossary), concurrency (tasks, generations, locks).
// Device kinds and echo risk come from AudioRules (PonteAudio); the voice meter and
// phrase timing from the transcriber (SpeechRules): they are not repeated here.

enum AppRules {
    // MARK: - Packed steps

    static func pack(_ state: Int32, _ action: Int32) -> Int32 { ln_pack(state, action) }
    static func stepState(_ step: Int32) -> Int32 { ln_step_state(step) }
    static func stepAction(_ step: Int32) -> Int32 { ln_step_action(step) }

    // MARK: - Capture modes

    static let MODE_CONTINUOUS: Int32 = LN_MODE_CONTINUOUS        // «Авто»
    static let MODE_PUSH_TO_TALK: Int32 = LN_MODE_PUSH_TO_TALK

    // MARK: - Lane capture gate (is a transcriber session open?)

    static let GATE_STOPPED: Int32 = LN_GATE_STOPPED
    static let GATE_STARTING: Int32 = LN_GATE_STARTING            // preparing models and the translator
    static let GATE_CLOSED: Int32 = LN_GATE_CLOSED                // running, audio ignored
    static let GATE_OPEN: Int32 = LN_GATE_OPEN                    // running, audio goes to a transcriber session

    static let GEV_START: Int32 = LN_GEV_START
    static let GEV_STARTED: Int32 = LN_GEV_STARTED
    static let GEV_START_FAILED: Int32 = LN_GEV_START_FAILED
    static let GEV_STOP: Int32 = LN_GEV_STOP
    static let GEV_KEY: Int32 = LN_GEV_KEY                        // push-to-talk key changed (keyHeld is the new value)
    static let GEV_PAUSE: Int32 = LN_GEV_PAUSE                    // pause changed (paused is the new value)
    static let GEV_MODE: Int32 = LN_GEV_MODE                      // mode changed (mode is the new value)

    static let GACT_NONE: Int32 = LN_GACT_NONE
    static let GACT_OPEN_SEGMENT: Int32 = LN_GACT_OPEN_SEGMENT
    static let GACT_CLOSE_SEGMENT: Int32 = LN_GACT_CLOSE_SEGMENT  // flush the session: its last phrase becomes final

    /// Audio is transcribed only while running, not paused, and in «Авто» or with the key held.
    static func gateWantsOpen(mode: Int32, keyHeld: Bool, paused: Bool) -> Bool {
        ln_gate_wants_open(mode, keyHeld, paused)
    }

    /// Gate state machine. `mode`, `keyHeld`, `paused` are the values after the event.
    static func gateStep(state: Int32, event: Int32, mode: Int32, keyHeld: Bool, paused: Bool) -> Int32 {
        ln_gate_step(state, event, mode, keyHeld, paused)
    }

    // MARK: - Phrase pipeline (one final phrase from transcript to speech)

    static let PH_LISTENING: Int32 = LN_PH_LISTENING              // volatile text only
    static let PH_TRANSLATING: Int32 = LN_PH_TRANSLATING
    static let PH_SYNTH_QUEUED: Int32 = LN_PH_SYNTH_QUEUED        // waiting for / in speech synthesis
    static let PH_PLAY_QUEUED: Int32 = LN_PH_PLAY_QUEUED
    static let PH_PLAYING: Int32 = LN_PH_PLAYING
    static let PH_SHOWN: Int32 = LN_PH_SHOWN                      // final: text on screen, not spoken
    static let PH_SPOKEN: Int32 = LN_PH_SPOKEN                    // final: text on screen and played
    static let PH_DROPPED: Int32 = LN_PH_DROPPED                  // final: nothing (empty text or speech cancelled)

    static let PEV_PARTIAL: Int32 = LN_PEV_PARTIAL
    static let PEV_FINAL: Int32 = LN_PEV_FINAL
    static let PEV_TRANSLATED: Int32 = LN_PEV_TRANSLATED
    static let PEV_TRANSLATE_FAILED: Int32 = LN_PEV_TRANSLATE_FAILED
    static let PEV_SYNTH_DEQUEUED: Int32 = LN_PEV_SYNTH_DEQUEUED  // the synth worker picked the phrase up
    static let PEV_SYNTHESIZED: Int32 = LN_PEV_SYNTHESIZED
    static let PEV_SYNTH_FAILED: Int32 = LN_PEV_SYNTH_FAILED
    static let PEV_PLAY_DEQUEUED: Int32 = LN_PEV_PLAY_DEQUEUED    // the play worker picked the audio up
    static let PEV_PLAYED: Int32 = LN_PEV_PLAYED

    static let PACT_NONE: Int32 = LN_PACT_NONE
    static let PACT_SHOW_PARTIAL: Int32 = LN_PACT_SHOW_PARTIAL
    static let PACT_TRANSLATE: Int32 = LN_PACT_TRANSLATE          // show the original, start translating
    static let PACT_SHOW_ONLY: Int32 = LN_PACT_SHOW_ONLY          // show the result, do not speak
    static let PACT_SYNTHESIZE: Int32 = LN_PACT_SYNTHESIZE        // show the translation, queue it for speech
    static let PACT_RUN_SYNTH: Int32 = LN_PACT_RUN_SYNTH          // synthesize now
    static let PACT_ENQUEUE_PLAY: Int32 = LN_PACT_ENQUEUE_PLAY
    static let PACT_PLAY: Int32 = LN_PACT_PLAY                    // play now
    static let PACT_DROP: Int32 = LN_PACT_DROP
    static let PACT_FINISH: Int32 = LN_PACT_FINISH                // playback done

    // Flags for phraseStep (bit set).
    static let PF_EMPTY_TEXT: Int32 = LN_PF_EMPTY_TEXT                  // FINAL: phrase empty; TRANSLATED: translation empty
    static let PF_SPEAK_REQUESTED: Int32 = LN_PF_SPEAK_REQUESTED        // decided when the phrase became final
    static let PF_GENERATION_CURRENT: Int32 = LN_PF_GENERATION_CURRENT  // no pause/stop/voice-off since queued
    static let PF_SPEECH_ENABLED: Int32 = LN_PF_SPEECH_ENABLED          // automatic speech is on for this lane now
    static let PF_PAUSED: Int32 = LN_PF_PAUSED
    static let PF_HAS_SYNTH: Int32 = LN_PF_HAS_SYNTH
    static let PF_HAS_PLAYER: Int32 = LN_PF_HAS_PLAYER
    static let PF_HAS_AUDIO: Int32 = LN_PF_HAS_AUDIO                    // synthesis produced at least one buffer

    static func phraseStep(stage: Int32, event: Int32, flags: Int32) -> Int32 {
        ln_phrase_step(stage, event, flags)
    }

    /// Recorded when a phrase becomes final (PF_SPEAK_REQUESTED).
    static func speakRequested(speechEnabled: Bool, paused: Bool) -> Bool {
        ln_speak_requested(speechEnabled, paused)
    }

    // MARK: - Pause, voice toggle, stop: does queued speech die?

    static let SCE_PAUSE: Int32 = LN_SCE_PAUSE                    // value = paused (new)
    static let SCE_VOICE: Int32 = LN_SCE_VOICE                    // value = automatic speech enabled (new)
    static let SCE_STOP: Int32 = LN_SCE_STOP
    static let SCE_OWN_VOICE: Int32 = LN_SCE_OWN_VOICE            // value = own voice on (new)

    static func cancelsSpeech(event: Int32, value: Bool) -> Bool { ln_cancels_speech(event, value) }

    // MARK: - Own voice («Свой голос»)

    /// The button works while running with a call output.
    static func ownVoiceAvailable(running: Bool, hasCallOutput: Bool) -> Bool { ln_own_voice_available(running, hasCallOutput) }
    /// Pressing it: off at any time, on only when available.
    static func ownVoiceAfterToggle(ownVoice: Bool, running: Bool, hasCallOutput: Bool) -> Bool {
        ln_own_voice_after_toggle(ownVoice, running, hasCallOutput)
    }
    /// The gate machine's `paused` input: paused, or the own voice goes out.
    static func gateHeld(paused: Bool, ownVoice: Bool) -> Bool { ln_gate_held(paused, ownVoice) }
    /// No translated speech goes into the call with the own voice.
    static func speechAllowed(ownVoice: Bool) -> Bool { ln_speech_allowed(ownVoice) }

    // MARK: - «Повторить» / «Сказать заново»

    static let RPL_NONE: Int32 = LN_RPL_NONE
    static let RPL_AUDIO: Int32 = LN_RPL_AUDIO                    // play the cached audio of the last phrase
    static let RPL_SYNTH: Int32 = LN_RPL_SYNTH                    // synthesize the last translation first

    /// Honoured even when paused or with automatic speech off: the user asked explicitly.
    static func replayAction(hasCachedAudio: Bool, hasLastTranslation: Bool, hasPlayer: Bool) -> Int32 {
        ln_replay_action(hasCachedAudio, hasLastTranslation, hasPlayer)
    }

    // MARK: - Speech rate by queue length

    /// `waiting` = phrases of this lane queued for speech ahead of this one.
    /// 0 → 100 %, 1 → 110 %, 2 → 120 %, 3 or more → 130 %.
    static func speechRatePercent(waiting: Int32) -> Int32 { ln_speech_rate_percent(waiting) }

    // MARK: - Echo guard (Mac speakers instead of headphones)

    static let ECHO_TAIL_MS = Int64(LN_ECHO_TAIL_MS)

    /// The mic is ignored while Ponte's Russian voice plays through the Mac's speakers
    /// and for ECHO_TAIL_MS after it. `msSinceSpeech` < 0 means "never spoke".
    static func echoGuardBlocksMic(speakerOutput: Bool, incomingSpeaking: Bool, msSinceSpeech: Int64) -> Bool {
        ln_echo_guard_blocks_mic(speakerOutput, incomingSpeaking, msSinceSpeech)
    }

    /// The echo guard is armed only when the owner listens on a loudspeaker
    /// (AudioRules.echoRisk == echoSpeaker) and the outgoing lane hears a live microphone.
    static func echoGuardApplies(speakerOutput: Bool, micIsLive: Bool) -> Bool {
        ln_echo_guard_applies(speakerOutput, micIsLive)
    }

    // MARK: - Phrase timing

    static let END_NOW: Int32 = LN_END_NOW
    // 1 was END_LAST_VOICE (the lane's own voice meter, replaced by the transcriber's timing).
    static let END_LAST_PARTIAL: Int32 = LN_END_LAST_PARTIAL
    static let END_TRANSCRIBER: Int32 = LN_END_TRANSCRIBER

    /// Which moment counts as "the speaker finished this phrase" when its final arrives.
    /// Arguments are milliseconds before now; negative means "unknown".
    static func phraseEndChoice(msSinceTimedEnd: Int64, msSincePartial: Int64) -> Int32 {
        ln_phrase_end_choice(msSinceTimedEnd, msSincePartial)
    }

    static func latencyMs(endMs: Int64, readyMs: Int64) -> Int64 { ln_latency_ms(endMs, readyMs) }

    /// Phrases of context passed to the translator, oldest first.
    static let CONTEXT_PHRASES: Int32 = LN_CONTEXT_PHRASES

    /// How many of the oldest remembered phrases to forget after adding one.
    static func contextOverflow(count: Int32) -> Int32 { ln_context_overflow(count) }

    // MARK: - Run state, start, stop

    static let RUN_IDLE: Int32 = UI_RUN_IDLE
    static let RUN_STARTING: Int32 = UI_RUN_STARTING
    static let RUN_RUNNING: Int32 = UI_RUN_RUNNING
    static let RUN_STOPPING: Int32 = UI_RUN_STOPPING

    static let TOGGLE_NONE: Int32 = UI_TOGGLE_NONE
    static let TOGGLE_START: Int32 = UI_TOGGLE_START
    static let TOGGLE_STOP: Int32 = UI_TOGGLE_STOP

    static func toggleRun(runState: Int32) -> Int32 { ui_toggle_run(runState) }

    /// Ponte runs if at least one lane started.
    static func runStateAfterStart(lanesStarted: Int32) -> Int32 { ui_run_state_after_start(lanesStarted) }

    static let BAN_NONE: Int32 = UI_BAN_NONE
    static let BAN_FAILED_PACKS: Int32 = UI_BAN_FAILED_PACKS      // error + «Открыть мастер» on the packs step
    static let BAN_FAILED_OTHER: Int32 = UI_BAN_FAILED_OTHER      // error + «Открыть мастер» on permissions
    static let BAN_NO_BLACKHOLE: Int32 = UI_BAN_NO_BLACKHOLE      // warning + «Как установить»
    static let BAN_SPEAKERS: Int32 = UI_BAN_SPEAKERS              // warning: put on headphones

    static func startBanner(lanesFailed: Int32, packsMissing: Bool, hasBlackHole: Bool, speakerOutput: Bool) -> Int32 {
        ui_start_banner(lanesFailed, packsMissing, hasBlackHole, speakerOutput)
    }

    static let BAN_NO_PACKS: Int32 = UI_BAN_NO_PACKS              // lanes listen, translation packs missing
    static let BAN_NO_TRANSLATOR: Int32 = UI_BAN_NO_TRANSLATOR    // lanes listen, translator failed otherwise

    /// Banner after «Старт» when a lane can run without its translator (recognition only).
    static func startBannerAfterStart(lanesFailed: Int32, translatorsFailed: Int32, packsMissing: Bool,
                                      hasBlackHole: Bool, speakerOutput: Bool) -> Int32 {
        ui_start_banner_after_start(lanesFailed, translatorsFailed, packsMissing, hasBlackHole, speakerOutput)
    }

    // MARK: - Translator that could not be prepared at «Старт»

    /// Before each phrase the lane prepares its translator again, at most once per PREPARE_RETRY_MS.
    static let PREPARE_RETRY_MS = Int64(LN_PREPARE_RETRY_MS)

    /// `msSinceAttempt` < 0 = never tried.
    static func retryTranslatorPrepare(prepared: Bool, msSinceAttempt: Int64) -> Bool {
        ln_retry_translator_prepare(prepared, msSinceAttempt)
    }

    static func autosaveOnStop(lines: Int32) -> Bool { ui_autosave_on_stop(lines) }

    // MARK: - Which controls are enabled

    static let BTN_START_STOP: Int32 = UI_BTN_START_STOP
    static let BTN_SOURCE: Int32 = UI_BTN_SOURCE
    static let BTN_REPLAY_INCOMING: Int32 = UI_BTN_REPLAY_INCOMING
    static let BTN_REPLAY_OUTGOING: Int32 = UI_BTN_REPLAY_OUTGOING
    static let BTN_SAVE_TRANSCRIPT: Int32 = UI_BTN_SAVE_TRANSCRIPT
    static let BTN_PAUSE_VOICE: Int32 = UI_BTN_PAUSE_VOICE
    static let BTN_MODE: Int32 = UI_BTN_MODE
    static let BTN_TALK_PAD: Int32 = UI_BTN_TALK_PAD
    static let BTN_TEST_CALL: Int32 = UI_BTN_TEST_CALL
    static let BTN_TEST_HEADPHONES: Int32 = UI_BTN_TEST_HEADPHONES
    static let BTN_VOICE_TOGGLE: Int32 = UI_BTN_VOICE_TOGGLE

    static func buttonEnabled(button: Int32, runState: Int32, incomingLines: Int32, outgoingLines: Int32,
                              hasBlackHole: Bool, busy: Bool) -> Bool {
        ui_button_enabled(button, runState, incomingLines, outgoingLines, hasBlackHole, busy)
    }

    // MARK: - Status lights and latency colour

    static let LIGHT_UNKNOWN: Int32 = UI_LIGHT_UNKNOWN
    static let LIGHT_OK: Int32 = UI_LIGHT_OK
    static let LIGHT_BAD: Int32 = UI_LIGHT_BAD
    static let LIGHT_BUSY: Int32 = UI_LIGHT_BUSY
    static let LIGHT_WARN: Int32 = UI_LIGHT_WARN

    static let AUDIO_FRESH_MS = Int64(UI_AUDIO_FRESH_MS)          // a buffer this recent means audio flows
    static let AUDIO_WARMUP_MS = Int64(UI_AUDIO_WARMUP_MS)        // grace period after Старт

    /// Source audio / microphone light. `msSinceBuffer` < 0 = no buffer yet.
    static func audioLight(runState: Int32, laneActive: Bool, msSinceStart: Int64, msSinceBuffer: Int64) -> Int32 {
        ui_audio_light(runState, laneActive, msSinceStart, msSinceBuffer)
    }

    /// Process tap status (AppAudioTapSource.Status), as codes.
    static let TAP_NONE: Int32 = UI_TAP_NONE                      // the source is not a process tap (test file)
    static let TAP_WAITING: Int32 = UI_TAP_WAITING                // the chosen app has no audio process yet
    static let TAP_CAPTURING: Int32 = UI_TAP_CAPTURING
    static let TAP_FAILED: Int32 = UI_TAP_FAILED
    static let TAP_IDLE: Int32 = UI_TAP_IDLE                      // not started or stopped

    /// Only exact zeros this long after «Старт»: the System Audio Recording permission is probably missing.
    static let SILENCE_SUSPECT_MS = Int64(UI_SILENCE_SUSPECT_MS)

    /// «Звук источника» light: audioLight, then the tap status. `msSinceSignal` < 0 = no non-zero sample.
    static func sourceLight(runState: Int32, laneActive: Bool, tapStatus: Int32, msSinceStart: Int64,
                            msSinceBuffer: Int64, msSinceSignal: Int64) -> Int32 {
        ui_source_light(runState, laneActive, tapStatus, msSinceStart, msSinceBuffer, msSinceSignal)
    }

    /// Microphone status (MicSource.Status), as codes.
    static let MIC_NONE: Int32 = UI_MIC_NONE                      // the outgoing source is not a microphone (test file)
    static let MIC_CAPTURING: Int32 = UI_MIC_CAPTURING
    static let MIC_RESTARTING: Int32 = UI_MIC_RESTARTING          // a device change stopped it; being rebuilt
    static let MIC_FAILED: Int32 = UI_MIC_FAILED                  // AudioRules.restartFailed: rebuilds keep failing
    static let MIC_IDLE: Int32 = UI_MIC_IDLE                      // not started or stopped

    /// «Микрофон» light. Not running or no lane: audioLight. MIC_FAILED → BAD and MIC_RESTARTING → BUSY,
    /// whatever the gate. Gate closed (push-to-talk key up, «Пауза голоса в звонок»): OK. Gate open:
    /// audioLight with the warm-up from the later of Старт and the gate opening.
    /// `msSinceListen` < 0 = the gate is closed.
    static func micLight(runState: Int32, laneActive: Bool, micStatus: Int32, msSinceStart: Int64, msSinceListen: Int64,
                         msSinceBuffer: Int64) -> Int32 {
        ui_mic_light(runState, laneActive, micStatus, msSinceStart, msSinceListen, msSinceBuffer)
    }

    /// Setup wizard «Запись звука программ»: listen to all audio except Ponte for CAPTURE_CHECK_MS.
    static let CAPTURE_CHECK_MS = Int64(UI_CAPTURE_CHECK_MS)

    /// Result of the wizard check: tap failed or no audio at all → BAD; only exact zeros → WARN; else OK.
    static func captureCheckLight(tapStatus: Int32, framesSeen: Bool, signalSeen: Bool) -> Int32 {
        ui_capture_check_light(tapStatus, framesSeen, signalSeen)
    }

    static func blackHoleLight(found: Bool) -> Int32 { ui_blackhole_light(found) }

    /// Models (transcribers + translator) light, from the last start attempt.
    static func modelsLight(runState: Int32, everStarted: Bool, lanesStarted: Int32, lanesFailed: Int32) -> Int32 {
        ui_models_light(runState, everStarted, lanesStarted, lanesFailed)
    }

    static let LAT_NONE: Int32 = UI_LAT_NONE
    static let LAT_GOOD: Int32 = UI_LAT_GOOD                      // ≤ 2 s: the target from SPEC.md
    static let LAT_SLOW: Int32 = UI_LAT_SLOW                      // ≤ 4 s
    static let LAT_BAD: Int32 = UI_LAT_BAD
    static let LAT_GOOD_MS = Int64(UI_LAT_GOOD_MS)
    static let LAT_SLOW_MS = Int64(UI_LAT_SLOW_MS)

    /// `ms` < 0 = no phrase yet.
    static func latencyColor(ms: Int64) -> Int32 { ui_latency_color(ms) }

    // MARK: - Source menu

    static let SRC_CALLS: Int32 = UI_SRC_CALLS                    // «Звонилки»
    static let SRC_PLAYING: Int32 = UI_SRC_PLAYING                // «Сейчас звучат»
    static let SRC_OTHER: Int32 = UI_SRC_OTHER                    // «Другие программы»

    static func sourceSection(isKnownCallApp: Bool, isPlayingAudio: Bool) -> Int32 {
        ui_source_section(isKnownCallApp, isPlayingAudio)
    }

    // MARK: - Translator

    static let TR_APPLE: Int32 = UI_TR_APPLE
    static let TR_CLAUDE: Int32 = UI_TR_CLAUDE

    static func translatorChoice(preferred: Int32, claudeAvailable: Bool) -> Int32 {
        ui_translator_choice(preferred, claudeAvailable)
    }

    // MARK: - Push-to-talk

    static let PTT_RIGHT_OPTION: Int32 = LN_PTT_RIGHT_OPTION
    static let PTT_RIGHT_COMMAND: Int32 = LN_PTT_RIGHT_COMMAND
    static let PTT_RIGHT_SHIFT: Int32 = LN_PTT_RIGHT_SHIFT
    static let PTT_RIGHT_CONTROL: Int32 = LN_PTT_RIGHT_CONTROL
    static let PTT_FN: Int32 = LN_PTT_FN

    /// `flags` = NSEvent.modifierFlags.rawValue (device-dependent right-hand bits; Fn = NSEventModifierFlagFunction).
    static func pttKeyDown(key: Int32, flags: UInt64) -> Bool { ln_ptt_key_down(key, flags) }

    static let PTT_SCOPE_NONE: Int32 = LN_PTT_SCOPE_NONE
    static let PTT_SCOPE_WINDOW: Int32 = LN_PTT_SCOPE_WINDOW      // only while a Ponte window is active
    static let PTT_SCOPE_GLOBAL: Int32 = LN_PTT_SCOPE_GLOBAL      // everywhere (needs Accessibility)

    static func pttScope(running: Bool, mode: Int32, accessibilityGranted: Bool) -> Int32 {
        ln_ptt_scope(running, mode, accessibilityGranted)
    }

    // MARK: - Setup wizard

    static let WZ_PERMISSIONS: Int32 = UI_WZ_PERMISSIONS
    static let WZ_MODELS: Int32 = UI_WZ_MODELS
    static let WZ_PACKS: Int32 = UI_WZ_PACKS
    static let WZ_BLACKHOLE: Int32 = UI_WZ_BLACKHOLE
    static let WZ_CALL_APPS: Int32 = UI_WZ_CALL_APPS
    static let WZ_DONE: Int32 = UI_WZ_DONE
    static let WZ_NONE: Int32 = UI_WZ_NONE

    static func wizardNext(step: Int32) -> Int32 { ui_wizard_next(step) }

    static func wizardPrevious(step: Int32) -> Int32 { ui_wizard_previous(step) }

    static let MARK_NONE: Int32 = UI_MARK_NONE
    static let MARK_DONE: Int32 = UI_MARK_DONE
    static let MARK_WARN: Int32 = UI_MARK_WARN

    static func wizardStepMark(step: Int32, micGranted: Bool, speechGranted: Bool, modelsReady: Int32,
                               packsReady: Int32, blackHoleFound: Bool, testPhraseOK: Bool) -> Int32 {
        ui_wizard_step_mark(step, micGranted, speechGranted, modelsReady, packsReady, blackHoleFound, testPhraseOK)
    }

    /// `forcedStep` ≥ 0 when the wizard was asked for explicitly.
    static func wizardShowOnLaunch(setupCompleted: Bool, forcedStep: Int32) -> Bool {
        ui_wizard_show_on_launch(setupCompleted, forcedStep)
    }

    /// Test mode (launch arguments with files) counts as set up: the wizard opens only when forced.
    static func wizardShowOnLaunchInMode(setupCompleted: Bool, forcedStep: Int32, testMode: Bool) -> Bool {
        ui_wizard_show_on_launch_in_mode(setupCompleted, forcedStep, testMode)
    }

    /// «Закрыть» keeps the old flag; «Начать работу» (finished) completes setup.
    static func wizardCompletedAfterClose(wasCompleted: Bool, finished: Bool) -> Bool {
        ui_wizard_completed_after_close(wasCompleted, finished)
    }

    // MARK: - Text size

    static let FONT_DEFAULT_PT: Int32 = UI_FONT_DEFAULT_PT
    static let FONT_MIN_PT: Int32 = UI_FONT_MIN_PT
    static let FONT_MAX_PT: Int32 = UI_FONT_MAX_PT

    /// Stored setting → translation font size: unset or below 14 → default, else clamped 16…40.
    static func translationFontSize(stored: Int32) -> Int32 { ui_translation_font_size(stored) }

    // MARK: - Subtitle overlay

    static let OVERLAY_MAX_LINES: Int32 = UI_OVERLAY_MAX_LINES
    static let OVERLAY_PADDING_PT: Int32 = UI_OVERLAY_PADDING_PT

    /// Last N incoming translations to show; 1 when the panel is too short for 2.
    static func overlayLineCount(available: Int32, panelHeight: Int32, fontSize: Int32) -> Int32 {
        ui_overlay_line_count(available, panelHeight, fontSize)
    }

    // MARK: - Transcript file

    /// "YYYY-MM-DD-HHMM.md"; attempt ≥ 2 adds "-N" so an existing file is never overwritten.
    static func transcriptFileName(year: Int32, month: Int32, day: Int32, hour: Int32, minute: Int32,
                                   attempt: Int32) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: Int(TR_BUFFER))
        let n = Int(tr_transcript_file_name(year, month, day, hour, minute, attempt, &out))
        return Array(out[0..<n])
    }

    /// Callers cut phrases to this many bytes (at a character boundary) before escaping,
    /// so the escaped text always fits a 4096-byte buffer.
    static let MD_ESCAPE_MAX_INPUT = Int32(TR_MD_ESCAPE_MAX_INPUT)

    /// Escapes Markdown in transcript text, byte by byte (UTF-8 passes through); see `tr_markdown_escape`.
    static func markdownEscape(_ input: [UInt8]) -> [UInt8] {
        var buffer = [UInt8](repeating: 0, count: Int(TR_BUFFER))
        let n = min(input.count, buffer.count)
        buffer.replaceSubrange(0..<n, with: input[0..<n])
        var out = [UInt8](repeating: 0, count: Int(TR_BUFFER))
        let written = Int(tr_markdown_escape(&buffer, Int64(input.count), &out))
        return Array(out[0..<written])
    }

    static func isMarkdownSpecial(_ byte: UInt8) -> Bool { tr_is_markdown_special(byte) }

    /// The first file name has no "-N"; each existing file moves to the next attempt.
    static let FIRST_ATTEMPT: Int32 = TR_FIRST_ATTEMPT

    /// TranscriptExporter.escaped: a character of `charBytes` bytes still fits after `bytes` bytes.
    static func fitsEscapeInput(bytes: Int, charBytes: Int) -> Bool { tr_fits_escape_input(Int64(bytes), Int64(charBytes)) }

    /// Transcript order: by time; lines of the same time keep their order.
    static func lineBefore(atA: Double, indexA: Int, atB: Double, indexB: Int) -> Bool {
        tr_line_before(atA, Int64(indexA), atB, Int64(indexB))
    }

    // MARK: - Lane rules moved here from TranslationLane, AppModel, PushToTalkMonitor, Glossary, WAVFileSink

    static let DIR_INCOMING: Int32 = LN_DIR_INCOMING
    static let DIR_OUTGOING: Int32 = LN_DIR_OUTGOING
    static func directionCode(_ direction: Direction) -> Int32 { direction.specCode }

    /// Defaults of the settings: «Авто» and the right Option key.
    static let DEFAULT_MODE: Int32 = LN_DEFAULT_MODE
    static let DEFAULT_PTT_KEY: Int32 = LN_DEFAULT_PTT_KEY

    /// stop(): wait for an open transcriber session, then for pending translations.
    static let STOP_SEGMENT_WAIT_MS = Int64(LN_STOP_SEGMENT_WAIT_MS)
    static let STOP_TRANSLATE_WAIT_MS = Int64(LN_STOP_TRANSLATE_WAIT_MS)

    /// The owner's own voice came back from the call: an incoming phrase mostly inside a talk-key interval
    /// (talkEndMs < 0 while held). A phrase without transcriber timing started PHRASE_FALLBACK_MS before its end.
    static func ownTalkDrops(phraseStartMs: Int64, phraseEndMs: Int64, talkStartMs: Int64, talkEndMs: Int64) -> Bool {
        ln_own_talk_drops(phraseStartMs, phraseEndMs, talkStartMs, talkEndMs)
    }
    static let PHRASE_FALLBACK_MS = Int64(LN_PHRASE_FALLBACK_MS)

    /// The owner's ears are sealed from the microphone: a jack headphone, or the headset whose mic Ponte uses.
    static func outputSealed(echoRiskNone: Bool, micIsOutputHeadset: Bool) -> Bool {
        ln_output_sealed(echoRiskNone, micIsOutputHeadset)
    }
    /// The microphone may hear Ponte's Russian voice: a loudspeaker or any output that is not sealed.
    static func echoOutput(speakerOutput: Bool, outputSealed: Bool) -> Bool { ln_echo_output(speakerOutput, outputSealed) }
    /// Another Russian's voice just played and the mic may hear it: nothing from the mic goes into the call.
    static func peerAudioBlocksCall(outputSealed: Bool, msSincePeerAudio: Int64) -> Bool {
        ln_peer_audio_blocks_call(outputSealed, msSincePeerAudio)
    }

    /// Seconds to whole milliseconds, rounded half away from zero (finite input).
    static func millis(_ seconds: Double) -> Int64 { ln_millis(seconds) }

    /// EchoGuard: the speech time is recorded when the voice starts, plays on, or stops.
    static func echoMarksTime(wasSpeaking: Bool, nowSpeaking: Bool) -> Bool { ln_echo_marks_time(wasSpeaking, nowSpeaking) }

    static func gateRunning(state: Int32) -> Bool { ln_gate_running(state) }
    static func gateCanStart(state: Int32) -> Bool { ln_gate_can_start(state) }

    /// phraseEndChoice from optional times (nil: not known; a time in the future counts as now or unknown).
    static func phraseEndChoiceKnown(msSinceTimedEnd: Int64?, msSincePartial: Int64?) -> Int32 {
        ln_phrase_end_choice_known(msSinceTimedEnd != nil, msSinceTimedEnd ?? 0, msSincePartial != nil, msSincePartial ?? 0)
    }

    /// The phraseStep flags (PF_*) from the facts.
    static func phraseFlags(emptyText: Bool = false, speakRequested: Bool = false, generationCurrent: Bool = false,
                            speechEnabled: Bool = false, paused: Bool = false, hasSynth: Bool = false,
                            hasPlayer: Bool = false, hasAudio: Bool = false) -> Int32 {
        ln_phrase_flags(emptyText, speakRequested, generationCurrent, speechEnabled, paused, hasSynth, hasPlayer, hasAudio)
    }

    static func needsSpeechWorkers(hasSynth: Bool, hasPlayer: Bool) -> Bool { ln_needs_speech_workers(hasSynth, hasPlayer) }
    static func backlogAfterSpeech(_ backlog: Int32, counted: Bool) -> Int32 { ln_backlog_after_speech(backlog, counted) }
    static func speechWaiting(backlog: Int32, counted: Bool) -> Int32 { ln_speech_waiting(backlog, counted) }
    static func reportsTranslationError(cancelled: Bool) -> Bool { ln_reports_translation_error(cancelled) }
    static func playEndReports(action: Int32, generationCurrent: Bool) -> Bool { ln_play_end_reports(action, generationCurrent) }
    static func intakeForwards(hasSegment: Bool, echoBlocks: Bool) -> Bool { ln_intake_forwards(hasSegment, echoBlocks) }

    /// AudioIntake: where a microphone buffer goes besides the transcriber (ROUTE_* bits).
    static let ROUTE_RELAY: Int32 = LN_ROUTE_RELAY
    static let ROUTE_PEERS: Int32 = LN_ROUTE_PEERS
    static func intakeRoutes(hasRelay: Bool, hasPeers: Bool, callBlocks: Bool) -> Int32 {
        ln_intake_routes(hasRelay, hasPeers, callBlocks)
    }
    /// EchoGuard: nothing from the microphone may go into the call or to the other Russians.
    static func blocksCall(micBlocks: Bool, peerAudioBlocks: Bool) -> Bool { ln_blocks_call(micBlocks, peerAudioBlocks) }
    /// «Свой голос»: a voice buffer is his last word; he talks while the gate is open; when a change is stamped.
    static func ownVoiceMarks(voice: Bool, callBlocks: Bool) -> Bool { ln_own_voice_marks(voice, callBlocks) }
    static func ownTalking(callBlocks: Bool, gateOpen: Bool) -> Bool { ln_own_talking(callBlocks, gateOpen) }
    static func ownTalkChangeMs(talking: Bool, nowMs: Int64, lastVoiceMs: Int64?) -> Int64 {
        ln_own_talk_change_ms(talking, nowMs, lastVoiceMs != nil, lastVoiceMs ?? 0)
    }
    /// When an incoming phrase started on the wall clock, from the transcriber's timing or its end.
    static func phraseStartMs(endArrivedMs: Int64?, audioStartMs: Int64, audioEndMs: Int64, endMs: Int64) -> Int64 {
        ln_phrase_start_ms(endArrivedMs != nil, endArrivedMs ?? 0, audioStartMs, audioEndMs, endMs)
    }
    /// Which incoming phrases are not translated.
    static func phraseDropped(ownTalk: Bool, ownWindows: Bool, linkOn: Bool, peerWindows: Bool) -> Bool {
        ln_phrase_dropped(ownTalk, ownWindows, linkOn, peerWindows)
    }
    /// OwnTalkLog: the talk key opens or closes an interval; the oldest are forgotten.
    static let TALK_NONE: Int32 = LN_TALK_NONE
    static let TALK_OPEN: Int32 = LN_TALK_OPEN
    static let TALK_CLOSE: Int32 = LN_TALK_CLOSE
    static func talkLogStep(held: Bool, hasOpen: Bool) -> Int32 { ln_talk_log_step(held, hasOpen) }
    static func talkLogForget(count: Int) -> Int { Int(ln_talk_log_forget(Int64(count))) }
    static func backlogAfterQueue(_ backlog: Int32) -> Int32 { ln_backlog_after_queue(backlog) }
    static func testHoldsKey(running: Bool, hasTestFile: Bool) -> Bool { ln_test_holds_key(running, hasTestFile) }

    /// Segment: what an audio buffer does, and what closing does.
    static let SEG_DROP: Int32 = LN_SEG_DROP
    static let SEG_FORWARD: Int32 = LN_SEG_FORWARD
    static let SEG_BUFFER: Int32 = LN_SEG_BUFFER
    static let SEGC_NONE: Int32 = LN_SEGC_NONE
    static let SEGC_FINISH: Int32 = LN_SEGC_FINISH
    static let SEGC_MARK: Int32 = LN_SEGC_MARK
    static func segmentAppend(started: Bool, closed: Bool) -> Int32 { ln_segment_append(started, closed) }
    static func segmentClose(started: Bool, closed: Bool) -> Int32 { ln_segment_close(started, closed) }

    /// Where a lane's audio comes from, and where the outgoing voice goes.
    static let SOURCE_LIVE: Int32 = LN_SOURCE_LIVE
    static let SOURCE_FILE: Int32 = LN_SOURCE_FILE
    static func sourceKind(hasTestFile: Bool) -> Int32 { ln_source_kind(hasTestFile) }
    static func requestsMicPermission(micIsLive: Bool, micDecision: Int) -> Bool {
        ln_requests_mic_permission(micIsLive, Int64(micDecision))
    }
    static let OUT_SINK: Int32 = LN_OUT_SINK
    static let OUT_DEVICE: Int32 = LN_OUT_DEVICE
    static let OUT_NONE: Int32 = LN_OUT_NONE
    static func callOutput(hasSink: Bool, hasBlackHole: Bool) -> Int32 { ln_call_output(hasSink, hasBlackHole) }

    /// Per-lane settings by direction.
    static func laneMode(direction: Int32, outgoingMode: Int32) -> Int32 { ln_lane_mode(direction, outgoingMode) }
    static func laneSpeaks(direction: Int32, speakRussian: Bool) -> Bool { ln_lane_speaks(direction, speakRussian) }
    /// The call output starts with the lane and keeps running between phrases.
    static func lanePreparesOutput(direction: Int32, speaks: Bool) -> Bool { ln_lane_prepares_output(direction, speaks) }
    static func laneVoicePause(direction: Int32) -> Bool { ln_lane_voice_pause(direction) }
    static func laneEchoGuarded(direction: Int32) -> Bool { ln_lane_echo_guarded(direction) }
    static func laneEchoSource(direction: Int32) -> Bool { ln_lane_echo_source(direction) }
    /// The lane whose voice plays into the call (its voice windows are kept and announced to the other Russians).
    static func laneVoiceInCall(direction: Int32) -> Bool { ln_lane_voice_in_call(direction) }
    static func glossarySourceIsPT(direction: Int32) -> Bool { ln_glossary_source_is_pt(direction) }

    /// PushToTalkMonitor: which monitors a scope installs.
    static func pttLocal(scope: Int32) -> Bool { ln_ptt_local(scope) }
    static func pttGlobal(scope: Int32) -> Bool { ln_ptt_global(scope) }

    /// WAVFileSink pacing step, seconds.
    static func sinkPaceStep(left: Double) -> Double { ln_sink_pace_step(left) }

    // MARK: - UI rules moved here from AppModel, the views, LaunchOptions, Preferences, PonteMain

    static let DEFAULT_TRANSLATOR: Int32 = UI_DEFAULT_TRANSLATOR
    static let DEFAULT_SPEAK_RUSSIAN = UI_DEFAULT_SPEAK_RUSSIAN != 0
    static let DEFAULT_OVERLAY_VISIBLE = UI_DEFAULT_OVERLAY_VISIBLE != 0
    static let DEFAULT_HEAR_ORIGINAL = UI_DEFAULT_HEAR_ORIGINAL != 0

    /// The status row polls this often; the catalogs are re-read on some polls.
    static let POLL_INTERVAL_MS = Int64(UI_POLL_INTERVAL_MS)
    static func pollRefreshesCatalogs(tick: Int64) -> Bool { ui_poll_refreshes_catalogs(tick) }

    /// "Скопировано" stays this long.
    static let COPIED_FEEDBACK_MS = Int64(UI_COPIED_FEEDBACK_MS)

    static func modelsLightAll(runState: Int32, everStarted: Bool, lanesStarted: Int32, lanesFailed: Int32,
                               translatorsFailed: Int32) -> Int32 {
        ui_models_light_all(runState, everStarted, lanesStarted, lanesFailed, translatorsFailed)
    }

    static func showsLevel(light: Int32) -> Bool { ui_shows_level(light) }
    /// The microphone meter: a green light and a fresh buffer.
    static func micShowsLevel(light: Int32, msSinceBuffer: Int64) -> Bool { ui_mic_shows_level(light, msSinceBuffer) }

    static let SB_NONE: Int32 = UI_SB_NONE
    static let SB_MARK: Int32 = UI_SB_MARK
    static let SB_SHOW: Int32 = UI_SB_SHOW
    static let SB_CLEAR: Int32 = UI_SB_CLEAR
    static func silenceBanner(sourceLight: Int32, alreadyWarned: Bool, errorShown: Bool, silenceShown: Bool) -> Int32 {
        ui_silence_banner(sourceLight, alreadyWarned, errorShown, silenceShown)
    }

    static let HELP_IDLE: Int32 = UI_HELP_IDLE
    static let HELP_WAITING: Int32 = UI_HELP_WAITING
    static let HELP_FAILED: Int32 = UI_HELP_FAILED
    static let HELP_FILE: Int32 = UI_HELP_FILE
    static let HELP_SILENCE: Int32 = UI_HELP_SILENCE
    static let HELP_FLOWING: Int32 = UI_HELP_FLOWING
    static func sourceHelp(runState: Int32, tapStatus: Int32, sourceLight: Int32) -> Int32 {
        ui_source_help(runState, tapStatus, sourceLight)
    }

    static let TITLE_SYSTEM: Int32 = UI_TITLE_SYSTEM
    static let TITLE_RUNNING: Int32 = UI_TITLE_RUNNING
    static let TITLE_LABEL: Int32 = UI_TITLE_LABEL
    static let TITLE_ID: Int32 = UI_TITLE_ID
    static func sourceTitle(isSystem: Bool, hasRunningName: Bool, hasLabel: Bool) -> Int32 {
        ui_source_title(isSystem, hasRunningName, hasLabel)
    }

    static func hasCallOutput(hasBlackHole: Bool, hasSink: Bool) -> Bool { ui_has_call_output(hasBlackHole, hasSink) }

    static let BK_NONE: Int32 = UI_BK_NONE
    static let BK_ERROR: Int32 = UI_BK_ERROR
    static let BK_WARNING: Int32 = UI_BK_WARNING
    static let BK_INFO: Int32 = UI_BK_INFO
    static func bannerKind(banner: Int32) -> Int32 { ui_banner_kind(banner) }
    static func bannerStep(banner: Int32) -> Int32 { ui_banner_step(banner) }

    static let TEB_NONE: Int32 = UI_TEB_NONE
    static let TEB_PACKS: Int32 = UI_TEB_PACKS
    static let TEB_WARNING: Int32 = UI_TEB_WARNING
    static func translationErrorBanner(missingPacks: Bool, packsBannerShown: Bool, sameTextShown: Bool) -> Int32 {
        ui_translation_error_banner(missingPacks, packsBannerShown, sameTextShown)
    }

    static let DEV_SAVED: Int32 = UI_DEV_SAVED
    static let DEV_AUTO: Int32 = UI_DEV_AUTO
    static func deviceChoice(hasSetting: Bool, found: Bool) -> Int32 { ui_device_choice(hasSetting, found) }

    static func probesClaude(preferred: Int32) -> Bool { ui_probes_claude(preferred) }
    static func transcriptHasEnd(runState: Int32) -> Bool { ui_transcript_has_end(runState) }
    static func testPhrasePossible(intoCall: Bool, hasBlackHole: Bool) -> Bool { ui_test_phrase_possible(intoCall, hasBlackHole) }

    static let OUTSTATUS_NONE: Int32 = UI_OUT_NONE
    static let OUTSTATUS_PAUSED: Int32 = UI_OUT_PAUSED
    static let OUTSTATUS_SPEAKING: Int32 = UI_OUT_SPEAKING
    static let OUTSTATUS_NO_BLACKHOLE: Int32 = UI_OUT_NO_BLACKHOLE
    static func outgoingStatus(paused: Bool, speaking: Bool, running: Bool, hasBlackHole: Bool) -> Int32 {
        ui_outgoing_status(paused, speaking, running, hasBlackHole)
    }

    static let COL_FOUND: Int32 = UI_COL_FOUND
    static let COL_SEARCH: Int32 = UI_COL_SEARCH
    static func callOutputLabel(hasBlackHole: Bool, hasSetting: Bool) -> Int32 { ui_call_output_label(hasBlackHole, hasSetting) }

    static let TN_NONE: Int32 = UI_TN_NONE
    static let TN_NO_KEY: Int32 = UI_TN_NO_KEY
    static let TN_NO_KEY_FALLBACK: Int32 = UI_TN_NO_KEY_FALLBACK
    static func translatorNote(preferred: Int32, claudeAvailable: Bool) -> Int32 { ui_translator_note(preferred, claudeAvailable) }

    /// Permissions: AVAuthorizationStatus / SFSpeechRecognizerAuthorizationStatus raw value → state → row.
    static let PERM_UNKNOWN: Int32 = UI_PERM_UNKNOWN
    static let PERM_GRANTED: Int32 = UI_PERM_GRANTED
    static let PERM_DENIED: Int32 = UI_PERM_DENIED
    static let PERM_NOT_ASKED: Int32 = UI_PERM_NOT_ASKED
    static func permissionState(raw: Int) -> Int32 { ui_permission_state(Int64(raw)) }
    static let PA_NONE: Int32 = UI_PA_NONE
    static let PA_REQUEST: Int32 = UI_PA_REQUEST
    static let PA_OPEN_SETTINGS: Int32 = UI_PA_OPEN_SETTINGS
    static func permissionAction(state: Int32) -> Int32 { ui_permission_action(state) }
    static func permissionLight(state: Int32) -> Int32 { ui_permission_light(state) }
    static func captureNeedsSettings(light: Int32) -> Bool { ui_capture_needs_settings(light) }
    static func accessibilityLight(granted: Bool) -> Int32 { ui_accessibility_light(granted) }

    /// Language packs (the SpeechRules.avail* codes).
    static func packLight(status: Int) -> Int32 { ui_pack_light(Int32(clamping: status)) }
    static func packRefreshable(light: Int32) -> Bool { ui_pack_refreshable(light) }
    static func packDownloadEnabled(light: Int32) -> Bool { ui_pack_download_enabled(light) }

    static let LINE_TRANSLATED: Int32 = UI_LINE_TRANSLATED
    static let LINE_FAILED: Int32 = UI_LINE_FAILED
    static let LINE_PENDING: Int32 = UI_LINE_PENDING
    static func lineState(hasTranslation: Bool, hasError: Bool) -> Int32 { ui_line_state(hasTranslation, hasError) }

    static func isTestMode(hasIncomingFile: Bool, hasOutgoingFile: Bool, hasSink: Bool, hasTranscriptDir: Bool) -> Bool {
        ui_is_test_mode(hasIncomingFile, hasOutgoingFile, hasSink, hasTranscriptDir)
    }

    /// A launch flag means yes ("yes", "true", "1"); Swift lowercases it first.
    static func isYes(utf8: [UInt8]) -> Bool {
        var text = [UInt8](repeating: 0, count: Int(UI_WORD_MAX))
        let n = min(utf8.count, text.count)
        text.replaceSubrange(0..<n, with: utf8[0..<n])
        return ui_is_yes(&text, Int64(utf8.count))
    }

    /// A stored source key: the byte length of its "app:" prefix, or -1 (all Mac audio).
    static func sourceKeyAppPrefix(utf8: [UInt8]) -> Int {
        var text = [UInt8](repeating: 0, count: Int(UI_KEY_MAX))
        let n = min(utf8.count, text.count)
        text.replaceSubrange(0..<n, with: utf8[0..<n])
        return Int(ui_source_key_app_prefix(&text, Int64(utf8.count)))
    }

    /// The stored source keys: all Mac audio, and the prefix of an app.
    static let SOURCE_SYSTEM_KEY = rowText(Int64(UI_ROW_SOURCE_SYSTEM))
    static let SOURCE_APP_PREFIX = rowText(Int64(UI_ROW_SOURCE_APP_PREFIX))

    private static func rowText(_ row: Int64) -> String {
        var out = [UInt8](repeating: 0, count: Int(UI_WORD_MAX))
        let n = Int(ui_row_bytes(row, &out))
        return String(decoding: out[0..<n], as: UTF8.self)
    }

    /// Quitting during a call stops it first (and saves the transcript).
    static func quitWaits(runState: Int32, analysisWork: Bool, peerOn: Bool) -> Bool { ui_quit_waits(runState, analysisWork, peerOn) }

    // MARK: - The checklist «Перед звонком»

    /// Rows, in the order the sheet shows them.
    static let CKI_LISTENER: Int32 = UI_CKI_LISTENER          // «Meet слушает BlackHole»
    static let CKI_CALL_MIC: Int32 = UI_CKI_CALL_MIC          // «Микрофон в Meet включён» (a reminder)
    static let CKI_HEADPHONES: Int32 = UI_CKI_HEADPHONES
    static let CKI_MY_MIC: Int32 = UI_CKI_MY_MIC              // «Ваш микрофон для Ponte»
    static let CKI_EXTENSIONS: Int32 = UI_CKI_EXTENSIONS      // browser translators that replace the mic (a reminder)
    static let CKI_HOW_TO_TALK: Int32 = UI_CKI_HOW_TO_TALK
    static let CKI_COUNT: Int32 = UI_CKI_COUNT

    /// Marks: ✓ green, ⚠ amber, ✗ red, a reminder, unknown.
    static let CK_UNKNOWN: Int32 = UI_CK_UNKNOWN
    static let CK_OK: Int32 = UI_CK_OK
    static let CK_WARN: Int32 = UI_CK_WARN
    static let CK_BAD: Int32 = UI_CK_BAD
    static let CK_INFO: Int32 = UI_CK_INFO

    /// Who listens to BlackHole (the AudioRules.listen* codes).
    static let LISTEN_UNKNOWN: Int32 = UI_LISTEN_UNKNOWN
    static let LISTEN_OK: Int32 = UI_LISTEN_OK
    static let LISTEN_NOBODY: Int32 = UI_LISTEN_NOBODY
    static let LISTEN_REAL_MIC: Int32 = UI_LISTEN_REAL_MIC
    static let LISTEN_BOTH: Int32 = UI_LISTEN_BOTH
    static let LISTEN_NO_BLACKHOLE: Int32 = UI_LISTEN_NO_BLACKHOLE

    /// Ponte's microphone: from the settings, picked automatically, or the system default (none found).
    static let MICSRC_SAVED: Int32 = UI_MICSRC_SAVED
    static let MICSRC_AUTO: Int32 = UI_MICSRC_AUTO
    static let MICSRC_SYSTEM: Int32 = UI_MICSRC_SYSTEM

    static let CKO_LAUNCH: Int32 = UI_CKO_LAUNCH
    static let CKO_ASKED: Int32 = UI_CKO_ASKED
    static let DEFAULT_CHECKLIST_ON_LAUNCH = UI_DEFAULT_CHECKLIST_ON_LAUNCH != 0

    static let LB_NONE: Int32 = UI_LB_NONE
    static let LB_SHOW: Int32 = UI_LB_SHOW
    static let LB_CLEAR: Int32 = UI_LB_CLEAR

    static let MIGRATE_NONE: Int32 = UI_MIGRATE_NONE
    static let MIGRATE_CLEAR: Int32 = UI_MIGRATE_CLEAR
    static let MIGRATE_MARK: Int32 = UI_MIGRATE_MARK

    static func listenerMark(listenStatus: Int32) -> Int32 { ui_listener_mark(listenStatus) }

    static func checklistMark(item: Int32, listenStatus: Int32, headphonesLike: Bool, micSource: Int32) -> Int32 {
        ui_checklist_mark(item, listenStatus, headphonesLike, micSource)
    }

    static func micSource(hasSetting: Bool, found: Bool, hasAuto: Bool) -> Int32 { ui_mic_source(hasSetting, found, hasAuto) }

    static func checklistOpens(reason: Int32, showOnLaunch: Bool, wizardShown: Bool, testMode: Bool, autostart: Bool) -> Bool {
        ui_checklist_opens(reason, showOnLaunch, wizardShown, testMode, autostart)
    }

    static func checklistCanStart(runState: Int32) -> Bool { ui_checklist_can_start(runState) }

    static func pollReadsListeners(tick: Int64, sheetOpen: Bool, runState: Int32) -> Bool {
        ui_poll_reads_listeners(tick, sheetOpen, runState)
    }

    static func listenerStreak(mark: Int32) -> Bool { ui_listener_streak(mark) }

    /// The call's red banner when nobody (or the wrong microphone) feeds the call: LB_*.
    static func listenerBanner(runState: Int32, mark: Int32, msBad: Int64, shown: Bool, dismissed: Bool) -> Int32 {
        ui_listener_banner(runState, mark, msBad, shown, dismissed)
    }

    static func micMigration(migrated: Bool, hasSetting: Bool) -> Int32 { ui_mic_migration(migrated, hasSetting) }

    // MARK: Moved out of Swift 2026-10-15 (ui_rules, transcript_rules)

    static func listenerDismissed(dismissed: Bool, gone: Bool, closed: Bool, streak: Bool) -> Bool {
        ui_listener_dismissed(dismissed, gone, closed, streak)
    }
    static func hearPickClearsHeadphones(hasSaved: Bool) -> Bool { ui_hear_pick_clears_headphones(hasSaved) }
    static func packsBannerClears(shown: Bool, translatorsFailed: Int32) -> Bool { ui_packs_banner_clears(shown, translatorsFailed) }
    static func hearPickFailed(systemIsPicked: Bool) -> Bool { ui_hear_pick_failed(systemIsPicked) }
    static func listenerTickReadsDevices(sheetOpen: Bool) -> Bool { ui_listener_tick_reads_devices(sheetOpen) }
    static let PEERNOTE_NOT_RUNNING: Int32 = UI_PEERNOTE_NOT_RUNNING
    static let PEERNOTE_SPEAKERS: Int32 = UI_PEERNOTE_SPEAKERS
    static func peerNotes(peerOn: Bool, running: Bool, headphonesLike: Bool) -> Int32 { ui_peer_notes(peerOn, running, headphonesLike) }

    static let ATTEMPTS_MAX: Int32 = TR_ATTEMPTS_MAX
    static func transcriptStartedMs(callStartMs: Int64?, firstLineMs: Int64) -> Int64 {
        tr_started_ms(callStartMs != nil, callStartMs ?? 0, firstLineMs)
    }
    static func nextAttempt(_ attempt: Int32) -> Int32 { tr_next_attempt(attempt) }
    static func attemptAllowed(_ attempt: Int32) -> Bool { tr_attempt_allowed(attempt) }
}
