// AudioProbe: manual checks for PonteAudio. Owned by the audio agent. See SPEC.md.
//
//   AudioProbe devices
//   AudioProbe apps [--raw]
//   AudioProbe inputs [--bundle <call app id>]   (which apps read which input devices; who listens to BlackHole)
//   AudioProbe tap (--bundle <id> | --pid <n> [--pid <n>…] | --system) --seconds N --out file.wav
//                  [--self-play file]   (also plays the file from this process: checks self-exclusion)
//   AudioProbe mic [--device <name>] --seconds N --out file.wav [--request]
//   AudioProbe permissions
//   AudioProbe play [--device <name substring>] [--volume 0..1] [--wait S] [--hold S] [--stop-engine-at S] file
//                  (--wait: the output runs S seconds before the phrase; --hold: S seconds after it;
//                   --stop-engine-at: stops the engine S seconds into the phrase the way a device change does)
//   AudioProbe file <path> [--realtime]
//   AudioProbe passthrough [--seconds N] [--file path] [--stop-engine-at S] [--trace]   («Свой голос»: the microphone, or
//                  the file in 10 ms buffers, relayed into BlackHole; BlackHole's input is recorded to measure
//                  latency and gaps; --stop-engine-at stops the output engine as a device change does)
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
                                            "--wait", "--hold", "--stop-engine-at", "--file"]

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
AudioProbe inputs [--bundle <call app id>]
AudioProbe tap (--bundle <id> | --pid <n> [--pid <n>...] | --system) --seconds N --out file.wav [--self-play file] [--mute]
AudioProbe mic [--device <name>] --seconds N --out file.wav [--request]
AudioProbe permissions
AudioProbe play [--device <name substring>] [--volume 0..1] [--wait S] [--hold S] [--stop-engine-at S] <file>
AudioProbe file <path> [--realtime]
AudioProbe passthrough [--seconds N] [--file path] [--stop-engine-at S] [--trace]
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
    // Timeline: buffers whose sample time does not follow the previous buffer, and the frames between.
    private var nextSample: Int64?
    private var gaps = 0
    private var missing: Int64 = 0

    /// A capture timestamp (sample time on the device's timeline), when the source gives one.
    func timeline(_ time: AVAudioTime?, frames: Int) {
        guard let time, time.isSampleTimeValid else { return }
        lock.lock()
        defer { lock.unlock() }
        if let expected = nextSample, time.sampleTime != expected {
            gaps += 1
            missing += time.sampleTime - expected
        }
        nextSample = time.sampleTime + Int64(frames)
    }

    func timelineReport() -> String? {
        lock.lock()
        defer { lock.unlock() }
        guard nextSample != nil else { return nil }
        return "timeline: \(gaps) discontinuities, \(missing) frames missing between buffers"
    }

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

    try source.start { buffer, time in
        meter.timeline(time, frames: Int(buffer.frameLength))
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
    if let report = meter.timelineReport() { print(report) }
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

/// Which apps read which input devices (HAL process objects, input scope), and the checklist's listener status
/// for a call app (`--bundle`; without it, all Mac audio is the source and any known call app counts).
func cmdInputs(_ args: Args) {
    let target = args.value("--bundle")
    guard let readers = AudioInputReaders.snapshot() else {
        print("The HAL process list could not be read.")
        return
    }
    func roleName(_ role: Int) -> String {
        [AudioRules.readerPonte: "Ponte", AudioRules.readerCall: "call app", AudioRules.readerOther: "other"][role] ?? "role \(role)"
    }
    func useName(_ use: Int) -> String {
        [AudioRules.useNone: "-", AudioRules.useCallBlackHole: "call app on BlackHole",
         AudioRules.useOtherBlackHole: "other on BlackHole", AudioRules.useCallRealMic: "CALL APP ON A REAL MIC"][use] ?? "use \(use)"
    }
    print("Input readers (kAudioProcessPropertyDevices, input scope), \(readers.count) pairs:")
    for r in readers.sorted(by: { ($0.pid, $0.device.id) < ($1.pid, $1.device.id) }) {
        let role = AudioRules.readerRole(ownerBundleID: r.ownerBundleID, targetBundleID: target, pid: r.pid, selfPID: getpid())
        let use = AudioRules.readerUse(role: role, kind: r.deviceKind, runningInput: r.isRunningInput)
        print("  pid \(r.pid)  \(r.bundleID ?? "-") → \(r.appName) [\(r.ownerBundleID)]  reads «\(r.device.name)» "
              + "(\(kindName(r.deviceKind)))  \(r.isRunningInput ? "running" : "not running")  role=\(roleName(role))  use=\(useName(use))")
    }
    var byApp: [String: [String]] = [:]
    for r in readers where r.isRunningInput { byApp[r.appName, default: []].append(r.device.name) }
    print("By app (running input):")
    for app in byApp.keys.sorted() { print("  \(app): \(byApp[app]!.joined(separator: ", "))") }
    if byApp.isEmpty { print("  none") }

    let catalog = CoreAudioDeviceCatalog()
    let blackHole = BlackHoleCheck.find(in: catalog)
    let check = AudioInputReaders.check(readers, targetBundleID: target, blackHolePresent: blackHole != nil)
    let statusName = [AudioRules.listenUnknown: "unknown", AudioRules.listenOK: "OK", AudioRules.listenNobody: "NOBODY",
                      AudioRules.listenRealMic: "REAL MIC", AudioRules.listenBoth: "BOTH",
                      AudioRules.listenNoBlackHole: "NO BLACKHOLE"][check.status] ?? "status \(check.status)"
    print("Source: \(target.map { "app \($0)" } ?? "all Mac audio (any known call app)")")
    print("Listener status: \(statusName)" + (check.reader.map { " — \($0.appName) reads «\($0.device.name)»" } ?? ""))
    if let blackHole {
        print("BlackHole input running somewhere (device flag, includes Ponte): \(AudioInputReaders.inputRunsSomewhere(blackHole) ? "yes" : "no")")
    }
    let listening = catalog.defaultOutput()
    let auto = catalog.autoMic(in: catalog.devices(), listening: listening)
    print("Default output: \(listening?.name ?? "none") (headphones-like: \(listening.map { AudioRules.isHeadphonesLike(kind: catalog.kind(of: $0)) } ?? false ? "yes" : "no"))"
          + ";  automatic mic for Ponte: \(auto?.name ?? "none")")
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
    if args.flags.contains("--mute") {
        // As Ponte does for the call app: the tapped audio is not heard on the Mac while it is read.
        source.hearOriginal = false
        print("mute: the tapped audio is muted on the Mac while tapped")
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

// MARK: Own voice

/// Mono samples with the host time of their first sample, gathered from a capture handler.
final class TimedRecording: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var samples: [Float] = []
    private(set) var startSeconds: Double?
    private(set) var rate: Double = 0
    private(set) var discontinuities = 0
    private var nextSample: Int64?

    func add(_ buffer: AVAudioPCMBuffer, _ time: AVAudioTime?) {
        let mono = PCM.samples(buffer)
        lock.withLock {
            if startSeconds == nil, let time, time.isHostTimeValid {
                startSeconds = AVAudioTime.seconds(forHostTime: time.hostTime)
                rate = buffer.format.sampleRate
            }
            guard startSeconds != nil else { return }
            if let time, time.isSampleTimeValid {
                if let expected = nextSample, time.sampleTime != expected { discontinuities += 1 }
                nextSample = time.sampleTime + Int64(buffer.frameLength)
            }
            samples += mono
        }
    }
}

/// Feeds a file as a microphone would: 10 ms buffers (480 frames at 48 kHz) in real time, stamped with the
/// host time.
final class FileMic: AudioSource {
    let outputFormat: AVAudioFormat
    private let samples: [Float]
    private var thread: Thread?
    private var running = false

    init(url: URL) throws {
        let mono = try FileSource.readMono(url: url)
        outputFormat = mono.format
        samples = PCM.samples(mono)
    }

    func start(handler: @escaping PCMHandler) throws {
        running = true
        let samples = samples, format = outputFormat
        let chunk = Int(format.sampleRate / 100)
        let t = Thread { [weak self] in
            let start = Date()
            var k = 0
            while self?.running == true, k * chunk < samples.count {
                let due = start.addingTimeInterval(Double(k * chunk) / format.sampleRate)
                let wait = due.timeIntervalSinceNow
                if wait > 0 { Thread.sleep(forTimeInterval: wait) }
                let n = min(chunk, samples.count - k * chunk)
                let b = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(n))!
                b.frameLength = AVAudioFrameCount(n)
                samples.withUnsafeBufferPointer { b.floatChannelData![0].update(from: $0.baseAddress! + k * chunk, count: n) }
                handler(b, AVAudioTime(hostTime: mach_absolute_time(), sampleTime: AVAudioFramePosition(k * chunk), atRate: format.sampleRate))
                k += 1
            }
        }
        t.qualityOfService = .userInteractive
        thread = t
        t.start()
    }

    func stop() { running = false }
}

/// «Свой голос» end to end: the microphone (or a file fed like one) → LiveRelay → DeviceAudioPlayer on BlackHole,
/// while BlackHole's own input is recorded in this process. The lag between the two recordings, found by
/// cross-correlation on the host clock, is the latency a call app reading BlackHole gets.
func cmdPassthrough(_ args: Args) async throws {
    let seconds = args.value("--seconds").flatMap(Double.init) ?? 6
    let catalog = CoreAudioDeviceCatalog()
    guard let blackHole = BlackHoleCheck.find(in: catalog) else { throw ProbeError.failed("BlackHole is not installed") }
    let source: AudioSource = try args.value("--file").map { try FileMic(url: URL(fileURLWithPath: $0)) } ?? MicSource(device: nil)
    print("source: \(args.value("--file") ?? "microphone \(catalog.defaultInput()?.name ?? "?")"), into \(blackHole.name); pid \(getpid())")
    let player = DeviceAudioPlayer(device: blackHole)
    try player.prepare()
    let recorder = MicSource(device: blackHole)
    let heard = TimedRecording()
    let said = TimedRecording()
    try recorder.start { buffer, time in heard.add(buffer, time) }
    try? await Task.sleep(nanoseconds: 300_000_000)
    let relay = LiveRelay(player: player)
    try source.start { buffer, time in
        said.add(buffer, time)
        relay.push(buffer)
    }
    if args.flags.contains("--trace") {
        Thread.detachNewThread {
            let start = Date()
            var line = ""
            while Date().timeIntervalSince(start) < seconds {
                line += player.streamQueuedMs().map { String(format: " %.0f", $0) } ?? " -"
                Thread.sleep(forTimeInterval: 0.05)
            }
            print("queued every 50 ms:" + line)
        }
    }
    if let at = args.value("--stop-engine-at").flatMap(Double.init), at >= 0, at < seconds {
        try? await Task.sleep(nanoseconds: UInt64(at * 1e9))
        print(String(format: "stopping the output engine at %.1f s, as a device change does", at))
        player.simulateDeviceStop()
        try? await Task.sleep(nanoseconds: UInt64((seconds - at) * 1e9))
    } else {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1e9))
    }
    source.stop()
    let stats = relay.stop()
    player.stopAll()
    try? await Task.sleep(nanoseconds: 300_000_000)
    recorder.stop()
    print("relay: sent \(stats.sent), dropped \(stats.dropped), trimmed \(stats.trimmed), refills \(stats.refills), max queued \(String(format: "%.1f", stats.maxQueuedMs)) ms")
    print("recorded: said \(said.samples.count) frames at \(Int(said.rate)) Hz (\(said.discontinuities) discontinuities), heard \(heard.samples.count) frames at \(Int(heard.rate)) Hz (\(heard.discontinuities) discontinuities)")
    guard let s0 = said.startSeconds, let h0 = heard.startSeconds, said.rate == heard.rate, said.rate > 0 else {
        throw ProbeError.failed("no common timeline (rates \(said.rate) and \(heard.rate))")
    }
    let rate = said.rate
    // Lag in samples between "said" sample n and "heard" sample n + offset + lag, for lags 0...300 ms.
    let offset = Int(((s0 - h0) * rate).rounded())
    let s = said.samples, h = heard.samples
    let maxLag = Int(0.3 * rate)
    let window = Int(1.0 * rate)
    func lag(from: Int) -> (lag: Int, score: Double) {
        var best = (lag: 0, score: -Double.infinity)
        guard from >= 0, from + window <= s.count else { return best }
        var energyS = 0.0
        for n in from..<(from + window) { energyS += Double(s[n]) * Double(s[n]) }
        for lag in 0...maxLag {
            var dot = 0.0, energyH = 0.0
            let base = from + offset + lag
            guard base >= 0, base + window <= h.count else { continue }
            for n in 0..<window {
                let a = Double(s[from + n]), b = Double(h[base + n])
                dot += a * b
                energyH += b * b
            }
            let score = dot / max(sqrt(energyS * energyH), 1e-30)
            if score > best.score { best = (lag, score) }
        }
        return best
    }
    let from = Int(0.5 * rate)
    let best = lag(from: from)
    print(String(format: "latency microphone → BlackHole input: %.1f ms (correlation %.3f) from 0.5 s", Double(best.lag) / rate * 1000, best.score))
    let late = lag(from: Int((seconds - 1.3) * rate))
    print(String(format: "latency microphone → BlackHole input: %.1f ms (correlation %.3f) from %.1f s",
                 Double(late.lag) / rate * 1000, late.score, seconds - 1.3))
    // Gaps: runs of exact zeros in what BlackHole heard while the relay ran (from the first relayed audio).
    let heardStart = max(from + offset + best.lag, 0)
    let heardEnd = min(heardStart + Int((seconds - 1) * rate), h.count)
    var gaps = 0, longest = 0, run = 0
    if heardStart < heardEnd {
        for n in heardStart..<heardEnd {
            if h[n] == 0 { run += 1 } else {
                if run >= Int(rate / 1000) { gaps += 1; longest = max(longest, run) }
                run = 0
            }
        }
        if run >= Int(rate / 1000) { gaps += 1; longest = max(longest, run) }
    }
    print(String(format: "dropouts (≥ 1 ms of exact zeros) over %.1f s: %d, longest %.1f ms",
                 Double(heardEnd - heardStart) / rate, gaps, Double(longest) / rate * 1000))
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
    case "inputs": cmdInputs(args)
    case "tap": try cmdTap(args)
    case "mic": try await cmdMic(args)
    case "permissions": cmdPermissions()
    case "play": try await cmdPlay(args)
    case "file": try cmdFile(args)
    case "passthrough": try await cmdPassthrough(args)
    default: throw ProbeError.usage("unknown command")
    }
} catch {
    FileHandle.standardError.write(Data("AudioProbe: \(error)\n".utf8))
    exit(1)
}
