import AVFoundation
import Foundation
import os
import PonteAudio
import PonteCore
import PontePeer

// One direction of the call:
// AudioSource → Transcriber → (.final) → Translator (+ last 4 phrases as context)
// → ConversationLine → optional SpeechSynth → AudioPlayer.
// Typed text (speakText, TextRules) enters the same pipeline as final phrases, without the transcriber.
//
// Every decision is asked from AppRules (gate machine, phrase pipeline, speech
// cancel, replay, speech rate, echo guard, phrase end, translator retry) and AudioRules
// (levels). This file only does the plumbing: tasks, queues, locks, generations. It knows
// only the PonteCore protocols, so tests drive it with fakes.

/// How audio reaches the transcriber.
enum CaptureMode: String, CaseIterable, Codable, Sendable {
    /// «Авто»: everything is transcribed; every final phrase is translated (and spoken).
    case continuous
    /// Only audio captured while the key is held; the phrase is flushed on release.
    case pushToTalk

    var ruleCode: Int32 { self == .continuous ? AppRules.MODE_CONTINUOUS : AppRules.MODE_PUSH_TO_TALK }
}

enum LaneEvent {
    /// Volatile text of the current phrase; "" clears it (also when the phrase was discarded).
    case partial(String)
    /// A final phrase arrived; translation is pending.
    case phrase(ConversationLine)
    /// The same line with translation and latency filled in. If the translation failed,
    /// `translation` is nil and `translationError` says why.
    case translated(ConversationLine)
    /// The translator failed on a phrase (sent right after its `.translated`).
    case translationFailed(Error)
    /// Synthesized speech for this lane is playing.
    case speaking(Bool)
    /// A non-fatal problem worth showing to the user.
    case problem(String)
    /// This lane's voice starts or stops playing: `text` is what it says (the translation), nil for «Свой голос».
    /// The outgoing lane plays into the call, so the other Russians' Ponte apps are told (PeerLink.sendVoice).
    case voiceOut(text: String?, playing: Bool)
}

/// When the owner held the talk key: the incoming lane drops his own voice coming back from the call
/// (AppRules.ownTalkDrops, lane_rules.t27). Thread-safe.
final class OwnTalkLog: @unchecked Sendable {
    private let lock = NSLock()
    /// Recent talk-key intervals in ms since 1970; end -1 while the key is held.
    private var intervals: [(start: Int64, end: Int64)] = []

    func setHeld(_ held: Bool, at date: Date) {
        let ms = Int64((date.timeIntervalSince1970 * 1000).rounded())
        lock.withLock {
            if held {
                if intervals.last?.end != -1 { intervals.append((ms, -1)) }
                if intervals.count > 20 { intervals.removeFirst(intervals.count - 20) }
            } else if let last = intervals.indices.last, intervals[last].end == -1 {
                intervals[last].end = ms
            }
        }
    }

    func drops(start: Date, end: Date) -> Bool {
        let s = Int64((start.timeIntervalSince1970 * 1000).rounded())
        let e = Int64((end.timeIntervalSince1970 * 1000).rounded())
        let snapshot = lock.withLock { intervals }
        return snapshot.contains { AppRules.ownTalkDrops(phraseStartMs: s, phraseEndMs: e, talkStartMs: $0.start, talkEndMs: $0.end) }
    }
}

/// The last phrases of the whole conversation (both lanes), oldest first.
final class ConversationMemory: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []

    func snapshot() -> [String] { lock.withLock { items } }

    func add(_ phrase: String) {
        lock.withLock {
            items.append(phrase)
            let overflow = Int(AppRules.contextOverflow(count: Int32(items.count)))
            if overflow > 0 { items.removeFirst(overflow) }
        }
    }

    func reset() { lock.withLock { items.removeAll() } }
}

/// Shared between the lanes: is Ponte's Russian voice playing through the Mac's speakers?
/// Read on the capture thread of the outgoing lane.
final class EchoGuard: @unchecked Sendable {
    private let lock = NSLock()
    private var speakerOutput = false
    private var speaking = false
    private var lastSpeechAt: Date?
    private var lastPeerAt: Date?

    func configure(speakerOutput: Bool) {
        lock.withLock {
            self.speakerOutput = speakerOutput
            speaking = false
            lastSpeechAt = nil
        }
    }

    func setSpeaking(_ on: Bool, at now: Date) {
        lock.withLock {
            if AppRules.echoMarksTime(wasSpeaking: speaking, nowSpeaking: on) { lastSpeechAt = now }
            speaking = on
        }
    }

    /// «Русские в звонке»: another Russian's voice just played (on speakers the mic would hear it, like the Russian voice).
    func notePeerAudio(at now: Date) { lock.withLock { lastPeerAt = now } }

    func blocksMic(at now: Date) -> Bool {
        lock.withLock {
            AppRules.echoGuardBlocksMic(speakerOutput: speakerOutput, incomingSpeaking: speaking,
                                        msSinceSpeech: lastSpeechAt.map { millis(now.timeIntervalSince($0)) } ?? -1)
                || AppRules.echoGuardBlocksMic(speakerOutput: speakerOutput, incomingSpeaking: false,
                                               msSinceSpeech: lastPeerAt.map { millis(now.timeIntervalSince($0)) } ?? -1)
        }
    }
}

/// Snapshot of what the audio thread has seen, for the status row.
struct LaneAudioStats: Sendable {
    var buffers: Int = 0
    var lastBufferAt: Date?
    /// Last buffer with a non-zero sample (AudioRules.levelCode ≠ levelDigitalSilence).
    var lastSignalAt: Date?
    /// RMS of the last buffer (AudioRules.rms).
    var level: Float = 0
    /// When the capture gate last opened (a transcriber session began); nil while it is closed:
    /// push-to-talk key up, «Пауза голоса в звонок», not running.
    var listeningSince: Date?
}

func millis(_ seconds: TimeInterval) -> Int64 { AppRules.millis(seconds) }

@MainActor
final class TranslationLane {
    let direction: Direction
    var onEvent: (LaneEvent) -> Void = { _ in }

    /// Speak every translated phrase automatically.
    var speechOutputEnabled: Bool {
        didSet {
            guard speechOutputEnabled != oldValue else { return }
            if AppRules.cancelsSpeech(event: AppRules.SCE_VOICE, value: speechOutputEnabled) { cancelSpeech() }
        }
    }
    var mode: CaptureMode {
        didSet { if mode != oldValue { Task { await gateEvent(AppRules.GEV_MODE) } } }
    }
    /// «Пауза голоса в звонок»: no listening, no automatic speech.
    var isPaused = false {
        didSet {
            guard isPaused != oldValue else { return }
            if AppRules.cancelsSpeech(event: AppRules.SCE_PAUSE, value: isPaused) { cancelSpeech() }
            Task { await gateEvent(AppRules.GEV_PAUSE) }
        }
    }
    var glossary: [GlossaryTerm] = []
    /// Incoming lane: true when a final phrase heard between the two dates is not the other side's speech (the owner's
    /// own voice coming back from the call, AppRules.ownTalkDrops); such a phrase is dropped, not translated.
    var dropsPhrase: ((String, Date, Date) -> Bool)?
    /// «Свой голос» (outgoing lane): the microphone goes straight into the call; no listening, no speech.
    private(set) var ownVoice = false
    /// Set on the outgoing lane: drops mic audio while the Russian voice plays through speakers.
    var echoGuard: EchoGuard? {
        didSet { intake.setEchoGuard(echoGuard) }
    }

    private(set) var gatePhase = AppRules.GATE_STOPPED
    private(set) var isKeyHeld = false
    private(set) var lastTranslatedLine: ConversationLine?
    var isRunning: Bool { AppRules.gateRunning(state: gatePhase) }
    /// Why the translator could not be prepared at `start()` (the lane then only transcribes
    /// until a retry succeeds); nil when it is ready.
    private(set) var translatorError: Error?

    private let source: AudioSource
    private let makeTranscriber: () -> Transcriber
    private let translator: Translator
    private let synth: SpeechSynth?
    private let player: AudioPlayer?
    private let memory: ConversationMemory
    private let clock: @Sendable () -> Date
    private let intake: AudioIntake
    private let log = Logger(subsystem: "app.ponte.translator", category: "lane")

    private var preparedTranscriber: Transcriber?
    private var translatorPrepared = false
    private var lastPrepareAttempt: Date?
    private var segment: Segment?
    private var gateChange: Task<Void, Never>?
    private var openSegments: [Segment] = []
    private var lastPartialAt: [UUID: Date] = [:]

    private var translateInput: AsyncStream<PendingPhrase>.Continuation?
    private var translateWorker: Task<Void, Never>?
    private var synthInput: AsyncStream<SpeakRequest>.Continuation?
    private var synthWorker: Task<Void, Never>?
    private var playInput: AsyncStream<PlayRequest>.Continuation?
    private var playWorker: Task<Void, Never>?
    /// Bumped whenever AppRules.cancelsSpeech says so; older queued speech is dropped.
    private var speechGeneration = 0
    /// Automatic phrases between PACT_SYNTHESIZE and the end of their playback.
    private(set) var speechBacklog: Int32 = 0
    private var lastSpoken: (text: String, buffers: [AVAudioPCMBuffer])?

    init(direction: Direction,
         source: AudioSource,
         makeTranscriber: @escaping () -> Transcriber,
         translator: Translator,
         synth: SpeechSynth?,
         player: AudioPlayer?,
         memory: ConversationMemory = ConversationMemory(),
         mode: CaptureMode = .continuous,
         speechOutputEnabled: Bool = true,
         clock: @escaping @Sendable () -> Date = { Date() }) {
        self.direction = direction
        self.source = source
        self.makeTranscriber = makeTranscriber
        self.translator = translator
        self.synth = synth
        self.player = player
        self.memory = memory
        self.mode = mode
        self.speechOutputEnabled = speechOutputEnabled
        self.clock = clock
        self.intake = AudioIntake(clock: clock)
        // «Свой голос»: the other Pontes are told only while the owner actually speaks, not for the whole mode.
        intake.onOwnTalk = { [weak self] on in
            DispatchQueue.main.async { self?.onEvent(.voiceOut(text: nil, playing: on)) }
        }
    }

    var audioStats: LaneAudioStats { intake.stats() }

    // MARK: Lifecycle

    /// Prepares the speech model, then starts capturing. A translator that cannot be prepared
    /// (for example a missing language pack) does not stop the lane: `translatorError` is set,
    /// originals are shown, and preparation is retried before later phrases.
    func start() async throws {
        guard AppRules.gateCanStart(state: gatePhase) else { return }
        await gateEvent(AppRules.GEV_START)
        do {
            let first = makeTranscriber()
            try await first.prepare()
            await prepareTranslator()
            preparedTranscriber = first
            startWorkers()
            prepareOutput()
            try source.start { [intake] buffer, _ in intake.handle(buffer) }
        } catch {
            stopWorkers()
            preparedTranscriber = nil
            await gateEvent(AppRules.GEV_START_FAILED)
            throw error
        }
        await gateEvent(AppRules.GEV_STARTED)
    }

    /// The call output starts with the lane, before the capture, and keeps running between phrases. A device
    /// that cannot start yet does not stop the lane: the player keeps retrying on its own.
    private func prepareOutput() {
        guard let player, AppRules.lanePreparesOutput(direction: AppRules.directionCode(direction), speaks: speechOutputEnabled) else {
            return
        }
        do {
            try player.prepare()
        } catch {
            log.error("output not ready \(self.direction.rawValue, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    private func prepareTranslator() async {
        lastPrepareAttempt = clock()
        do {
            try await translator.prepare(from: direction.source, to: direction.target)
            translatorPrepared = true
            translatorError = nil
        } catch {
            translatorPrepared = false
            translatorError = error
            log.error("translator not ready \(self.direction.rawValue, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Stops capture, flushes the transcriber and waits for pending translations
    /// (so the transcript is complete). Queued speech is dropped.
    func stop() async {
        guard isRunning else { return }
        isKeyHeld = false
        ownVoice = false
        intake.setRelay(nil)
        source.stop()
        await gateEvent(AppRules.GEV_STOP)
        for open in openSegments { await open.waitForConsumer(timeoutMs: AppRules.STOP_SEGMENT_WAIT_MS) }
        openSegments.removeAll()
        translateInput?.finish()
        if let worker = translateWorker {
            let watchdog = Task { try? await Task.sleep(for: .milliseconds(AppRules.STOP_TRANSLATE_WAIT_MS)); worker.cancel() }
            await worker.value
            watchdog.cancel()
        }
        if AppRules.cancelsSpeech(event: AppRules.SCE_STOP, value: true) { cancelSpeech() }
        stopWorkers()
        preparedTranscriber = nil
        lastPartialAt.removeAll()
        onEvent(.partial(""))
    }

    // MARK: Controls

    /// «Свой голос» on or off. On: the speech queued or playing is cancelled, the gate closes (the key does
    /// nothing) and the microphone is relayed to the player. Off: the relay stops at once, its jitter buffer
    /// and what the player still holds are dropped, and the lane listens again.
    /// «Русские в звонке» (outgoing lane): the microphone also goes to PeerMicGate.
    func setPeerSink(_ sink: ((AVAudioPCMBuffer, Bool) -> Void)?) { intake.setPeerSink(sink) }

    func setOwnVoice(_ on: Bool) {
        guard on != ownVoice else { return }
        ownVoice = on
        if !on { intake.setRelay(nil) }
        if AppRules.cancelsSpeech(event: AppRules.SCE_OWN_VOICE, value: on) { cancelSpeech() }
        if on, let player { intake.setRelay(LiveRelay(player: player)) }
        Task { await gateEvent(AppRules.GEV_PAUSE) }
    }

    /// Push-to-talk key state (the gate ignores it in «Авто»).
    func setKeyHeld(_ held: Bool) {
        guard held != isKeyHeld else { return }
        isKeyHeld = held
        Task { await gateEvent(AppRules.GEV_KEY) }
    }

    /// «Сказать»: text the owner typed. Its phrases (TextRules.phrases) enter the phrase pipeline as finals,
    /// in order, after any phrase already queued: same translator and context, voice, pause and call output
    /// as a spoken phrase, but no transcriber and no push-to-talk gate. Returns the IDs of the new lines.
    @discardableResult
    func speakText(_ text: String) -> [UUID] {
        guard isRunning else { return [] }
        let now = clock()
        return TextRules.phrases(text).compactMap { piece in
            guard finalTranslates(piece) else { return nil }
            let line = ConversationLine(direction: direction, at: now, original: piece)
            enqueue(line, end: now, recognitionMs: nil)
            return line.id
        }
    }

    /// «Повторить» / «Сказать заново»: the last translated phrase again.
    func replayLast() {
        let translation = lastTranslatedLine?.translation ?? ""
        // Cached audio counts only if it is of that phrase (a phrase shown but not spoken, say while paused,
        // is synthesized instead of replaying the one before it).
        let action = AppRules.replayAction(hasCachedAudio: lastSpoken.map { $0.text == translation } ?? false,
                                           hasLastTranslation: !translation.isEmpty,
                                           hasPlayer: player != nil && AppRules.speechAllowed(ownVoice: ownVoice))
        guard action != AppRules.RPL_NONE else { return }
        ensureSpeechWorkers()
        if action == AppRules.RPL_AUDIO, let lastSpoken {
            playInput?.yield(PlayRequest(text: lastSpoken.text, buffers: lastSpoken.buffers, generation: speechGeneration, counted: false))
        } else if action == AppRules.RPL_SYNTH {
            synthInput?.yield(SpeakRequest(text: translation, generation: speechGeneration, counted: false))
        }
    }

    private func cancelSpeech() {
        speechGeneration += 1
        player?.stopAll()
        onEvent(.speaking(false))
    }

    // MARK: Gate (one transcriber session per open period)

    /// Feeds one event to AppRules.gateStep and performs its action. Serialized, so quick
    /// key taps cannot interleave.
    private func gateEvent(_ event: Int32) async {
        let previous = gateChange
        let change = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            let step = AppRules.gateStep(state: self.gatePhase, event: event, mode: self.mode.ruleCode, keyHeld: self.isKeyHeld,
                                         paused: AppRules.gateHeld(paused: self.isPaused, ownVoice: self.ownVoice))
            self.gatePhase = AppRules.stepState(step)
            switch AppRules.stepAction(step) {
            case AppRules.GACT_OPEN_SEGMENT:
                self.openSegment()
            case AppRules.GACT_CLOSE_SEGMENT:
                if let segment = self.segment { await self.close(segment) }
            default:
                break
            }
        }
        gateChange = change
        await change.value
    }

    private func openSegment() {
        let transcriber = preparedTranscriber ?? makeTranscriber()
        let needsPrepare = preparedTranscriber == nil
        preparedTranscriber = nil
        let segment = Segment(transcriber: transcriber)
        self.segment = segment
        openSegments.append(segment)
        intake.setSegment(segment)
        segment.consumer = Task { [weak self] in
            do {
                if needsPrepare { try await transcriber.prepare() }
                let stream = try transcriber.start()
                if segment.markStarted() {
                    // Closed before it started (a short key tap): flush what we have.
                    Task { await transcriber.finish() }
                }
                for await event in stream {
                    self?.handle(event, from: transcriber)
                }
            } catch {
                self?.onEvent(.problem("Распознавание: \(error.localizedDescription)"))
            }
            self?.openSegments.removeAll { $0 === segment }
        }
    }

    private func close(_ segment: Segment) async {
        if self.segment === segment {
            self.segment = nil
            intake.setSegment(nil)
        }
        if segment.markClosed() {
            await segment.transcriber.finish()
        }
    }

    // MARK: Transcript events

    private func handle(_ event: TranscriptEvent, from transcriber: Transcriber) {
        switch event {
        case .partial(let id, let text):
            lastPartialAt[id] = clock()
            let step = AppRules.phraseStep(stage: AppRules.PH_LISTENING, event: AppRules.PEV_PARTIAL, flags: 0)
            if AppRules.stepAction(step) == AppRules.PACT_SHOW_PARTIAL { onEvent(.partial(text)) }
        case .final(let id, let text):
            // Also a discarded phrase (empty text): its volatile line goes away.
            let partialAt = lastPartialAt.removeValue(forKey: id)
            onEvent(.partial(""))
            let phrase = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard finalTranslates(phrase) else { return }
            let timing = transcriber.timing(for: id)
            let end = phraseEnd(timing: timing, lastPartialAt: partialAt)
            if let dropsPhrase {
                let start = timing.map { $0.audioEndArrivedAt.addingTimeInterval(-max(0, $0.audioEnd - $0.audioStart)) }
                    ?? end.addingTimeInterval(-Double(AppRules.PHRASE_FALLBACK_MS) / 1000)
                if dropsPhrase(phrase, start, end) {
                    log.info("dropped a phrase that was not the other side: \(phrase, privacy: .private)")
                    PonteDiagnostics.log("incoming phrase dropped (own voice from the call)")
                    return
                }
            }
            enqueue(ConversationLine(id: id, direction: direction, at: end, original: phrase), end: end,
                    recognitionMs: timing.map { millis($0.recognitionLatency) })
        }
    }

    /// PEV_FINAL: an empty phrase is dropped, any other is translated.
    private func finalTranslates(_ phrase: String) -> Bool {
        let step = AppRules.phraseStep(stage: AppRules.PH_LISTENING, event: AppRules.PEV_FINAL,
                                       flags: AppRules.phraseFlags(emptyText: phrase.isEmpty))
        return AppRules.stepAction(step) == AppRules.PACT_TRANSLATE
    }

    /// A final phrase (spoken or typed) enters the pipeline: shown, remembered as context, queued for translation.
    private func enqueue(_ line: ConversationLine, end: Date, recognitionMs: Int64?) {
        onEvent(.phrase(line))
        let context = memory.snapshot()
        memory.add(line.original)
        // «Свой голос» holds the translation voice like a pause: a typed phrase is shown, not spoken.
        let speak = AppRules.speakRequested(speechEnabled: speechOutputEnabled,
                                            paused: AppRules.gateHeld(paused: isPaused, ownVoice: ownVoice))
        translateInput?.yield(PendingPhrase(line: line, context: context, end: end, recognitionMs: recognitionMs,
                                            speak: speak, generation: speechGeneration))
    }

    private func phraseEnd(timing: PhraseTiming?, lastPartialAt: Date?) -> Date {
        let now = clock()
        let choice = AppRules.phraseEndChoiceKnown(
            msSinceTimedEnd: timing.map { millis(now.timeIntervalSince($0.audioEndArrivedAt)) },
            msSincePartial: lastPartialAt.map { millis(now.timeIntervalSince($0)) })
        switch choice {
        case AppRules.END_TRANSCRIBER: return timing?.audioEndArrivedAt ?? now
        case AppRules.END_LAST_PARTIAL: return lastPartialAt ?? now
        default: return now
        }
    }

    // MARK: Workers (each one is a FIFO, so order is kept end to end)

    private struct PendingPhrase {
        var line: ConversationLine
        let context: [String]
        let end: Date
        /// End of the voice → final text, from the transcriber (for the log).
        let recognitionMs: Int64?
        let speak: Bool
        let generation: Int
    }

    private struct SpeakRequest {
        let text: String
        let generation: Int
        /// Automatic phrases count in the backlog; replays do not.
        let counted: Bool
    }

    private struct PlayRequest {
        let text: String
        let buffers: [AVAudioPCMBuffer]
        let generation: Int
        let counted: Bool
    }

    private func flags(generation: Int, emptyText: Bool = false, speakRequested: Bool = false,
                       hasAudio: Bool = false) -> Int32 {
        AppRules.phraseFlags(emptyText: emptyText, speakRequested: speakRequested,
                             generationCurrent: generation == speechGeneration, speechEnabled: speechOutputEnabled,
                             paused: isPaused, hasSynth: synth != nil, hasPlayer: player != nil, hasAudio: hasAudio)
    }

    private func startWorkers() {
        let (translateStream, translateInput) = AsyncStream<PendingPhrase>.makeStream()
        self.translateInput = translateInput
        translateWorker = Task { [weak self] in
            for await pending in translateStream {
                guard let self else { return }
                await self.translate(pending)
            }
        }
        ensureSpeechWorkers()
    }

    private func ensureSpeechWorkers() {
        guard AppRules.needsSpeechWorkers(hasSynth: synth != nil, hasPlayer: player != nil), synthWorker == nil else { return }
        let (synthStream, synthInput) = AsyncStream<SpeakRequest>.makeStream()
        let (playStream, playInput) = AsyncStream<PlayRequest>.makeStream()
        self.synthInput = synthInput
        self.playInput = playInput
        synthWorker = Task { [weak self] in
            for await request in synthStream {
                guard let self else { return }
                await self.synthesize(request)
            }
        }
        playWorker = Task { [weak self] in
            for await request in playStream {
                guard let self else { return }
                await self.play(request)
            }
        }
    }

    private func stopWorkers() {
        translateInput?.finish()
        synthInput?.finish()
        playInput?.finish()
        translateWorker?.cancel()
        synthWorker?.cancel()
        playWorker?.cancel()
        translateInput = nil
        synthInput = nil
        playInput = nil
        translateWorker = nil
        synthWorker = nil
        playWorker = nil
        speechBacklog = 0
    }

    private func endOfSpeech(_ counted: Bool) {
        speechBacklog = AppRules.backlogAfterSpeech(speechBacklog, counted: counted)
    }

    private func translate(_ pending: PendingPhrase) async {
        var line = pending.line
        let sinceAttempt = lastPrepareAttempt.map { millis(clock().timeIntervalSince($0)) } ?? -1
        if AppRules.retryTranslatorPrepare(prepared: translatorPrepared, msSinceAttempt: sinceAttempt) {
            await prepareTranslator()
        }
        do {
            let raw = try await translator.translate(line.original, from: direction.source,
                                                     to: direction.target, context: pending.context)
            // Names and terms the translator passed through: fixed in the app for every engine
            // (Claude also gets the glossary in its prompt).
            let text = GlossaryTerm.apply(glossary, to: raw, direction: direction)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            line.translation = text
            let latency = AppRules.latencyMs(endMs: millis(pending.end.timeIntervalSince1970),
                                             readyMs: millis(clock().timeIntervalSince1970))
            line.latency = Double(latency) / 1000
            let recognition = pending.recognitionMs.map { String($0) } ?? "?"
            log.info("latency \(self.direction.rawValue, privacy: .public) \(latency, privacy: .public) ms (recognition \(recognition, privacy: .public) ms)")
            lastTranslatedLine = line
            let step = AppRules.phraseStep(stage: AppRules.PH_TRANSLATING, event: AppRules.PEV_TRANSLATED,
                                           flags: flags(generation: pending.generation, emptyText: text.isEmpty,
                                                        speakRequested: pending.speak))
            onEvent(.translated(line))
            if AppRules.stepAction(step) == AppRules.PACT_SYNTHESIZE {
                speechBacklog += 1
                synthInput?.yield(SpeakRequest(text: text, generation: pending.generation, counted: true))
            }
        } catch {
            // PEV_TRANSLATE_FAILED always shows the original only.
            _ = AppRules.phraseStep(stage: AppRules.PH_TRANSLATING, event: AppRules.PEV_TRANSLATE_FAILED, flags: 0)
            let reports = AppRules.reportsTranslationError(cancelled: error is CancellationError)
            line.translationError = reports ? error.localizedDescription : "перевод прерван"
            onEvent(.translated(line))
            if reports {
                log.error("translation failed \(self.direction.rawValue, privacy: .public): \(error.localizedDescription, privacy: .public)")
                onEvent(.translationFailed(error))
            }
        }
    }

    private func synthesize(_ request: SpeakRequest) async {
        let start = AppRules.phraseStep(stage: AppRules.PH_SYNTH_QUEUED, event: AppRules.PEV_SYNTH_DEQUEUED,
                                        flags: flags(generation: request.generation))
        guard AppRules.stepAction(start) == AppRules.PACT_RUN_SYNTH, let synth else {
            endOfSpeech(request.counted)
            return
        }
        do {
            let waiting = AppRules.speechWaiting(backlog: speechBacklog, counted: request.counted)
            let rate = AppRules.speechRatePercent(waiting: waiting)
            let buffers = try await synth.synthesize(request.text, lang: direction.target, ratePercent: rate)
            if !buffers.isEmpty { lastSpoken = (request.text, buffers) }
            let done = AppRules.phraseStep(stage: AppRules.PH_SYNTH_QUEUED, event: AppRules.PEV_SYNTHESIZED,
                                           flags: flags(generation: request.generation, hasAudio: !buffers.isEmpty))
            if AppRules.stepAction(done) == AppRules.PACT_ENQUEUE_PLAY {
                playInput?.yield(PlayRequest(text: request.text, buffers: buffers, generation: request.generation, counted: request.counted))
            } else {
                endOfSpeech(request.counted)
            }
        } catch {
            _ = AppRules.phraseStep(stage: AppRules.PH_SYNTH_QUEUED, event: AppRules.PEV_SYNTH_FAILED, flags: 0)
            endOfSpeech(request.counted)
            onEvent(.problem("Голос: \(error.localizedDescription)"))
        }
    }

    private func play(_ request: PlayRequest) async {
        let start = AppRules.phraseStep(stage: AppRules.PH_PLAY_QUEUED, event: AppRules.PEV_PLAY_DEQUEUED,
                                        flags: flags(generation: request.generation, hasAudio: !request.buffers.isEmpty))
        guard AppRules.stepAction(start) == AppRules.PACT_PLAY, let player else {
            endOfSpeech(request.counted)
            return
        }
        onEvent(.speaking(true))
        onEvent(.voiceOut(text: request.text, playing: true))
        // One gapless call per phrase; cancelSpeech() → player.stopAll() ends it early.
        await player.play(request.buffers)
        onEvent(.voiceOut(text: request.text, playing: false))
        let finish = AppRules.phraseStep(stage: AppRules.PH_PLAYING, event: AppRules.PEV_PLAYED, flags: 0)
        endOfSpeech(request.counted)
        if AppRules.playEndReports(action: AppRules.stepAction(finish), generationCurrent: request.generation == speechGeneration) {
            onEvent(.speaking(false))
        }
    }
}

// MARK: - Audio-thread side

/// Receives PCM on the capture thread and forwards it to the open segment.
final class AudioIntake: @unchecked Sendable {
    private let lock = NSLock()
    private var segment: Segment?
    private var echoGuard: EchoGuard?
    private var relay: LiveRelay?
    private var peerSink: ((AVAudioPCMBuffer, Bool) -> Void)?
    /// «Свой голос»: whether the owner is speaking into the call now (mic signal with PeerRules.vadHangoverMs).
    private var ownTalking = false
    private var lastOwnSignalAt: Date?
    /// Called (on the capture thread) when `ownTalking` changes.
    var onOwnTalk: ((Bool) -> Void)?
    private var current = LaneAudioStats()
    private let clock: @Sendable () -> Date

    init(clock: @escaping @Sendable () -> Date) { self.clock = clock }

    /// Set when the gate opens (AppRules.gateStep → GACT_OPEN_SEGMENT), cleared when it closes.
    func setSegment(_ segment: Segment?) {
        let now = clock()
        lock.withLock {
            self.segment = segment
            current.listeningSince = segment == nil ? nil : now
        }
    }
    func setEchoGuard(_ echoGuard: EchoGuard?) { lock.withLock { self.echoGuard = echoGuard } }

    /// «Свой голос»: every buffer also goes to the relay. Replacing it stops the previous one at once.
    func setRelay(_ relay: LiveRelay?) {
        let old = lock.withLock { () -> LiveRelay? in
            defer { self.relay = relay }
            return self.relay
        }
        if relay == nil {
            let ended = lock.withLock { () -> Bool in
                defer { ownTalking = false; lastOwnSignalAt = nil }
                return ownTalking
            }
            if ended { onOwnTalk?(false) }
        }
        if let stats = old?.stop() {
            PonteDiagnostics.log("own voice relay stopped: sent \(stats.sent), dropped \(stats.dropped), trimmed \(stats.trimmed), refills \(stats.refills), max queued \(Int(stats.maxQueuedMs)) ms")
        }
        if relay != nil { PonteDiagnostics.log("own voice relay started") }
    }

    func stats() -> LaneAudioStats { lock.withLock { current } }

    /// «Русские в звонке»: every microphone buffer also goes here with whether it has signal (PeerMicGate decides).
    func setPeerSink(_ sink: ((AVAudioPCMBuffer, Bool) -> Void)?) { lock.withLock { peerSink = sink } }

    func handle(_ buffer: AVAudioPCMBuffer) {
        let (rms, peak) = buffer.laneLevels
        let signal = AudioRules.hasSignal(peak: peak, rms: rms)
        let now = clock()
        let (segment, echo, relay, peer): (Segment?, EchoGuard?, LiveRelay?, ((AVAudioPCMBuffer, Bool) -> Void)?) = lock.withLock {
            current.buffers += 1
            current.lastBufferAt = now
            current.level = rms
            if signal { current.lastSignalAt = now }
            return (self.segment, self.echoGuard, self.relay, self.peerSink)
        }
        // On speakers the mic also hears Ponte's Russian voice and the other Russians: none of it goes on.
        let blocks = echo?.blocksMic(at: now) ?? false
        if !blocks {
            relay?.push(buffer)
            peer?(buffer, signal)
        }
        if relay != nil {
            let change: Bool? = lock.withLock {
                if signal && !blocks { lastOwnSignalAt = now }
                let since = lastOwnSignalAt.map { millis(now.timeIntervalSince($0)) } ?? -1
                let talking = !blocks && PeerRules.vadSends(hasSignal: signal, msSinceSignal: since)
                guard talking != ownTalking else { return nil }
                ownTalking = talking
                return talking
            }
            if let change { onOwnTalk?(change) }
        }
        guard AppRules.intakeForwards(hasSegment: segment != nil, echoBlocks: blocks), let segment else { return }
        segment.append(buffer)
    }
}

/// One transcriber session. Audio that arrives before `start()` returned is kept
/// and replayed in order.
final class Segment: @unchecked Sendable {
    let transcriber: Transcriber
    var consumer: Task<Void, Never>?
    private let lock = NSLock()
    private var started = false
    private var closed = false
    private var pending: [AVAudioPCMBuffer] = []

    init(transcriber: Transcriber) { self.transcriber = transcriber }

    func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        defer { lock.unlock() }
        switch AppRules.segmentAppend(started: started, closed: closed) {
        case AppRules.SEG_FORWARD:
            transcriber.append(buffer)
        case AppRules.SEG_BUFFER:
            if let copy = buffer.copy() as? AVAudioPCMBuffer { pending.append(copy) }
        default:
            break
        }
    }

    /// Flushes buffered audio. Returns true if the segment was closed meanwhile,
    /// so the caller must finish the transcriber itself.
    func markStarted() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        started = true
        for buffer in pending { transcriber.append(buffer) }
        pending.removeAll()
        return closed
    }

    /// Returns true if the transcriber had started and must be finished now.
    func markClosed() -> Bool {
        lock.withLock {
            let action = AppRules.segmentClose(started: started, closed: closed)
            if action != AppRules.SEGC_NONE { closed = true }
            return action == AppRules.SEGC_FINISH
        }
    }

    func waitForConsumer(timeoutMs: Int64) async {
        guard let consumer else { return }
        let watchdog = Task { try? await Task.sleep(for: .milliseconds(timeoutMs)); consumer.cancel() }
        await consumer.value
        watchdog.cancel()
    }
}

extension AVAudioPCMBuffer {
    /// RMS and peak of the first channel (AudioRules). Sources deliver Float32 (PonteCore
    /// contract); any other sample type reads as silence.
    var laneLevels: (rms: Float, peak: Float) {
        guard frameLength > 0, let data = floatChannelData else { return (0, 0) }
        let samples = UnsafeBufferPointer(start: data[0], count: Int(frameLength))
        return (AudioRules.rms(samples), AudioRules.peak(samples))
    }
}
