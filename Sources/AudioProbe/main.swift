// AudioProbe: manual checks for PonteAudio. Owned by the audio agent. See SPEC.md.
//
//   AudioProbe devices
//   AudioProbe apps [--raw]
//   AudioProbe tap (--bundle <id> | --pid <n> [--pid <n>…] | --system) --seconds N --out file.wav
//                  [--self-play file]   (also plays the file from this process: checks self-exclusion)
//   AudioProbe mic [--device <name>] --seconds N --out file.wav [--request]
//   AudioProbe permissions
//   AudioProbe play [--device <name substring>] [--volume 0..1] [--wait S] [--hold S] [--stop-engine-at S] file
//                  (--wait: the output runs S seconds before the phrase; --hold: S seconds after it;
//                   --stop-engine-at: stops the engine S seconds into the phrase the way a device change does)
//   AudioProbe file <path> [--realtime]
//
// Capture commands print the format, then frames and RMS once per second.
import AVFoundation
import Foundation
@_spi(Probe) import PonteAudio
import PonteCore

setvbuf(stdout, nil, _IOLBF, 0)

// MARK: Arguments

struct Args {
    var positional: [String] = []
    var options: [String: [String]] = [:]
    var flags: Set<String> = []

    static let valueOptions: Set<String> = ["--bundle", "--pid", "--seconds", "--out", "--device", "--self-play", "--volume",
                                            "--wait", "--hold", "--stop-engine-at"]

    init(_ argv: [String]) throws {
        var i = 0
        while i < argv.count {
            let a = argv[i]
            if Self.valueOptions.contains(a) {
                guard i + 1 < argv.count else { throw ProbeError.usage("\(a) needs a value") }
                options[a, default: []].append(argv[i + 1])
                i += 2
            } else if a.hasPrefix("--") {
                flags.insert(a)
                i += 1
            } else {
                positional.append(a)
                i += 1
            }
        }
    }

    func value(_ key: String) -> String? { options[key]?.last }
    func values(_ key: String) -> [String] { options[key] ?? [] }
}

enum ProbeError: Error, CustomStringConvertible {
    case usage(String)
    case failed(String)
    var description: String {
        switch self {
        case let .usage(s): return "usage: \(s)\n\n\(usageText)"
        case let .failed(s): return s
        }
    }
}

let usageText = """
AudioProbe devices
AudioProbe apps [--raw]
AudioProbe tap (--bundle <id> | --pid <n> [--pid <n>...] | --system) --seconds N --out file.wav [--self-play file]
AudioProbe mic [--device <name>] --seconds N --out file.wav [--request]
AudioProbe permissions
AudioProbe play [--device <name substring>] [--volume 0..1] [--wait S] [--hold S] [--stop-engine-at S] <file>
AudioProbe file <path> [--realtime]
"""

// MARK: Level meter

/// Collects frames and levels from the capture thread; the main thread prints once per second.
final class Meter {
    private let lock = NSLock()
    private var frames = 0
    private var buffers = 0
    private var sumSquares: Double = 0
    private var windowFrames = 0
    private var windowSquares: Double = 0
    private var windowPeak: Float = 0
    private var peak: Float = 0
    private var firstFormat: AVAudioFormat?

    func add(_ buffer: AVAudioPCMBuffer) {
        let samples = PCM.samples(buffer)
        var sq: Double = 0
        for s in samples { sq += Double(s) * Double(s) }
        let pk = AudioRules.peak(samples)
        lock.lock()
        if firstFormat == nil { firstFormat = buffer.format }
        frames += samples.count
        buffers += 1
        sumSquares += sq
        windowFrames += samples.count
        windowSquares += sq
        windowPeak = max(windowPeak, pk)
        peak = max(peak, pk)
        lock.unlock()
    }

    /// Returns (total frames, window RMS, window peak) and resets the window.
    func tick() -> (frames: Int, buffers: Int, rms: Float, peak: Float, format: AVAudioFormat?) {
        lock.lock()
        defer { windowFrames = 0; windowSquares = 0; windowPeak = 0; lock.unlock() }
        let rms = AudioRules.rmsFromSum(sumSquares: windowSquares, count: windowFrames)
        return (frames, buffers, rms, windowPeak, firstFormat)
    }

    func total() -> (frames: Int, rms: Float, peak: Float) {
        lock.lock()
        defer { lock.unlock() }
        return (frames, AudioRules.rmsFromSum(sumSquares: sumSquares, count: frames), peak)
    }
}

func fmt(_ x: Float) -> String { String(format: "%.5f", x) }
func db(_ x: Float) -> String { String(format: "%.1f dBFS", AudioRules.dBFS(x)) }
func levelName(peak: Float, rms: Float) -> String {
    switch AudioRules.levelCode(peak: peak, rms: rms) {
    case AudioRules.levelDigitalSilence: return "silence"
    case AudioRules.levelQuiet: return "quiet"
    default: return "signal"
    }
}

/// 16-bit PCM WAV writer fed with mono Float32 buffers.
final class WavWriter {
    private let file: AVAudioFile
    private let lock = NSLock()
    private(set) var error: Error?

    init(url: URL, sampleRate: Double) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        try? FileManager.default.removeItem(at: url)
        file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
    }

    func write(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        defer { lock.unlock() }
        do { try file.write(from: buffer) } catch { self.error = error }
    }

    func close() {
        lock.lock()
        file.close()
        lock.unlock()
    }
}

/// Runs a capture source for `seconds`, printing levels every second and writing a WAV.
func capture(source: AudioSource, seconds: Double, out: URL?, describeExtra: (() -> String?)? = nil) throws {
    let meter = Meter()
    var writer: WavWriter?
    var formatError: String?
    let writerLock = NSLock()

    try source.start { buffer, _ in
        meter.add(buffer)
        writerLock.lock()
        defer { writerLock.unlock() }
        if writer == nil, let out, formatError == nil {
            do { writer = try WavWriter(url: out, sampleRate: buffer.format.sampleRate) } catch { formatError = "\(error)" }
        }
        writer?.write(buffer)
    }
    print("source format: \(PCM.describe(source.outputFormat))")
    if let extra = describeExtra?() { print(extra) }

    let start = Date()
    var second = 0
    while Date().timeIntervalSince(start) < seconds {
        Thread.sleep(forTimeInterval: min(1, seconds - Date().timeIntervalSince(start)))
        second += 1
        let t = meter.tick()
        print("[\(second)s] frames=\(t.frames) buffers=\(t.buffers) rms=\(fmt(t.rms)) (\(db(t.rms))) peak=\(fmt(t.peak)) \(levelName(peak: t.peak, rms: t.rms))")
    }
    source.stop()
    writerLock.lock()
    writer?.close()
    writerLock.unlock()

    let total = meter.total()
    let rate = source.outputFormat.sampleRate
    print(String(format: "total: frames=%d (%.2f s at %.0f Hz) rms=%@ (%@) peak=%@",
                 total.frames, Double(total.frames) / rate, rate, fmt(total.rms), db(total.rms), fmt(total.peak)))
    if let formatError { throw ProbeError.failed("WAV writer: \(formatError)") }
    if let out {
        if total.frames > 0 { print("wrote \(out.path)") } else { print("no audio delivered; \(out.path) not written") }
    }
    if AudioRules.tapSilenceSuspect(totalFrames: total.frames, peak: total.peak) {
        print("NOTE: every sample is exactly 0. For a process tap this usually means the System Audio Recording")
        print("      permission is missing for the app that launched this tool (System Settings → Privacy & Security")
        print("      → Screen & System Audio Recording → System Audio Recording Only), or the target was silent.")
    }
}

// MARK: Commands

func kindName(_ kind: Int) -> String {
    let names = [
        AudioRules.kindUnknown: "unknown", AudioRules.kindBuiltInSpeaker: "built-in speaker",
        AudioRules.kindBuiltInHeadphones: "built-in headphones", AudioRules.kindBuiltInMic: "built-in mic",
        AudioRules.kindBlackHole: "BlackHole", AudioRules.kindBluetooth: "Bluetooth", AudioRules.kindUSB: "USB",
        AudioRules.kindDisplay: "display", AudioRules.kindAirPlay: "AirPlay", AudioRules.kindAggregate: "aggregate",
        AudioRules.kindPonteAggregate: "Ponte tap", AudioRules.kindVirtual: "virtual",
        AudioRules.kindContinuity: "Continuity", AudioRules.kindOtherWired: "wired",
    ]
    return names[kind] ?? "kind \(kind)"
}

func cmdDevices() {
    let catalog = CoreAudioDeviceCatalog()
    let defIn = catalog.defaultInput()
    let defOut = catalog.defaultOutput()
    print("Audio devices:")
    for d in catalog.devices() {
        var marks: [String] = []
        if d.id == defIn?.id { marks.append("default input") }
        if d.id == defOut?.id { marks.append("default output") }
        if d.outputChannels > 0 && catalog.echoRisk(of: d) == AudioRules.echoSpeaker { marks.append("loudspeaker: headphone warning") }
        let rate = catalog.sampleRate(of: d).map { "\(Int($0)) Hz" } ?? "? Hz"
        print("  [\(d.id)] \(d.name)  in=\(d.inputChannels) out=\(d.outputChannels) \(rate)  kind=\(kindName(catalog.kind(of: d)))  uid=\(d.uid)"
              + (marks.isEmpty ? "" : "  (\(marks.joined(separator: ", ")))"))
    }
    print("default input:  \(defIn?.name ?? "none")")
    print("default output: \(defOut?.name ?? "none")")
    print("suggested mic: \(catalog.suggestedMic()?.name ?? "none");  suggested listen output: \(catalog.suggestedListenOutput()?.name ?? "none")")
    if let bh = BlackHoleCheck.find(in: catalog) {
        print("BlackHole: found \(bh.name) [\(bh.id)]")
    } else {
        print("BlackHole: not installed (\(BlackHoleCheck.installCommand))")
    }
}

func cmdApps(raw: Bool) {
    let apps = RunningAudioAppCatalog().apps()
    print("Audio apps (\(apps.count)):")
    for a in apps {
        var marks: [String] = []
        if a.isPlayingAudio { marks.append("PLAYING") }
        if a.isKnownCallApp { marks.append("call app") }
        print("  \(a.name)  [\(a.bundleID)]  pids=\(a.pids.map(String.init).joined(separator: ","))"
              + (marks.isEmpty ? "" : "  (\(marks.joined(separator: ", ")))"))
    }
    if raw {
        print("\nHAL client processes:")
        for p in RunningAudioAppCatalog.rawProcesses().sorted(by: { $0.pid < $1.pid }) {
            print("  pid \(p.pid)  \(p.bundleID ?? "-")  → \(p.ownerName) [\(p.ownerBundleID)]\(p.playing ? "  PLAYING" : "")")
        }
    }
}

func cmdTap(_ args: Args) throws {
    guard let seconds = args.value("--seconds").flatMap(Double.init), seconds > 0 else {
        throw ProbeError.usage("tap needs --seconds N")
    }
    let out = args.value("--out").map { URL(fileURLWithPath: $0) }
    let source: AppAudioTapSource
    if let bundle = args.value("--bundle") {
        source = AppAudioTapSource(target: .app(bundleID: bundle))
        print("tap target: app \(bundle)")
    } else if !args.values("--pid").isEmpty {
        let pids = try args.values("--pid").map { s -> Int32 in
            guard let p = Int32(s) else { throw ProbeError.usage("bad --pid \(s)") }
            return p
        }
        source = AppAudioTapSource(pids: pids)
        print("tap target: pids \(pids)")
    } else if args.flags.contains("--system") {
        source = AppAudioTapSource(target: .systemExceptSelf)
        print("tap target: all system audio except this process")
    } else {
        throw ProbeError.usage("tap needs --bundle, --pid or --system")
    }
    source.onStatusChange = { status in print("tap status: \(status)") }
    if let selfPlay = args.value("--self-play") {
        // Ponte's own output (TTS into headphones) must never reach a system-wide tap.
        let buffer = try FileSource.readMono(url: URL(fileURLWithPath: selfPlay))
        let player = DeviceAudioPlayer(device: nil)
        try player.prepare()
        print("self-play: \(selfPlay) through this process on the default output")
        Task.detached {
            try? await Task.sleep(nanoseconds: 300_000_000)
            await player.play(buffer)
            print("self-play: finished")
        }
    }
    try capture(source: source, seconds: seconds, out: out) {
        let live = AppAudioTapSource.liveObjectCounts()
        let stream = source.tapStreamDescription.map { "tap stream: \(PCM.describe($0))\n" } ?? ""
        return stream + "while running: \(live.aggregates) Ponte aggregate(s), \(live.taps) tap(s)"
    }
    Thread.sleep(forTimeInterval: 0.3)   // aggregate destruction is asynchronous
    let left = AppAudioTapSource.liveObjectCounts()
    print("after stop: \(left.aggregates) Ponte aggregate(s), \(left.taps) tap(s) left")
}

func cmdMic(_ args: Args) async throws {
    guard let seconds = args.value("--seconds").flatMap(Double.init), seconds > 0 else {
        throw ProbeError.usage("mic needs --seconds N")
    }
    let catalog = CoreAudioDeviceCatalog()
    var device: AudioDevice?
    if let name = args.value("--device") {
        guard let d = catalog.device(matching: name), d.inputChannels > 0 else {
            throw ProbeError.failed("no input device matching \"\(name)\"")
        }
        device = d
    }
    print("mic: \((device ?? catalog.defaultInput())?.name ?? "default input")")
    switch MicSource.permission {
    case .authorized:
        break
    case .notDetermined:
        // One prompt at most, only on request: an undecided permission would block the engine.
        guard args.flags.contains("--request") else {
            throw ProbeError.failed("""
                Microphone permission is not decided yet for the app that launched this tool.
                Run again with --request to show the macOS prompt once, or enable it in
                \(AudioPermission.microphone.settingsPath).
                """)
        }
        print("requesting microphone permission (macOS shows a prompt once)…")
        guard await MicSource.requestPermission() else {
            throw ProbeError.failed("Microphone permission denied. Enable it in \(AudioPermission.microphone.settingsPath).")
        }
    default:
        throw ProbeError.failed("Microphone permission denied. Enable it in \(AudioPermission.microphone.settingsPath).")
    }
    try capture(source: MicSource(device: device), seconds: seconds, out: args.value("--out").map { URL(fileURLWithPath: $0) })
}

func cmdPermissions() {
    let mic: String
    switch MicSource.permission {
    case .authorized: mic = "granted"
    case .notDetermined: mic = "not decided yet"
    case .denied: mic = "denied"
    case .restricted: mic = "restricted"
    @unknown default: mic = "unknown"
    }
    print("Microphone: \(mic)  (\(AudioPermission.microphone.settingsPath))")
    print("System Audio Recording: no query API; a tap that delivers only exact zeros while the target plays")
    print("  means it is missing (\(AudioPermission.systemAudioRecording.settingsPath))")
    print("Permissions of a command-line tool belong to the app that launched it (Terminal, Claude, …).")
}

func cmdPlay(_ args: Args) async throws {
    guard let path = args.positional.dropFirst().first else { throw ProbeError.usage("play needs a file") }
    let catalog = CoreAudioDeviceCatalog()
    var device: AudioDevice?
    if let name = args.value("--device") {
        guard let d = catalog.device(matching: name), d.outputChannels > 0 else {
            let outs = catalog.outputDevices().map(\.name).joined(separator: ", ")
            throw ProbeError.failed("no output device matching \"\(name)\" (outputs: \(outs))")
        }
        device = d
    }
    let url = URL(fileURLWithPath: path)
    let file = try AVAudioFile(forReading: url)
    let whole = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
    try file.read(into: whole)
    let duration = Double(whole.frameLength) / file.processingFormat.sampleRate
    print("file: \(url.lastPathComponent)  \(PCM.describe(file.processingFormat))  \(String(format: "%.2f", duration)) s")
    print("output: \((device ?? catalog.defaultOutput())?.name ?? "default output")")

    let player = DeviceAudioPlayer(device: device)
    if let v = args.value("--volume").flatMap(Float.init) {
        player.volume = v   // clamped to 0…1 by AudioRules.clampUnit
        print("volume: \(player.volume)")
    }
    print("pid \(getpid())")
    try player.prepare()
    // The output stays on (silence) before and after the phrase, as the call output does.
    if let wait = args.value("--wait").flatMap(Double.init), wait > 0 {
        print(String(format: "output running, phrase in %.1f s", wait))
        try? await Task.sleep(nanoseconds: UInt64(wait * 1e9))
    }
    // Feed ~100 ms chunks like a synthesizer would, in one gapless call; it returns once all are heard.
    let chunk = Int(PCM.framesPerChunk(sampleRate: file.processingFormat.sampleRate))
    let pieces = PCM.chunkRanges(total: Int(whole.frameLength), chunk: chunk).compactMap { sliceAny(whole, $0) }
    let started = Date()
    print("phrase start \(ISO8601DateFormatter.probe.string(from: started))")
    await withTaskGroup(of: Void.self) { group in
        group.addTask { await player.play(pieces) }
        group.addTask {
            try? await Task.sleep(nanoseconds: 500_000_000)
            let used = RunningAudioAppCatalog.outputDevices(ofPID: getpid()).map(\.name)
            print("this process is playing to: \(used.isEmpty ? "-" : used.joined(separator: ", "))")
        }
        if let at = args.value("--stop-engine-at").flatMap(Double.init), at >= 0 {
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(at * 1e9))
                print(String(format: "stopping the engine at %.2f s, as a device change does", Date().timeIntervalSince(started)))
                player.simulateDeviceStop()
            }
        }
    }
    let ended = Date()
    print("phrase end \(ISO8601DateFormatter.probe.string(from: ended))")
    print(String(format: "played in %.2f s (file %.2f s)", ended.timeIntervalSince(started), duration))
    if let hold = args.value("--hold").flatMap(Double.init), hold > 0 {
        try? await Task.sleep(nanoseconds: UInt64(hold * 1e9))
    }
    if let err = player.lastError { throw ProbeError.failed("player: \(err)") }
}

extension ISO8601DateFormatter {
    static let probe: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}

/// Slices any deinterleaved Float32 buffer; other layouts are first downmixed to mono.
func sliceAny(_ buffer: AVAudioPCMBuffer, _ range: Range<Int>) -> AVAudioPCMBuffer? {
    if let s = PCM.slice(buffer, range) { return s }
    return PCM.mono(buffer).flatMap { PCM.slice($0, range) }
}

func cmdFile(_ args: Args) throws {
    guard let path = args.positional.dropFirst().first else { throw ProbeError.usage("file needs a path") }
    let source = FileSource(url: URL(fileURLWithPath: path), realtime: args.flags.contains("--realtime"))
    let done = DispatchSemaphore(value: 0)
    let meter = Meter()
    let started = Date()
    source.onFinish = { done.signal() }
    print("source format: \(PCM.describe(source.outputFormat))")
    try source.start { buffer, _ in meter.add(buffer) }
    done.wait()
    let t = meter.tick()
    let total = meter.total()
    print(String(format: "chunks=%d frames=%d (%.2f s audio) in %.2f s wall, rms=%@ peak=%@",
                 t.buffers, total.frames, Double(total.frames) / source.outputFormat.sampleRate,
                 Date().timeIntervalSince(started), fmt(total.rms), fmt(total.peak)))
}

// MARK: Main

do {
    let args = try Args(Array(CommandLine.arguments.dropFirst()))
    switch args.positional.first {
    case "devices": cmdDevices()
    case "apps": cmdApps(raw: args.flags.contains("--raw"))
    case "tap": try cmdTap(args)
    case "mic": try await cmdMic(args)
    case "permissions": cmdPermissions()
    case "play": try await cmdPlay(args)
    case "file": try cmdFile(args)
    default: throw ProbeError.usage("unknown command")
    }
} catch {
    FileHandle.standardError.write(Data("AudioProbe: \(error)\n".utf8))
    exit(1)
}
