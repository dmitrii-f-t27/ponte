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

    static func cancelsSpeech(event: Int32, value: Bool) -> Bool { ln_cancels_speech(event, value) }

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
}
