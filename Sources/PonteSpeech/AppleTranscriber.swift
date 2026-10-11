import AVFoundation
import CoreMedia
import Foundation
import PonteCore
import Speech

/// Timing of one final phrase, for latency logs (end of phrase → translation).
public struct PhraseTiming: Equatable, Sendable {
    /// Audio time of the first word, seconds from the start of the stream.
    public let audioStart: TimeInterval
    /// Audio time where the voice of the last word ended.
    public let audioEnd: TimeInterval
    /// Wall clock time when the audio at `audioEnd` reached `append(_:)`.
    public let audioEndArrivedAt: Date
    /// Wall clock time when the final was emitted.
    public let finalizedAt: Date
    /// True when Ponte finalized the phrase itself (`SpeechRules.finalizeAction`: end-of-phrase pause
    /// or a cut inside a long monologue) instead of waiting for the analyzer.
    public let forced: Bool

    /// End of phrase audio → final text.
    public var recognitionLatency: TimeInterval { finalizedAt.timeIntervalSince(audioEndArrivedAt) }
}

/// A recognized word with its audio time range (seconds of stream audio).
struct TimedToken: Equatable {
    var text: String
    var start: Double
    var end: Double
}

/// On-device speech recognition with the macOS 26 `SpeechAnalyzer`.
/// pt-BR uses `SpeechTranscriber`, ru-RU uses `DictationTranscriber` (SpeechTranscriber has no Russian).
///
/// Events: `.partial(id, text)` while the phrase is volatile, then `.final(id, text)` with the same id.
/// A `.final` with empty text means "discard this phrase" (the recognizer heard words in silence):
/// remove its partial and do not translate it.
public final class AppleTranscriber: Transcriber, @unchecked Sendable {
    public let language: Lang
    /// pt-BR only: `SpeechTranscriber.ReportingOption.fastResults` (lower latency, slightly less accurate).
    public var fastResults = true
    /// Ponte's own finalization (`SpeechRules.finalizeAction`). Off = the analyzer alone decides
    /// (it finalizes about 2.9 s after the speaker stops). Change before `start()`.
    public var ownCutsEnabled = true
    /// Progress of the last model download, for the setup wizard.
    public private(set) var installationProgress: Progress?
    /// The error that stopped the last session early (for example a TCC refusal), if any.
    public private(set) var lastError: Error?

    private enum Module {
        case speech(SpeechTranscriber)
        case dictation(DictationTranscriber)

        var any: any SpeechModule {
            switch self {
            case .speech(let m): return m
            case .dictation(let m): return m
            }
        }
    }

    private let lock = NSLock()
    private var resolvedLocale: Locale?
    private var analyzerFormat: AVAudioFormat?

    private var analyzer: SpeechAnalyzer?
    private var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?
    private var eventContinuation: AsyncStream<TranscriptEvent>.Continuation?
    private var startTask: Task<Void, Never>?
    private var resultsTask: Task<Void, Never>?
    private var monitorTask: Task<Void, Never>?

    private var converter: AVAudioConverter?
    private var framesFed: AVAudioFramePosition = 0
    private var arrivals: [(audioEnd: Double, at: Date)] = []
    private var activity = VoiceActivity()
    private var lastVoiceEnd: Double = 0
    private var phraseVoiceStart: Double?
    private var lastAppendAt: Date?
    private var finishing = false

    private var currentID = UUID()
    private var phraseStart: Double = 0
    private var volatileTokens: [TimedToken] = []
    private var volatileText = ""
    private var lastPartialText = ""
    private var lastCut: Double?
    private var timings: [UUID: PhraseTiming] = [:]
    private var timingOrder: [UUID] = []

    public init(language: Lang) {
        self.language = language
    }

    /// Timing of a phrase that was already emitted as `.final`. Keeps the last 200 phrases.
    public func timing(for id: UUID) -> PhraseTiming? {
        lock.withLock { timings[id] }
    }

    /// Audio seconds fed to the recognizer in the current session.
    public var audioTimeFed: TimeInterval {
        lock.withLock { fedSeconds }
    }

    /// Call with `lock` held.
    private var fedSeconds: Double {
        guard let format = analyzerFormat else { return 0 }
        return Double(framesFed) / format.sampleRate
    }

    // MARK: - Transcriber

    public func prepare() async throws {
        if lock.withLock({ analyzerFormat != nil }) { return }

        let locale: Locale
        switch language {
        case .ptBR:
            guard let l = await SpeechTranscriber.supportedLocale(equivalentTo: language.locale) else {
                throw PonteSpeechError.unsupportedLanguage(language)
            }
            locale = l
        case .ru:
            guard let l = await DictationTranscriber.supportedLocale(equivalentTo: language.locale) else {
                throw PonteSpeechError.unsupportedLanguage(language)
            }
            locale = l
        }
        let modules = [makeModule(locale: locale).any]

        do {
            if let request = try await AssetInventory.assetInstallationRequest(supporting: modules) {
                lock.withLock { installationProgress = request.progress }
                try await request.downloadAndInstall()
            }
        } catch {
            throw PonteSpeechError.speechAssetsUnavailable(language, reason: error.localizedDescription)
        }
        let status = await AssetInventory.status(forModules: modules)
        guard status == .installed else {
            throw PonteSpeechError.speechAssetsUnavailable(language, reason: "Статус модели: \(status).")
        }
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: modules) else {
            throw PonteSpeechError.speechAssetsUnavailable(language, reason: "Нет подходящего аудиоформата.")
        }
        lock.withLock {
            resolvedLocale = locale
            analyzerFormat = format
        }
    }

    public func start() throws -> AsyncStream<TranscriptEvent> {
        lock.lock()
        defer { lock.unlock() }
        guard let format = analyzerFormat, let locale = resolvedLocale else {
            throw PonteSpeechError.transcriberNotPrepared(language)
        }
        guard analyzer == nil else { throw PonteSpeechError.transcriberAlreadyRunning(language) }

        // Fresh session state.
        converter = nil
        framesFed = 0
        arrivals = []
        activity = VoiceActivity()
        lastVoiceEnd = 0
        phraseVoiceStart = nil
        lastAppendAt = nil
        finishing = false
        currentID = UUID()
        phraseStart = 0
        volatileTokens = []
        volatileText = ""
        lastPartialText = ""
        lastCut = nil
        lastError = nil

        let (inputStream, inputContinuation) = AsyncStream.makeStream(of: AnalyzerInput.self)
        let (events, eventContinuation) = AsyncStream.makeStream(of: TranscriptEvent.self)
        let module = makeModule(locale: locale)
        let analyzer = SpeechAnalyzer(modules: [module.any],
                                      options: .init(priority: .userInitiated, modelRetention: .processLifetime))
        self.analyzer = analyzer
        self.inputContinuation = inputContinuation
        self.eventContinuation = eventContinuation

        resultsTask = Task { [self] in await consumeResults(module) }
        startTask = Task { [self] in
            do {
                try await analyzer.prepareToAnalyze(in: format)
                try await analyzer.start(inputSequence: inputStream)
            } catch {
                lock.withLock { lastError = error }
                await analyzer.cancelAndFinishNow()
            }
        }
        // Cuts are decided on every appended buffer (see `feed`). This watchdog covers a source
        // that stops sending audio in the middle of a phrase.
        monitorTask = Task { [self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(SpeechRules.watchdogPeriodMs))
                finalizeIfStalled(analyzer)
            }
        }
        return events
    }

    public func append(_ buffer: AVAudioPCMBuffer) {
        guard buffer.frameLength > 0 else { return }
        lock.lock()
        defer { lock.unlock() }
        guard let continuation = inputContinuation, let format = analyzerFormat else { return }
        let converted: AVAudioPCMBuffer
        do {
            if buffer.format == format {
                guard let c = AudioConversion.copy(buffer) else { return }
                converted = c
            } else {
                if converter == nil || converter?.inputFormat != buffer.format {
                    converter = AVAudioConverter(from: buffer.format, to: format)
                    converter?.downmix = true
                }
                guard let converter else {
                    lastError = PonteSpeechError.audioConversionFailed("\(buffer.format) → \(format)")
                    return
                }
                converted = try AudioConversion.convert(buffer, with: converter)
            }
        } catch {
            lastError = error
            return
        }
        guard converted.frameLength > 0 else { return }
        feed(converted, format: format, continuation: continuation)
    }

    public func finish() async {
        let (analyzer, startTask, resultsTask, monitorTask): (SpeechAnalyzer?, Task<Void, Never>?, Task<Void, Never>?, Task<Void, Never>?) = lock.withLock {
            finishing = true
            if let converter, let format = analyzerFormat, let continuation = inputContinuation,
               let tail = AudioConversion.flush(converter) {
                feed(tail, format: format, continuation: continuation)
            }
            inputContinuation?.finish()
            inputContinuation = nil
            return (self.analyzer, self.startTask, self.resultsTask, self.monitorTask)
        }
        monitorTask?.cancel()
        await startTask?.value
        if let analyzer {
            do {
                try await analyzer.finalizeAndFinishThroughEndOfInput()
            } catch {
                await analyzer.cancelAndFinishNow()
            }
        }
        await resultsTask?.value
        lock.withLock {
            self.analyzer = nil
            self.startTask = nil
            self.resultsTask = nil
            self.monitorTask = nil
            self.eventContinuation = nil
            self.finishing = false
        }
    }

    // MARK: - Internals

    private func makeModule(locale: Locale) -> Module {
        switch language {
        case .ptBR:
            var reporting: Set<SpeechTranscriber.ReportingOption> = [.volatileResults]
            if fastResults { reporting.insert(.fastResults) }
            return .speech(SpeechTranscriber(locale: locale, transcriptionOptions: [],
                                             reportingOptions: reporting, attributeOptions: [.audioTimeRange]))
        case .ru:
            return .dictation(DictationTranscriber(locale: locale, contentHints: [],
                                                   transcriptionOptions: [.punctuation],
                                                   reportingOptions: [.volatileResults, .frequentFinalization],
                                                   attributeOptions: [.audioTimeRange]))
        }
    }

    /// Call with `lock` held. Meters the level in `SpeechRules.meterWindowMs` windows, passes the audio
    /// on, then asks `SpeechRules.finalizeAction` whether to cut at the end of this buffer.
    private func feed(_ converted: AVAudioPCMBuffer, format: AVAudioFormat,
                      continuation: AsyncStream<AnalyzerInput>.Continuation) {
        let rate = format.sampleRate
        let window = max(1, Int(rate) * SpeechRules.meterWindowMs / 1000)
        let total = Int(converted.frameLength)
        var offset = 0
        while offset < total {
            let n = min(window, total - offset)
            let level = VoiceActivity.level(rms: AudioConversion.rms(converted, from: offset, count: n))
            let start = Double(framesFed + AVAudioFramePosition(offset)) / rate
            let duration = Double(n) / rate
            if activity.add(level: level, start: start, duration: duration) {
                lastVoiceEnd = start + duration
                if phraseVoiceStart == nil { phraseVoiceStart = start }
            }
            offset += n
        }
        framesFed += AVAudioFramePosition(converted.frameLength)
        let end = Double(framesFed) / rate
        let now = Date()
        lastAppendAt = now
        arrivals.append((end, now))
        if arrivals.count > 2400, let cut = arrivals.firstIndex(where: { $0.audioEnd > end - 120 }) {
            arrivals.removeFirst(cut)
        }
        continuation.yield(AnalyzerInput(buffer: converted))
        if let cut = cutDecision(now: end) { requestFinalize(through: cut) }
    }

    private static func ms(_ seconds: Double) -> Int { Int((seconds * 1000).rounded()) }

    /// Call with `lock` held. Measures the phrase and asks `SpeechRules.finalizeAction`.
    private func cutDecision(now: Double) -> Double? {
        guard analyzer != nil else { return nil }
        let start = max(phraseStart, phraseVoiceStart ?? phraseStart)
        var pause = 0.0
        var speech = now - start
        if let silence = activity.silenceStart {
            if silence > start {
                pause = now - silence
                speech = silence - start
            } else {
                speech = 0   // silent since before this phrase's speech
            }
        }
        var flags = 0
        if !volatileText.isEmpty || lastVoiceEnd > phraseStart + 0.05 { flags |= SpeechRules.flagHasContent }
        if finishing { flags |= SpeechRules.flagFinishing }
        if !ownCutsEnabled { flags |= SpeechRules.flagCutsDisabled }
        let action = SpeechRules.finalizeAction(
            pauseMs: Self.ms(pause), speechMs: Self.ms(speech),
            punctuation: SpeechRules.punctuationCode(utf8: Array(volatileText.utf8)),
            lastCutAgoMs: lastCut.map { Self.ms(now - $0) } ?? Int.max,
            phraseAgeMs: Self.ms(now - phraseStart), flags: flags)
        guard action != SpeechRules.actionWait else { return nil }
        let cut = now - Double(SpeechRules.cutBackoffMs(action: action, pauseMs: Self.ms(pause))) / 1000
        if Self.debug { Self.log("cut \(action): finalize(through: \(f(cut))) at \(f(now))") }
        return cut
    }

    /// Call with `lock` held.
    private func requestFinalize(through cut: Double) {
        guard let analyzer else { return }
        lastCut = cut
        Task { [self] in
            do {
                try await analyzer.finalize(through: CMTime(seconds: cut, preferredTimescale: 16_000))
            } catch {
                lock.withLock { if lastError == nil { lastError = error } }
            }
        }
    }

    /// The source stopped sending audio in the middle of a phrase: finalize what was heard.
    private func finalizeIfStalled(_ analyzer: SpeechAnalyzer) {
        lock.withLock {
            guard self.analyzer === analyzer, !finishing, ownCutsEnabled, !volatileText.isEmpty,
                  let last = lastAppendAt,
                  Self.ms(Date().timeIntervalSince(last)) > SpeechRules.stallTimeoutMs else { return }
            let fed = fedSeconds
            if let lastCut, Self.ms(fed - lastCut) <= SpeechRules.minCutSpacingMs { return }
            if Self.debug { Self.log("source stalled: finalize at \(f(fed))") }
            requestFinalize(through: fed)
        }
    }

    /// Call with `lock` held.
    private func arrivalTime(ofAudio t: Double) -> Date {
        if let mark = arrivals.first(where: { $0.audioEnd >= t - 0.0005 }) { return mark.at }
        return arrivals.last?.at ?? Date()
    }

    private func consumeResults(_ module: Module) async {
        do {
            switch module {
            case .speech(let m):
                for try await r in m.results { handle(text: r.text, range: r.range, isFinal: r.isFinal) }
            case .dictation(let m):
                for try await r in m.results { handle(text: r.text, range: r.range, isFinal: r.isFinal) }
            }
        } catch {
            lock.withLock { if lastError == nil { lastError = error } }
        }
        // Whatever is still volatile when the analyzer stops becomes a final.
        let (pending, continuation): (TranscriptEvent?, AsyncStream<TranscriptEvent>.Continuation?) = lock.withLock {
            var event: TranscriptEvent?
            if !volatileText.isEmpty {
                let id = currentID
                recordTiming(id: id, tokens: volatileTokens, rangeEnd: phraseStart, forced: false)
                event = .final(id: id, text: volatileText)
                volatileText = ""
                volatileTokens = []
                currentID = UUID()
            }
            return (event, eventContinuation)
        }
        if let pending { continuation?.yield(pending) }
        continuation?.finish()
    }

    private func handle(text: AttributedString, range: CMTimeRange, isFinal: Bool) {
        let plain = String(text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
        let tokens = Self.tokens(from: text)
        let rangeStart = range.start.seconds
        let rangeEnd = CMTimeRangeGetEnd(range).seconds

        if Self.debug {
            let span = tokens.isEmpty ? "no word times" : "\(tokens.count) words \(f(tokens.first!.start))–\(f(tokens.last!.end))"
            Self.log("\(isFinal ? "final" : "volatile") range \(f(rangeStart))–\(f(rangeEnd)) \(span) fed \(f(audioTimeFed)): \(plain)")
        }
        lock.lock()
        let continuation = eventContinuation
        var event: TranscriptEvent?
        // Drops text without letters, and words "heard" in silence the level meter disagrees with.
        let verdict = plain.isEmpty ? SpeechRules.phraseDropNoContent
            : SpeechRules.phraseAction(utf8: Array(plain.utf8), voiceMs: Self.ms(voiceDuration(rangeStart, rangeEnd)))
        let keep = verdict == SpeechRules.phraseKeep
        if isFinal {
            if keep {
                let id = currentID
                let forced = lastCut.map { $0 > phraseStart } ?? false   // a cut was requested in this phrase
                recordTiming(id: id, tokens: tokens, rangeEnd: rangeEnd, forced: forced)
                event = .final(id: id, text: plain)
                currentID = UUID()
            } else if !lastPartialText.isEmpty {
                // Close the partial the UI already shows: an empty final means "discard".
                event = .final(id: currentID, text: "")
                currentID = UUID()
            }
            if !keep, !plain.isEmpty, Self.debug { Self.log("dropped final (\(verdict)): \(plain)") }
            if rangeEnd.isFinite { phraseStart = max(phraseStart, rangeEnd) }
            phraseVoiceStart = nil
            volatileTokens = []
            volatileText = ""
            lastPartialText = ""
        } else {
            if rangeStart.isFinite { phraseStart = max(phraseStart, rangeStart) }
            volatileTokens = tokens
            volatileText = keep ? plain : ""
            if keep, plain != lastPartialText {
                lastPartialText = plain
                event = .partial(id: currentID, text: plain)
            }
        }
        lock.unlock()
        if let event { continuation?.yield(event) }
    }

    /// Call with `lock` held.
    private func recordTiming(id: UUID, tokens: [TimedToken], rangeEnd: Double, forced: Bool) {
        var audioEnd = tokens.last?.end ?? rangeEnd
        let audioStart = tokens.first?.start ?? phraseStart
        // Word times can run into the following silence; the level meter knows when the voice stopped.
        let lastWordStart = tokens.last?.start ?? audioStart
        if audioEnd > lastVoiceEnd && lastVoiceEnd > lastWordStart { audioEnd = lastVoiceEnd }
        timings[id] = PhraseTiming(audioStart: audioStart, audioEnd: audioEnd,
                                   audioEndArrivedAt: arrivalTime(ofAudio: audioEnd),
                                   finalizedAt: Date(), forced: forced)
        timingOrder.append(id)
        if timingOrder.count > 200 { timings[timingOrder.removeFirst()] = nil }
    }

    /// Call with `lock` held.
    private func voiceDuration(_ start: Double, _ end: Double) -> Double {
        guard start.isFinite, end.isFinite, end > start else { return 0 }
        return activity.voiceDuration(in: start...end)
    }

    /// `PONTE_SPEECH_DEBUG=1` prints recognizer results and cuts to stderr.
    static let debug = ProcessInfo.processInfo.environment["PONTE_SPEECH_DEBUG"] != nil

    static func log(_ message: String) {
        FileHandle.standardError.write(Data("[PonteSpeech] \(message)\n".utf8))
    }

    private func f(_ x: Double) -> String { String(format: "%.2f", x) }

    /// Words with audio time ranges. Runs without a time range (punctuation, spaces) join the previous word.
    /// Volatile results usually carry one range for the whole text (measured).
    static func tokens(from text: AttributedString) -> [TimedToken] {
        var tokens: [TimedToken] = []
        for run in text.runs {
            let piece = String(text[run.range].characters)
            if let r = run[AttributeScopes.SpeechAttributes.TimeRangeAttribute.self], r.isValid {
                let start = r.start.seconds
                let end = CMTimeRangeGetEnd(r).seconds
                let word = piece.trimmingCharacters(in: .whitespacesAndNewlines)
                guard start.isFinite, end.isFinite, !word.isEmpty else { continue }
                tokens.append(TimedToken(text: word, start: start, end: end))
            } else if !tokens.isEmpty {
                let extra = piece.trimmingCharacters(in: .whitespacesAndNewlines)
                if !extra.isEmpty { tokens[tokens.count - 1].text += extra }
            }
        }
        return tokens
    }
}
