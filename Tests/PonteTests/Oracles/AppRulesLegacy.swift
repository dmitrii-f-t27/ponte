// Test oracle, owned by the t27 agent. The Swift AppRules as it was before its bodies called the C generated from Specs/*.t27.
// Kept verbatim (only renamed) as the reference the differential tests compare the C-backed
// facade with, function by function, bit for bit.

// Every pure decision of Ponte's app layer, in one place.
//
// The decisions are specified in t27 (Specs/*.t27) and compiled to C. At integration
// the bodies below are replaced by calls into the generated C; until then, and
// afterwards as test oracles, these Swift versions define the behaviour.
//
// Rules for this file:
// - static functions only, deterministic, no clocks, no I/O, no SwiftUI/AppKit types;
// - inputs and outputs are Bool, Int32 codes, Int64 milliseconds, UInt64 bit sets,
//   Double levels, or [UInt8] byte strings (UTF-8);
// - a function that returns "next state + action" packs them as (next << 8) | action,
//   read back with stepState(_:) and stepAction(_:).
//
// Swift keeps: views and Russian texts, system calls, Unicode work (lowercasing,
// word boundaries for the glossary), concurrency (tasks, generations, locks).
// Device kinds and echo risk come from AudioRules (PonteAudio); the voice meter and
// phrase timing from the transcriber (SpeechRules): they are not repeated here.

import AVFoundation
import Speech

enum AppRulesLegacy {
    // MARK: - Packed steps

    static func pack(_ state: Int32, _ action: Int32) -> Int32 { (state << 8) | (action & 0xFF) }
    static func stepState(_ step: Int32) -> Int32 { step >> 8 }
    static func stepAction(_ step: Int32) -> Int32 { step & 0xFF }

    // MARK: - Capture modes

    static let MODE_CONTINUOUS: Int32 = 0       // «Авто»
    static let MODE_PUSH_TO_TALK: Int32 = 1

    // MARK: - Lane capture gate (is a transcriber session open?)

    static let GATE_STOPPED: Int32 = 0
    static let GATE_STARTING: Int32 = 1          // preparing models and the translator
    static let GATE_CLOSED: Int32 = 2            // running, audio ignored
    static let GATE_OPEN: Int32 = 3              // running, audio goes to a transcriber session

    static let GEV_START: Int32 = 1
    static let GEV_STARTED: Int32 = 2
    static let GEV_START_FAILED: Int32 = 3
    static let GEV_STOP: Int32 = 4
    static let GEV_KEY: Int32 = 5                // push-to-talk key changed (keyHeld is the new value)
    static let GEV_PAUSE: Int32 = 6              // pause changed (paused is the new value)
    static let GEV_MODE: Int32 = 7               // mode changed (mode is the new value)

    static let GACT_NONE: Int32 = 0
    static let GACT_OPEN_SEGMENT: Int32 = 1
    static let GACT_CLOSE_SEGMENT: Int32 = 2     // flush the session: its last phrase becomes final

    /// Audio is transcribed only while running, not paused, and in «Авто» or with the key held.
    static func gateWantsOpen(mode: Int32, keyHeld: Bool, paused: Bool) -> Bool {
        !paused && (mode == MODE_CONTINUOUS || keyHeld)
    }

    /// Gate state machine. `mode`, `keyHeld`, `paused` are the values after the event.
    static func gateStep(state: Int32, event: Int32, mode: Int32, keyHeld: Bool, paused: Bool) -> Int32 {
        let want = gateWantsOpen(mode: mode, keyHeld: keyHeld, paused: paused)
        switch (state, event) {
        case (GATE_STOPPED, GEV_START):
            return pack(GATE_STARTING, GACT_NONE)
        case (GATE_STARTING, GEV_STARTED):
            return want ? pack(GATE_OPEN, GACT_OPEN_SEGMENT) : pack(GATE_CLOSED, GACT_NONE)
        case (GATE_STARTING, GEV_START_FAILED), (GATE_STARTING, GEV_STOP):
            return pack(GATE_STOPPED, GACT_NONE)
        case (GATE_CLOSED, GEV_STOP):
            return pack(GATE_STOPPED, GACT_NONE)
        case (GATE_OPEN, GEV_STOP):
            return pack(GATE_STOPPED, GACT_CLOSE_SEGMENT)
        case (GATE_CLOSED, GEV_KEY), (GATE_CLOSED, GEV_PAUSE), (GATE_CLOSED, GEV_MODE):
            return want ? pack(GATE_OPEN, GACT_OPEN_SEGMENT) : pack(GATE_CLOSED, GACT_NONE)
        case (GATE_OPEN, GEV_KEY), (GATE_OPEN, GEV_PAUSE), (GATE_OPEN, GEV_MODE):
            return want ? pack(GATE_OPEN, GACT_NONE) : pack(GATE_CLOSED, GACT_CLOSE_SEGMENT)
        default:
            return pack(state, GACT_NONE)
        }
    }

    // MARK: - Phrase pipeline (one final phrase from transcript to speech)

    static let PH_LISTENING: Int32 = 0           // volatile text only
    static let PH_TRANSLATING: Int32 = 1
    static let PH_SYNTH_QUEUED: Int32 = 2        // waiting for / in speech synthesis
    static let PH_PLAY_QUEUED: Int32 = 3
    static let PH_PLAYING: Int32 = 4
    static let PH_SHOWN: Int32 = 5               // final: text on screen, not spoken
    static let PH_SPOKEN: Int32 = 6              // final: text on screen and played
    static let PH_DROPPED: Int32 = 7             // final: nothing (empty text or speech cancelled)

    static let PEV_PARTIAL: Int32 = 1
    static let PEV_FINAL: Int32 = 2
    static let PEV_TRANSLATED: Int32 = 3
    static let PEV_TRANSLATE_FAILED: Int32 = 4
    static let PEV_SYNTH_DEQUEUED: Int32 = 5     // the synth worker picked the phrase up
    static let PEV_SYNTHESIZED: Int32 = 6
    static let PEV_SYNTH_FAILED: Int32 = 7
    static let PEV_PLAY_DEQUEUED: Int32 = 8      // the play worker picked the audio up
    static let PEV_PLAYED: Int32 = 9

    static let PACT_NONE: Int32 = 0
    static let PACT_SHOW_PARTIAL: Int32 = 1
    static let PACT_TRANSLATE: Int32 = 2         // show the original, start translating
    static let PACT_SHOW_ONLY: Int32 = 3         // show the result, do not speak
    static let PACT_SYNTHESIZE: Int32 = 4        // show the translation, queue it for speech
    static let PACT_RUN_SYNTH: Int32 = 5         // synthesize now
    static let PACT_ENQUEUE_PLAY: Int32 = 6
    static let PACT_PLAY: Int32 = 7              // play now
    static let PACT_DROP: Int32 = 8
    static let PACT_FINISH: Int32 = 9            // playback done

    // Flags for phraseStep (bit set).
    static let PF_EMPTY_TEXT: Int32 = 1          // FINAL: phrase empty; TRANSLATED: translation empty
    static let PF_SPEAK_REQUESTED: Int32 = 2     // decided when the phrase became final
    static let PF_GENERATION_CURRENT: Int32 = 4  // no pause/stop/voice-off since the phrase was queued
    static let PF_SPEECH_ENABLED: Int32 = 8      // automatic speech is on for this lane now
    static let PF_PAUSED: Int32 = 16
    static let PF_HAS_SYNTH: Int32 = 32
    static let PF_HAS_PLAYER: Int32 = 64
    static let PF_HAS_AUDIO: Int32 = 128         // synthesis produced at least one buffer

    static func phraseStep(stage: Int32, event: Int32, flags: Int32) -> Int32 {
        func has(_ flag: Int32) -> Bool { flags & flag != 0 }
        switch (stage, event) {
        case (PH_LISTENING, PEV_PARTIAL):
            return pack(PH_LISTENING, PACT_SHOW_PARTIAL)
        case (PH_LISTENING, PEV_FINAL):
            return has(PF_EMPTY_TEXT) ? pack(PH_DROPPED, PACT_DROP) : pack(PH_TRANSLATING, PACT_TRANSLATE)
        case (PH_TRANSLATING, PEV_TRANSLATED):
            let speak = !has(PF_EMPTY_TEXT) && has(PF_SPEAK_REQUESTED) && has(PF_GENERATION_CURRENT)
                && has(PF_SPEECH_ENABLED) && !has(PF_PAUSED) && has(PF_HAS_SYNTH) && has(PF_HAS_PLAYER)
            return speak ? pack(PH_SYNTH_QUEUED, PACT_SYNTHESIZE) : pack(PH_SHOWN, PACT_SHOW_ONLY)
        case (PH_TRANSLATING, PEV_TRANSLATE_FAILED):
            return pack(PH_SHOWN, PACT_SHOW_ONLY)
        case (PH_SYNTH_QUEUED, PEV_SYNTH_DEQUEUED):
            return has(PF_GENERATION_CURRENT) && has(PF_HAS_SYNTH)
                ? pack(PH_SYNTH_QUEUED, PACT_RUN_SYNTH) : pack(PH_DROPPED, PACT_DROP)
        case (PH_SYNTH_QUEUED, PEV_SYNTHESIZED):
            return has(PF_GENERATION_CURRENT) && has(PF_HAS_AUDIO)
                ? pack(PH_PLAY_QUEUED, PACT_ENQUEUE_PLAY) : pack(PH_DROPPED, PACT_DROP)
        case (PH_SYNTH_QUEUED, PEV_SYNTH_FAILED):
            return pack(PH_DROPPED, PACT_DROP)
        case (PH_PLAY_QUEUED, PEV_PLAY_DEQUEUED):
            return has(PF_GENERATION_CURRENT) && has(PF_HAS_PLAYER) && has(PF_HAS_AUDIO)
                ? pack(PH_PLAYING, PACT_PLAY) : pack(PH_DROPPED, PACT_DROP)
        case (PH_PLAYING, PEV_PLAYED):
            return pack(PH_SPOKEN, PACT_FINISH)
        default:
            return pack(stage, PACT_NONE)
        }
    }

    /// Recorded when a phrase becomes final (PF_SPEAK_REQUESTED).
    static func speakRequested(speechEnabled: Bool, paused: Bool) -> Bool {
        speechEnabled && !paused
    }

    // MARK: - Pause, voice toggle, stop: does queued speech die?

    static let SCE_PAUSE: Int32 = 1              // value = paused (new)
    static let SCE_VOICE: Int32 = 2              // value = automatic speech enabled (new)
    static let SCE_STOP: Int32 = 3

    static func cancelsSpeech(event: Int32, value: Bool) -> Bool {
        switch event {
        case SCE_PAUSE: return value
        case SCE_VOICE: return !value
        case SCE_STOP: return true
        default: return false
        }
    }

    // MARK: - «Повторить» / «Сказать заново»

    static let RPL_NONE: Int32 = 0
    static let RPL_AUDIO: Int32 = 1              // play the cached audio of the last phrase
    static let RPL_SYNTH: Int32 = 2              // synthesize the last translation first

    /// Honoured even when paused or with automatic speech off: the user asked explicitly.
    static func replayAction(hasCachedAudio: Bool, hasLastTranslation: Bool, hasPlayer: Bool) -> Int32 {
        guard hasPlayer else { return RPL_NONE }
        if hasCachedAudio { return RPL_AUDIO }
        if hasLastTranslation { return RPL_SYNTH }
        return RPL_NONE
    }

    // MARK: - Speech rate by queue length

    /// `waiting` = phrases of this lane queued for speech ahead of this one.
    /// 0 → 100 %, 1 → 110 %, 2 → 120 %, 3 or more → 130 %.
    static func speechRatePercent(waiting: Int32) -> Int32 {
        if waiting <= 0 { return 100 }
        return 100 + 10 * min(waiting, 3)
    }

    // MARK: - Echo guard (Mac speakers instead of headphones)

    static let ECHO_TAIL_MS: Int64 = 700

    /// The mic is ignored while Ponte's Russian voice plays through the Mac's speakers
    /// and for ECHO_TAIL_MS after it; otherwise the outgoing lane would translate it back.
    /// `msSinceSpeech` < 0 means "never spoke".
    static func echoGuardBlocksMic(speakerOutput: Bool, incomingSpeaking: Bool, msSinceSpeech: Int64) -> Bool {
        guard speakerOutput else { return false }
        if incomingSpeaking { return true }
        return msSinceSpeech >= 0 && msSinceSpeech < ECHO_TAIL_MS
    }

    /// The echo guard is armed only when the owner listens on a loudspeaker
    /// (AudioRules.echoRisk == echoSpeaker) and the outgoing lane hears a live microphone
    /// (a test file cannot pick up the speakers).
    static func echoGuardApplies(speakerOutput: Bool, micIsLive: Bool) -> Bool {
        speakerOutput && micIsLive
    }

    // MARK: - Phrase timing

    static let END_NOW: Int32 = 0
    // 1 was END_LAST_VOICE (the lane's own voice meter, replaced by the transcriber's timing).
    static let END_LAST_PARTIAL: Int32 = 2
    static let END_TRANSCRIBER: Int32 = 3

    /// Which moment counts as "the speaker finished this phrase" when its final arrives:
    /// the transcriber's own timing (Transcriber.timing(for:), the wall clock time when the
    /// end of the voice reached it) if known; else the last volatile update of the phrase;
    /// else now. Arguments are milliseconds before now; negative means "unknown".
    static func phraseEndChoice(msSinceTimedEnd: Int64, msSincePartial: Int64) -> Int32 {
        if msSinceTimedEnd >= 0 { return END_TRANSCRIBER }
        if msSincePartial >= 0 { return END_LAST_PARTIAL }
        return END_NOW
    }

    static func latencyMs(endMs: Int64, readyMs: Int64) -> Int64 { max(0, readyMs - endMs) }

    /// Phrases of context passed to the translator, oldest first.
    static let CONTEXT_PHRASES: Int32 = 4

    /// How many of the oldest remembered phrases to forget after adding one.
    static func contextOverflow(count: Int32) -> Int32 { max(0, count - CONTEXT_PHRASES) }

    // MARK: - Run state, start, stop

    static let RUN_IDLE: Int32 = 0
    static let RUN_STARTING: Int32 = 1
    static let RUN_RUNNING: Int32 = 2
    static let RUN_STOPPING: Int32 = 3

    static let TOGGLE_NONE: Int32 = 0
    static let TOGGLE_START: Int32 = 1
    static let TOGGLE_STOP: Int32 = 2

    static func toggleRun(runState: Int32) -> Int32 {
        switch runState {
        case RUN_IDLE: return TOGGLE_START
        case RUN_RUNNING: return TOGGLE_STOP
        default: return TOGGLE_NONE
        }
    }

    /// Ponte runs if at least one lane started.
    static func runStateAfterStart(lanesStarted: Int32) -> Int32 {
        lanesStarted > 0 ? RUN_RUNNING : RUN_IDLE
    }

    static let BAN_NONE: Int32 = 0
    static let BAN_FAILED_PACKS: Int32 = 1       // error + «Открыть мастер» on the packs step
    static let BAN_FAILED_OTHER: Int32 = 2       // error + «Открыть мастер» on permissions
    static let BAN_NO_BLACKHOLE: Int32 = 3       // warning + «Как установить»
    static let BAN_SPEAKERS: Int32 = 4           // warning: put on headphones

    static func startBanner(lanesFailed: Int32, packsMissing: Bool, hasBlackHole: Bool, speakerOutput: Bool) -> Int32 {
        if lanesFailed > 0 { return packsMissing ? BAN_FAILED_PACKS : BAN_FAILED_OTHER }
        if !hasBlackHole { return BAN_NO_BLACKHOLE }
        if speakerOutput { return BAN_SPEAKERS }
        return BAN_NONE
    }

    static let BAN_NO_PACKS: Int32 = 5           // lanes listen, translation packs missing: error + packs step
    static let BAN_NO_TRANSLATOR: Int32 = 6      // lanes listen, translator failed otherwise: error

    /// Banner after «Старт» when a lane can run without its translator (recognition only).
    /// `translatorsFailed` = started lanes whose translator could not be prepared;
    /// `packsMissing` = one of the failures (lane or translator) was a missing language pack.
    /// A failed lane wins; then a failed translator; then startBanner's warnings.
    static func startBannerAfterStart(lanesFailed: Int32, translatorsFailed: Int32, packsMissing: Bool,
                                      hasBlackHole: Bool, speakerOutput: Bool) -> Int32 {
        if lanesFailed == 0 && translatorsFailed > 0 { return packsMissing ? BAN_NO_PACKS : BAN_NO_TRANSLATOR }
        return startBanner(lanesFailed: lanesFailed, packsMissing: packsMissing,
                           hasBlackHole: hasBlackHole, speakerOutput: speakerOutput)
    }

    // MARK: - Translator that could not be prepared at «Старт»

    /// A lane whose translator failed to prepare still transcribes and shows the originals.
    /// Before each phrase it tries to prepare again (the owner may have downloaded the packs
    /// meanwhile), at most once per PREPARE_RETRY_MS.
    static let PREPARE_RETRY_MS: Int64 = 5_000

    /// `msSinceAttempt` < 0 = never tried.
    static func retryTranslatorPrepare(prepared: Bool, msSinceAttempt: Int64) -> Bool {
        !prepared && (msSinceAttempt < 0 || msSinceAttempt >= PREPARE_RETRY_MS)
    }

    static func autosaveOnStop(lines: Int32) -> Bool { lines > 0 }

    // MARK: - Which controls are enabled

    static let BTN_START_STOP: Int32 = 1
    static let BTN_SOURCE: Int32 = 2
    static let BTN_REPLAY_INCOMING: Int32 = 3
    static let BTN_REPLAY_OUTGOING: Int32 = 4
    static let BTN_SAVE_TRANSCRIPT: Int32 = 5
    static let BTN_PAUSE_VOICE: Int32 = 6
    static let BTN_MODE: Int32 = 7
    static let BTN_TALK_PAD: Int32 = 8
    static let BTN_TEST_CALL: Int32 = 9
    static let BTN_TEST_HEADPHONES: Int32 = 10
    static let BTN_VOICE_TOGGLE: Int32 = 11

    static func buttonEnabled(button: Int32, runState: Int32, incomingLines: Int32, outgoingLines: Int32,
                              hasBlackHole: Bool, busy: Bool) -> Bool {
        let running = runState == RUN_RUNNING
        switch button {
        case BTN_START_STOP: return runState == RUN_IDLE || running
        case BTN_SOURCE: return runState == RUN_IDLE
        case BTN_REPLAY_INCOMING: return running && incomingLines > 0
        case BTN_REPLAY_OUTGOING: return running && outgoingLines > 0
        case BTN_SAVE_TRANSCRIPT: return incomingLines + outgoingLines > 0
        case BTN_PAUSE_VOICE, BTN_MODE, BTN_VOICE_TOGGLE: return true
        case BTN_TALK_PAD: return running
        case BTN_TEST_CALL: return hasBlackHole && !busy
        case BTN_TEST_HEADPHONES: return !busy
        default: return false
        }
    }

    // MARK: - Status lights and latency colour

    static let LIGHT_UNKNOWN: Int32 = 0
    static let LIGHT_OK: Int32 = 1
    static let LIGHT_BAD: Int32 = 2
    static let LIGHT_BUSY: Int32 = 3
    static let LIGHT_WARN: Int32 = 4

    static let AUDIO_FRESH_MS: Int64 = 2_000     // a buffer this recent means audio flows
    static let AUDIO_WARMUP_MS: Int64 = 4_000    // grace period after Старт

    /// Source audio / microphone light. `msSinceBuffer` < 0 = no buffer yet.
    static func audioLight(runState: Int32, laneActive: Bool, msSinceStart: Int64, msSinceBuffer: Int64) -> Int32 {
        if runState == RUN_STARTING { return LIGHT_BUSY }
        guard runState == RUN_RUNNING else { return LIGHT_UNKNOWN }
        guard laneActive else { return LIGHT_BAD }
        if msSinceBuffer >= 0 && msSinceBuffer < AUDIO_FRESH_MS { return LIGHT_OK }
        if msSinceStart < AUDIO_WARMUP_MS { return LIGHT_BUSY }
        return LIGHT_BAD
    }

    /// Process tap status (AppAudioTapSource.Status), as codes.
    static let TAP_NONE: Int32 = 0               // the source is not a process tap (test file)
    static let TAP_WAITING: Int32 = 1            // the chosen app has no audio process yet
    static let TAP_CAPTURING: Int32 = 2
    static let TAP_FAILED: Int32 = 3
    static let TAP_IDLE: Int32 = 4               // not started or stopped

    /// Only exact zeros this long after «Старт»: the System Audio Recording permission is
    /// probably missing (a process tap without it delivers digital silence).
    static let SILENCE_SUSPECT_MS: Int64 = 8_000

    /// «Звук источника» light. Starts from audioLight (buffers flow?), then the tap status:
    /// failed → BAD; waiting for the app → BUSY; capturing but never a non-zero sample for
    /// SILENCE_SUSPECT_MS → WARN. `msSinceSignal` < 0 = no non-zero sample since «Старт».
    static func sourceLight(runState: Int32, laneActive: Bool, tapStatus: Int32, msSinceStart: Int64,
                            msSinceBuffer: Int64, msSinceSignal: Int64) -> Int32 {
        let base = audioLight(runState: runState, laneActive: laneActive, msSinceStart: msSinceStart,
                              msSinceBuffer: msSinceBuffer)
        guard runState == RUN_RUNNING, laneActive else { return base }
        if tapStatus == TAP_FAILED { return LIGHT_BAD }
        if tapStatus == TAP_WAITING { return LIGHT_BUSY }
        if base == LIGHT_OK && tapStatus == TAP_CAPTURING && msSinceSignal < 0 && msSinceStart >= SILENCE_SUSPECT_MS {
            return LIGHT_WARN
        }
        return base
    }

    /// Microphone status (MicSource.Status), as codes (2026-10-13, after the live crash: a device change
    /// stops the microphone and it is rebuilt with a backoff).
    static let MIC_NONE: Int32 = 0               // the outgoing source is not a microphone (test file)
    static let MIC_CAPTURING: Int32 = 1
    static let MIC_RESTARTING: Int32 = 2
    static let MIC_FAILED: Int32 = 3
    static let MIC_IDLE: Int32 = 4

    /// «Микрофон» light (2026-10-13: was audioLight, which turned BAD in push-to-talk with the key up).
    /// A failed rebuild is BAD and a rebuild in progress BUSY, whatever the gate. The outgoing lane asks
    /// for audio only while its capture gate is open; with it closed (key up, «Пауза голоса в звонок») a
    /// started microphone is OK. With it open: audioLight, the warm-up from the later of «Старт» and the
    /// gate opening. `msSinceListen` < 0 = the gate is closed.
    static func micLight(runState: Int32, laneActive: Bool, micStatus: Int32, msSinceStart: Int64, msSinceListen: Int64,
                         msSinceBuffer: Int64) -> Int32 {
        guard runState == RUN_RUNNING, laneActive else {
            return audioLight(runState: runState, laneActive: laneActive, msSinceStart: msSinceStart, msSinceBuffer: msSinceBuffer)
        }
        if micStatus == MIC_FAILED { return LIGHT_BAD }
        if micStatus == MIC_RESTARTING { return LIGHT_BUSY }
        guard msSinceListen >= 0 else { return LIGHT_OK }
        return audioLight(runState: runState, laneActive: laneActive, msSinceStart: min(msSinceStart, msSinceListen),
                          msSinceBuffer: msSinceBuffer)
    }

    /// Setup wizard «Запись звука программ»: listen to all audio except Ponte for CAPTURE_CHECK_MS.
    static let CAPTURE_CHECK_MS: Int64 = 3_000

    /// Result of the wizard check: tap failed or no audio at all → BAD; only exact zeros → WARN
    /// (nothing played, or the permission is missing); any non-zero sample → OK.
    static func captureCheckLight(tapStatus: Int32, framesSeen: Bool, signalSeen: Bool) -> Int32 {
        if tapStatus == TAP_FAILED || !framesSeen { return LIGHT_BAD }
        return signalSeen ? LIGHT_OK : LIGHT_WARN
    }

    static func blackHoleLight(found: Bool) -> Int32 { found ? LIGHT_OK : LIGHT_BAD }

    /// Models (transcribers + translator) light, from the last start attempt.
    static func modelsLight(runState: Int32, everStarted: Bool, lanesStarted: Int32, lanesFailed: Int32) -> Int32 {
        if runState == RUN_STARTING { return LIGHT_BUSY }
        guard everStarted else { return LIGHT_UNKNOWN }
        if lanesFailed > 0 { return LIGHT_BAD }
        return lanesStarted > 0 ? LIGHT_OK : LIGHT_UNKNOWN
    }

    static let LAT_NONE: Int32 = 0
    static let LAT_GOOD: Int32 = 1               // ≤ 2 s: the target from SPEC.md
    static let LAT_SLOW: Int32 = 2               // ≤ 4 s
    static let LAT_BAD: Int32 = 3
    static let LAT_GOOD_MS: Int64 = 2_000
    static let LAT_SLOW_MS: Int64 = 4_000

    /// `ms` < 0 = no phrase yet.
    static func latencyColor(ms: Int64) -> Int32 {
        if ms < 0 { return LAT_NONE }
        if ms <= LAT_GOOD_MS { return LAT_GOOD }
        if ms <= LAT_SLOW_MS { return LAT_SLOW }
        return LAT_BAD
    }

    // MARK: - Source menu

    static let SRC_CALLS: Int32 = 0              // «Звонилки»
    static let SRC_PLAYING: Int32 = 1            // «Сейчас звучат»
    static let SRC_OTHER: Int32 = 2              // «Другие программы»

    static func sourceSection(isKnownCallApp: Bool, isPlayingAudio: Bool) -> Int32 {
        if isKnownCallApp { return SRC_CALLS }
        return isPlayingAudio ? SRC_PLAYING : SRC_OTHER
    }

    // MARK: - Translator

    static let TR_APPLE: Int32 = 0
    static let TR_CLAUDE: Int32 = 1

    static func translatorChoice(preferred: Int32, claudeAvailable: Bool) -> Int32 {
        preferred == TR_CLAUDE && claudeAvailable ? TR_CLAUDE : TR_APPLE
    }

    // MARK: - Push-to-talk

    static let PTT_RIGHT_OPTION: Int32 = 0
    static let PTT_RIGHT_COMMAND: Int32 = 1
    static let PTT_RIGHT_SHIFT: Int32 = 2
    static let PTT_RIGHT_CONTROL: Int32 = 3
    static let PTT_FN: Int32 = 4

    /// `flags` = NSEvent.modifierFlags.rawValue. Right-hand keys use the device-dependent
    /// bits from IOLLEvent.h (NX_DEVICER*KEYMASK); Fn uses NSEventModifierFlagFunction.
    static func pttKeyDown(key: Int32, flags: UInt64) -> Bool {
        switch key {
        case PTT_RIGHT_OPTION: return flags & 0x40 != 0
        case PTT_RIGHT_COMMAND: return flags & 0x10 != 0
        case PTT_RIGHT_SHIFT: return flags & 0x04 != 0
        case PTT_RIGHT_CONTROL: return flags & 0x2000 != 0
        case PTT_FN: return flags & 0x80_0000 != 0
        default: return false
        }
    }

    static let PTT_SCOPE_NONE: Int32 = 0
    static let PTT_SCOPE_WINDOW: Int32 = 1       // only while a Ponte window is active
    static let PTT_SCOPE_GLOBAL: Int32 = 2       // everywhere (needs Accessibility)

    static func pttScope(running: Bool, mode: Int32, accessibilityGranted: Bool) -> Int32 {
        guard running, mode == MODE_PUSH_TO_TALK else { return PTT_SCOPE_NONE }
        return accessibilityGranted ? PTT_SCOPE_GLOBAL : PTT_SCOPE_WINDOW
    }

    // MARK: - Setup wizard

    static let WZ_PERMISSIONS: Int32 = 0
    static let WZ_MODELS: Int32 = 1
    static let WZ_PACKS: Int32 = 2
    static let WZ_BLACKHOLE: Int32 = 3
    static let WZ_CALL_APPS: Int32 = 4
    static let WZ_DONE: Int32 = 5
    static let WZ_NONE: Int32 = -1

    static func wizardNext(step: Int32) -> Int32 {
        step >= WZ_PERMISSIONS && step < WZ_DONE ? step + 1 : WZ_NONE
    }

    static func wizardPrevious(step: Int32) -> Int32 {
        step > WZ_PERMISSIONS && step <= WZ_DONE ? step - 1 : WZ_NONE
    }

    static let MARK_NONE: Int32 = 0
    static let MARK_DONE: Int32 = 1
    static let MARK_WARN: Int32 = 2

    static func wizardStepMark(step: Int32, micGranted: Bool, speechGranted: Bool, modelsReady: Int32,
                               packsReady: Int32, blackHoleFound: Bool, testPhraseOK: Bool) -> Int32 {
        switch step {
        case WZ_PERMISSIONS: return micGranted && speechGranted ? MARK_DONE : MARK_NONE
        case WZ_MODELS: return modelsReady >= 2 ? MARK_DONE : MARK_NONE
        case WZ_PACKS: return packsReady >= 2 ? MARK_DONE : MARK_NONE
        case WZ_BLACKHOLE: return blackHoleFound ? MARK_DONE : MARK_WARN
        case WZ_CALL_APPS: return testPhraseOK ? MARK_DONE : MARK_NONE
        default: return MARK_NONE
        }
    }

    /// `forcedStep` ≥ 0 when the wizard was asked for explicitly.
    static func wizardShowOnLaunch(setupCompleted: Bool, forcedStep: Int32) -> Bool {
        forcedStep >= 0 || !setupCompleted
    }

    /// Test mode (launch arguments with files) counts as set up: the wizard opens only when forced.
    static func wizardShowOnLaunchInMode(setupCompleted: Bool, forcedStep: Int32, testMode: Bool) -> Bool {
        wizardShowOnLaunch(setupCompleted: setupCompleted || testMode, forcedStep: forcedStep)
    }

    /// «Закрыть» keeps the old flag; «Начать работу» (finished) completes setup.
    static func wizardCompletedAfterClose(wasCompleted: Bool, finished: Bool) -> Bool {
        wasCompleted || finished
    }

    // MARK: - Text size

    static let FONT_DEFAULT_PT: Int32 = 24
    static let FONT_MIN_PT: Int32 = 16
    static let FONT_MAX_PT: Int32 = 40

    /// Stored setting → translation font size: unset or below 14 → default, else clamped 16…40.
    static func translationFontSize(stored: Int32) -> Int32 {
        if stored < 14 { return FONT_DEFAULT_PT }
        return min(FONT_MAX_PT, max(FONT_MIN_PT, stored))
    }

    // MARK: - Subtitle overlay

    static let OVERLAY_MAX_LINES: Int32 = 2
    static let OVERLAY_PADDING_PT: Int32 = 32

    /// Last N incoming translations to show; 1 when the panel is too short for 2.
    static func overlayLineCount(available: Int32, panelHeight: Int32, fontSize: Int32) -> Int32 {
        guard available > 0 else { return 0 }
        let lineHeight = fontSize * 13 / 10 + 8
        let fits: Int32 = panelHeight - OVERLAY_PADDING_PT >= OVERLAY_MAX_LINES * lineHeight ? OVERLAY_MAX_LINES : 1
        return min(available, fits)
    }

    // MARK: - Transcript file

    /// "YYYY-MM-DD-HHMM.md"; attempt ≥ 2 adds "-N" so an existing file is never overwritten.
    static func transcriptFileName(year: Int32, month: Int32, day: Int32, hour: Int32, minute: Int32,
                                   attempt: Int32) -> [UInt8] {
        var out: [UInt8] = []
        appendDigits(&out, year, width: 4)
        out.append(0x2D)
        appendDigits(&out, month, width: 2)
        out.append(0x2D)
        appendDigits(&out, day, width: 2)
        out.append(0x2D)
        appendDigits(&out, hour, width: 2)
        appendDigits(&out, minute, width: 2)
        if attempt >= 2 {
            out.append(0x2D)
            appendDigits(&out, attempt, width: 1)
        }
        out.append(contentsOf: Array(".md".utf8))
        return out
    }

    /// Callers cut phrases to this many bytes (at a character boundary) before escaping,
    /// so the escaped text always fits a 4096-byte buffer.
    static let MD_ESCAPE_MAX_INPUT: Int32 = 2_048

    /// Escapes Markdown in transcript text, byte by byte (UTF-8 passes through):
    /// - anywhere: \ ` * _ [ ] < > # | ~ & get a backslash;
    /// - at the start of a line (after spaces): - + = get a backslash, and in a leading
    ///   digit run the following . or ) gets one ("1." would start a list);
    /// - CR is dropped; LF is kept and starts a new line.
    static func markdownEscape(_ input: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(input.count * 2)
        let lineStart = 0, digits = 1, text = 2
        var state = lineStart
        for byte in input {
            if byte == 0x0D { continue }
            if byte == 0x0A {
                out.append(byte)
                state = lineStart
                continue
            }
            if state == lineStart {
                if byte == 0x20 { out.append(byte); continue }
                if byte == 0x2D || byte == 0x2B || byte == 0x3D {          // - + =
                    out.append(0x5C)
                    out.append(byte)
                    state = text
                    continue
                }
                if byte >= 0x30 && byte <= 0x39 { out.append(byte); state = digits; continue }
            } else if state == digits {
                if byte >= 0x30 && byte <= 0x39 { out.append(byte); continue }
                if byte == 0x2E || byte == 0x29 {                         // . )
                    out.append(0x5C)
                    out.append(byte)
                    state = text
                    continue
                }
            }
            state = text
            if isMarkdownSpecial(byte) { out.append(0x5C) }
            out.append(byte)
        }
        return out
    }

    static func isMarkdownSpecial(_ byte: UInt8) -> Bool {
        switch byte {
        case 0x5C, 0x60, 0x2A, 0x5F, 0x5B, 0x5D, 0x3C, 0x3E, 0x23, 0x7C, 0x7E, 0x26: return true
        default: return false
        }
    }

    // MARK: - Byte helpers (t27 has its own)

    private static func appendDigits(_ out: inout [UInt8], _ value: Int32, width: Int) {
        var digits: [UInt8] = []
        var v = max(0, value)
        repeat {
            digits.append(UInt8(0x30 + v % 10))
            v /= 10
        } while v > 0
        while digits.count < width { digits.append(0x30) }
        out.append(contentsOf: digits.reversed())
    }
}

// MARK: - Decisions extracted unchanged from the app before they moved to t27 (2026-10-11)
// Each body is the old expression at its call site, rewritten over codes where the call site used an enum.

extension AppRulesLegacy {
    // TranscriptExporter
    static let FIRST_ATTEMPT: Int32 = 1
    /// escaped(): `if bytes + size > MD_ESCAPE_MAX_INPUT { break }`.
    static func fitsEscapeInput(bytes: Int, charBytes: Int) -> Bool { !(bytes + charBytes > Int(MD_ESCAPE_MAX_INPUT)) }
    /// markdown(): `lines.sorted(by: { $0.at < $1.at })`, a stable sort.
    static func sortedIndices(_ at: [Double]) -> [Int] {
        at.enumerated().map { (index: $0.offset, at: $0.element) }.sorted { $0.at < $1.at }.map(\.index)
    }

    // TranslationLane, AppModel (Direction: 0 incoming, 1 outgoing)
    static let DIR_INCOMING: Int32 = 0
    static let DIR_OUTGOING: Int32 = 1
    /// AppModel.init: `?? .continuous`, `?? .rightOption`.
    static let DEFAULT_MODE: Int32 = MODE_CONTINUOUS
    static let DEFAULT_PTT_KEY: Int32 = PTT_RIGHT_OPTION
    /// stop(): `waitForConsumer(timeout: 3)`, `Task.sleep(for: .seconds(8))`.
    static let STOP_SEGMENT_WAIT_MS: Int64 = 3_000
    static let STOP_TRANSLATE_WAIT_MS: Int64 = 8_000
    static func millis(_ seconds: Double) -> Int64 { Int64((seconds * 1000).rounded()) }
    /// EchoGuard.setSpeaking: `if speaking || on`.
    static func echoMarksTime(wasSpeaking: Bool, nowSpeaking: Bool) -> Bool { wasSpeaking || nowSpeaking }
    /// isRunning, start().
    static func gateRunning(state: Int32) -> Bool { state == GATE_OPEN || state == GATE_CLOSED }
    static func gateCanStart(state: Int32) -> Bool { state == GATE_STOPPED }
    /// phraseEnd(): `timing.map { max(0, ms) } ?? -1`, `lastPartialAt.map { max(-1, ms) } ?? -1`.
    static func phraseEndChoiceKnown(msSinceTimedEnd: Int64?, msSincePartial: Int64?) -> Int32 {
        phraseEndChoice(msSinceTimedEnd: msSinceTimedEnd.map { max(0, $0) } ?? -1,
                        msSincePartial: msSincePartial.map { max(-1, $0) } ?? -1)
    }
    /// flags(generation:extra:) and the extras at its call sites.
    static func phraseFlags(emptyText: Bool, speakRequested: Bool, generationCurrent: Bool, speechEnabled: Bool,
                            paused: Bool, hasSynth: Bool, hasPlayer: Bool, hasAudio: Bool) -> Int32 {
        var f: Int32 = emptyText ? PF_EMPTY_TEXT : 0
        if speakRequested { f |= PF_SPEAK_REQUESTED }
        if hasAudio { f |= PF_HAS_AUDIO }
        if generationCurrent { f |= PF_GENERATION_CURRENT }
        if speechEnabled { f |= PF_SPEECH_ENABLED }
        if paused { f |= PF_PAUSED }
        if hasSynth { f |= PF_HAS_SYNTH }
        if hasPlayer { f |= PF_HAS_PLAYER }
        return f
    }
    static func needsSpeechWorkers(hasSynth: Bool, hasPlayer: Bool) -> Bool { hasSynth || hasPlayer }
    /// endOfSpeech: `if counted { speechBacklog = max(0, speechBacklog - 1) }`.
    static func backlogAfterSpeech(_ backlog: Int32, counted: Bool) -> Int32 { counted ? max(0, backlog - 1) : backlog }
    /// synthesize: `request.counted ? speechBacklog - 1 : speechBacklog`.
    static func speechWaiting(backlog: Int32, counted: Bool) -> Int32 { counted ? backlog - 1 : backlog }
    /// translate: `if !(error is CancellationError)`.
    static func reportsTranslationError(cancelled: Bool) -> Bool { !cancelled }
    /// play: `stepAction(finish) == PACT_FINISH, request.generation == speechGeneration`.
    static func playEndReports(action: Int32, generationCurrent: Bool) -> Bool { action == PACT_FINISH && generationCurrent }
    /// AudioIntake.handle: `guard let segment`, `if let echo, echo.blocksMic(at: now) { return }`.
    static func intakeForwards(hasSegment: Bool, echoBlocks: Bool) -> Bool { hasSegment && !echoBlocks }
    /// Segment.append: 0 drop, 1 forward, 2 buffer; markClosed: 0 nothing, 1 finish now, 2 mark only.
    static func segmentAppend(started: Bool, closed: Bool) -> Int32 { closed ? 0 : (started ? 1 : 2) }
    static func segmentClose(started: Bool, closed: Bool) -> Int32 { closed ? 0 : (started ? 1 : 2) }
    /// AppModel: `if let url = launch.incomingFile` (0 live, 1 file); `launch.outgoingFile == nil`.
    static func sourceKind(hasTestFile: Bool) -> Int32 { hasTestFile ? 1 : 0 }
    /// AppModel.start: `if micIsLive, micStartDecision(...) == micRequestFirst`.
    static func requestsMicPermission(micIsLive: Bool, micDecision: Int) -> Bool {
        micIsLive && micDecision == AudioRulesLegacy.micRequestFirst
    }
    /// `launch.outgoingSink.map { WAVFileSink } ?? blackHoleDevice.map { DeviceAudioPlayer }`: 0 sink, 1 device, 2 none.
    static func callOutput(hasSink: Bool, hasBlackHole: Bool) -> Int32 { hasSink ? 0 : (hasBlackHole ? 1 : 2) }
    /// The two TranslationLane(...) calls in AppModel.start.
    static func laneMode(direction: Int32, outgoingMode: Int32) -> Int32 { direction == DIR_INCOMING ? MODE_CONTINUOUS : MODE_PUSH_TO_TALK }
    static func laneSpeaks(direction: Int32, speakRussian: Bool) -> Bool { direction == DIR_INCOMING ? speakRussian : true }
    /// `outgoing.isPaused = voicePaused`, `outgoing.echoGuard = echoGuard`, `.speaking` of the incoming lane.
    static func laneVoicePause(direction: Int32) -> Bool { direction == DIR_OUTGOING }
    static func laneEchoGuarded(direction: Int32) -> Bool { direction == DIR_OUTGOING }
    static func laneEchoSource(direction: Int32) -> Bool { direction == DIR_INCOMING }
    /// GlossaryTerm: `direction == .incoming ? term.pt : term.ru`.
    static func glossarySourceIsPT(direction: Int32) -> Bool { direction == DIR_INCOMING }
    /// PushToTalkMonitor.apply.
    static func pttLocal(scope: Int32) -> Bool { scope != PTT_SCOPE_NONE }
    static func pttGlobal(scope: Int32) -> Bool { scope == PTT_SCOPE_GLOBAL }
    /// WAVFileSink.play: `min(left, 0.05)`.
    static func sinkPaceStep(left: Double) -> Double { min(left, 0.05) }

    // AppModel, views, LaunchOptions, Preferences, PonteMain
    /// `?? .apple`, `d.bool(...)` of a missing key.
    static let DEFAULT_TRANSLATOR: Int32 = TR_APPLE
    static let DEFAULT_SPEAK_RUSSIAN = false
    static let DEFAULT_OVERLAY_VISIBLE = false
    /// startPolling: `Task.sleep(for: .milliseconds(500))`, `tick % 6 == 5`.
    static let POLL_INTERVAL_MS: Int64 = 500
    static func pollRefreshesCatalogs(tick: Int64) -> Bool { tick % 6 == 5 }
    /// CommandBox: `Task.sleep(for: .seconds(2))`.
    static let COPIED_FEEDBACK_MS: Int64 = 2_000
    /// modelsCheck: `lanesFailed: lanesFailed + translatorsFailed`.
    static func modelsLightAll(runState: Int32, everStarted: Bool, lanesStarted: Int32, lanesFailed: Int32,
                               translatorsFailed: Int32) -> Int32 {
        modelsLight(runState: runState, everStarted: everStarted, lanesStarted: lanesStarted, lanesFailed: lanesFailed + translatorsFailed)
    }
    /// pollAudioStats `sourceCode == LIGHT_OK ? level : 0`; StatusChip `check == .ok`.
    static func showsLevel(light: Int32) -> Bool { light == LIGHT_OK }
    /// pollAudioStats, microphone (2026-10-13): the level only next to a green light and while the
    /// last buffer is fresh (a closed gate keeps the light green without audio).
    static func micShowsLevel(light: Int32, msSinceBuffer: Int64) -> Bool {
        showsLevel(light: light) && msSinceBuffer >= 0 && msSinceBuffer < AUDIO_FRESH_MS
    }
    /// pollAudioStats: 0 nothing, 1 only remember, 2 show the warning, 3 take the silence banner down
    /// (2026-10-13: the banner follows the source light; it stayed after real audio arrived).
    static func silenceBanner(sourceLight: Int32, alreadyWarned: Bool, errorShown: Bool, silenceShown: Bool) -> Int32 {
        guard sourceLight == LIGHT_WARN else { return silenceShown ? 3 : 0 }
        guard !alreadyWarned else { return 0 }
        return errorShown ? 1 : 2
    }
    /// sourceHelp: 0 idle, 1 waiting, 2 failed, 3 file, 4 silence, 5 audio flows.
    static func sourceHelp(runState: Int32, tapStatus: Int32, sourceLight: Int32) -> Int32 {
        guard runState == RUN_RUNNING else { return 0 }
        switch tapStatus {
        case TAP_WAITING: return 1
        case TAP_FAILED: return 2
        case TAP_NONE: return 3
        default: break
        }
        if sourceLight == LIGHT_WARN { return 4 }
        return 5
    }
    /// sourceTitle: 0 system, 1 running app's name, 2 known call app label, 3 the bundle ID.
    static func sourceTitle(isSystem: Bool, hasRunningName: Bool, hasLabel: Bool) -> Int32 {
        isSystem ? 0 : (hasRunningName ? 1 : (hasLabel ? 2 : 3))
    }
    /// start(): `blackHoleDevice != nil || launch.outgoingSink != nil`.
    static func hasCallOutput(hasBlackHole: Bool, hasSink: Bool) -> Bool { hasBlackHole || hasSink }
    /// The start banner switch and packsBanner: kind 0 none, 1 error, 2 warning; the wizard step it opens.
    static func bannerKind(banner: Int32) -> Int32 {
        switch banner {
        case BAN_NO_PACKS, BAN_NO_TRANSLATOR, BAN_FAILED_PACKS, BAN_FAILED_OTHER: return 1
        case BAN_NO_BLACKHOLE, BAN_SPEAKERS: return 2
        default: return 0
        }
    }
    static func bannerStep(banner: Int32) -> Int32 {
        switch banner {
        case BAN_NO_PACKS, BAN_NO_TRANSLATOR, BAN_FAILED_PACKS: return WZ_PACKS
        case BAN_FAILED_OTHER: return WZ_PERMISSIONS
        case BAN_NO_BLACKHOLE: return WZ_BLACKHOLE
        default: return WZ_NONE
        }
    }
    /// handle(.translationFailed): 0 nothing, 1 the packs banner, 2 a warning.
    static func translationErrorBanner(missingPacks: Bool, packsBannerShown: Bool, sameTextShown: Bool) -> Int32 {
        if missingPacks { return packsBannerShown ? 0 : 1 }
        return sameTextShown ? 0 : 2
    }
    /// refreshCatalogs: `if !callOutputUID.isEmpty, let chosen` (0 saved, 1 automatic).
    static func deviceChoice(hasSetting: Bool, found: Bool) -> Int32 { hasSetting && found ? 0 : 1 }
    /// makeTranslator: `translatorKind == .claude && claudeTranslator() != nil`.
    static func probesClaude(preferred: Int32) -> Bool { preferred == TR_CLAUDE }
    /// saveTranscript: `endedAt: isRunning ? nil : Date()`.
    static func transcriptHasEnd(runState: Int32) -> Bool { !(runState == RUN_RUNNING) }
    /// playTestPhrase: `if intoCall && blackHoleDevice == nil { throw }`.
    static func testPhrasePossible(intoCall: Bool, hasBlackHole: Bool) -> Bool { !(intoCall && !hasBlackHole) }
    /// OutgoingColumn status: 0 none, 1 paused, 2 speaking, 3 no BlackHole.
    static func outgoingStatus(paused: Bool, speaking: Bool, running: Bool, hasBlackHole: Bool) -> Int32 {
        if paused { return 1 }
        if speaking { return 2 }
        if running && !hasBlackHole { return 3 }
        return 0
    }
    /// SettingsView «Вывод в звонок»: `blackHoleDevice != nil && callOutputUID.isEmpty` (0 found, 1 search).
    static func callOutputLabel(hasBlackHole: Bool, hasSetting: Bool) -> Int32 { hasBlackHole && !hasSetting ? 0 : 1 }
    /// SettingsView translator: `if !claude { …; if translatorKind == .claude { … } }` (0 none, 1 no key, 2 + Apple used).
    static func translatorNote(preferred: Int32, claudeAvailable: Bool) -> Int32 {
        guard !claudeAvailable else { return 0 }
        return preferred == TR_CLAUDE ? 2 : 1
    }
    /// Permissions: AVAuthorizationStatus and SFSpeechRecognizerAuthorizationStatus → 0 unknown, 1 granted,
    /// 2 denied, 3 not asked.
    static func micPermissionState(raw: Int) -> Int32 {
        guard let status = AVAuthorizationStatus(rawValue: raw) else { return 0 }
        switch status {
        case .authorized: return 1
        case .denied, .restricted: return 2
        case .notDetermined: return 3
        @unknown default: return 0
        }
    }
    static func speechPermissionState(raw: Int) -> Int32 {
        guard let status = SFSpeechRecognizerAuthorizationStatus(rawValue: raw) else { return 0 }
        switch status {
        case .authorized: return 1
        case .denied, .restricted: return 2
        case .notDetermined: return 3
        @unknown default: return 0
        }
    }
    /// The wizard's permission rows: `if s == .denied { settings } else if s != .granted { request }`
    /// (0 none, 1 request, 2 settings); check(_:): granted ok, denied bad, else unknown.
    static func permissionAction(state: Int32) -> Int32 {
        if state == 2 { return 2 }
        if state != 1 { return 1 }
        return 0
    }
    static func permissionLight(state: Int32) -> Int32 { state == 1 ? LIGHT_OK : (state == 2 ? LIGHT_BAD : LIGHT_UNKNOWN) }
    /// `state.capture == .bad || state.capture == .warn`.
    static func captureNeedsSettings(light: Int32) -> Bool { light == LIGHT_BAD || light == LIGHT_WARN }
    /// `model.accessibilityGranted ? .ok : .unknown`.
    static func accessibilityLight(granted: Bool) -> Int32 { granted ? LIGHT_OK : LIGHT_UNKNOWN }
    /// refreshPacks over LanguageAvailability.Status codes (0 installed, 1 supported, 2 unsupported, 3 unknown).
    static func packLight(status: Int) -> Int32 {
        switch status {
        case 0: return LIGHT_OK
        case 2: return LIGHT_BAD
        default: return LIGHT_UNKNOWN
        }
    }
    /// `where packs[direction] != .busy`; `.disabled(packs == .busy || packs == .ok)`.
    static func packRefreshable(light: Int32) -> Bool { light != LIGHT_BUSY }
    static func packDownloadEnabled(light: Int32) -> Bool { !(light == LIGHT_BUSY || light == LIGHT_OK) }
    /// LineRow: 0 translated, 1 failed, 2 pending.
    static func lineState(hasTranslation: Bool, hasError: Bool) -> Int32 { hasTranslation ? 0 : (hasError ? 1 : 2) }
    /// LaunchOptions.
    static func isTestMode(hasIncomingFile: Bool, hasOutgoingFile: Bool, hasSink: Bool, hasTranscriptDir: Bool) -> Bool {
        hasIncomingFile || hasOutgoingFile || hasSink || hasTranscriptDir
    }
    static func isYes(_ lowercased: String) -> Bool { ["yes", "true", "1"].contains(lowercased) }
    /// SourceChoice(key:): the bundle ID of an "app:" key, nil for all Mac audio; and the keys it writes.
    static func sourceBundleID(key: String) -> String? { key.hasPrefix("app:") ? String(key.dropFirst(4)) : nil }
    static let SOURCE_SYSTEM_KEY = "system"
    static let SOURCE_APP_PREFIX = "app:"
    /// PonteAppDelegate.applicationShouldTerminate: `model.isRunning`.
    static func quitWaits(runState: Int32) -> Bool { runState == RUN_RUNNING }
}
