// Tests for the app's pure logic: AppRules (the oracle for the t27 specs),
// TranslationLane, GlossaryTerm, TranscriptExporter, LaunchOptions, WAVFileSink.
// All fakes here are prefixed `AppTest` to avoid clashing with other agents' tests.
import AVFoundation
import Foundation
import PonteAudio
@testable import PonteApp
import PonteCore
import Testing

// MARK: - Fakes

final class AppTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current = Date(timeIntervalSince1970: 1_800_000_000)
    var now: Date { lock.withLock { current } }
    func advance(_ seconds: TimeInterval) { lock.withLock { current += seconds } }
    var function: @Sendable () -> Date { { [self] in self.now } }
}

final class AppTestSource: AudioSource {
    let outputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
    private var handler: PCMHandler?
    private(set) var stopped = false

    func start(handler: @escaping PCMHandler) throws { self.handler = handler }
    func stop() { stopped = true; handler = nil }

    /// Pushes `seconds` of audio; amplitude 0 is silence, 0.5 is clearly speech.
    func push(seconds: Double = 0.1, amplitude: Float = 0.5) {
        let frames = AVAudioFrameCount(seconds * 16_000)
        let buffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: frames)!
        buffer.frameLength = frames
        for i in 0..<Int(frames) { buffer.floatChannelData![0][i] = amplitude * sin(Float(i) * 0.3) }
        handler?(buffer, nil)
    }
}

final class AppTestTranscriber: Transcriber {
    let language: Lang
    private let lock = NSLock()
    private var continuation: AsyncStream<TranscriptEvent>.Continuation?
    private(set) var appendedFrames: AVAudioFrameCount = 0
    private(set) var prepared = 0
    private(set) var startCount = 0
    private(set) var finished = false
    /// Emitted as a final phrase when `finish()` flushes (push-to-talk release).
    var finalOnFinish: String?
    /// Timing reported for finals (Transcriber.timing(for:)); nil = unknown.
    var timings: [UUID: PhraseTiming] = [:]

    func timing(for id: UUID) -> PhraseTiming? { lock.withLock { timings[id] } }

    init(language: Lang) { self.language = language }

    func prepare() async throws { prepared += 1 }

    func start() throws -> AsyncStream<TranscriptEvent> {
        let (stream, continuation) = AsyncStream<TranscriptEvent>.makeStream()
        lock.withLock {
            self.continuation = continuation
            startCount += 1
        }
        return stream
    }

    func append(_ buffer: AVAudioPCMBuffer) { lock.withLock { appendedFrames += buffer.frameLength } }

    func finish() async {
        lock.withLock {
            if let text = finalOnFinish { continuation?.yield(.final(id: UUID(), text: text)) }
            continuation?.finish()
            finished = true
        }
    }

    func emit(_ event: TranscriptEvent) { _ = lock.withLock { continuation?.yield(event) } }
    func say(_ text: String) { emit(.final(id: UUID(), text: text)) }
}

struct AppTestPacksMissing: Error {}

final class AppTestTranslator: Translator {
    let name = "test"
    private(set) var calls: [(text: String, context: [String])] = []
    private(set) var prepareCount = 0
    var clock: AppTestClock?
    /// Simulated translation time, applied to the test clock.
    var cost: TimeInterval = 0
    /// Real delay per text, to check that order survives uneven translation times.
    var realDelay: [String: Duration] = [:]
    /// Like a missing language pack: prepare and translate throw.
    var broken = false

    func prepare(from: Lang, to: Lang) async throws {
        prepareCount += 1
        if broken { throw AppTestPacksMissing() }
    }

    func translate(_ text: String, from: Lang, to: Lang, context: [String]) async throws -> String {
        calls.append((text, context))
        if broken { throw AppTestPacksMissing() }
        if let delay = realDelay[text] { try await Task.sleep(for: delay) }
        clock?.advance(cost)
        return "T(\(text))"
    }
}

final class AppTestSynth: SpeechSynth {
    private(set) var texts: [String] = []
    private(set) var rates: [Int32] = []
    private var labels: [ObjectIdentifier: String] = [:]

    func synthesize(_ text: String, lang: Lang, ratePercent: Int32) async throws -> [AVAudioPCMBuffer] {
        rates.append(ratePercent)
        return try await synthesize(text, lang: lang)
    }

    func synthesize(_ text: String, lang: Lang) async throws -> [AVAudioPCMBuffer] {
        texts.append(text)
        let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 160)!
        buffer.frameLength = 160
        labels[ObjectIdentifier(buffer)] = text
        return [buffer]
    }

    func label(_ buffer: AVAudioPCMBuffer) -> String { labels[ObjectIdentifier(buffer)] ?? "?" }
}

final class AppTestPlayer: AudioPlayer {
    let device: AudioDevice? = nil
    private(set) var played: [AVAudioPCMBuffer] = []
    /// Buffer counts of each `play` call (the lane plays a phrase in one gapless call).
    private(set) var calls: [Int] = []
    private(set) var stopCount = 0
    var duration: Duration = .milliseconds(5)

    func play(_ buffer: AVAudioPCMBuffer) async {
        await play([buffer])
    }

    func play(_ buffers: [AVAudioPCMBuffer]) async {
        calls.append(buffers.count)
        played += buffers
        try? await Task.sleep(for: duration)
    }

    func stopAll() { stopCount += 1 }
}

@MainActor
final class AppTestRig {
    let clock = AppTestClock()
    let source = AppTestSource()
    let translator = AppTestTranslator()
    let synth = AppTestSynth()
    let player = AppTestPlayer()
    var transcribers: [AppTestTranscriber] = []
    var events: [LaneEvent] = []
    let lane: TranslationLane

    init(direction: Direction = .outgoing, mode: CaptureMode = .continuous, speak: Bool = true,
         memory: ConversationMemory = ConversationMemory()) {
        translator.clock = clock
        let box = AppTestBox()
        lane = TranslationLane(direction: direction, source: source,
                               makeTranscriber: {
                                   let t = AppTestTranscriber(language: direction.source)
                                   box.items.append(t)
                                   return t
                               },
                               translator: translator, synth: synth, player: player,
                               memory: memory, mode: mode, speechOutputEnabled: speak,
                               clock: clock.function)
        self.box = box
        lane.onEvent = { [weak self] in self?.events.append($0) }
    }

    private let box: AppTestBox
    var current: AppTestTranscriber? { box.items.last }
    var allTranscribers: [AppTestTranscriber] { box.items }

    var translatedLines: [ConversationLine] {
        events.compactMap { if case .translated(let line) = $0 { return line } else { return nil } }
    }
    var spokenTexts: [String] { player.played.map(synth.label) }
}

final class AppTestBox { var items: [AppTestTranscriber] = [] }

@MainActor
func appTestWait(_ what: String = "", timeout: Duration = .seconds(2),
                 _ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now + timeout
    while !condition() {
        if ContinuousClock.now > deadline {
            Issue.record("timed out waiting: \(what)")
            return
        }
        try await Task.sleep(for: .milliseconds(5))
    }
}

// MARK: - TranslationLane

@MainActor @Test func laneTranslatesFinalsInOrderWithContextAndSpeaks() async throws {
    let rig = AppTestRig(direction: .outgoing)
    try await rig.lane.start()
    let phrases = (1...6).map { "фраза \($0)" }
    rig.source.push()
    for p in phrases { rig.current?.say(p) }
    try await appTestWait("6 translations") { rig.translatedLines.count == 6 }
    try await appTestWait("6 spoken") { rig.player.played.count == 6 }

    #expect(rig.translatedLines.map(\.original) == phrases)
    #expect(rig.translatedLines.map(\.translation) == phrases.map { "T(\($0))" })
    #expect(rig.spokenTexts == phrases.map { "T(\($0))" })
    #expect(rig.translatedLines.allSatisfy { $0.direction == .outgoing && $0.latency != nil })
    // Context = the previous 4 phrases, oldest first.
    #expect(rig.translator.calls[0].context.isEmpty)
    #expect(rig.translator.calls[5].context == ["фраза 2", "фраза 3", "фраза 4", "фраза 5"])
    #expect((rig.current?.appendedFrames ?? 0) > 0)
    await rig.lane.stop()
    #expect(rig.source.stopped)
    #expect(rig.current?.finished == true)
}

@MainActor @Test func laneKeepsOrderWhenTranslationsTakeUnevenTime() async throws {
    let rig = AppTestRig(direction: .incoming)
    rig.translator.realDelay = ["um": .milliseconds(80), "dois": .milliseconds(1)]
    try await rig.lane.start()
    rig.current?.say("um")
    rig.current?.say("dois")
    rig.current?.say("três")
    try await appTestWait("3 spoken") { rig.player.played.count == 3 }
    #expect(rig.spokenTexts == ["T(um)", "T(dois)", "T(três)"])
    await rig.lane.stop()
}

@MainActor @Test func laneMeasuresLatencyFromTheTranscribersEndOfVoice() async throws {
    let rig = AppTestRig(direction: .incoming)
    rig.translator.cost = 0.3
    try await rig.lane.start()
    let voiceEnd = rig.clock.now                         // the speaker stops (t0)
    rig.clock.advance(0.5)                               // the transcriber finalizes at t0 + 0.5
    let id = UUID()
    rig.current?.timings[id] = PhraseTiming(audioStart: 0, audioEnd: 1.2, audioEndArrivedAt: voiceEnd,
                                            finalizedAt: rig.clock.now, forced: true)
    rig.current?.emit(.final(id: id, text: "Bom dia"))
    try await appTestWait("translation") { rig.translatedLines.count == 1 }
    let line = try #require(rig.translatedLines.first)
    #expect(abs((line.latency ?? -1) - 0.8) < 0.001)    // 0.5 recognition + 0.3 translation
    #expect(line.at == voiceEnd)
    await rig.lane.stop()
}

@MainActor @Test func laneWithoutTimingUsesTheLastPartial() async throws {
    let rig = AppTestRig(direction: .incoming)
    rig.translator.cost = 0.3
    try await rig.lane.start()
    let id = UUID()
    rig.current?.emit(.partial(id: id, text: "Bom"))
    try await appTestWait("partial") { rig.events.contains { if case .partial("Bom") = $0 { true } else { false } } }
    let partialAt = rig.clock.now
    rig.clock.advance(0.2)
    rig.current?.emit(.final(id: id, text: "Bom dia"))
    try await appTestWait("translation") { rig.translatedLines.count == 1 }
    #expect(rig.translatedLines.first?.at == partialAt)
    #expect(abs((rig.translatedLines.first?.latency ?? -1) - 0.5) < 0.001)
    await rig.lane.stop()
}

@MainActor @Test func laneStartsWithoutItsTranslatorAndRetries() async throws {
    let rig = AppTestRig(direction: .incoming)
    rig.translator.broken = true
    try await rig.lane.start()                           // recognition runs anyway
    #expect(rig.lane.isRunning)
    #expect(rig.lane.translatorError is AppTestPacksMissing)
    rig.current?.say("Olá")
    try await appTestWait("failed line") { rig.translatedLines.count == 1 }
    let failed = try #require(rig.translatedLines.first)
    #expect(failed.translation == nil && failed.translationError != nil)
    #expect(rig.events.contains { if case .translationFailed = $0 { true } else { false } })
    #expect(rig.translator.prepareCount == 1)            // no retry within PREPARE_RETRY_MS

    rig.translator.broken = false                        // the owner downloaded the packs
    rig.clock.advance(Double(AppRules.PREPARE_RETRY_MS) / 1000)
    rig.current?.say("Tchau")
    try await appTestWait("translated after retry") { rig.translatedLines.count == 2 }
    #expect(rig.translator.prepareCount == 2)
    #expect(rig.translatedLines.last?.translation == "T(Tchau)")
    #expect(rig.lane.translatorError == nil)
    await rig.lane.stop()
}

@MainActor @Test func lanePlaysEachPhraseInOneGaplessCall() async throws {
    let rig = AppTestRig(direction: .outgoing)
    try await rig.lane.start()
    rig.current?.say("um")
    rig.current?.say("dois")
    try await appTestWait("2 played") { rig.player.played.count == 2 }
    #expect(rig.player.calls == [1, 1])
    await rig.lane.stop()
}

@MainActor @Test func laneWithoutAutoSpeechStaysQuietButReplays() async throws {
    let rig = AppTestRig(direction: .incoming, speak: false)
    try await rig.lane.start()
    rig.current?.say("Olá")
    try await appTestWait("translation") { rig.translatedLines.count == 1 }
    try await Task.sleep(for: .milliseconds(30))
    #expect(rig.synth.texts.isEmpty)
    rig.lane.replayLast()
    try await appTestWait("replay") { rig.player.played.count == 1 }
    #expect(rig.spokenTexts == ["T(Olá)"])
    rig.lane.replayLast()
    try await appTestWait("second replay") { rig.player.played.count == 2 }
    #expect(rig.synth.texts.count == 1)    // the second replay reuses the audio
    await rig.lane.stop()
}

@MainActor @Test func pushToTalkOnlyUsesAudioWhileKeyIsHeld() async throws {
    let rig = AppTestRig(direction: .outgoing, mode: .pushToTalk)
    try await rig.lane.start()
    rig.source.push(seconds: 0.5)
    try await Task.sleep(for: .milliseconds(20))
    #expect(rig.allTranscribers.count == 1)
    #expect(rig.current?.appendedFrames == 0)      // key not held: nothing transcribed

    #expect(rig.current?.startCount == 0)          // prepared, but no session yet

    rig.lane.setKeyHeld(true)
    let segment = try #require(rig.current)        // the first press reuses the prepared one
    try await appTestWait("session started") { segment.startCount == 1 }
    rig.source.push(seconds: 0.2)
    segment.finalOnFinish = "Привет"
    try await appTestWait("audio appended") { segment.appendedFrames > 0 }
    #expect(segment.appendedFrames == 3_200)

    rig.lane.setKeyHeld(false)
    try await appTestWait("flushed and spoken") { rig.player.played.count == 1 }
    #expect(segment.finished)
    #expect(rig.spokenTexts == ["T(Привет)"])

    rig.source.push(seconds: 0.3)                  // released: ignored
    #expect(segment.appendedFrames == 3_200)

    rig.lane.setKeyHeld(true)                      // a new press opens a new session
    try await appTestWait("second segment") { rig.allTranscribers.count == 2 }
    try await appTestWait("second session started") { rig.current?.startCount == 1 }
    rig.source.push(seconds: 0.1)
    try await appTestWait("second audio") { (rig.current?.appendedFrames ?? 0) == 1_600 }
    await rig.lane.stop()
    #expect(rig.current?.finished == true)
}

@MainActor @Test func pauseStopsSpeechAndListening() async throws {
    let rig = AppTestRig(direction: .outgoing)
    try await rig.lane.start()
    let first = try #require(rig.current)
    rig.lane.isPaused = true
    try await appTestWait("segment closed") { first.finished }
    #expect(rig.player.stopCount >= 1)
    rig.source.push(seconds: 0.2)
    #expect(first.appendedFrames == 0)
    #expect(rig.allTranscribers.count == 1)

    rig.lane.isPaused = false
    try await appTestWait("listening again") { rig.allTranscribers.count == 2 }
    rig.current?.say("снова")
    try await appTestWait("spoken after pause") { rig.player.played.count == 1 }
    await rig.lane.stop()
}

@MainActor @Test func lanesShareConversationContext() async throws {
    let memory = ConversationMemory()
    let incoming = AppTestRig(direction: .incoming, memory: memory)
    let outgoing = AppTestRig(direction: .outgoing, memory: memory)
    try await incoming.lane.start()
    try await outgoing.lane.start()
    incoming.current?.say("Tudo bem?")
    try await appTestWait { incoming.translatedLines.count == 1 }
    outgoing.current?.say("Всё хорошо")
    try await appTestWait { outgoing.translatedLines.count == 1 }
    #expect(outgoing.translator.calls.first?.context == ["Tudo bem?"])
    await incoming.lane.stop()
    await outgoing.lane.stop()
}

@MainActor @Test func laneAppliesGlossary() async throws {
    let rig = AppTestRig(direction: .incoming)
    rig.lane.glossary = [GlossaryTerm(pt: "T", ru: "Т")]
    try await rig.lane.start()
    rig.current?.say("x")
    try await appTestWait { rig.translatedLines.count == 1 }
    #expect(rig.translatedLines.first?.translation == "Т(x)")
    await rig.lane.stop()
}

// MARK: - Glossary

@Test func glossaryForTheTranslatorFollowsTheDirection() {
    let terms = [GlossaryTerm(pt: " Trinity ", ru: "Тринити"), GlossaryTerm(pt: "Pix", ru: "")]
    #expect(GlossaryTerm.translatorGlossary(terms, direction: .incoming) == ["Trinity": "Тринити"])
    #expect(GlossaryTerm.translatorGlossary(terms, direction: .outgoing) == ["Тринити": "Trinity"])
}

@Test func glossaryReplacesUntranslatedTermsAsWholeWords() {
    let terms = [GlossaryTerm(pt: "Trinity", ru: "Тринити"),
                 GlossaryTerm(pt: "Dmitrii", ru: "Дмитрий"),
                 GlossaryTerm(pt: "", ru: "пусто")]
    let incoming = GlossaryTerm.apply(terms, to: "Привет, Dmitrii! Это про trinity, а не Trinityx.", direction: .incoming)
    #expect(incoming == "Привет, Дмитрий! Это про Тринити, а не Trinityx.")
    let outgoing = GlossaryTerm.apply(terms, to: "Olá, sou Дмитрий da Тринити.", direction: .outgoing)
    #expect(outgoing == "Olá, sou Dmitrii da Trinity.")
    #expect(GlossaryTerm.decode(GlossaryTerm.encode(terms)) == terms)
}

// MARK: - Transcript export

@Test func transcriptMarkdownAndFile() throws {
    let utc = TimeZone(identifier: "UTC")!
    let start = Date(timeIntervalSince1970: 1_791_725_100)   // 2026-10-11 13:25:00 UTC
    let lines = [
        ConversationLine(direction: .incoming, at: start + 5, original: "Bom dia!", translation: "Доброе утро!", latency: 1.24),
        ConversationLine(direction: .outgoing, at: start + 9, original: "Привет", translation: nil),
    ]
    #expect(TranscriptExporter.fileName(for: start, timeZone: utc) == "2026-10-11-1325.md")
    let md = TranscriptExporter.markdown(lines: lines, startedAt: start, sourceName: "Zoom", timeZone: utc)
    #expect(md.contains("# Ponte — звонок 11.10.2026, 13:25"))
    #expect(md.contains("**13:25:05 · Они** (pt-BR → ru-RU) · задержка 1.2 с"))
    #expect(md.contains("> Bom dia!\n\nДоброе утро!"))
    #expect(md.contains("**13:25:09 · Я** (ru-RU → pt-BR)"))
    #expect(md.contains("_перевод не получен_"))

    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ponte-tests-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: folder) }
    let first = try TranscriptExporter.write(lines: lines, startedAt: start, to: folder)
    let second = try TranscriptExporter.write(lines: lines, startedAt: start, to: folder)
    #expect(first.pathExtension == "md")
    #expect(first != second)
    #expect(second.lastPathComponent.hasSuffix("-2.md"))
    #expect(try String(contentsOf: first, encoding: .utf8).contains("Доброе утро!"))
    let tricky = [ConversationLine(direction: .incoming, at: start, original: "1. Preço: 5*2", translation: "- цена [итог]")]
    let escaped = TranscriptExporter.markdown(lines: tricky, startedAt: start, timeZone: utc)
    #expect(escaped.contains("> 1\\. Preço: 5\\*2\n\n\\- цена \\[итог\\]"))
}

// MARK: - Lane: echo guard, speech rate, empty phrases

@MainActor @Test func echoGuardDropsMicWhileRussianVoicePlaysThroughSpeakers() async throws {
    let rig = AppTestRig(direction: .outgoing)
    let echo = EchoGuard()
    rig.lane.echoGuard = echo
    try await rig.lane.start()
    let session = try #require(rig.current)
    try await appTestWait("session started") { session.startCount == 1 }

    echo.configure(speakerOutput: true)
    echo.setSpeaking(true, at: rig.clock.now)
    rig.source.push(seconds: 0.1)
    #expect(session.appendedFrames == 0)                       // blocked while speaking

    echo.setSpeaking(false, at: rig.clock.now)
    rig.clock.advance(0.5)
    rig.source.push(seconds: 0.1)
    #expect(session.appendedFrames == 0)                       // still inside the 700 ms tail
    rig.clock.advance(0.3)
    rig.source.push(seconds: 0.1)
    #expect(session.appendedFrames == 1_600)                   // tail over

    echo.configure(speakerOutput: false)                       // headphones: never blocked
    echo.setSpeaking(true, at: rig.clock.now)
    rig.source.push(seconds: 0.1)
    #expect(session.appendedFrames == 3_200)
    await rig.lane.stop()
}

@MainActor @Test func speechGetsFasterWhenPhrasesPileUp() async throws {
    let rig = AppTestRig(direction: .outgoing)
    rig.player.duration = .milliseconds(400)
    for text in ["a", "b", "c", "d"] { rig.translator.realDelay[text] = .milliseconds(40) }
    try await rig.lane.start()
    for text in ["a", "b", "c", "d"] { rig.current?.say(text) }
    try await appTestWait("4 synthesized") { rig.synth.rates.count == 4 }
    #expect(rig.synth.rates == [100, 110, 120, 130])
    await rig.lane.stop()
    #expect(rig.lane.speechBacklog == 0)
}

@MainActor @Test func emptyFinalIsDropped() async throws {
    let rig = AppTestRig(direction: .incoming)
    try await rig.lane.start()
    rig.current?.say("   ")
    rig.current?.say("ok")
    try await appTestWait { rig.translatedLines.count == 1 }
    #expect(rig.translator.calls.map(\.text) == ["ok"])
    await rig.lane.stop()
}

@MainActor @Test func discardedPhraseRemovesItsVolatileLine() async throws {
    let rig = AppTestRig(direction: .incoming)
    try await rig.lane.start()
    let id = UUID()
    rig.current?.emit(.partial(id: id, text: "hum"))
    rig.current?.emit(.final(id: id, text: ""))          // the recognizer decided it was noise
    try await appTestWait("cleared") {
        if case .partial("") = rig.events.last { return true }
        return false
    }
    let partials = rig.events.compactMap { if case .partial(let t) = $0 { t } else { nil } }
    #expect(partials == ["hum", ""])
    #expect(!rig.events.contains { if case .phrase = $0 { true } else { false } })
    #expect(rig.translator.calls.isEmpty)
    await rig.lane.stop()
}

// MARK: - AppRules (oracle for the t27 specs)

private typealias R = AppRules

@Test func rulesGateMachine() {
    func step(_ s: Int32, _ e: Int32, mode: Int32 = R.MODE_CONTINUOUS, key: Bool = false, paused: Bool = false) -> [Int32] {
        let x = R.gateStep(state: s, event: e, mode: mode, keyHeld: key, paused: paused)
        return [R.stepState(x), R.stepAction(x)]
    }
    #expect(step(R.GATE_STOPPED, R.GEV_START) == [R.GATE_STARTING, R.GACT_NONE])
    #expect(step(R.GATE_STARTING, R.GEV_STARTED) == [R.GATE_OPEN, R.GACT_OPEN_SEGMENT])
    #expect(step(R.GATE_STARTING, R.GEV_STARTED, mode: R.MODE_PUSH_TO_TALK) == [R.GATE_CLOSED, R.GACT_NONE])
    #expect(step(R.GATE_STARTING, R.GEV_STARTED, paused: true) == [R.GATE_CLOSED, R.GACT_NONE])
    #expect(step(R.GATE_STARTING, R.GEV_START_FAILED) == [R.GATE_STOPPED, R.GACT_NONE])
    #expect(step(R.GATE_STARTING, R.GEV_STOP) == [R.GATE_STOPPED, R.GACT_NONE])
    #expect(step(R.GATE_CLOSED, R.GEV_KEY, mode: R.MODE_PUSH_TO_TALK, key: true) == [R.GATE_OPEN, R.GACT_OPEN_SEGMENT])
    #expect(step(R.GATE_OPEN, R.GEV_KEY, mode: R.MODE_PUSH_TO_TALK, key: false) == [R.GATE_CLOSED, R.GACT_CLOSE_SEGMENT])
    #expect(step(R.GATE_OPEN, R.GEV_KEY, mode: R.MODE_CONTINUOUS, key: false) == [R.GATE_OPEN, R.GACT_NONE])
    #expect(step(R.GATE_OPEN, R.GEV_PAUSE, paused: true) == [R.GATE_CLOSED, R.GACT_CLOSE_SEGMENT])
    #expect(step(R.GATE_CLOSED, R.GEV_PAUSE, paused: false) == [R.GATE_OPEN, R.GACT_OPEN_SEGMENT])
    #expect(step(R.GATE_CLOSED, R.GEV_PAUSE, mode: R.MODE_PUSH_TO_TALK, key: true, paused: true) == [R.GATE_CLOSED, R.GACT_NONE])
    #expect(step(R.GATE_OPEN, R.GEV_MODE, mode: R.MODE_PUSH_TO_TALK) == [R.GATE_CLOSED, R.GACT_CLOSE_SEGMENT])
    #expect(step(R.GATE_CLOSED, R.GEV_MODE, mode: R.MODE_CONTINUOUS) == [R.GATE_OPEN, R.GACT_OPEN_SEGMENT])
    #expect(step(R.GATE_OPEN, R.GEV_STOP) == [R.GATE_STOPPED, R.GACT_CLOSE_SEGMENT])
    #expect(step(R.GATE_CLOSED, R.GEV_STOP) == [R.GATE_STOPPED, R.GACT_NONE])
    #expect(step(R.GATE_STOPPED, R.GEV_KEY, key: true) == [R.GATE_STOPPED, R.GACT_NONE])
    #expect(step(R.GATE_OPEN, R.GEV_START) == [R.GATE_OPEN, R.GACT_NONE])
    #expect(R.pack(3, 2) == 0x302 && R.stepState(0x302) == 3 && R.stepAction(0x302) == 2)
}

@Test func rulesPhrasePipeline() {
    func step(_ s: Int32, _ e: Int32, _ f: Int32 = 0) -> [Int32] {
        let x = R.phraseStep(stage: s, event: e, flags: f)
        return [R.stepState(x), R.stepAction(x)]
    }
    let all = R.PF_SPEAK_REQUESTED | R.PF_GENERATION_CURRENT | R.PF_SPEECH_ENABLED | R.PF_HAS_SYNTH | R.PF_HAS_PLAYER
    #expect(step(R.PH_LISTENING, R.PEV_PARTIAL) == [R.PH_LISTENING, R.PACT_SHOW_PARTIAL])
    #expect(step(R.PH_LISTENING, R.PEV_FINAL) == [R.PH_TRANSLATING, R.PACT_TRANSLATE])
    #expect(step(R.PH_LISTENING, R.PEV_FINAL, R.PF_EMPTY_TEXT) == [R.PH_DROPPED, R.PACT_DROP])
    #expect(step(R.PH_TRANSLATING, R.PEV_TRANSLATED, all) == [R.PH_SYNTH_QUEUED, R.PACT_SYNTHESIZE])
    for missing in [R.PF_SPEAK_REQUESTED, R.PF_GENERATION_CURRENT, R.PF_SPEECH_ENABLED, R.PF_HAS_SYNTH, R.PF_HAS_PLAYER] {
        #expect(step(R.PH_TRANSLATING, R.PEV_TRANSLATED, all & ~missing) == [R.PH_SHOWN, R.PACT_SHOW_ONLY])
    }
    #expect(step(R.PH_TRANSLATING, R.PEV_TRANSLATED, all | R.PF_PAUSED) == [R.PH_SHOWN, R.PACT_SHOW_ONLY])
    #expect(step(R.PH_TRANSLATING, R.PEV_TRANSLATED, all | R.PF_EMPTY_TEXT) == [R.PH_SHOWN, R.PACT_SHOW_ONLY])
    #expect(step(R.PH_TRANSLATING, R.PEV_TRANSLATE_FAILED, all) == [R.PH_SHOWN, R.PACT_SHOW_ONLY])
    #expect(step(R.PH_SYNTH_QUEUED, R.PEV_SYNTH_DEQUEUED, R.PF_GENERATION_CURRENT | R.PF_HAS_SYNTH) == [R.PH_SYNTH_QUEUED, R.PACT_RUN_SYNTH])
    #expect(step(R.PH_SYNTH_QUEUED, R.PEV_SYNTH_DEQUEUED, R.PF_HAS_SYNTH) == [R.PH_DROPPED, R.PACT_DROP])
    #expect(step(R.PH_SYNTH_QUEUED, R.PEV_SYNTHESIZED, R.PF_GENERATION_CURRENT | R.PF_HAS_AUDIO) == [R.PH_PLAY_QUEUED, R.PACT_ENQUEUE_PLAY])
    #expect(step(R.PH_SYNTH_QUEUED, R.PEV_SYNTHESIZED, R.PF_GENERATION_CURRENT) == [R.PH_DROPPED, R.PACT_DROP])
    #expect(step(R.PH_SYNTH_QUEUED, R.PEV_SYNTHESIZED, R.PF_HAS_AUDIO) == [R.PH_DROPPED, R.PACT_DROP])
    #expect(step(R.PH_SYNTH_QUEUED, R.PEV_SYNTH_FAILED, all) == [R.PH_DROPPED, R.PACT_DROP])
    let playable = R.PF_GENERATION_CURRENT | R.PF_HAS_PLAYER | R.PF_HAS_AUDIO
    #expect(step(R.PH_PLAY_QUEUED, R.PEV_PLAY_DEQUEUED, playable) == [R.PH_PLAYING, R.PACT_PLAY])
    #expect(step(R.PH_PLAY_QUEUED, R.PEV_PLAY_DEQUEUED, playable & ~R.PF_GENERATION_CURRENT) == [R.PH_DROPPED, R.PACT_DROP])
    #expect(step(R.PH_PLAYING, R.PEV_PLAYED) == [R.PH_SPOKEN, R.PACT_FINISH])
    #expect(step(R.PH_SHOWN, R.PEV_PLAYED) == [R.PH_SHOWN, R.PACT_NONE])
    #expect(R.speakRequested(speechEnabled: true, paused: false))
    #expect(!R.speakRequested(speechEnabled: true, paused: true))
    #expect(!R.speakRequested(speechEnabled: false, paused: false))
}

@Test func rulesSpeechControl() {
    #expect(R.cancelsSpeech(event: R.SCE_PAUSE, value: true))
    #expect(!R.cancelsSpeech(event: R.SCE_PAUSE, value: false))
    #expect(R.cancelsSpeech(event: R.SCE_VOICE, value: false))
    #expect(!R.cancelsSpeech(event: R.SCE_VOICE, value: true))
    #expect(R.cancelsSpeech(event: R.SCE_STOP, value: false))
    #expect(!R.cancelsSpeech(event: 99, value: true))
    #expect(R.replayAction(hasCachedAudio: true, hasLastTranslation: true, hasPlayer: true) == R.RPL_AUDIO)
    #expect(R.replayAction(hasCachedAudio: false, hasLastTranslation: true, hasPlayer: true) == R.RPL_SYNTH)
    #expect(R.replayAction(hasCachedAudio: false, hasLastTranslation: false, hasPlayer: true) == R.RPL_NONE)
    #expect(R.replayAction(hasCachedAudio: true, hasLastTranslation: true, hasPlayer: false) == R.RPL_NONE)
    #expect([-1, 0, 1, 2, 3, 4, 10].map { R.speechRatePercent(waiting: Int32($0)) } == [100, 100, 110, 120, 130, 130, 130])
}

@Test func rulesEchoAndTiming() {
    #expect(!R.echoGuardBlocksMic(speakerOutput: false, incomingSpeaking: true, msSinceSpeech: 0))
    #expect(R.echoGuardBlocksMic(speakerOutput: true, incomingSpeaking: true, msSinceSpeech: -1))
    #expect(R.echoGuardBlocksMic(speakerOutput: true, incomingSpeaking: false, msSinceSpeech: 699))
    #expect(!R.echoGuardBlocksMic(speakerOutput: true, incomingSpeaking: false, msSinceSpeech: 700))
    #expect(!R.echoGuardBlocksMic(speakerOutput: true, incomingSpeaking: false, msSinceSpeech: -1))
    #expect(R.echoGuardApplies(speakerOutput: true, micIsLive: true))
    #expect(!R.echoGuardApplies(speakerOutput: true, micIsLive: false))
    #expect(!R.echoGuardApplies(speakerOutput: false, micIsLive: true))
    #expect(R.phraseEndChoice(msSinceTimedEnd: 0, msSincePartial: 10) == R.END_TRANSCRIBER)
    #expect(R.phraseEndChoice(msSinceTimedEnd: 700, msSincePartial: -1) == R.END_TRANSCRIBER)
    #expect(R.phraseEndChoice(msSinceTimedEnd: -1, msSincePartial: 0) == R.END_LAST_PARTIAL)
    #expect(R.phraseEndChoice(msSinceTimedEnd: -1, msSincePartial: -1) == R.END_NOW)
    #expect(R.latencyMs(endMs: 1_000, readyMs: 2_250) == 1_250)
    #expect(R.latencyMs(endMs: 2_000, readyMs: 1_000) == 0)
    #expect([0, 3, 4, 5, 9].map { R.contextOverflow(count: Int32($0)) } == [0, 0, 0, 1, 5])
}

@Test func rulesRunStateBannersAndButtons() {
    #expect(R.toggleRun(runState: R.RUN_IDLE) == R.TOGGLE_START)
    #expect(R.toggleRun(runState: R.RUN_RUNNING) == R.TOGGLE_STOP)
    #expect(R.toggleRun(runState: R.RUN_STARTING) == R.TOGGLE_NONE)
    #expect(R.toggleRun(runState: R.RUN_STOPPING) == R.TOGGLE_NONE)
    #expect(R.runStateAfterStart(lanesStarted: 0) == R.RUN_IDLE)
    #expect(R.runStateAfterStart(lanesStarted: 1) == R.RUN_RUNNING)
    #expect(R.startBanner(lanesFailed: 1, packsMissing: true, hasBlackHole: false, speakerOutput: true) == R.BAN_FAILED_PACKS)
    #expect(R.startBanner(lanesFailed: 2, packsMissing: false, hasBlackHole: true, speakerOutput: false) == R.BAN_FAILED_OTHER)
    #expect(R.startBanner(lanesFailed: 0, packsMissing: false, hasBlackHole: false, speakerOutput: true) == R.BAN_NO_BLACKHOLE)
    #expect(R.startBanner(lanesFailed: 0, packsMissing: false, hasBlackHole: true, speakerOutput: true) == R.BAN_SPEAKERS)
    #expect(R.startBanner(lanesFailed: 0, packsMissing: true, hasBlackHole: true, speakerOutput: false) == R.BAN_NONE)
    func after(_ lanes: Int32, _ translators: Int32, packs: Bool = false, bh: Bool = true, speakers: Bool = false) -> Int32 {
        R.startBannerAfterStart(lanesFailed: lanes, translatorsFailed: translators, packsMissing: packs,
                                hasBlackHole: bh, speakerOutput: speakers)
    }
    #expect(after(1, 1, packs: true) == R.BAN_FAILED_PACKS)
    #expect(after(1, 0) == R.BAN_FAILED_OTHER)
    #expect(after(0, 2, packs: true, bh: false) == R.BAN_NO_PACKS)
    #expect(after(0, 1, bh: false, speakers: true) == R.BAN_NO_TRANSLATOR)
    #expect(after(0, 0, bh: false) == R.BAN_NO_BLACKHOLE)
    #expect(after(0, 0, speakers: true) == R.BAN_SPEAKERS)
    #expect(after(0, 0) == R.BAN_NONE)
    #expect(R.retryTranslatorPrepare(prepared: false, msSinceAttempt: -1))
    #expect(!R.retryTranslatorPrepare(prepared: false, msSinceAttempt: 4_999))
    #expect(R.retryTranslatorPrepare(prepared: false, msSinceAttempt: 5_000))
    #expect(!R.retryTranslatorPrepare(prepared: true, msSinceAttempt: 60_000))
    #expect(R.autosaveOnStop(lines: 1) && !R.autosaveOnStop(lines: 0))

    func on(_ b: Int32, _ run: Int32, inc: Int32 = 0, out: Int32 = 0, bh: Bool = true, busy: Bool = false) -> Bool {
        R.buttonEnabled(button: b, runState: run, incomingLines: inc, outgoingLines: out, hasBlackHole: bh, busy: busy)
    }
    #expect(on(R.BTN_START_STOP, R.RUN_IDLE) && on(R.BTN_START_STOP, R.RUN_RUNNING))
    #expect(!on(R.BTN_START_STOP, R.RUN_STARTING) && !on(R.BTN_START_STOP, R.RUN_STOPPING))
    #expect(on(R.BTN_SOURCE, R.RUN_IDLE) && !on(R.BTN_SOURCE, R.RUN_RUNNING))
    #expect(!on(R.BTN_REPLAY_INCOMING, R.RUN_RUNNING) && on(R.BTN_REPLAY_INCOMING, R.RUN_RUNNING, inc: 1))
    #expect(!on(R.BTN_REPLAY_INCOMING, R.RUN_IDLE, inc: 1))
    #expect(on(R.BTN_REPLAY_OUTGOING, R.RUN_RUNNING, out: 1) && !on(R.BTN_REPLAY_OUTGOING, R.RUN_RUNNING, inc: 1))
    #expect(on(R.BTN_SAVE_TRANSCRIPT, R.RUN_IDLE, out: 1) && !on(R.BTN_SAVE_TRANSCRIPT, R.RUN_RUNNING))
    #expect(on(R.BTN_PAUSE_VOICE, R.RUN_IDLE) && on(R.BTN_MODE, R.RUN_STOPPING) && on(R.BTN_VOICE_TOGGLE, R.RUN_STARTING))
    #expect(on(R.BTN_TALK_PAD, R.RUN_RUNNING) && !on(R.BTN_TALK_PAD, R.RUN_IDLE))
    #expect(on(R.BTN_TEST_CALL, R.RUN_IDLE) && !on(R.BTN_TEST_CALL, R.RUN_IDLE, bh: false) && !on(R.BTN_TEST_CALL, R.RUN_IDLE, busy: true))
    #expect(on(R.BTN_TEST_HEADPHONES, R.RUN_IDLE, bh: false) && !on(R.BTN_TEST_HEADPHONES, R.RUN_IDLE, busy: true))
    #expect(!on(0, R.RUN_RUNNING))
}

@Test func rulesLightsAndLatency() {
    #expect(R.audioLight(runState: R.RUN_IDLE, laneActive: true, msSinceStart: 0, msSinceBuffer: 0) == R.LIGHT_UNKNOWN)
    #expect(R.audioLight(runState: R.RUN_STARTING, laneActive: false, msSinceStart: 0, msSinceBuffer: -1) == R.LIGHT_BUSY)
    #expect(R.audioLight(runState: R.RUN_RUNNING, laneActive: false, msSinceStart: 0, msSinceBuffer: -1) == R.LIGHT_BAD)
    #expect(R.audioLight(runState: R.RUN_RUNNING, laneActive: true, msSinceStart: 9_000, msSinceBuffer: 1_999) == R.LIGHT_OK)
    #expect(R.audioLight(runState: R.RUN_RUNNING, laneActive: true, msSinceStart: 3_999, msSinceBuffer: -1) == R.LIGHT_BUSY)
    #expect(R.audioLight(runState: R.RUN_RUNNING, laneActive: true, msSinceStart: 4_000, msSinceBuffer: 2_000) == R.LIGHT_BAD)
    #expect(R.blackHoleLight(found: true) == R.LIGHT_OK && R.blackHoleLight(found: false) == R.LIGHT_BAD)
    #expect(R.modelsLight(runState: R.RUN_IDLE, everStarted: false, lanesStarted: 0, lanesFailed: 0) == R.LIGHT_UNKNOWN)
    #expect(R.modelsLight(runState: R.RUN_STARTING, everStarted: true, lanesStarted: 0, lanesFailed: 0) == R.LIGHT_BUSY)
    #expect(R.modelsLight(runState: R.RUN_RUNNING, everStarted: true, lanesStarted: 2, lanesFailed: 0) == R.LIGHT_OK)
    #expect(R.modelsLight(runState: R.RUN_RUNNING, everStarted: true, lanesStarted: 1, lanesFailed: 1) == R.LIGHT_BAD)
    #expect(R.modelsLight(runState: R.RUN_IDLE, everStarted: true, lanesStarted: 2, lanesFailed: 0) == R.LIGHT_OK)
    #expect([-1, 0, 2_000, 2_001, 4_000, 4_001].map { R.latencyColor(ms: Int64($0)) }
            == [R.LAT_NONE, R.LAT_GOOD, R.LAT_GOOD, R.LAT_SLOW, R.LAT_SLOW, R.LAT_BAD])

    func source(_ run: Int32 = R.RUN_RUNNING, active: Bool = true, tap: Int32 = R.TAP_CAPTURING,
                start: Int64 = 9_000, buffer: Int64 = 100, signal: Int64 = 100) -> Int32 {
        R.sourceLight(runState: run, laneActive: active, tapStatus: tap, msSinceStart: start,
                      msSinceBuffer: buffer, msSinceSignal: signal)
    }
    #expect(source() == R.LIGHT_OK)
    #expect(source(R.RUN_STARTING) == R.LIGHT_BUSY)
    #expect(source(R.RUN_IDLE, tap: R.TAP_FAILED) == R.LIGHT_UNKNOWN)
    #expect(source(active: false) == R.LIGHT_BAD)
    #expect(source(tap: R.TAP_FAILED) == R.LIGHT_BAD)
    #expect(source(tap: R.TAP_WAITING, buffer: -1, signal: -1) == R.LIGHT_BUSY)
    #expect(source(signal: -1) == R.LIGHT_WARN)                          // only zeros for 9 s
    #expect(source(start: 7_999, signal: -1) == R.LIGHT_OK)              // too early to tell
    #expect(source(tap: R.TAP_NONE, signal: -1) == R.LIGHT_OK)           // a test file is not a tap
    #expect(source(start: 9_000, buffer: 2_000) == R.LIGHT_BAD)          // buffers stopped
    #expect(R.captureCheckLight(tapStatus: R.TAP_CAPTURING, framesSeen: true, signalSeen: true) == R.LIGHT_OK)
    #expect(R.captureCheckLight(tapStatus: R.TAP_CAPTURING, framesSeen: true, signalSeen: false) == R.LIGHT_WARN)
    #expect(R.captureCheckLight(tapStatus: R.TAP_CAPTURING, framesSeen: false, signalSeen: false) == R.LIGHT_BAD)
    #expect(R.captureCheckLight(tapStatus: R.TAP_FAILED, framesSeen: true, signalSeen: true) == R.LIGHT_BAD)
}

@Test func rulesSourceTranslatorPushToTalk() {
    #expect(R.sourceSection(isKnownCallApp: true, isPlayingAudio: false) == R.SRC_CALLS)
    #expect(R.sourceSection(isKnownCallApp: false, isPlayingAudio: true) == R.SRC_PLAYING)
    #expect(R.sourceSection(isKnownCallApp: false, isPlayingAudio: false) == R.SRC_OTHER)
    #expect(R.translatorChoice(preferred: R.TR_CLAUDE, claudeAvailable: true) == R.TR_CLAUDE)
    #expect(R.translatorChoice(preferred: R.TR_CLAUDE, claudeAvailable: false) == R.TR_APPLE)
    #expect(R.translatorChoice(preferred: R.TR_APPLE, claudeAvailable: true) == R.TR_APPLE)
    // NSEvent flags: Option = 0x80000 plus device bit 0x20 (left) or 0x40 (right).
    #expect(R.pttKeyDown(key: R.PTT_RIGHT_OPTION, flags: 0x80040))
    #expect(!R.pttKeyDown(key: R.PTT_RIGHT_OPTION, flags: 0x80020))
    #expect(R.pttKeyDown(key: R.PTT_RIGHT_COMMAND, flags: 0x100010))
    #expect(!R.pttKeyDown(key: R.PTT_RIGHT_COMMAND, flags: 0x100008))
    #expect(R.pttKeyDown(key: R.PTT_RIGHT_SHIFT, flags: 0x20004))
    #expect(R.pttKeyDown(key: R.PTT_RIGHT_CONTROL, flags: 0x42000))
    #expect(R.pttKeyDown(key: R.PTT_FN, flags: 0x800000))
    #expect(!R.pttKeyDown(key: R.PTT_FN, flags: 0x40))
    #expect(!R.pttKeyDown(key: 9, flags: 0xFFFF_FFFF))
    #expect(R.pttScope(running: false, mode: R.MODE_PUSH_TO_TALK, accessibilityGranted: true) == R.PTT_SCOPE_NONE)
    #expect(R.pttScope(running: true, mode: R.MODE_CONTINUOUS, accessibilityGranted: true) == R.PTT_SCOPE_NONE)
    #expect(R.pttScope(running: true, mode: R.MODE_PUSH_TO_TALK, accessibilityGranted: false) == R.PTT_SCOPE_WINDOW)
    #expect(R.pttScope(running: true, mode: R.MODE_PUSH_TO_TALK, accessibilityGranted: true) == R.PTT_SCOPE_GLOBAL)
}

@Test func rulesWizardAndOverlay() {
    #expect((0...5).map { R.wizardNext(step: Int32($0)) } == [1, 2, 3, 4, 5, R.WZ_NONE])
    #expect((0...5).map { R.wizardPrevious(step: Int32($0)) } == [R.WZ_NONE, 0, 1, 2, 3, 4])
    #expect(R.wizardNext(step: -1) == R.WZ_NONE && R.wizardPrevious(step: 6) == R.WZ_NONE)
    func mark(_ s: Int32, mic: Bool = false, speech: Bool = false, models: Int32 = 0, packs: Int32 = 0,
              bh: Bool = false, test: Bool = false) -> Int32 {
        R.wizardStepMark(step: s, micGranted: mic, speechGranted: speech, modelsReady: models,
                         packsReady: packs, blackHoleFound: bh, testPhraseOK: test)
    }
    #expect(mark(R.WZ_PERMISSIONS, mic: true, speech: true) == R.MARK_DONE)
    #expect(mark(R.WZ_PERMISSIONS, mic: true) == R.MARK_NONE)
    #expect(mark(R.WZ_MODELS, models: 2) == R.MARK_DONE && mark(R.WZ_MODELS, models: 1) == R.MARK_NONE)
    #expect(mark(R.WZ_PACKS, packs: 2) == R.MARK_DONE && mark(R.WZ_PACKS, packs: 1) == R.MARK_NONE)
    #expect(mark(R.WZ_BLACKHOLE, bh: true) == R.MARK_DONE && mark(R.WZ_BLACKHOLE) == R.MARK_WARN)
    #expect(mark(R.WZ_CALL_APPS, test: true) == R.MARK_DONE && mark(R.WZ_CALL_APPS) == R.MARK_NONE)
    #expect(mark(R.WZ_DONE, mic: true, speech: true, models: 2, packs: 2, bh: true, test: true) == R.MARK_NONE)
    #expect(R.wizardShowOnLaunch(setupCompleted: false, forcedStep: -1))
    #expect(!R.wizardShowOnLaunch(setupCompleted: true, forcedStep: -1))
    #expect(R.wizardShowOnLaunch(setupCompleted: true, forcedStep: 3))
    #expect(!R.wizardShowOnLaunchInMode(setupCompleted: false, forcedStep: -1, testMode: true))
    #expect(R.wizardShowOnLaunchInMode(setupCompleted: false, forcedStep: -1, testMode: false))
    #expect(R.wizardShowOnLaunchInMode(setupCompleted: true, forcedStep: 2, testMode: true))
    #expect(R.wizardCompletedAfterClose(wasCompleted: false, finished: true))
    #expect(!R.wizardCompletedAfterClose(wasCompleted: false, finished: false))
    #expect(R.wizardCompletedAfterClose(wasCompleted: true, finished: false))

    #expect([0, 13, 14, 16, 30, 40, 41, 99].map { R.translationFontSize(stored: Int32($0)) } == [24, 24, 16, 16, 30, 40, 40, 40])
    #expect(R.overlayLineCount(available: 0, panelHeight: 500, fontSize: 24) == 0)
    #expect(R.overlayLineCount(available: 5, panelHeight: 130, fontSize: 24) == 2)   // 2 × (31 + 8) = 78 ≤ 98
    #expect(R.overlayLineCount(available: 1, panelHeight: 130, fontSize: 24) == 1)
    #expect(R.overlayLineCount(available: 5, panelHeight: 90, fontSize: 40) == 1)    // 2 × 60 > 58
    #expect(R.overlayLineCount(available: 5, panelHeight: 1_000, fontSize: 16) == 2)
}

@Test func rulesTranscriptBytes() {
    func name(_ y: Int32, _ mo: Int32, _ d: Int32, _ h: Int32, _ mi: Int32, _ a: Int32) -> String {
        String(decoding: R.transcriptFileName(year: y, month: mo, day: d, hour: h, minute: mi, attempt: a), as: UTF8.self)
    }
    #expect(name(2026, 10, 11, 9, 5, 1) == "2026-10-11-0905.md")
    #expect(name(2026, 1, 2, 23, 59, 0) == "2026-01-02-2359.md")
    #expect(name(2026, 10, 11, 14, 0, 2) == "2026-10-11-1400-2.md")
    #expect(name(2026, 10, 11, 14, 0, 12) == "2026-10-11-1400-12.md")

    func esc(_ s: String) -> String { String(decoding: R.markdownEscape(Array(s.utf8)), as: UTF8.self) }
    #expect(esc("Olá, tudo bem?") == "Olá, tudo bem?")
    #expect(esc("5*2 = 10 [ok] <b> a_b `x` #1 | ~ & \\") == "5\\*2 = 10 \\[ok\\] \\<b\\> a\\_b \\`x\\` \\#1 \\| \\~ \\& \\\\")
    #expect(esc("- пункт") == "\\- пункт")
    #expect(esc("  + plus") == "  \\+ plus")
    #expect(esc("=== титул") == "\\=== титул")
    #expect(esc("1. Первое") == "1\\. Первое")
    #expect(esc("2026) год") == "2026\\) год")
    #expect(esc("10.5 реалов") == "10\\.5 реалов")
    #expect(esc("в 10.5") == "в 10.5")
    #expect(esc("a - b") == "a - b")
    #expect(esc("строка\r\n- вторая\n3) третья") == "строка\n\\- вторая\n3\\) третья")
    #expect(R.markdownEscape([]) == [])
    #expect(TranscriptExporter.escaped(String(repeating: "я", count: 1_100)).utf8.count == 2_048)
}

// MARK: - Test mode

@Test func launchOptionsReadTheArgumentDomain() {
    let none = LaunchOptions(arguments: [:])
    #expect(!none.isTestMode && !none.autostart && none.wizardStep == AppRules.WZ_NONE)
    let options = LaunchOptions(arguments: [
        "PonteIncomingFile": "/tmp/pt_1.wav", "PonteOutgoingFile": "~/ru_1.wav",
        "PonteOutgoingSink": "/tmp/out.wav", "PonteTranscriptDir": "/tmp/e2e",
        "PonteAutostart": "YES", "PonteWizardStep": "2", "PonteAppearance": "dark",
    ])
    #expect(options.isTestMode && options.autostart)
    #expect(options.incomingFile?.path == "/tmp/pt_1.wav")
    #expect(options.outgoingFile?.path == NSHomeDirectory() + "/ru_1.wav")
    #expect(options.outgoingSink?.lastPathComponent == "out.wav")
    #expect(options.transcriptDir?.path == "/tmp/e2e")
    #expect(options.wizardStep == 2 && options.appearance == "dark")
    #expect(!LaunchOptions(arguments: ["PonteAutostart": "NO"]).autostart)
    #expect(LaunchOptions(arguments: ["PonteTranscriptDir": "/tmp/x"]).isTestMode)
}

/// The synthesizer renders 22 050 Hz mono; the call output runs at 48 kHz. The sink resamples
/// like DeviceAudioPlayer: same duration, same pitch, nothing lost at the end.
@Test func wavSinkResamplesSynthesizedSpeechTo48kHz() async throws {
    let rate = 22_050.0
    let tone = (0..<Int(rate)).map { Float(0.5 * sin(2 * Double.pi * 440 * Double($0) / rate)) }
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ponte-sink-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: folder) }
    let url = folder.appendingPathComponent("out.wav")
    let sink = WAVFileSink(url: url, realtime: false)
    await sink.play([PCM.buffer(tone, sampleRate: rate)])
    await sink.play([PCM.buffer(Array(tone[..<11_025]), sampleRate: rate), PCM.buffer(Array(tone[11_025...]), sampleRate: rate)])
    #expect(sink.lastError == nil)

    let file = try AVAudioFile(forReading: url)
    #expect(file.fileFormat.sampleRate == 48_000)
    #expect(file.fileFormat.channelCount == 1)
    #expect(abs(Int(file.length) - 96_000) <= 64)               // 2 × 1 s
    let read = PCM.samples(try FileSource.readMono(url: url))
    let first = Array(read[2_000..<46_000])                     // skip the edges of the resampler
    var crossings = 0
    for i in 1..<first.count where (first[i - 1] < 0) != (first[i] < 0) { crossings += 1 }
    let hz = Double(crossings) / 2 / (Double(first.count) / 48_000)
    #expect(abs(hz - 440) < 3)
    #expect(abs(AudioRules.rms(first) - Float(0.5 / 2.0.squareRoot())) < 0.01)
}

/// A test file is followed by silence, like a live source, until stop().
@Test func testFileSourceContinuesWithSilence() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ponte-file-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let url = folder.appendingPathComponent("tone.wav")
    let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16_000.0,
                                   AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false]
    do {
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        try file.write(from: PCM.buffer([Float](repeating: 0.5, count: 3_200), sampleRate: 16_000))   // 0.2 s
        file.close()
    }
    final class Box: @unchecked Sendable {
        let lock = NSLock()
        var frames = 0, loud = 0, ended = false
    }
    let box = Box()
    let source = TestFileSource(url: url)
    source.onFileEnd = { box.lock.withLock { box.ended = true } }
    try source.start { buffer, _ in
        let peak = AudioRules.peak(PCM.samples(buffer))
        box.lock.withLock {
            box.frames += Int(buffer.frameLength)
            if peak > 0 { box.loud += Int(buffer.frameLength) }
        }
    }
    try await Task.sleep(for: .milliseconds(700))
    source.stop()
    let (frames, loud, ended) = box.lock.withLock { (box.frames, box.loud, box.ended) }
    #expect(ended)
    #expect(loud == 3_200)
    #expect(frames >= 3_200 + 4 * 1_600)          // about 0.5 s of silence after the file
    try await Task.sleep(for: .milliseconds(250))
    #expect(box.lock.withLock { box.frames } <= frames + 1_600)   // stopped
}
