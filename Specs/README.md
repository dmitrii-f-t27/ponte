# Decisions written in t27

Every decision Ponte makes is written in [t27](https://github.com/gHashTag/t27), the spec language of the Trinity stack, and compiled to C with `t27c gen-c`. Swift collects the facts (device names and transport types, audio blocks, the volatile text, timings, what the person clicked), asks a spec, and carries out the answer through the system APIs and the views.

Each spec mirrors one Swift facade **one to one**: the same functions, codes, constants, order of checks and arithmetic. At integration every facade body becomes a call into the C, and the Swift version stays in the tests as the differential oracle. Each spec function's comment names the Swift function it mirrors.

| Spec | Decides | Mirrors |
|---|---|---|
| `audio_rules.t27` (`au_`) | sample conversion, frames in a buffer, mono downmix (interleaved and planar), gain with hard clip, RMS, peak, dBFS, level codes, silent-tap suspicion, rates and chunks, resampler capacity, real-time pacing, player conversion path, usable tap format, the process-tap lifecycle, the microphone permission | `PonteAudio/AudioRules.swift`: audio math, rates, pacing, tap lifecycle, microphone |
| `device_rules.t27` (`dv_`) | device kind from UID prefix, name and Core Audio transport type; echo risk; which devices are excluded; the BlackHole, microphone and listening-output picks; device lookup; the known call apps and their labels; FaceTime companion processes; which processes a tap takes; helper to parent app; the outermost `.app` of a path; where a process's owner comes from; app listing, rank and order; ASCII case folding | `PonteAudio/AudioRules.swift`: devices, app catalog, text helpers |
| `segment_rules.t27` (`sg_`) | the voice threshold over a noise floor and how the floor moves; when SpeechAnalyzer is asked to finalize (end of phrase, monologue cuts, backoff, cut spacing); punctuation at the end of a text; word count; speech content; dropping hallucinated phrases; where long text is cut for synthesis | `PonteSpeech/SpeechRules.swift`: voice activity, finalization, text, cut index |
| `context_rules.t27` (`cx_`) | how many previous phrases go into the Claude prompt; the primary and fallback translation engine; per-attempt timeouts; HTTP status to error; retry, switch or give up; the Claude request constants (model id, API version, max tokens, effort, timeout) | `PonteSpeech/SpeechRules.swift`: context, translator choice, Claude request |
| `voice_rules.t27` (`vo_`) | voice quality code, novelty voices, the voice rank key, the synthesis time limit | `PonteSpeech/SpeechRules.swift`: voices, synthesis |
| `lane_rules.t27` (`ln_`) | packed steps; the capture gate (is a transcriber session open, and when a segment opens or closes); the phrase pipeline from final text to played speech; what cancels queued speech; replay; the speech rate by queue length; the echo guard; which moment ends a phrase; latency; the context window; push-to-talk keys and scope | `PonteApp/AppRules.swift`: lane |
| `ui_rules.t27` (`ui_`) | run state and the start/stop toggle; start banners; autosave; which controls are enabled; the audio, BlackHole and models lights; the latency colour; source menu sections; the translator setting; the setup wizard steps and marks; translation font size; subtitle overlay lines | `PonteApp/AppRules.swift`: interface |
| `transcript_rules.t27` (`tr_`) | the transcript file name `YYYY-MM-DD-HHMM[-N].md`; Markdown escaping by bytes | `PonteApp/AppRules.swift`: transcript |

Not ported, by decision: `AppRules.isBuiltInSpeaker` (the app uses `dv_device_kind` and `dv_echo_risk`, which also flag display and AirPlay speakers) and `AppRules.isVoice(rms)` (the app uses `sg_is_voice`). One rule exists only in the spec: `au_meter_smooth` (a level meter that rises at 0.5 and falls at 0.1 per step), for a meter the facades may add.

## Calling the C from Swift

`import PonteSpecs` gives the constants (`#define`s; Swift imports integers as `Int32` and decimals as `Double`, so compare with the heterogeneous `==` or convert) and the prototypes. Types follow the facades: `Int` is `int64_t`, `Int32` codes are `int32_t`, `Float` is `float`, `Double` is `double`, `UInt32` and `UInt64` stay unsigned.

- **Float buffers** are fixed blocks: a mono block holds `AU_BLOCK_FRAMES` (4096) samples, an interleaved or planar block `AU_BLOCK_SAMPLES` (8192). A `[N]f32` parameter is `float x[static N]` in C: Swift passes an `N`-element `[Float]` with `&` and processes longer buffers block by block. `au_sum_squares_continue` and `au_peak_continue` carry a running sum and peak across blocks in the same index order, so the result equals one pass over the whole buffer. A count beyond a block is read as a full block.
- **Text** is UTF-8 bytes. `device_rules` takes every string as an offset and a length into one `text` buffer of `DV_TEXT_MAX` (8192) bytes, and a list of strings as parallel `offsets[256]`/`lengths[256]` arrays with a count (DiskBloom style). `segment_rules` takes a buffer of `SG_TEXT_MAX` (8192) bytes with its length, `voice_rules` one of `VO_ID_MAX` (1024), `transcript_rules` input and output buffers of `TR_BUFFER` (4096). Outputs are written to an out-buffer and the function returns their length.
- **Packed steps** (`ln_gate_step`, `ln_phrase_step`) return `(state << 8) | action`, read back with `ln_step_state` and `ln_step_action`.
- **Fixtures.** `*_FX_*` constants and `sg_fixture`, `dv_fixture`, `dv_fixture_push`, `vo_fixture`, `tr_fixture`, `tr_fixture_matches` hold the UTF-8 texts the specs' own tests use (t27 has no byte-string literals that reach C). The app does not need them.

## What stays in Swift, and why

- Views, their Russian texts and the Markdown layout of the transcript; the codes a spec returns are mapped to words in Swift.
- System calls: Core Audio (devices, process taps, aggregate devices), AVFoundation (engine, converters, synthesizer), SpeechAnalyzer, the Translation framework, URLSession and the Anthropic request JSON, Keychain, NSEvent and Accessibility, FileManager.
- Unicode work the OS owns: lowercasing, `Character.isLetter`, word boundaries for the glossary, cutting a phrase to `TR_MD_ESCAPE_MAX_INPUT` bytes at a character boundary before escaping.
- Concurrency (tasks, generations, locks, queues) and sorting voices by name after `vo_voice_rank_key`.

## Regenerate

```bash
T27C=~/Documents/t27-v051/target/release/t27c ./Specs/generate.sh
```

The script:

1. runs `Specs/tables/ponte_tables.py`, which writes the byte tables (device words, the known call apps sorted by bundle ID with their labels, the FaceTime companions, novelty-voice parts) and the test texts into the specs between the `; >>> generated` markers;
2. checks the whole tree with `t27c parse-complete` (no spec may be truncated or lose tokens) and `t27c check-calls` (every call matches its callee);
3. for each spec runs `t27c check` (warnings are printed), `t27c gen-c`, and the spec's own tests with `xcrun clang -std=c11 -ffp-contract=off -Wall -Wshorten-64-to-32 -Wno-parentheses-equality -Werror -DT27_TEST_MAIN`, and checks that every `test` block ran;
4. writes `Sources/PonteSpecs/<spec>.h` (the full C, compiled once by `Sources/PonteSpecs/t27_specs.c`) and `Sources/PonteSpecs/include/<spec>.api.h` (constants and prototypes), and rewrites `include/ponte_specs.h` (the umbrella Swift imports) and `t27_specs.c`.

Files are copied only when their content changed. The generated C is committed, so `swift build` and `scripts/bundle.sh` never need `t27c`. `T27C_PIN` names the compiler the committed C was generated with. `-ffp-contract=off` is required wherever the C is compiled (Package.swift sets it for PonteSpecs): a fused multiply-add would change the float results in the last bit.

## Tests

- Each spec's own `test` blocks (26 in all) run in `generate.sh`. They carry the facades' test cases and, where the input space is small, exhaustive loops (every flag set, state and event of the state machines; every byte for the text rules; every chunk split).
- `Tests/PonteTests/SpecsTests.swift` calls every spec through its C API from Swift, checks the constants that must equal system values (Core Audio transport types, `AVAuthorizationStatus`, `AVSpeechSynthesisVoiceQuality`, `NSEvent.ModifierFlags.function`, `AudioApp.knownCallApps`), and compares the float arithmetic bit for bit with the facade formulas: dBFS over 214 000 positive floats, downmix for 1 to 6 channels, RMS, peak, gain and `framesPerChunk`.

## Known differences from the Swift

- Equality of texts is byte equality; Swift's `String ==` also equates canonically equivalent forms. Device names, UIDs and bundle IDs arrive in one form, so the results agree in practice.
- Inputs beyond a buffer are clamped (a longer text is read up to the buffer size, a slice outside the buffer reads as empty), where Swift would read the whole array or trap. Integer overflow and out-of-range float-to-integer conversions trap in Swift and are undefined in C; the facades never pass such values.

## Compiler notes (t27c v0.5.1)

- A one-element array literal breaks `gen-c`; `ponte_tables.py` refuses to write one.
- An unused `pub const` array fails the tests (`-Wunused-const-variable`); a test that passes an array literal produces invalid C. Tests use named arrays.
- Constants become untyped `#define`s; a negative one is written without parentheses (`#define AU_DBFS_FLOOR -120.0`), so the specs never write `-CONST`.
- `sqrt`, `floor`, `round` and `abs` (as `fabsf`/`fabs` through `_Generic`) pull in `<math.h>`; other libm calls (`log10f`, `ceil`) compile only in a spec that already uses one of those.
- `cast_i64(x)`, `cast_u64(x)` and the other integer casts also convert floats (C truncation), without the typecheck warning a typed `var` gives.
- Every condition is emitted in double parentheses; `t27_specs.c` turns off `-Wparentheses-equality`.
