# Ponte

A live speech translator between Brazilian Portuguese and Russian for calls in any app: Zoom, Google Meet or Teams in a browser, Telegram, WhatsApp, FaceTime. It runs on the Mac and needs no account or cloud service.

- **They speak.** Ponte captures the call app's audio, or all Mac audio, without a driver. It shows the Russian translation as live subtitles, in the main window and in a floating panel above the call. A Russian voice-over in your headphones is optional.
- **You speak.** Ponte hears your Russian, translates it, and speaks Portuguese into the call through a virtual microphone (BlackHole 2ch).

Recognition, translation and speech run on the device: SpeechAnalyzer, the Translation framework and AVSpeechSynthesizer. Claude (`claude-haiku-5-5`) is an optional translator. It is used only when its key is in the macOS Keychain under the item `ponte-anthropic-key`.

## Written in t27

Every decision Ponte makes is written in [t27](https://github.com/gHashTag/t27), the spec language of the Trinity stack, and compiled to C by `t27c`. Swift collects facts (audio levels, device lists, recognizer results, what you clicked), asks a spec, and carries out the answer. The `Specs/` folder holds these specs:

| Spec | Decides |
|---|---|
| `audio_rules.t27` | downmix, RMS/peak, dBFS, chunking, resampling capacity, tap lifecycle, mic start |
| `device_rules.t27` | device kinds, echo risk, default mic, headphones and BlackHole picks, call apps, helper → app attribution, app order |
| `segment_rules.t27` | silence meter, when a phrase ends, monologue cuts, hallucination filter, where to split text for speech |
| `context_rules.t27` | conversation context for the translator, engine choice, timeouts, retries and fallback, Claude request constants |
| `voice_rules.t27` | voice ranking, synthesis timeout |
| `lane_rules.t27` | the mic gate and phrase pipeline state machines, push-to-talk, echo guard, speaking rate, replay |
| `ui_rules.t27` | buttons, status lights, latency colours, setup wizard, overlay |
| `transcript_rules.t27` | transcript file names, Markdown escaping |

The generated C is committed in `Sources/PonteSpecs`, so building the app does not need `t27c`. To regenerate the C and run every spec's own tests:

```bash
T27C=/path/to/t27c Specs/generate.sh
```

`Specs/T27C_PIN` names the compiler release, which is t27c v0.5.1. `Specs/README.md` maps each spec to the Swift that calls it.

The Swift facades `AudioRules`, `SpeechRules` and `AppRules` only pass values to the generated C and back. Swift keeps only what t27 cannot reach: SwiftUI views and their texts, Core Audio, AVFoundation, Speech, Translation, Keychain, URLSession, Unicode text handling, the Claude prompt and JSON, and concurrency. `Specs/README.md` lists what stays in Swift and why.

## Requirements

- An Apple Silicon Mac with macOS 26 or later, and Xcode 26 or later to build.
- [BlackHole 2ch](https://github.com/ExistentialAudio/BlackHole). Install it with `brew install --cask blackhole-2ch`. In the call app, choose **BlackHole 2ch** as the microphone and your headphones as the speaker.
- Headphones. With speakers, the microphone hears the other side.

## Build and run

```bash
swift build
swift test
scripts/bundle.sh
open dist/Ponte.app
```

`scripts/bundle.sh` signs the app with your first Apple Development identity. Without one, it falls back to ad hoc signing. On first launch, a wizard walks you through five steps:

1. Grant the microphone, audio recording and speech permissions.
2. Download the speech models.
3. Download the Portuguese and Russian translation languages.
4. Check BlackHole.
5. Play a test phrase into the call.

The command-line probes help with diagnosis: `swift run AudioProbe devices|apps|tap|mic|play` and `swift run SpeechProbe transcribe|translate|synth|pipeline`. `scripts/make-fixtures.sh` creates test phrases with the system voices.

## Status

This is a work in progress. These parts are verified on a Mac:

- Capturing one app's audio by its process.
- Re-attaching after the app restarts.
- Excluding Ponte's own sound.
- On-device recognition of pt-BR and ru-RU, 0.35–0.8 s after the speaker stops.
- Speech synthesis.
- Every decision runs in the C generated from the t27 specs. The three Swift rules facades only pass values to it. The Swift they replaced is kept as a test oracle. 42 differential tests compare the two bit for bit over about 23.6 million inputs.
- The full app, built and signed, with 176 tests passing and no build warnings.
- An end-to-end run with test files, one phrase each way, from the end of the phrase to the translation on screen:
  - Ru → Pt took 0.6 s.
  - Pt → Ru took 0.4 s.
  - The first run after a build took 1.5 s and 0.7 s.

Next step: a live call test.

Dmitrii Fedorov ([@dmitrii-f-t27](https://github.com/dmitrii-f-t27))
