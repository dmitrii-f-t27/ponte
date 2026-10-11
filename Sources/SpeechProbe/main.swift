// Owned by the speech agent. See SPEC.md.
//
// SpeechProbe — command-line checks for PonteSpeech.
//   SpeechProbe assets [--download]
//   SpeechProbe voices --lang pt-BR|ru-RU
//   SpeechProbe transcribe --lang pt-BR|ru-RU [--realtime] [--no-cuts] file
//   SpeechProbe translate --from pt-BR --to ru-RU [--engine auto|apple|claude] "text"
//   SpeechProbe synth --lang pt-BR [--voice id] --out file.wav "text"
//   SpeechProbe pipeline --direction incoming|outgoing [--engine auto|apple|claude] [--tail 2] [--out file.wav] file
//   SpeechProbe packs        (opens the system download prompt for the translation packs)
// PONTE_SPEECH_DEBUG=1 prints recognizer results and cut decisions to stderr.
import AVFoundation
import Foundation
import PonteCore
import PonteSpeech

setvbuf(stdout, nil, _IOLBF, 0)

// MARK: - Arguments

struct Args {
    var command = ""
    var options: [String: String] = [:]
    var flags: Set<String> = []
    var positional: [String] = []

    static let valueOptions: Set<String> = ["--lang", "--from", "--to", "--engine", "--out", "--voice",
                                            "--direction", "--tail", "--rate"]

    init(_ argv: [String]) {
        var it = argv.dropFirst().makeIterator()
        command = it.next() ?? ""
        while let a = it.next() {
            if Self.valueOptions.contains(a) {
                options[a] = it.next() ?? ""
            } else if a.hasPrefix("--") {
                flags.insert(a)
            } else {
                positional.append(a)
            }
        }
    }

    func lang(_ key: String) -> Lang? { options[key].flatMap(Lang.init(rawValue:)) }
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
    exit(1)
}

func describe(_ error: Error) -> String {
    if let e = error as? LocalizedError, let d = e.errorDescription { return d }
    return "\(error)"
}

func f2(_ x: Double) -> String { String(format: "%.2f", x) }

func secs(_ d: Duration) -> Double { Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18 }

let usage = """
usage:
  SpeechProbe assets [--download]
  SpeechProbe voices --lang pt-BR|ru-RU
  SpeechProbe transcribe --lang pt-BR|ru-RU [--realtime] [--no-fast] [--no-cuts] file
  SpeechProbe translate --from pt-BR --to ru-RU [--engine auto|apple|claude] "text"
  SpeechProbe synth --lang pt-BR [--voice id] [--rate 0.5] --out file.wav "text"
  SpeechProbe pipeline --direction incoming|outgoing [--engine auto|apple|claude] [--tail 2] [--out file.wav]
                       [--no-fast] [--no-cuts] file
  SpeechProbe packs
"""

// MARK: - Helpers

/// `--no-cuts` switches off Ponte's own finalization (the analyzer alone decides), for comparison.
nonisolated(unsafe) var ownCutsEnabled = true

func makeTranscriber(_ lang: Lang, fast: Bool) -> AppleTranscriber {
    let t = AppleTranscriber(language: lang)
    t.fastResults = fast
    t.ownCutsEnabled = ownCutsEnabled
    return t
}

/// `--engine apple|claude|auto` (default auto: `RoutingTranslator`, Apple first, Claude as fallback if keyed).
func makeTranslator(_ engine: String?) -> Translator? {
    switch engine ?? "auto" {
    case "claude": return ClaudeTranslator()
    case "apple": return AppleTranslator()
    default: return RoutingTranslator()
    }
}

/// Reads the file and feeds it in 100 ms chunks, at real-time pace if asked, then `tail` seconds of silence.
func feed(file url: URL, into transcriber: AppleTranscriber, realtime: Bool, tail: Double,
          clockStart: ContinuousClock.Instant) throws -> Double {
    let file = try AVAudioFile(forReading: url)
    let format = file.processingFormat
    let chunk = AVAudioFrameCount(format.sampleRate / 10)
    var fed = 0.0
    var index = 0
    func waitForSlot() {
        guard realtime else { return }
        index += 1
        let due = clockStart + .milliseconds(100 * index)
        let now = ContinuousClock.now
        if due > now { Thread.sleep(forTimeInterval: secs(due - now)) }
    }
    while file.framePosition < file.length {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk) else { break }
        try file.read(into: buffer, frameCount: chunk)
        if buffer.frameLength == 0 { break }
        waitForSlot()
        transcriber.append(buffer)
        fed += Double(buffer.frameLength) / format.sampleRate
    }
    let speechEnd = fed
    var silence = 0.0
    while silence < tail {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk) else { break }
        buffer.frameLength = chunk   // zero-filled
        waitForSlot()
        transcriber.append(buffer)
        silence += Double(chunk) / format.sampleRate
    }
    return speechEnd
}

func writeWAV(_ buffers: [AVAudioPCMBuffer], to url: URL, gap: Double = 0.3) throws -> Double {
    guard let first = buffers.first else { throw PonteSpeechError.synthesisFailed("нет звука для записи") }
    let format = first.format
    let settings: [String: Any] = [
        AVFormatIDKey: kAudioFormatLinearPCM,
        AVSampleRateKey: format.sampleRate,
        AVNumberOfChannelsKey: 1,
        AVLinearPCMBitDepthKey: 16,
        AVLinearPCMIsFloatKey: false,
        AVLinearPCMIsBigEndianKey: false,
    ]
    try? FileManager.default.removeItem(at: url)
    let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
    var seconds = 0.0
    for (i, b) in buffers.enumerated() {
        if i > 0, gap > 0, let pause = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(gap * format.sampleRate)) {
            pause.frameLength = pause.frameCapacity
            try file.write(from: pause)
            seconds += gap
        }
        try file.write(from: b)
        seconds += Double(b.frameLength) / format.sampleRate
    }
    return seconds
}

// MARK: - Commands

func cmdAssets(download: Bool) async {
    for lang in Lang.allCases {
        let t = AppleTranscriber(language: lang)
        if download {
            let t0 = Date()
            do {
                try await t.prepare()
                print("speech \(lang.rawValue): installed (prepare \(f2(Date().timeIntervalSince(t0))) s)")
            } catch {
                print("speech \(lang.rawValue): ERROR \(describe(error))")
            }
        }
    }
    if !download { print("speech models: run with --download to install/check them") }
    for d in Direction.allCases {
        let status = await AppleTranslator.status(from: d.source, to: d.target)
        print("translation \(d.source.rawValue) → \(d.target.rawValue): \(status)")
    }
    print("claude key (keychain ponte-anthropic-key): \(ClaudeTranslator() == nil ? "absent" : "present")")
}

func cmdVoices(_ lang: Lang) {
    for v in SystemSpeechSynth.voices(for: lang) {
        print("\(v.quality.title.padding(toLength: 11, withPad: " ", startingAt: 0)) \(v.name.padding(toLength: 22, withPad: " ", startingAt: 0)) \(v.id)")
    }
}

func cmdTranscribe(_ lang: Lang, file: URL, realtime: Bool, fast: Bool) async {
    let t = makeTranscriber(lang, fast: fast)
    do { try await t.prepare() } catch { fail("prepare: \(describe(error))") }
    let events: AsyncStream<TranscriptEvent>
    do { events = try t.start() } catch { fail("start: \(describe(error))") }
    let clock = ContinuousClock.now
    let printer = Task {
        for await e in events {
            let at = f2(secs(ContinuousClock.now - clock))
            switch e {
            case .partial(_, let text): print("[\(at)s] partial: \(text)")
            case .final(let id, let text):
                let timing = t.timing(for: id)
                print("[\(at)s] FINAL:   \(text)" + (timing.map { "   (audio \(f2($0.audioStart))–\(f2($0.audioEnd)) s\($0.forced ? ", forced cut" : ""))" } ?? ""))
            }
        }
    }
    do {
        _ = try await Task.detached { try feed(file: file, into: t, realtime: realtime, tail: realtime ? 1.5 : 0.5, clockStart: clock) }.value
    } catch { fail("read \(file.path): \(describe(error))") }
    await t.finish()
    await printer.value
    if let e = t.lastError { print("transcriber error: \(describe(e))") }
}

func cmdTranslate(from: Lang, to: Lang, text: String, engine: String?) async {
    guard let tr = makeTranslator(engine) else {
        fail("Claude: ключа ponte-anthropic-key в связке ключей нет")
    }
    do {
        try await tr.prepare(from: from, to: to)
        let t0 = Date()
        let out = try await tr.translate(text, from: from, to: to, context: [])
        print("\(tr.name) \(from.rawValue) → \(to.rawValue) (\(f2(Date().timeIntervalSince(t0))) s): \(out)")
    } catch {
        fail("translate: \(describe(error))")
    }
}

func cmdSynth(_ lang: Lang, text: String, out: URL, voice: String?, rate: Float?) async {
    let synth = SystemSpeechSynth(voiceIdentifiers: voice.map { [lang: $0] } ?? [:])
    synth.rate = rate
    let t0 = Date()
    do {
        let buffers = try await synth.synthesize(text, lang: lang)
        let render = Date().timeIntervalSince(t0)
        let seconds = try writeWAV(buffers, to: out)
        let fmt = buffers.first!.format
        print("voice: \(synth.voice(for: lang)?.name ?? "?") (\(synth.voice(for: lang)?.identifier ?? "?"))")
        print("format: \(fmt.commonFormat == .pcmFormatFloat32 ? "Float32" : "\(fmt.commonFormat)") \(fmt.channelCount) ch \(Int(fmt.sampleRate)) Hz")
        print("rendered \(f2(seconds)) s of audio in \(f2(render)) s → \(out.path)")
    } catch {
        fail("synth: \(describe(error))")
    }
}

func cmdPipeline(_ direction: Direction, file: URL, engine: String?, tail: Double, out: URL?, fast: Bool) async {
    let source = direction.source, target = direction.target
    print("pipeline \(direction.rawValue): \(source.rawValue) → \(target.rawValue), file \(file.lastPathComponent), real-time 100 ms chunks")
    let transcriber = makeTranscriber(source, fast: fast)
    let t0 = Date()
    do { try await transcriber.prepare() } catch { fail("prepare ASR: \(describe(error))") }
    print("ASR ready in \(f2(Date().timeIntervalSince(t0))) s")

    var translator = makeTranslator(engine)
    if translator == nil { print("translator: Claude key absent → no translation") }
    if let tr = translator {
        do {
            try await tr.prepare(from: source, to: target)
            print("translator: \(tr.name)")
        } catch {
            print("translator \(tr.name) unavailable: \(describe(error))")
            translator = nil
        }
    }
    let synth = direction == .outgoing ? SystemSpeechSynth() : nil
    if let synth { print("voice \(target.rawValue): \(synth.voice(for: target)?.name ?? "none")") }

    let events: AsyncStream<TranscriptEvent>
    do { events = try transcriber.start() } catch { fail("start: \(describe(error))") }
    let clock = ContinuousClock.now
    func elapsed() -> String {
        return f2(secs(ContinuousClock.now - clock))
    }

    struct Row { var text: String; var asr: Double?; var mt: Double?; var total: Double?; var forced: Bool; var translation: String? }
    let (finals, finalsCont) = AsyncStream.makeStream(of: (UUID, String, Date).self)

    let eventTask = Task {
        for await e in events {
            switch e {
            case .partial(_, let text):
                print("[\(elapsed())s] partial  \(source.rawValue): \(text)")
            case .final(let id, let text):
                let now = Date()
                let timing = transcriber.timing(for: id)
                let asr = timing.map { now.timeIntervalSince($0.audioEndArrivedAt) }
                print("[\(elapsed())s] FINAL    \(source.rawValue): \(text)"
                      + (timing.map { "   [audio \(f2($0.audioStart))–\(f2($0.audioEnd)) s\($0.forced ? ", forced cut" : "")]" } ?? "")
                      + (asr.map { "  end of phrase → final \(f2($0)) s" } ?? ""))
                finalsCont.yield((id, text, now))
            }
        }
        finalsCont.finish()
    }

    let translateTask = Task { () -> ([Row], [AVAudioPCMBuffer]) in
        var rows: [Row] = []
        var audio: [AVAudioPCMBuffer] = []
        var context: [String] = []
        for await (id, text, finalAt) in finals {
            let timing = transcriber.timing(for: id)
            var row = Row(text: text, asr: timing.map { finalAt.timeIntervalSince($0.audioEndArrivedAt) },
                          mt: nil, total: nil, forced: timing?.forced ?? false, translation: nil)
            guard let tr = translator else { rows.append(row); continue }
            do {
                let translated = try await tr.translate(text, from: source, to: target, context: context)
                let done = Date()
                row.translation = translated
                row.mt = done.timeIntervalSince(finalAt)
                row.total = timing.map { done.timeIntervalSince($0.audioEndArrivedAt) }
                print("[\(elapsed())s] → \(target.rawValue): \(translated)   final → translation \(f2(row.mt!)) s"
                      + (row.total.map { "; end of phrase → translation \(f2($0)) s" } ?? ""))
                context.append(text)
                if let synth {
                    // Piece by piece (SpeechRules.cutByteIndex): the first piece could start playing at once.
                    let s0 = Date()
                    var secs = 0.0
                    var firstAudio: Double?
                    let pieces = SystemSpeechSynth.chunks(translated)
                    for piece in pieces {
                        let buffers = try await synth.synthesize(piece, lang: target)
                        if firstAudio == nil { firstAudio = Date().timeIntervalSince(s0) }
                        secs += buffers.reduce(0.0) { $0 + Double($1.frameLength) / $1.format.sampleRate }
                        audio += buffers
                    }
                    print("[\(elapsed())s] synth \(target.rawValue): \(f2(secs)) s of audio in \(pieces.count) piece(s), "
                          + "first audio after \(f2(firstAudio ?? 0)) s, all in \(f2(Date().timeIntervalSince(s0))) s")
                }
            } catch {
                print("[\(elapsed())s] translation error: \(describe(error))")
            }
            rows.append(row)
        }
        return (rows, audio)
    }

    let speechEnd: Double
    do {
        speechEnd = try await Task.detached { try feed(file: file, into: transcriber, realtime: true, tail: tail, clockStart: clock) }.value
    } catch { fail("read \(file.path): \(describe(error))") }
    print("[\(elapsed())s] file audio ended at \(f2(speechEnd)) s; fed \(f2(tail)) s of silence; finishing")
    await transcriber.finish()
    await eventTask.value
    let (rows, audio) = await translateTask.value
    if let e = transcriber.lastError { print("transcriber error: \(describe(e))") }

    print("\nsummary (\(rows.count) phrases):")
    for (i, r) in rows.enumerated() {
        let parts = [r.asr.map { "ASR \(f2($0)) s" }, r.mt.map { "MT \(f2($0)) s" }, r.total.map { "total \(f2($0)) s" }]
            .compactMap { $0 }.joined(separator: ", ")
        print("  \(i + 1). \(parts.isEmpty ? "-" : parts)\(r.forced ? " (forced cut)" : "")  \(r.text)")
    }
    let totals = rows.compactMap(\.total)
    if !totals.isEmpty {
        print("  end of phrase → translation: max \(f2(totals.max()!)) s, mean \(f2(totals.reduce(0, +) / Double(totals.count))) s (target ≤ 2 s)")
    } else {
        let asr = rows.compactMap(\.asr)
        if !asr.isEmpty { print("  end of phrase → final: max \(f2(asr.max()!)) s, mean \(f2(asr.reduce(0, +) / Double(asr.count))) s") }
    }
    if direction == .outgoing {
        if audio.isEmpty {
            print("  no pt-BR audio written (no translation)")
        } else {
            let url = out ?? file.deletingLastPathComponent()
                .appendingPathComponent("out_" + file.deletingPathExtension().lastPathComponent + "_\(target.rawValue).wav")
            do {
                let secs = try writeWAV(audio, to: url)
                print("  wrote \(f2(secs)) s of \(target.rawValue) speech → \(url.path)")
            } catch { print("  WAV write failed: \(describe(error))") }
        }
    }
}

// MARK: - Main

let args = Args(CommandLine.arguments)
ownCutsEnabled = !args.flags.contains("--no-cuts")
switch args.command {
case "assets":
    await cmdAssets(download: args.flags.contains("--download"))
case "voices":
    guard let lang = args.lang("--lang") else { fail(usage) }
    cmdVoices(lang)
case "transcribe":
    guard let lang = args.lang("--lang"), let path = args.positional.first else { fail(usage) }
    await cmdTranscribe(lang, file: URL(fileURLWithPath: path), realtime: args.flags.contains("--realtime"),
                        fast: !args.flags.contains("--no-fast"))
case "translate":
    guard let from = args.lang("--from"), let to = args.lang("--to"), let text = args.positional.first else { fail(usage) }
    await cmdTranslate(from: from, to: to, text: text, engine: args.options["--engine"])
case "synth":
    guard let lang = args.lang("--lang"), let out = args.options["--out"], let text = args.positional.first else { fail(usage) }
    await cmdSynth(lang, text: text, out: URL(fileURLWithPath: out), voice: args.options["--voice"],
                   rate: args.options["--rate"].flatMap(Float.init))
case "pipeline":
    guard let d = args.options["--direction"].flatMap(Direction.init(rawValue:)), let path = args.positional.first else { fail(usage) }
    await cmdPipeline(d, file: URL(fileURLWithPath: path), engine: args.options["--engine"],
                      tail: args.options["--tail"].flatMap(Double.init) ?? 2.0,
                      out: args.options["--out"].map { URL(fileURLWithPath: $0) }, fast: !args.flags.contains("--no-fast"))
case "packs":
    runPackDownloader()
default:
    fail(usage)
}
exit(0)
