// Owned by the t27 agent. The C generated from Specs/*.t27 (module PonteSpecs), called from Swift:
// every spec at least once through its C API, the constants that must equal system values, and
// bit-exact differential sweeps of the float arithmetic against the Swift formulas of the facades
// (copied here from AudioRules.swift until the facades call the C and become the oracles themselves).
import AppKit
import AVFoundation
import CoreAudio
import Foundation
import Testing
import PonteCore
import PonteSpecs

// MARK: - Buffers of the sizes the C expects

/// A text buffer of `size` bytes holding `strings` one after another; returns offsets and lengths.
private struct TextBuffer {
    var bytes: [UInt8]
    var offsets: [UInt32]
    var lengths: [UInt32]

    init(_ strings: [String], size: Int = 8192, slots: Int = 256) {
        bytes = [UInt8](repeating: 0, count: size)
        offsets = [UInt32](repeating: 0, count: slots)
        lengths = [UInt32](repeating: 0, count: slots)
        var at = 0
        for (i, s) in strings.enumerated() {
            let u = Array(s.utf8)
            bytes.replaceSubrange(at..<(at + u.count), with: u)
            offsets[i] = UInt32(at)
            lengths[i] = UInt32(u.count)
            at += u.count
        }
    }

    func off(_ i: Int) -> Int64 { Int64(offsets[i]) }
    func len(_ i: Int) -> Int64 { Int64(lengths[i]) }
}

private func bytes(_ s: String, size: Int) -> ([UInt8], Int64) {
    var b = [UInt8](repeating: 0, count: size)
    let u = Array(s.utf8)
    b.replaceSubrange(0..<u.count, with: u)
    return (b, Int64(u.count))
}

private func text(_ buffer: [UInt8], _ count: Int64) -> String {
    String(decoding: buffer[0..<Int(count)], as: UTF8.self)
}

/// A deterministic stream of Floats in -1.5...1.5 (no randomness in tests).
private struct Samples {
    var state: UInt64 = 0x9E37_79B9_7F4A_7C15
    mutating func next() -> Float {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return Float(Int32(truncatingIfNeeded: state >> 32)) / Float(Int32.max) * 1.5
    }
}

// MARK: - audio_rules

@Suite("audio_rules") struct AudioRulesSpecTests {
    @Test func constantsAndCodes() {
        #expect(AU_DBFS_FLOOR == -120)
        #expect(AU_QUIET_THRESHOLD_DBFS == -60)
        #expect(AU_CHUNK_SECONDS == 0.1)
        #expect(AU_FALLBACK_SAMPLE_RATE == 48_000)
        #expect(AU_CONVERSION_SLACK_FRAMES == 1024)
        #expect(AU_MIC_TAP_BUFFER_FRAMES == 2048)
        #expect(AU_AV_AUTHORIZED == AVAuthorizationStatus.authorized.rawValue)
        #expect(AU_AV_NOT_DETERMINED == AVAuthorizationStatus.notDetermined.rawValue)
        #expect(au_mic_start_decision(Int64(AVAuthorizationStatus.authorized.rawValue)) == AU_MIC_START)
        #expect(au_mic_start_decision(Int64(AVAuthorizationStatus.denied.rawValue)) == AU_MIC_DENIED)
        #expect(au_tap_action(false, 2, false, false, true) == AU_TAP_REBUILD)
        #expect(au_tap_action(true, 0, false, false, false) == AU_TAP_WAIT)
        #expect(au_frames_per_chunk(11_025, AU_CHUNK_SECONDS) == 1103)
        #expect(au_conversion_capacity(1, 44_100, 48_000) == 2 + 1024)
        #expect(au_pacing_sleep_nanos(0, 40_000_000, 4800, 48_000) == 60_000_000)
        #expect(au_int16_to_float(16_384) == 0.5)
        #expect(au_int32_to_float(Int32.min) == -1)
    }

    /// dBFS uses log10f in C and log10(Float) in Swift: equal bit for bit over the positive floats.
    @Test func dBFSMatchesSwiftBitForBit() {
        func oracle(_ level: Float) -> Float { level > 0 ? max(-120, 20 * log10(level)) : -120 }
        var mismatches = 0
        var checked = 0
        var bits: UInt32 = 1
        while bits < 0x7F80_0000 {
            let x = Float(bitPattern: bits)
            if au_dbfs(x).bitPattern != oracle(x).bitPattern { mismatches += 1 }
            checked += 1
            bits &+= 9_973
        }
        for x: Float in [0, -0.0, -1, 1, 0.1, 0.5, 2, .infinity, .nan, .leastNonzeroMagnitude, .greatestFiniteMagnitude] {
            if au_dbfs(x).bitPattern != oracle(x).bitPattern { mismatches += 1 }
        }
        #expect(checked > 200_000)
        #expect(mismatches == 0)
    }

    /// Downmix: the Float channel sum times the Float reciprocal, as AudioRules does it.
    @Test func downmixMatchesSwiftBitForBit() {
        func oracle(_ s: [Float], channels: Int) -> [Float] {
            let frames = s.count / channels
            var out = [Float](repeating: 0, count: frames)
            for i in 0..<frames {
                if channels == 1 {
                    out[i] += s[i]
                } else {
                    var sum: Float = 0
                    for c in 0..<channels { sum += s[i * channels + c] }
                    out[i] += sum
                }
            }
            let factor: Float = channels > 1 ? 1 / Float(channels) : 1
            if factor != 1 { for i in 0..<frames { out[i] *= factor } }
            return out
        }
        var gen = Samples()
        var mismatches = 0
        for channels in 1...6 {
            let count = 8192 - 8192 % channels
            var input = [Float](repeating: 0, count: 8192)
            for i in 0..<count { input[i] = gen.next() }
            var out = [Float](repeating: 0, count: 4096)
            let frames = au_downmix_interleaved(&input, Int64(count), Int64(channels), &out)
            let expected = oracle(Array(input[0..<count]), channels: channels)
            #expect(Int(frames) == min(4096, expected.count))
            for i in 0..<Int(frames) where out[i].bitPattern != expected[i].bitPattern { mismatches += 1 }
        }
        #expect(mismatches == 0)
        // 9 × Float(1/3), not 9 ÷ 3.
        var three = [Float](repeating: 0, count: 8192)
        three[0] = 3; three[1] = 3; three[2] = 3
        var out = [Float](repeating: 0, count: 4096)
        #expect(au_downmix_interleaved(&three, 3, 3, &out) == 1)
        #expect(out[0] == Float(9) * (Float(1) / Float(3)))
        // Planar: shortest channel, channels added in order.
        var planar = [Float](repeating: 0, count: 8192)
        var lengths = [Int64](repeating: 0, count: 64)
        planar.replaceSubrange(0..<6, with: [1, 1, 1, 0, -1, 1])
        lengths[0] = 3; lengths[1] = 3
        #expect(au_downmix_planar(&planar, &lengths, 2, &out) == 3)
        #expect(Array(out[0..<3]) == [0.5, 0, 1])
    }

    /// RMS (squares summed in Double, in index order), peak and gain against the Swift formulas.
    @Test func levelsAndGainMatchSwift() {
        var gen = Samples()
        var block = [Float](repeating: 0, count: 4096)
        for i in 0..<4096 { block[i] = gen.next() }
        var sum: Double = 0
        for s in block { sum += Double(s) * Double(s) }
        let rms = Float((sum / 4096).squareRoot())
        var peak: Float = 0
        for s in block { peak = max(peak, abs(s)) }
        #expect(au_rms(&block, 4096).bitPattern == rms.bitPattern)
        #expect(au_peak(&block, 4096).bitPattern == peak.bitPattern)
        #expect(au_sum_squares_continue(&block, 4096, 0) == sum)
        #expect(au_level_code(0, 0) == AU_LEVEL_DIGITAL_SILENCE)
        #expect(au_level_code(0.0005, 0.0005) == AU_LEVEL_QUIET)
        #expect(au_level_code(0.002, 0.001) == AU_LEVEL_SIGNAL)
        var gained = block
        #expect(au_apply_gain(&gained, 4096, 1.7) == 4096)
        var mismatches = 0
        for i in 0..<4096 where gained[i].bitPattern != min(1, max(-1, block[i] * 1.7)).bitPattern { mismatches += 1 }
        #expect(mismatches == 0)
        // framesPerChunk = max(1, round(rate × 0.1)) for every rate up to 200 kHz.
        var chunkMismatches = 0
        for rate in stride(from: 0.0, through: 200_000, by: 25) {
            if au_frames_per_chunk(rate, 0.1) != Int64(max(1, (rate * 0.1).rounded())) { chunkMismatches += 1 }
        }
        #expect(chunkMismatches == 0)
    }
}

// MARK: - segment_rules

@Suite("segment_rules") struct SegmentRulesSpecTests {
    @Test func finalizationAndVoiceActivity() {
        #expect(sg_finalize_action(600, 2000, 0, Int64.max, 60_000, Int64(SG_FLAG_HAS_CONTENT)) == SG_ACTION_END_OF_PHRASE)
        #expect(sg_finalize_action(600, 2000, 0, 550, 60_000, Int64(SG_FLAG_HAS_CONTENT)) == SG_ACTION_WAIT)
        #expect(sg_finalize_action(0, 12_000, 0, Int64.max, 60_000, Int64(SG_FLAG_HAS_CONTENT)) == SG_ACTION_MONOLOGUE_FORCED)
        #expect(sg_finalize_action(80, 6500, Int64(SG_PUNCTUATION_SENTENCE), Int64.max, 60_000, 1) == SG_ACTION_MONOLOGUE_PAUSE)
        #expect(sg_cut_backoff_ms(Int64(SG_ACTION_END_OF_PHRASE), 600) == 450)
        #expect(sg_effective_threshold(1_000_000) == 2500)
        #expect(sg_is_voice(1000, 0) && !sg_is_voice(999, 0))
        #expect(sg_next_noise_floor(0, true, 1000, 20) == 333)
    }

    @Test func textRules() {
        var (b, n) = bytes("então…", size: 8192)
        #expect(sg_punctuation_code(&b, n) == SG_PUNCTUATION_SENTENCE)
        (b, n) = bytes("«конец.»", size: 8192)
        #expect(sg_punctuation_code(&b, n) == SG_PUNCTUATION_SENTENCE)
        (b, n) = bytes("итак —", size: 8192)
        #expect(sg_punctuation_code(&b, n) == SG_PUNCTUATION_CLAUSE)
        (b, n) = bytes("um  dois\ttrês ", size: 8192)
        #expect(sg_word_count(&b, n) == 3)
        (b, n) = bytes("« — »", size: 8192)
        #expect(!sg_has_speech_content(&b, n))
        (b, n) = bytes("B.", size: 8192)
        #expect(sg_phrase_action(&b, n, 0) == SG_PHRASE_DROP_HALLUCINATION)
        (b, n) = bytes("Ok. Então… vamos ver isso com calma amanhã de manhã cedo", size: 8192)
        let cut = sg_cut_byte_index(&b, n, 30, 8)
        #expect(text(b, cut) == "Ok. Então…")
        (b, n) = bytes(String(repeating: "Ж", count: 40), size: 8192)
        #expect(sg_cut_byte_index(&b, n, 31, 5) == 30)
    }
}

// MARK: - context_rules

@Suite("context_rules") struct ContextRulesSpecTests {
    @Test func contextEnginesAndRequest() {
        var lengths: [Int64] = [500, 50, 50, 0, 0, 0, 0, 0]
        #expect(cx_context_count(&lengths, 3) == 3)
        lengths[0] = 501
        #expect(cx_context_count(&lengths, 3) == 2)
        lengths = [10, 700, 10, 0, 0, 0, 0, 0]
        #expect(cx_context_count(&lengths, 3) == 1)
        #expect(cx_primary_engine(Int64(CX_ENGINE_CLAUDE), true, false) == CX_ENGINE_APPLE)
        #expect(cx_fallback_engine(Int64(CX_ENGINE_APPLE), true, true) == CX_ENGINE_CLAUDE)
        #expect(cx_translation_timeout_ms(Int64(CX_ENGINE_CLAUDE)) == 5000)
        #expect(cx_error_code(529) == CX_ERROR_OVERLOADED)
        #expect(cx_retry_action(Int64(CX_ERROR_TIMEOUT), 0, Int64(CX_ENGINE_NONE)) == CX_RETRY_SAME)
        var out = [UInt8](repeating: 0, count: 64)
        let modelLength = cx_claude_model_id(&out)
        #expect(String(decoding: out[0..<Int(modelLength)], as: UTF8.self) == "claude-haiku-5-5")
        let versionLength = cx_anthropic_version(&out)
        #expect(String(decoding: out[0..<Int(versionLength)], as: UTF8.self) == "2023-06-01")
        #expect(CX_CLAUDE_MAX_TOKENS == 1024 && CX_CLAUDE_REQUEST_TIMEOUT_MS == 20_000)
    }
}

// MARK: - device_rules

@Suite("device_rules") struct DeviceRulesSpecTests {
    @Test func transportCodesMatchCoreAudio() {
        #expect(DV_TRANSPORT_BUILT_IN == kAudioDeviceTransportTypeBuiltIn)
        #expect(DV_TRANSPORT_AGGREGATE == kAudioDeviceTransportTypeAggregate)
        #expect(DV_TRANSPORT_VIRTUAL == kAudioDeviceTransportTypeVirtual)
        #expect(DV_TRANSPORT_PCI == kAudioDeviceTransportTypePCI)
        #expect(DV_TRANSPORT_USB == kAudioDeviceTransportTypeUSB)
        #expect(DV_TRANSPORT_FIREWIRE == kAudioDeviceTransportTypeFireWire)
        #expect(DV_TRANSPORT_BLUETOOTH == kAudioDeviceTransportTypeBluetooth)
        #expect(DV_TRANSPORT_BLUETOOTH_LE == kAudioDeviceTransportTypeBluetoothLE)
        #expect(DV_TRANSPORT_HDMI == kAudioDeviceTransportTypeHDMI)
        #expect(DV_TRANSPORT_DISPLAYPORT == kAudioDeviceTransportTypeDisplayPort)
        #expect(DV_TRANSPORT_AIRPLAY == kAudioDeviceTransportTypeAirPlay)
        #expect(DV_TRANSPORT_AVB == kAudioDeviceTransportTypeAVB)
        #expect(DV_TRANSPORT_THUNDERBOLT == kAudioDeviceTransportTypeThunderbolt)
        #expect(DV_TRANSPORT_CONTINUITY_WIRED == kAudioDeviceTransportTypeContinuityCaptureWired)
        #expect(DV_TRANSPORT_CONTINUITY_WIRELESS == kAudioDeviceTransportTypeContinuityCaptureWireless)
    }

    @Test func deviceKindsAndPicks() {
        var t = TextBuffer(["MacBook Pro Speakers", "BuiltInSpeakerDevice", "BlackHole 2ch", "ai.ponte.tap.7"])
        #expect(dv_device_kind(&t.bytes, t.off(0), t.len(0), t.off(1), t.len(1), kAudioDeviceTransportTypeBuiltIn, 0, 2) == DV_KIND_BUILT_IN_SPEAKER)
        #expect(dv_device_kind(&t.bytes, t.off(2), t.len(2), t.off(1), t.len(1), kAudioDeviceTransportTypeVirtual, 2, 2) == DV_KIND_BLACKHOLE)
        #expect(dv_device_kind(&t.bytes, t.off(2), t.len(2), t.off(3), t.len(3), kAudioDeviceTransportTypeAggregate, 2, 0) == DV_KIND_PONTE_AGGREGATE)
        #expect(dv_echo_risk(Int64(DV_KIND_BUILT_IN_SPEAKER)) == DV_ECHO_SPEAKER)
        #expect(dv_echo_risk(Int64(DV_KIND_DISPLAY)) == DV_ECHO_SPEAKER)
        var names = TextBuffer(["MacBook Pro Speakers", "BlackHole 16ch", "BlackHole 2ch"])
        var outputs = [Int64](repeating: 0, count: 256)
        outputs[0] = 2; outputs[1] = 16; outputs[2] = 2
        #expect(dv_pick_blackhole_index(&names.bytes, &names.offsets, &names.lengths, &outputs, 3) == 2)
        var kinds = [Int64](repeating: 0, count: 256)
        var inputs = [Int64](repeating: 0, count: 256)
        kinds[0] = Int64(DV_KIND_BLACKHOLE); kinds[1] = Int64(DV_KIND_USB); kinds[2] = Int64(DV_KIND_BUILT_IN_MIC)
        inputs[0] = 2; inputs[1] = 1; inputs[2] = 1
        #expect(dv_pick_mic_index(&kinds, &inputs, 4, 0) == 2)
        #expect(dv_pick_listen_output_index(&kinds, &outputs, 1, 0) == -1)
    }

    @Test func knownCallAppsMatchContracts() {
        let ids = AudioApp.knownCallApps.keys.sorted()
        #expect(DV_CALL_APPS == ids.count)
        var out = [UInt8](repeating: 0, count: 8192)
        for (i, id) in ids.enumerated() {
            let n = dv_call_app_bundle_id(Int64(i), &out)
            #expect(text(out, n) == id)
            let m = dv_call_app_label(Int64(i), &out)
            #expect(text(out, m) == AudioApp.knownCallApps[id])
            var t = TextBuffer([id])
            #expect(dv_known_call_app_index(&t.bytes, 0, t.len(0)) == Int64(i))
        }
    }

    @Test func appCatalog() {
        var apps = TextBuffer(["com.google.Chrome", "com.google", "com.apple.Safari", "", "com.google.Chrome.helper.Renderer"])
        #expect(dv_parent_app_index(&apps.bytes, apps.off(4), apps.len(4), &apps.offsets, &apps.lengths, 4) == 0)
        var path = TextBuffer(["/Applications/Téléphone.app/Contents/MacOS/x"])
        #expect(dv_outermost_app_path_length(&path.bytes, 0, path.len(0)) == Int64("/Applications/Téléphone.app".utf8.count))
        var p = TextBuffer(["com.apple.avconferenced", "com.apple.avconferenced", "com.apple.FaceTime"])
        #expect(dv_is_tap_target_process(&p.bytes, p.off(0), p.len(0), p.off(1), p.len(1), p.off(2), p.len(2), 5, 9))
        #expect(!dv_is_tap_target_process(&p.bytes, p.off(0), p.len(0), p.off(1), p.len(1), p.off(2), p.len(2), 9, 9))
        #expect(dv_owner_source(false, false, true, true, true) == DV_OWNER_RESPONSIBLE)
        #expect(dv_app_rank(false, true) == 1)
        var names = TextBuffer(["notes", "Zoom", "Music", "Notes", "x", "notes"])
        var ranks = [Int64](repeating: 0, count: 256)
        ranks.replaceSubrange(0..<6, with: [3, 0, 3, 3, 1, 3])
        var order = [Int64](repeating: 0, count: 256)
        #expect(dv_app_sort_order(&ranks, &names.bytes, &names.offsets, &names.lengths, 6, &order) == 6)
        #expect(Array(order[0..<6]) == [1, 4, 2, 0, 3, 5])
        var folded = [UInt8](repeating: 0, count: 8192)
        var abz = TextBuffer(["AbZ-ç"])
        let n = dv_folded_bytes(&abz.bytes, 0, abz.len(0), &folded)
        #expect(text(folded, n) == "abz-ç")
    }
}

// MARK: - voice_rules

@Suite("voice_rules") struct VoiceRulesSpecTests {
    @Test func rankingAndSynthesis() {
        #expect(VO_QUALITY_COMPACT == AVSpeechSynthesisVoiceQuality.default.rawValue)
        #expect(VO_QUALITY_ENHANCED == AVSpeechSynthesisVoiceQuality.enhanced.rawValue)
        #expect(VO_QUALITY_PREMIUM == AVSpeechSynthesisVoiceQuality.premium.rawValue)
        #expect(vo_voice_quality_code(9) == VO_QUALITY_COMPACT)
        #expect(vo_voice_rank_key(Int64(VO_QUALITY_PREMIUM), true, -1) > vo_voice_rank_key(Int64(VO_QUALITY_ENHANCED), false, 0))
        #expect(vo_voice_rank_key(Int64(VO_QUALITY_ENHANCED), false, 0) == 21_100)
        var (id, n) = bytes("com.apple.eloquence.pt-BR.Eddy", size: 1024)
        #expect(vo_is_novelty_voice(&id, n))
        (id, n) = bytes("com.apple.voice.compact.pt-BR.Luciana", size: 1024)
        #expect(!vo_is_novelty_voice(&id, n))
        #expect(vo_synthesis_timeout_ms(100) == 10_000)
        #expect(vo_synthesis_timeout_ms(10_000) == 60_000)
        #expect(vo_utterance_rate_milli(130, Int64(VO_DEFAULT_UTTERANCE_RATE_MILLI)) == 551)
    }
}

// MARK: - lane_rules

@Suite("lane_rules") struct LaneRulesSpecTests {
    @Test func gatePipelineAndControls() {
        #expect(ln_pack(3, 2) == 0x302 && ln_step_state(0x302) == 3 && ln_step_action(0x302) == 2)
        let step = ln_gate_step(LN_GATE_CLOSED, LN_GEV_KEY, LN_MODE_PUSH_TO_TALK, true, false)
        #expect(ln_step_state(step) == LN_GATE_OPEN && ln_step_action(step) == LN_GACT_OPEN_SEGMENT)
        let all = LN_PF_SPEAK_REQUESTED | LN_PF_GENERATION_CURRENT | LN_PF_SPEECH_ENABLED | LN_PF_HAS_SYNTH | LN_PF_HAS_PLAYER
        #expect(ln_phrase_step(LN_PH_TRANSLATING, LN_PEV_TRANSLATED, all) == ln_pack(LN_PH_SYNTH_QUEUED, LN_PACT_SYNTHESIZE))
        #expect(ln_phrase_step(LN_PH_TRANSLATING, LN_PEV_TRANSLATED, all | LN_PF_PAUSED) == ln_pack(LN_PH_SHOWN, LN_PACT_SHOW_ONLY))
        #expect(ln_cancels_speech(LN_SCE_VOICE, false))
        #expect(ln_replay_action(false, true, true) == LN_RPL_SYNTH)
        #expect([-1, 0, 1, 2, 3, 10].map { ln_speech_rate_percent(Int32($0)) } == [100, 100, 110, 120, 130, 130])
        #expect(ln_echo_guard_blocks_mic(true, false, 699) && !ln_echo_guard_blocks_mic(true, false, 700))
        #expect(ln_phrase_end_choice(250, 10) == LN_END_TRANSCRIBER && ln_phrase_end_choice(-1, 3) == LN_END_LAST_PARTIAL)
        #expect(ln_echo_guard_applies(true, true) && !ln_echo_guard_applies(true, false))
        #expect(ln_retry_translator_prepare(false, 5000) && !ln_retry_translator_prepare(false, 4999))
        #expect(ln_latency_ms(1000, 2250) == 1250)
        #expect(ln_context_overflow(9) == 5)
        #expect(ln_ptt_key_down(LN_PTT_RIGHT_OPTION, 0x80040) && !ln_ptt_key_down(LN_PTT_RIGHT_OPTION, 0x80020))
        #expect(ln_ptt_key_down(LN_PTT_FN, UInt64(NSEvent.ModifierFlags.function.rawValue)))
        #expect(ln_ptt_scope(true, LN_MODE_PUSH_TO_TALK, false) == LN_PTT_SCOPE_WINDOW)
    }
}

// MARK: - ui_rules

@Suite("ui_rules") struct UIRulesSpecTests {
    @Test func runButtonsLightsWizardOverlay() {
        #expect(ui_toggle_run(UI_RUN_RUNNING) == UI_TOGGLE_STOP)
        #expect(ui_start_banner(0, false, true, true) == UI_BAN_SPEAKERS)
        #expect(ui_start_banner_after_start(0, 1, true, true, false) == UI_BAN_NO_PACKS)
        #expect(ui_source_light(UI_RUN_RUNNING, true, UI_TAP_CAPTURING, 8000, 10, -1) == UI_LIGHT_WARN)
        #expect(ui_capture_check_light(UI_TAP_CAPTURING, true, false) == UI_LIGHT_WARN)
        #expect(!ui_wizard_show_on_launch_in_mode(false, -1, true))
        #expect(ui_button_enabled(UI_BTN_TEST_CALL, UI_RUN_IDLE, 0, 0, true, true) == false)
        #expect(ui_audio_light(UI_RUN_RUNNING, true, 3999, -1) == UI_LIGHT_BUSY)
        #expect(ui_models_light(UI_RUN_RUNNING, true, 1, 1) == UI_LIGHT_BAD)
        #expect([-1, 0, 2000, 2001, 4000, 4001].map { ui_latency_color(Int64($0)) }
                == [UI_LAT_NONE, UI_LAT_GOOD, UI_LAT_GOOD, UI_LAT_SLOW, UI_LAT_SLOW, UI_LAT_BAD])
        #expect(ui_source_section(false, true) == UI_SRC_PLAYING)
        #expect(ui_translator_choice(UI_TR_CLAUDE, false) == UI_TR_APPLE)
        #expect((0...5).map { ui_wizard_next(Int32($0)) } == [1, 2, 3, 4, 5, UI_WZ_NONE])
        #expect(ui_wizard_step_mark(UI_WZ_BLACKHOLE, false, false, 0, 0, false, false) == UI_MARK_WARN)
        #expect(ui_wizard_show_on_launch(true, 3))
        #expect([0, 13, 14, 16, 30, 40, 41, 99].map { ui_translation_font_size(Int32($0)) } == [24, 24, 16, 16, 30, 40, 40, 40])
        #expect(ui_overlay_line_count(5, 130, 24) == 2 && ui_overlay_line_count(5, 90, 40) == 1)
    }
}

// MARK: - transcript_rules

@Suite("transcript_rules") struct TranscriptRulesSpecTests {
    @Test func fileNameAndEscape() {
        var out = [UInt8](repeating: 0, count: 4096)
        var n = tr_transcript_file_name(2026, 10, 11, 14, 0, 2, &out)
        #expect(text(out, n) == "2026-10-11-1400-2.md")
        n = tr_transcript_file_name(2026, 10, 11, 9, 5, 1, &out)
        #expect(text(out, n) == "2026-10-11-0905.md")
        func escape(_ s: String) -> String {
            var (input, length) = bytes(s, size: 4096)
            var escaped = [UInt8](repeating: 0, count: 4096)
            let m = tr_markdown_escape(&input, length, &escaped)
            return text(escaped, m)
        }
        #expect(escape("1. Preço: 5*2") == "1\\. Preço: 5\\*2")
        #expect(escape("- цена [итог]") == "\\- цена \\[итог\\]")
        #expect(escape("строка\r\n- вторая\n3) третья") == "строка\n\\- вторая\n3\\) третья")
        #expect(escape("в 10.5") == "в 10.5")
        #expect(tr_is_markdown_special(UInt8(ascii: "~")) && !tr_is_markdown_special(UInt8(ascii: "a")))
    }
}

// MARK: - Codes shared between specs and with the system

@Suite("cross-spec codes") struct CrossSpecCodeTests {
    /// Codes one spec produces and another reads must be the same numbers; system raw values must match.
    @Test func sharedCodes() {
        // The app passes AudioRules.micStartDecision (audio_rules) to ln_requests_mic_permission (lane_rules).
        #expect(LN_MIC_REQUEST_FIRST == AU_MIC_REQUEST_FIRST)
        // AppleTranslator.availabilityCode (context_rules) feeds ui_pack_light (ui_rules).
        #expect([UI_AVAIL_INSTALLED, UI_AVAIL_SUPPORTED, UI_AVAIL_UNSUPPORTED, UI_AVAIL_UNKNOWN].map(Int64.init)
                == [CX_AVAIL_INSTALLED, CX_AVAIL_SUPPORTED, CX_AVAIL_UNSUPPORTED, CX_AVAIL_UNKNOWN].map(Int64.init))
        // SpeechRules.langCode feeds both segment_rules and voice_rules.
        #expect([VO_LANG_PT_BR, VO_LANG_RU] == [SG_LANG_PT_BR, SG_LANG_RU])
        // AVAudioConverterInputStatus for both converters.
        #expect([AU_INPUT_HAVE_DATA, AU_INPUT_NO_DATA_NOW, AU_INPUT_END_OF_STREAM].map(Int.init)
                == [AVAudioConverterInputStatus.haveData, .noDataNow, .endOfStream].map(\.rawValue))
        #expect([SG_INPUT_HAVE_DATA, SG_INPUT_NO_DATA_NOW, SG_INPUT_END_OF_STREAM].map(Int.init)
                == [AVAudioConverterInputStatus.haveData, .noDataNow, .endOfStream].map(\.rawValue))
        // AVAudioCommonFormat.
        #expect([AU_FORMAT_OTHER, AU_FORMAT_FLOAT32, AU_FORMAT_FLOAT64, AU_FORMAT_INT16, AU_FORMAT_INT32].map(UInt.init)
                == [AVAudioCommonFormat.otherFormat, .pcmFormatFloat32, .pcmFormatFloat64, .pcmFormatInt16, .pcmFormatInt32].map(\.rawValue))
        // AVAuthorizationStatus raw values ui_permission_state reads.
        #expect(ui_permission_state(Int64(AVAuthorizationStatus.authorized.rawValue)) == UI_PERM_GRANTED)
        #expect(ui_permission_state(Int64(AVAuthorizationStatus.denied.rawValue)) == UI_PERM_DENIED)
        #expect(ui_permission_state(Int64(AVAuthorizationStatus.restricted.rawValue)) == UI_PERM_DENIED)
        #expect(ui_permission_state(Int64(AVAuthorizationStatus.notDetermined.rawValue)) == UI_PERM_NOT_ASKED)
        // Directions: the lane codes the app maps Direction to.
        #expect(ln_lane_mode(LN_DIR_INCOMING, LN_MODE_PUSH_TO_TALK) == LN_MODE_CONTINUOUS)
        #expect(ln_lane_mode(LN_DIR_OUTGOING, LN_MODE_PUSH_TO_TALK) == LN_MODE_PUSH_TO_TALK)
        #expect(ln_glossary_source_is_pt(LN_DIR_INCOMING) && !ln_glossary_source_is_pt(LN_DIR_OUTGOING))
    }
}
