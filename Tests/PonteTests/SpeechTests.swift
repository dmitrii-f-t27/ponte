// Owned by the speech agent. Tests for the pure parts of PonteSpeech: SpeechRules (the t27 oracle),
// the Claude request builder, voice ranking, text chunks, the level-meter state and the translator router.
import Foundation
import Testing
@testable import PonteCore
@testable import PonteSpeech

private typealias R = SpeechRules

private func bytes(_ s: String) -> [UInt8] { Array(s.utf8) }

// MARK: - Phrase finalization

@Suite struct FinalizeActionTests {
    let has = R.flagHasContent

    func action(pause: Int, speech: Int, punct: Int = R.punctuationNone, lastCutAgo: Int = .max,
                age: Int = 60_000, flags: Int? = nil) -> Int {
        R.finalizeAction(pauseMs: pause, speechMs: speech, punctuation: punct, lastCutAgoMs: lastCutAgo,
                         phraseAgeMs: age, flags: flags ?? has)
    }

    @Test func waitsWhileSpeakingAShortPhrase() {
        #expect(action(pause: 0, speech: 3_000) == R.actionWait)
        #expect(action(pause: 0, speech: 11_999) == R.actionWait)
    }

    @Test func endOfPhraseAfterSixHundredMilliseconds() {
        #expect(action(pause: 599, speech: 2_000) == R.actionWait)
        #expect(action(pause: 600, speech: 2_000) == R.actionEndOfPhrase)
        #expect(action(pause: 600, speech: 200) == R.actionEndOfPhrase)   // short answers too ("Sim.")
    }

    @Test func flagsBlockCuts() {
        #expect(action(pause: 900, speech: 2_000, flags: 0) == R.actionWait)
        #expect(action(pause: 900, speech: 2_000, flags: has | R.flagFinishing) == R.actionWait)
        #expect(action(pause: 900, speech: 2_000, flags: has | R.flagCutsDisabled) == R.actionWait)
    }

    @Test func longMonologueCutsInAPause() {
        #expect(action(pause: 300, speech: 5_999) == R.actionWait)            // not long yet
        #expect(action(pause: 149, speech: 6_500) == R.actionWait)
        #expect(action(pause: 150, speech: 6_500) == R.actionMonologuePause)
    }

    @Test func shortPauseNeedsSentenceEndOrHardLimit() {
        #expect(action(pause: 80, speech: 6_500, punct: R.punctuationClause) == R.actionWait)
        #expect(action(pause: 80, speech: 6_500, punct: R.punctuationSentence) == R.actionMonologuePause)
        #expect(action(pause: 79, speech: 6_500, punct: R.punctuationSentence) == R.actionWait)
        #expect(action(pause: 80, speech: 8_999) == R.actionWait)
        #expect(action(pause: 80, speech: 9_000) == R.actionMonologuePause)
    }

    @Test func absoluteLimitCutsInsideSpeech() {
        #expect(action(pause: 0, speech: 12_000) == R.actionMonologueForced)
    }

    @Test func cutsAreSpacedAndStayInsideThePhrase() {
        // pause 600 → backoff 450; the cut must lie more than 100 ms after the last one.
        #expect(action(pause: 600, speech: 2_000, lastCutAgo: 550) == R.actionWait)
        #expect(action(pause: 600, speech: 2_000, lastCutAgo: 551) == R.actionEndOfPhrase)
        // …and after the start of the phrase.
        #expect(action(pause: 600, speech: 2_000, age: 450) == R.actionWait)
        #expect(action(pause: 600, speech: 2_000, age: 451) == R.actionEndOfPhrase)
    }

    @Test func backoffKeepsATrailingMargin() {
        #expect(R.cutBackoffMs(action: R.actionEndOfPhrase, pauseMs: 600) == 450)
        #expect(R.cutBackoffMs(action: R.actionMonologuePause, pauseMs: 100) == 0)
        #expect(R.cutBackoffMs(action: R.actionMonologueForced, pauseMs: 0) == 0)
        #expect(R.cutBackoffMs(action: R.actionWait, pauseMs: 900) == 0)
    }
}

// MARK: - Text classification

@Suite struct TextRulesTests {
    @Test func punctuation() {
        #expect(R.punctuationCode(utf8: bytes("Bom dia.")) == R.punctuationSentence)
        #expect(R.punctuationCode(utf8: bytes("Você me ouve?  ")) == R.punctuationSentence)
        #expect(R.punctuationCode(utf8: bytes("Добрый день!")) == R.punctuationSentence)
        #expect(R.punctuationCode(utf8: bytes("então…")) == R.punctuationSentence)
        #expect(R.punctuationCode(utf8: bytes("ele disse \"fim.\"")) == R.punctuationSentence)
        #expect(R.punctuationCode(utf8: bytes("«конец.»")) == R.punctuationSentence)
        #expect(R.punctuationCode(utf8: bytes("como eu dizia,")) == R.punctuationClause)
        #expect(R.punctuationCode(utf8: bytes("итак —")) == R.punctuationClause)
        #expect(R.punctuationCode(utf8: bytes("sem pontuação")) == R.punctuationNone)
        #expect(R.punctuationCode(utf8: []) == R.punctuationNone)
    }

    @Test func words() {
        #expect(R.wordCount(utf8: bytes("um  dois\ttrês ")) == 3)
        #expect(R.wordCount(utf8: bytes("")) == 0)
        #expect(R.wordCount(utf8: bytes("  да")) == 1)
    }

    @Test func speechContent() {
        #expect(R.hasSpeechContent(utf8: bytes("ok")))
        #expect(R.hasSpeechContent(utf8: bytes("12")))
        #expect(R.hasSpeechContent(utf8: bytes("Я")))
        #expect(R.hasSpeechContent(utf8: bytes("É")))
        #expect(!R.hasSpeechContent(utf8: bytes("a")))          // shorter than minPhraseBytes
        #expect(!R.hasSpeechContent(utf8: bytes(".")))
        #expect(!R.hasSpeechContent(utf8: bytes("…")))
        #expect(!R.hasSpeechContent(utf8: bytes("« — »")))
    }

    @Test func phraseVerdict() {
        // Measured: "B." and "." came out of 2 s of digital silence after a phrase.
        #expect(R.phraseAction(utf8: bytes("B."), voiceMs: 0) == R.phraseDropHallucination)
        #expect(R.phraseAction(utf8: bytes("."), voiceMs: 0) == R.phraseDropNoContent)
        #expect(R.phraseAction(utf8: bytes("Sim."), voiceMs: 400) == R.phraseKeep)
        #expect(R.phraseAction(utf8: bytes("um dois três quatro"), voiceMs: 0) == R.phraseKeep)
        #expect(R.phraseAction(utf8: bytes("um dois três"), voiceMs: 99) == R.phraseDropHallucination)
        #expect(R.phraseAction(utf8: bytes("um dois três"), voiceMs: 100) == R.phraseKeep)
    }
}

// MARK: - Cutting long text

@Suite struct CutByteIndexTests {
    @Test func shortTextIsNotCut() {
        let t = bytes("Bom dia.")
        #expect(R.cutByteIndex(utf8: t, maxBytes: 200, minBytes: 24) == t.count)
    }

    @Test func prefersTheLastSentenceEnd() {
        let t = bytes("Primeira frase. Segunda frase, com vírgula, e mais texto que passa do limite")
        let cut = R.cutByteIndex(utf8: t, maxBytes: 40, minBytes: 5)
        #expect(String(decoding: t[0..<cut], as: UTF8.self) == "Primeira frase.")
    }

    @Test func thenTheLastClause() {
        let t = bytes("sem ponto final, mas com vírgulas, e continua sem parar por muito tempo")
        let cut = R.cutByteIndex(utf8: t, maxBytes: 40, minBytes: 5)
        #expect(String(decoding: t[0..<cut], as: UTF8.self) == "sem ponto final, mas com vírgulas,")
    }

    @Test func thenTheLastSpace() {
        let t = bytes("palavras sem nenhuma pontuação até o fim do texto longo")
        let cut = R.cutByteIndex(utf8: t, maxBytes: 30, minBytes: 5)
        #expect(cut <= 30)
        #expect(t[cut] == 0x20)
    }

    @Test func neverSplitsACharacter() {
        let t = bytes(String(repeating: "Ж", count: 40))   // 2 bytes each, no spaces
        let cut = R.cutByteIndex(utf8: t, maxBytes: 31, minBytes: 5)
        #expect(cut == 30)
        #expect(String(decoding: t[0..<cut], as: UTF8.self) == String(repeating: "Ж", count: 15))
    }

    @Test func respectsMinBytesAndEllipsis() {
        let t = bytes("Ok. Então… vamos ver isso com calma amanhã de manhã cedo")
        // "Ok." is shorter than minBytes, the ellipsis ends a sentence.
        let cut = R.cutByteIndex(utf8: t, maxBytes: 30, minBytes: 8)
        #expect(String(decoding: t[0..<cut], as: UTF8.self) == "Ok. Então…")
    }

    @Test func synthChunksFitAndKeepTheText() {
        let text = "O valor total é de quarenta e cinco mil reais, com pagamento em três parcelas. "
            + "A primeira parcela vence no dia dez, a segunda no dia vinte e a terceira no fim do mês. "
            + "Se precisar, a gente ajusta as datas com o financeiro sem nenhum problema."
        let pieces = SystemSpeechSynth.chunks(text, maxBytes: 100)
        #expect(pieces.count >= 3)
        #expect(pieces.allSatisfy { $0.utf8.count <= 100 })
        #expect(pieces.joined(separator: " ") == text)
    }
}

// MARK: - Context

@Suite struct ContextTests {
    @Test func countAndByteCap() {
        #expect(R.contextCount(byteLengths: []) == 0)
        #expect(R.contextCount(byteLengths: [10, 10, 10, 10, 10, 10]) == 4)
        #expect(R.contextCount(byteLengths: [500, 50, 50]) == 3)          // exactly 600
        #expect(R.contextCount(byteLengths: [501, 50, 50]) == 2)
        #expect(R.contextCount(byteLengths: [700]) == 0)
        #expect(R.contextCount(byteLengths: [10, 700, 10]) == 1)          // stops at the first that does not fit
    }
}

// MARK: - Translator choice

@Suite struct TranslatorRulesTests {
    @Test func primaryAndFallback() {
        #expect(R.primaryEngine(preferred: R.engineApple, appleReady: true, claudeAvailable: true) == R.engineApple)
        #expect(R.primaryEngine(preferred: R.engineClaude, appleReady: true, claudeAvailable: true) == R.engineClaude)
        #expect(R.primaryEngine(preferred: R.engineClaude, appleReady: true, claudeAvailable: false) == R.engineApple)
        #expect(R.primaryEngine(preferred: R.engineApple, appleReady: false, claudeAvailable: true) == R.engineClaude)
        #expect(R.primaryEngine(preferred: R.engineApple, appleReady: false, claudeAvailable: false) == R.engineNone)
        #expect(R.fallbackEngine(failed: R.engineApple, appleReady: true, claudeAvailable: true) == R.engineClaude)
        #expect(R.fallbackEngine(failed: R.engineClaude, appleReady: true, claudeAvailable: true) == R.engineApple)
        #expect(R.fallbackEngine(failed: R.engineClaude, appleReady: false, claudeAvailable: true) == R.engineNone)
        #expect(R.fallbackEngine(failed: R.engineApple, appleReady: true, claudeAvailable: false) == R.engineNone)
    }

    @Test func timeoutsAndHTTPErrors() {
        #expect(R.translationTimeoutMs(engine: R.engineApple) == 3_000)
        #expect(R.translationTimeoutMs(engine: R.engineClaude) == 5_000)
        #expect(R.translationTimeoutMs(engine: R.engineNone) == 0)
        #expect(R.errorCode(httpStatus: 0) == R.errorNetwork)
        #expect(R.errorCode(httpStatus: 429) == R.errorOverloaded)
        #expect(R.errorCode(httpStatus: 529) == R.errorOverloaded)
        #expect(R.errorCode(httpStatus: 401) == R.errorRejected)
        #expect(R.errorCode(httpStatus: 200) == R.errorOther)
    }

    @Test func retry() {
        // A fallback exists: switch on any error, once.
        #expect(R.retryAction(errorCode: R.errorAssetsMissing, attempt: 0, fallback: R.engineClaude) == R.retrySwitch)
        #expect(R.retryAction(errorCode: R.errorTimeout, attempt: 0, fallback: R.engineApple) == R.retrySwitch)
        // No fallback: retry transient errors, give up on the others.
        #expect(R.retryAction(errorCode: R.errorTimeout, attempt: 0, fallback: R.engineNone) == R.retrySame)
        #expect(R.retryAction(errorCode: R.errorOverloaded, attempt: 0, fallback: R.engineNone) == R.retrySame)
        #expect(R.retryAction(errorCode: R.errorRefused, attempt: 0, fallback: R.engineNone) == R.retryGiveUp)
        #expect(R.retryAction(errorCode: R.errorAssetsMissing, attempt: 0, fallback: R.engineNone) == R.retryGiveUp)
        // Two attempts per phrase at most.
        #expect(R.retryAction(errorCode: R.errorTimeout, attempt: 1, fallback: R.engineApple) == R.retryGiveUp)
    }
}

// MARK: - Router with fake translators

private final class FakeTranslator: Translator, @unchecked Sendable {
    let name: String
    var results: [Result<String, Error>]
    var calls = 0
    init(_ name: String, _ results: [Result<String, Error>]) {
        self.name = name
        self.results = results
    }
    func prepare(from: Lang, to: Lang) async throws {
        if case .failure(let e) = results.first, case PonteSpeechError.translationAssetsMissing = e { throw e }
    }
    func translate(_ text: String, from: Lang, to: Lang, context: [String]) async throws -> String {
        let r = results[min(calls, results.count - 1)]
        calls += 1
        return try r.get()
    }
}

@Suite struct RoutingTranslatorTests {
    @Test func appleFirstThenClaudeOnFailure() async throws {
        let apple = FakeTranslator("apple", [.failure(PonteSpeechError.translationFailed("x")), .success("A")])
        let claude = FakeTranslator("claude", [.success("C")])
        let router = RoutingTranslator(apple: apple, claude: claude)
        try await router.prepare(from: .ptBR, to: .ru)
        let out = try await router.translate("Bom dia", from: .ptBR, to: .ru, context: [])
        #expect(out == "C")
        #expect(router.lastEngine == R.engineClaude)
        #expect(apple.calls == 1 && claude.calls == 1)
    }

    @Test func missingPackUsesClaude() async throws {
        let apple = FakeTranslator("apple", [.failure(PonteSpeechError.translationAssetsMissing(from: .ru, to: .ptBR))])
        let claude = FakeTranslator("claude", [.success("Bom dia")])
        let router = RoutingTranslator(apple: apple, claude: claude)
        try await router.prepare(from: .ru, to: .ptBR)
        #expect(try await router.translate("Добрый день", from: .ru, to: .ptBR, context: []) == "Bom dia")
        #expect(apple.calls == 0)
    }

    @Test func noEngineThrowsThePackError() async {
        let apple = FakeTranslator("apple", [.failure(PonteSpeechError.translationAssetsMissing(from: .ptBR, to: .ru))])
        let router = RoutingTranslator(apple: apple, claude: nil)
        await #expect(throws: PonteSpeechError.translationAssetsMissing(from: .ptBR, to: .ru)) {
            try await router.prepare(from: .ptBR, to: .ru)
        }
    }

    @Test func retriesOnceWithoutFallback() async throws {
        let claude = FakeTranslator("claude", [.failure(PonteSpeechError.cloudRequestFailed(status: 529, message: "overloaded")),
                                               .success("ok")])
        let router = RoutingTranslator(apple: nil, claude: claude)
        try await router.prepare(from: .ptBR, to: .ru)
        #expect(try await router.translate("x y", from: .ptBR, to: .ru, context: []) == "ok")
        #expect(claude.calls == 2)
    }

    @Test func errorCodes() {
        #expect(RoutingTranslator.errorCode(PonteSpeechError.cloudRequestFailed(status: 401, message: "")) == R.errorRejected)
        #expect(RoutingTranslator.errorCode(PonteSpeechError.translationTimedOut("x", ms: 1)) == R.errorTimeout)
        #expect(RoutingTranslator.errorCode(PonteSpeechError.cloudRefused) == R.errorRefused)
        #expect(RoutingTranslator.errorCode(URLError(.timedOut)) == R.errorNetwork)
    }
}

// MARK: - Claude request (fake key; the live API is not called)

@Suite struct ClaudeRequestTests {
    let fakeKey = "sk-ant-test-0000-not-a-real-key"

    @Test func requestShape() throws {
        var builder = ClaudeRequestBuilder(glossary: ["Dmitrii": "Дмитрий", "Ponte": "Ponte"])
        builder.glossary["contrato"] = "договор"
        let context = ["um", "dois", "três", "quatro", "cinco", "seis"]
        let request = try builder.urlRequest(apiKey: fakeKey, text: "Bom dia, Dmitrii", from: .ptBR, to: .ru, context: context)

        #expect(request.url?.absoluteString == "https://api.anthropic.com/v1/messages")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "x-api-key") == fakeKey)
        #expect(request.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")
        #expect(request.value(forHTTPHeaderField: "content-type") == "application/json")

        let body = try #require(request.httpBody)
        let object = try JSONSerialization.jsonObject(with: body)
        let json = try #require(object as? [String: Any])
        #expect(json["model"] as? String == "claude-haiku-5-5")
        #expect(json["max_tokens"] as? Int == 1024)
        #expect((json["output_config"] as? [String: Any])?["effort"] as? String == "low")
        #expect(json["temperature"] == nil && json["thinking"] == nil)   // Haiku 5.5: defaults only

        let system = try #require(json["system"] as? String)
        #expect(system.hasPrefix("Translate the spoken phrase from Brazilian Portuguese (pt-BR) to Russian (ru-RU). "
                                  + "Conversational register, keep names and numbers, output only the translation."))
        #expect(system.contains("- Dmitrii → Дмитрий"))
        #expect(system.contains("- contrato → договор"))

        let messages = try #require(json["messages"] as? [[String: Any]])
        #expect(messages.count == 1)
        #expect(messages[0]["role"] as? String == "user")
        let content = try #require(messages[0]["content"] as? String)
        #expect(content.hasSuffix("<phrase>\nBom dia, Dmitrii\n</phrase>"))
        #expect(content.contains("<context>\ntrês\nquatro\ncinco\nseis\n</context>"))   // the last 4
        #expect(!content.contains("dois"))
    }

    @Test func contextByteCap() {
        let long = String(repeating: "a", count: 597)
        #expect(ClaudeRequestBuilder.selectContext(["velho", long, "novo"]) == ["novo"])   // 4 + 597 > 600
        #expect(ClaudeRequestBuilder.selectContext(["velho", String(long.dropFirst()), "novo"]).count == 2)
        #expect(ClaudeRequestBuilder.selectContext(["  ", "a b"]) == ["a b"])
    }

    @Test func reverseDirectionPrompt() {
        let s = ClaudeRequestBuilder().systemPrompt(from: .ru, to: .ptBR)
        #expect(s.hasPrefix("Translate the spoken phrase from Russian (ru-RU) to Brazilian Portuguese (pt-BR)."))
    }

    @Test func parseReplies() throws {
        let ok = #"{"content":[{"type":"thinking","thinking":"","signature":"x"},{"type":"text","text":" Доброе утро. "}],"stop_reason":"end_turn"}"#
        #expect(try ClaudeRequestBuilder.parseResponse(Data(ok.utf8), status: 200) == "Доброе утро.")

        let refusal = #"{"content":[],"stop_reason":"refusal"}"#
        #expect(throws: PonteSpeechError.cloudRefused) { try ClaudeRequestBuilder.parseResponse(Data(refusal.utf8), status: 200) }

        let overloaded = #"{"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#
        #expect(throws: PonteSpeechError.cloudRequestFailed(status: 529, message: "Overloaded")) {
            try ClaudeRequestBuilder.parseResponse(Data(overloaded.utf8), status: 529)
        }

        let empty = #"{"content":[{"type":"text","text":"  "}],"stop_reason":"end_turn"}"#
        #expect(throws: PonteSpeechError.cloudEmptyResponse) { try ClaudeRequestBuilder.parseResponse(Data(empty.utf8), status: 200) }
    }

    @Test func noKeyNoTranslator() {
        #expect(ClaudeTranslator(keychainItem: "ponte-test-item-that-does-not-exist") == nil)
    }
}

// MARK: - Voices

@Suite struct VoiceRankingTests {
    @Test func rankKey() {
        #expect(R.voiceRankKey(qualityCode: R.qualityPremium, isNovelty: true, preferredIndex: -1)
                > R.voiceRankKey(qualityCode: R.qualityEnhanced, isNovelty: false, preferredIndex: 0))
        #expect(R.voiceRankKey(qualityCode: R.qualityCompact, isNovelty: false, preferredIndex: -1)
                > R.voiceRankKey(qualityCode: R.qualityCompact, isNovelty: true, preferredIndex: 0))
        #expect(R.voiceRankKey(qualityCode: R.qualityCompact, isNovelty: false, preferredIndex: 0)
                > R.voiceRankKey(qualityCode: R.qualityCompact, isNovelty: false, preferredIndex: 1))
        #expect(R.voiceQualityCode(avQualityRaw: 0) == R.qualityCompact)
        #expect(R.voiceQualityCode(avQualityRaw: 3) == R.qualityPremium)
        #expect(R.voiceQualityCode(avQualityRaw: 9) == R.qualityCompact)
    }

    @Test func novelty() {
        #expect(R.isNoveltyVoice(identifierUTF8: bytes("com.apple.eloquence.pt-BR.Eddy")))
        #expect(R.isNoveltyVoice(identifierUTF8: bytes("com.apple.speech.synthesis.voice.Bells")))
        #expect(!R.isNoveltyVoice(identifierUTF8: bytes("com.apple.voice.compact.pt-BR.Luciana")))
        #expect(!R.isNoveltyVoice(identifierUTF8: []))
    }

    @Test func ranking() {
        let voices = [
            SpeechVoice(id: "com.apple.eloquence.pt-BR.Eddy", name: "Eddy", quality: .compact, language: "pt-BR"),
            SpeechVoice(id: "com.apple.voice.compact.pt-BR.Luciana", name: "Luciana", quality: .compact, language: "pt-BR"),
            SpeechVoice(id: "com.apple.eloquence.pt-BR.Flo", name: "Flo", quality: .compact, language: "pt-BR"),
            SpeechVoice(id: "com.apple.voice.enhanced.pt-BR.Felipe", name: "Felipe", quality: .enhanced, language: "pt-BR"),
        ]
        let ranked = VoiceRanking.rank(voices, preferredNames: VoiceRanking.preferredNames(for: .ptBR))
        #expect(ranked.map(\.name) == ["Felipe", "Luciana", "Eddy", "Flo"])
    }

    @Test func installedVoicesOnThisMac() {
        // Facts probed 2026-10-13, after Felipe, Milena and Yuri (Enhanced) were downloaded: Felipe is the best
        // pt-BR voice, Milena the best ru voice, and «М» of the Russian switch picks Yuri.
        #expect(SystemSpeechSynth.voices(for: .ptBR).first?.name.contains("Felipe") == true)
        #expect(SystemSpeechSynth.voices(for: .ru).first?.name.contains("Milena") == true)
        let ru = SystemSpeechSynth.voices(for: .ru)
        let male = SpeechRules.pickGender(genders: ru.map(\.gender), want: SpeechRules.genderMale)
        #expect(male >= 0 && ru[male].name.contains("Yuri"))
    }

    @Test func synthesisTimeout() {
        #expect(R.synthesisTimeoutMs(textBytes: 0) == 5_000)
        #expect(R.synthesisTimeoutMs(textBytes: 100) == 10_000)
        #expect(R.synthesisTimeoutMs(textBytes: 10_000) == 60_000)
    }
}

// MARK: - Level meter

@Suite struct VoiceActivityTests {
    @Test func thresholdsAndFloor() {
        #expect(!R.isVoice(level: 999, floorMilli: 0))
        #expect(R.isVoice(level: 1_000, floorMilli: 0))
        #expect(R.effectiveThreshold(floorMilli: 1_000_000) == 2_500)      // noisy room: floor 0.01 → 0.025
        #expect(R.nextNoiseFloor(floorMilli: 0, hasFloor: false, level: 700, durationMs: 20) == 700_000)
        #expect(R.nextNoiseFloor(floorMilli: 500_000, hasFloor: true, level: 100, durationMs: 20) == 100_000)
        #expect(R.nextNoiseFloor(floorMilli: 0, hasFloor: true, level: 1_000, durationMs: 20) == 333)
    }

    @Test func pausesAndVoiceDuration() {
        var a = VoiceActivity()
        var t = 0.0
        func add(_ level: Int, _ seconds: Double) {
            for _ in 0..<Int((seconds / 0.02).rounded()) {
                a.add(level: level, start: t, duration: 0.02)
                t += 0.02
            }
        }
        add(0, 0.5)          // silence
        add(10_000, 1.0)     // voice 0.5–1.5
        add(0, 0.04)         // gap inside a word: shorter than minRecordedPauseMs
        add(10_000, 0.46)    // voice to 2.0
        add(0, 0.3)          // pause 2.0–2.3
        add(10_000, 0.5)     // voice 2.3–2.8
        add(0, 0.7)          // silence from 2.8
        #expect(abs((a.silenceStart ?? -1) - 2.8) < 0.001)
        #expect(a.voiceSegments.count == 1)                    // 0.5–2.0 closed; 2.3–2.8 still open
        #expect(abs(a.voiceDuration(in: 0...3.5) - 2.0) < 0.05)
        #expect(a.voiceDuration(in: 2.85...3.5) == 0)
    }
}

// MARK: - Integration additions (speaking rate, per-direction glossary)

@Test func speakingRateMapsPercentToUtteranceRate() {
    #expect(SpeechRules.utteranceRateMilli(ratePercent: 100, baseRateMilli: 500) == 500)
    #expect([110, 120, 130].map { SpeechRules.utteranceRateMilli(ratePercent: $0, baseRateMilli: 500) } == [517, 534, 551])
    #expect(SpeechRules.utteranceRateMilli(ratePercent: 90, baseRateMilli: 500) == 483)   // truncates toward zero
    #expect(SpeechRules.utteranceRateMilli(ratePercent: 130, baseRateMilli: 990) == 1_000)
    #expect(SpeechRules.utteranceRateMilli(ratePercent: 0, baseRateMilli: 100) == 0)
}

@Test func claudeGlossaryIsKeptPerDirection() {
    let claude = ClaudeTranslator(apiKey: "test")
    claude.glossary = ["shared": "общий"]
    claude.setGlossary(["Trinity": "Тринити"], from: .ptBR, to: .ru)
    claude.setGlossary(["Тринити": "Trinity"], from: .ru, to: .ptBR)
    #expect(claude.glossary(from: .ptBR, to: .ru) == ["Trinity": "Тринити"])
    #expect(claude.glossary(from: .ru, to: .ptBR) == ["Тринити": "Trinity"])
    let other = ClaudeTranslator(apiKey: "test")
    other.glossary = ["shared": "общий"]
    #expect(other.glossary(from: .ptBR, to: .ru) == ["shared": "общий"])
    let prompt = ClaudeRequestBuilder(glossary: claude.glossary(from: .ptBR, to: .ru)).systemPrompt(from: .ptBR, to: .ru)
    #expect(prompt.contains("Trinity → Тринити") && !prompt.contains("Тринити → Trinity"))
}

/// SystemSpeechSynth at 130 % renders the same phrase noticeably shorter (real voices on this Mac).
@Test func systemSynthSpeaksFasterAtHigherRate() async throws {
    let synth = SystemSpeechSynth()
    guard synth.voice(for: .ptBR) != nil else { return }
    let text = "Podemos enviar a proposta até sexta-feira."
    let normal = try await synth.synthesize(text, lang: .ptBR)
    let fast = try await synth.synthesize(text, lang: .ptBR, ratePercent: 130)
    let n = normal.reduce(0) { $0 + Double($1.frameLength) / $1.format.sampleRate }
    let f = fast.reduce(0) { $0 + Double($1.frameLength) / $1.format.sampleRate }
    #expect(n > 0 && f > 0)
    #expect(f < n * 0.85)
}
