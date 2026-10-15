# Ponte

A live speech translator between Brazilian Portuguese and Russian for calls in any app: Zoom, Google Meet or Teams in a browser, Telegram, WhatsApp, FaceTime. It runs on the Mac and needs no account or cloud service.

- **They speak.** Ponte captures the call app's audio, or all Mac audio, without a driver. It shows the Russian translation as live subtitles, in the main window and in a floating panel above the call. A Russian voice-over in your headphones is optional.
- **You speak.** Hold the talk key (right ⌥) and speak Russian. Ponte translates it and speaks Portuguese into the call through a virtual microphone (BlackHole 2ch). You can also type a text and press «Сказать».

Where the sound goes is fixed:
- The Portuguese voice goes only into the call. You do not hear it.
- You hear only the Russian translation. While Ponte listens to the call app, that app is muted on your Mac. «Слышать их» turns the other side's own voices back on.
- The «Звук ▾» menu in the top row picks where you hear everything: headphones, the Mac speakers or another output.
- The Russian voice never plays into the call. If macOS ever makes BlackHole the system output, for example when AirPods drop, Ponte moves the output back to your ears at once.
- Your own voice, if it comes back from the call (say, the other laptop sits next to you), is not translated back to you.
- «Ж | М» picks the female or male voice, separately for Portuguese (for example Felipe) and for Russian (Milena or Yuri).

Recognition, translation and speech run on the device: SpeechAnalyzer, the Translation framework and AVSpeechSynthesizer. Claude (`claude-haiku-5-5`) is an optional translator. It is used only when its key is in the macOS Keychain under the item `ponte-anthropic-key`.

**Russians in the call.** When several Russians each run Ponte in one call, they hear each other's own voices without translation, and the Portuguese side does not hear them. One of them presses «Русские в звонке» → «Создать код» and sends the code to the other Russians, not to the Portuguese side. Everyone enters it and presses «Подключиться». Up to six people fit in one room. A code is for one call: Ponte does not store it, and «Создать код» makes the next one. If the room is full, Ponte tries again every 15 seconds, because the relay may still count a Mac that went to sleep. If the relay counts more connections than Pontes that announced themselves, the panel warns that someone may be listening.

Ponte apps meet through a small relay, `relay/`, which runs on Railway. The code is the only secret; the Meet code is never used, because every participant has it. PBKDF2 derives the room and the AES-GCM key from the code, so the relay forwards only encrypted frames.

Each Ponte also announces when it speaks into the call, so no Ponte translates another Ponte's Portuguese voice back into Russian. With headphones your voice goes to the other Russians whenever you speak; without them, only while you hold the talk key, so they do not hear themselves as an echo. Only speech is sent, not the quiet noise of the room. When another Russian's voice plays on speakers, your microphone stays out of the call for 0.7 s after it, so the Portuguese side does not hear him.

**Camera in Meet.** The Mac's built-in camera gives programs no exposure or white balance, and macOS video effects belong to each program separately. So Ponte changes the picture Meet gets in BrowserOS itself: the Ponte Camera extension (`camera/extension`) wraps the camera track Meet asks for and draws each frame through a small shader. The toolbar button «Камера в Meet» opens the panel: light (brightness, contrast, shadows), colour (warmth, saturation), frame (zoom up to 3×, pan, mirror) and ready-made settings (normal, warm, dark room, vivid). Changes show at once in Meet's own preview of you. Install the extension once: «Папка расширения» in the panel, then in BrowserOS chrome://extensions → «Режим разработчика» → «Загрузить распакованное». Ponte talks to it only on 127.0.0.1:47839 and accepts only the extension's own origin; without Ponte the extension keeps the last settings and connects again by itself when Ponte starts (within about half a minute while Meet is open). The browser lists each refused attempt while Ponte is closed in chrome://extensions; that is expected, and the attempts are spaced out. If a frame cannot be drawn, Meet gets the live camera unprocessed rather than a black picture, the extension tries again by itself (another renderer at once if this one never drew here, then again after 30 s or on new settings), and the panel says «без обработки» with the step and the browser's error instead of «обработанную». A Meet tab that reloads or leaves Meet stops counting at once; one whose page crashed stops counting within about two minutes. A virtual camera for every app would need a paid Apple Developer account with system extensions.

The call analysis is optional too. In Settings → «Анализ звонка» you pick a chat service (Z.ai GLM, DeepSeek, or any OpenAI-compatible one), paste its API key (kept only in the Keychain as `ponte-analysis-<id>`) and check it. During a call an agent sends the new lines (who spoke, original and translation) to that service about every two minutes and keeps notes. After «Стоп», or from the toolbar button «Отчёт по звонку», it writes a report: summary, participants, important data, agreements, tasks, open questions, risks and next steps. «Сохранить в TXT» writes the report and the whole transcript to `~/Documents/Ponte/Ponte-report-YYYY-MM-DD-HHmm.txt`. Nothing is sent until a key is saved. The key is saved for one address and is sent only there: change the address and Ponte asks for the key again. Plain `http://` is allowed only for this Mac (`localhost`, `127.0.0.1`). A reply cut short by the service is never used as notes or as a report. A report you did not save is written to a file before the next call, and also when you quit Ponte; quitting waits up to 10 s for a report still being written.

## Written in t27

Ponte's business rules and policy (thresholds, limits, timers, state machines, recovery, routing choices) are written in [t27](https://github.com/gHashTag/t27), the spec language of the Trinity stack, and compiled to C by `t27c`. Swift and JavaScript collect facts (audio levels, device lists, recognizer results, camera frames, what you clicked), ask a spec, and carry out the answer through the platform APIs, which stay in Swift and JavaScript. The audit that moved the remaining rules was selective (pattern searches and reading of suspect places), not a line-by-line proof. The `Specs/` folder holds these specs:

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
| `peer_rules.t27` | «Русские в звонке»: the secret code, frames and their freshness, link status and reconnects, presence, when your microphone goes to the other Russians, the jitter buffer, voice windows, and which recognized phrase is a Ponte's voice (another Ponte's, or this Ponte's own TTS echoed back), while a short reply that repeats a word of the TTS is translated |
| `camera_rules.t27` | the camera picture in Meet: settings and presets, the colour matrix and shadow lift, zoom/pan/mirror, the frame pipeline (pass or draw, which renderer, what a failure does, when to try again, what the page reports), when the extension dials Ponte, the link's WebSocket checks and the panel's status; the extension runs the same C as WebAssembly |
| `relay_rules.t27` | the relay of «Русские в звонке»: room paths, who joins, the rate, what is forwarded and to whom, pings, every limit; `relay/server.js` runs it as WebAssembly |
| `analysis_rules.t27` | the call analysis agent: providers and defaults, endpoint, when notes update, request chunks, error classes, retries and backoff, the report and its TXT file name |

The generated C is committed in `Sources/PonteSpecs`, so building the app does not need `t27c`. To regenerate the C and run every spec's own tests:

```bash
T27C=/path/to/t27c Specs/generate.sh
```

`Specs/T27C_PIN` names the compiler release, which is t27c v0.5.1. `Specs/README.md` maps each spec to the Swift that calls it.

The Swift facades `AudioRules`, `SpeechRules`, `AppRules`, `TextRules`, `PeerRules`, `AnalysisRules` and `CameraRules` only pass values to the generated C and back. Swift keeps only what t27 cannot reach: SwiftUI views and their texts, Core Audio, AVFoundation, Speech, Translation, Keychain, URLSession, Unicode text handling, the Claude prompt and JSON, and concurrency. The extension's JavaScript keeps the browser APIs (getUserMedia, WebGL2, VideoFrame, storage, WebSocket) and the relay's keeps Node's HTTP and WebSocket; their decisions come from cm.wasm and rl.wasm. `Specs/README.md` lists what stays native and why; `reports/camera-t27-2026-10-15.md` maps each moved place to its spec function.

## Requirements

- An Apple Silicon Mac with macOS 26 or later, and Xcode 26 or later to build.
- [BlackHole 2ch](https://github.com/ExistentialAudio/BlackHole). Install it with `brew install --cask blackhole-2ch`. In the call app, choose **BlackHole 2ch** as the microphone and your headphones as the speaker.
- Headphones are recommended. With speakers, the microphone also hears the other side, so the voice to the other Russians goes out only while you hold the talk key.

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

The command-line probes help with diagnosis: `swift run AudioProbe devices|apps|inputs|tap|mic|play`, `swift run SpeechProbe transcribe|translate|synth|pipeline`, and `swift run PeerProbe --relay wss://…/r/ --secret abcd-efgh-jkmn` (a test "second Russian" for the peer link). `scripts/make-fixtures.sh` creates test phrases with the system voices.

## Status

This is a work in progress. These parts are verified on a Mac:

- Capturing one app's audio by its process.
- Re-attaching after the app restarts.
- Excluding Ponte's own sound.
- On-device recognition of pt-BR and ru-RU, 0.35–0.8 s after the speaker stops.
- Speech synthesis.
- The decisions run in the C generated from the t27 specs (0.1.14: 13 specs, 94 spec test blocks passing). The Swift rules facades only pass values to it; the system APIs (Core Audio, AVFoundation, Speech, the browser's camera and WebGL APIs, Node's network) stay in Swift and JavaScript adapters. The Swift the facades replaced, or a separate plain-Swift version, is kept as a test oracle and compared bit for bit.
- 0.1.14: `swift test` passes 333 tests in 41 suites (0.1.13: 327).
- The camera extension up to 0.1.13: its WebAssembly equals the native C bit for bit (`node camera/test/wasm-vectors.mjs`), and in a headless Chrome with a fake camera and SwiftShader the shader's colours equal `cm_apply_pixel` (`node camera/test/e2e.mjs`, also with Ponte's own link: `PONTE_LINK=1`). On the owner's Mac (BrowserOS, real camera, Apple GPU) 0.1.13 logged «passing frames unchanged [object DOMException]»; its cause is still not known. 0.1.14 reports the failing step and the error, recovers by itself and never hands Meet a closed frame. Checked locally:
  - the WebAssembly equals the native C (157 845 cases);
  - e2e with the fake camera passes, with Ponte's own link too: the shader equals `cm_apply_pixel` within 0/255;
  - the fault and recovery checks pass (28 checks, 0 closed frames handed over);
  - on the owner's Mac (BrowserOS neo, ANGLE Metal, Apple M4, the real camera) `camera/test/diagnose.mjs` passed: the WebGL2 canvas renderer drew about 30 frames/s, processed, never in trouble.

  A live Meet call has not been tested yet. Details are in `reports/camera-t27-2026-10-15.md`.
- An end-to-end run with test files, one phrase each way, from the end of the phrase to the translation on screen:
  - Ru → Pt took 0.6 s.
  - Pt → Ru took 0.4 s.
  - The first run after a build took 1.5 s and 0.7 s.

Before each call, the sheet «Перед звонком» opens (it can be turned off, and it is in the toolbar and the «Звонок» menu). It shows live, about once a second, whether the call app reads BlackHole 2ch or a real microphone, whether you listen on headphones, and which microphone Ponte uses. `AudioProbe inputs` prints which apps read which input devices.

Next step: a live call test.

Dmitrii Fedorov ([@dmitrii-f-t27](https://github.com/dmitrii-f-t27))
