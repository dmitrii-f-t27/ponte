// «Сказать»: text typed into «Я → по-португальски» is translated and said into the call through the
// outgoing lane (TranslationLane.speakText), decided by Specs/text_rules.t27 (TextRules).
// Fakes here are prefixed `TextSay`; the lane's source and transcriber come from AppTests.swift.
import AVFoundation
import Foundation
@testable import PonteApp
import PonteCore
import Testing

// MARK: - Fakes sharing one log, so the order of translate → synth → play is visible

final class TextSayLog: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []
    private var labels: [ObjectIdentifier: String] = [:]

    var entries: [String] { lock.withLock { items } }
    func add(_ entry: String) { lock.withLock { items.append(entry) } }
    func label(_ buffer: AVAudioPCMBuffer, _ text: String) { lock.withLock { labels[ObjectIdentifier(buffer)] = text } }
    func label(of buffer: AVAudioPCMBuffer) -> String { lock.withLock { labels[ObjectIdentifier(buffer)] ?? "?" } }
    func count(_ prefix: String) -> Int { entries.filter { $0.hasPrefix(prefix) }.count }
    func index(_ entry: String) -> Int? { entries.firstIndex(of: entry) }
}

final class TextSayTranslator: Translator {
    let name = "text-say"
    let log: TextSayLog
    private(set) var contexts: [[String]] = []
    init(log: TextSayLog) { self.log = log }
    func prepare(from: Lang, to: Lang) async throws {}
    func translate(_ text: String, from: Lang, to: Lang, context: [String]) async throws -> String {
        contexts.append(context)
        log.add("translate:\(text)")
        return "PT(\(text))"
    }
}

final class TextSaySynth: SpeechSynth {
    let log: TextSayLog
    init(log: TextSayLog) { self.log = log }
    func synthesize(_ text: String, lang: Lang) async throws -> [AVAudioPCMBuffer] {
        log.add("synth:\(text)")
        let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 160)!
        buffer.frameLength = 160
        log.label(buffer, text)
        return [buffer]
    }
}

final class TextSayPlayer: AudioPlayer {
    let device: AudioDevice? = nil
    let log: TextSayLog
    init(log: TextSayLog) { self.log = log }
    func play(_ buffer: AVAudioPCMBuffer) async { await play([buffer]) }
    func play(_ buffers: [AVAudioPCMBuffer]) async {
        for buffer in buffers { log.add("play:\(log.label(of: buffer))") }
        try? await Task.sleep(for: .milliseconds(5))
    }
    func stopAll() {}
}

@MainActor
final class TextSayRig {
    let log = TextSayLog()
    let source = AppTestSource()
    let box = AppTestBox()
    let translator: TextSayTranslator
    var events: [LaneEvent] = []
    let lane: TranslationLane

    /// The outgoing lane as the app builds it: push-to-talk, speech on.
    init(mode: CaptureMode = .pushToTalk) {
        translator = TextSayTranslator(log: log)
        let box = self.box
        lane = TranslationLane(direction: .outgoing, source: source,
                               makeTranscriber: {
                                   let t = AppTestTranscriber(language: .ru)
                                   box.items.append(t)
                                   return t
                               },
                               translator: translator, synth: TextSaySynth(log: log), player: TextSayPlayer(log: log),
                               mode: mode, speechOutputEnabled: true)
        lane.onEvent = { [weak self] in self?.events.append($0) }
    }

    var phraseLines: [ConversationLine] {
        events.compactMap { if case .phrase(let line) = $0 { return line } else { return nil } }
    }
    var translatedLines: [ConversationLine] {
        events.compactMap { if case .translated(let line) = $0 { return line } else { return nil } }
    }
    var played: [String] { log.entries.filter { $0.hasPrefix("play:") }.map { String($0.dropFirst(5)) } }
}

private let dobryi = "Добрый день, коллеги."
private let zovut = "Меня зовут Дмитрий."
private let trinity = "Я представляю компанию Trinity."

// MARK: - Lane

@MainActor @Test func typedTextIsTranslatedSynthesizedAndPlayedInOrderWithoutTheTalkKey() async throws {
    let rig = TextSayRig()
    try await rig.lane.start()
    #expect(!rig.lane.isKeyHeld)
    let pieces = [dobryi, zovut, trinity]
    let ids = rig.lane.speakText("  " + pieces.joined(separator: " ") + "\n")
    #expect(ids.count == 3)
    try await appTestWait("3 played") { rig.played.count == 3 }

    #expect(rig.phraseLines.map(\.id) == ids)
    #expect(rig.phraseLines.map(\.original) == pieces)
    #expect(rig.translatedLines.map(\.translation) == pieces.map { "PT(\($0))" })
    #expect(rig.translatedLines.allSatisfy { $0.direction == .outgoing && $0.latency != nil })
    #expect(rig.played == pieces.map { "PT(\($0))" })
    // Each phrase: translate before synthesize before play.
    for p in pieces {
        let t = try #require(rig.log.index("translate:\(p)"))
        let s = try #require(rig.log.index("synth:PT(\(p))"))
        let y = try #require(rig.log.index("play:PT(\(p))"))
        #expect(t < s && s < y)
    }
    // The same context as spoken phrases: the previous phrases, oldest first.
    #expect(rig.translator.contexts == [[], [dobryi], [dobryi, zovut]])
    // No transcriber session was opened: the key stayed up.
    #expect(rig.box.items.allSatisfy { $0.startCount == 0 })
    await rig.lane.stop()
}

@MainActor @Test func typedTextWhileVoicePausedIsShownButNotSaidAndReplaysAfterwards() async throws {
    let rig = TextSayRig()
    try await rig.lane.start()
    let first = "Первая фраза, сказанная в звонок."
    let second = "Вторая фраза, только на экране."
    rig.lane.speakText(first)
    try await appTestWait("first played") { rig.played.count == 1 }

    rig.lane.isPaused = true                         // «Пауза голоса в звонок»
    rig.lane.speakText(second)
    try await appTestWait("second translated") { rig.translatedLines.count == 2 }
    try await Task.sleep(for: .milliseconds(40))
    #expect(rig.translatedLines.last?.translation == "PT(\(second))")
    #expect(rig.log.count("synth:") == 1)
    #expect(rig.played == ["PT(\(first))"])

    // «Сказать заново» after the pause says the typed phrase, not the cached audio of the one before it.
    rig.lane.isPaused = false
    rig.lane.replayLast()
    try await appTestWait("replayed") { rig.played.count == 2 }
    #expect(rig.played == ["PT(\(first))", "PT(\(second))"])
    #expect(rig.log.count("synth:") == 2)
    await rig.lane.stop()
}

@MainActor @Test func sayAgainRepeatsATypedPhraseFromItsAudio() async throws {
    let rig = TextSayRig()
    try await rig.lane.start()
    rig.lane.speakText(dobryi)
    try await appTestWait("played") { rig.played.count == 1 }
    rig.lane.replayLast()
    try await appTestWait("replayed") { rig.played.count == 2 }
    #expect(rig.played == ["PT(\(dobryi))", "PT(\(dobryi))"])
    #expect(rig.log.count("synth:") == 1)            // the cached audio of that phrase
    await rig.lane.stop()
}

@MainActor @Test func typedAndSpokenPhrasesShareOneQueue() async throws {
    let rig = TextSayRig(mode: .continuous)
    try await rig.lane.start()
    let transcriber = try #require(rig.box.items.last)
    try await appTestWait("session") { transcriber.startCount == 1 }
    transcriber.say("первая фраза голосом")
    try await appTestWait("first phrase") { rig.phraseLines.count == 1 }
    rig.lane.speakText("вторая фраза написана текстом")
    transcriber.say("третья фраза голосом")
    try await appTestWait("3 played") { rig.played.count == 3 }
    #expect(rig.played == ["PT(первая фраза голосом)", "PT(вторая фраза написана текстом)", "PT(третья фраза голосом)"])
    await rig.lane.stop()
}

@MainActor @Test func speakTextNeedsARunningLaneAndSomethingToSay() async throws {
    let rig = TextSayRig()
    #expect(rig.lane.speakText(dobryi).isEmpty)       // not started
    try await rig.lane.start()
    #expect(rig.lane.speakText("  \n\t ").isEmpty)
    #expect(rig.lane.speakText(":) :)").isEmpty)      // no speech content
    await rig.lane.stop()
    #expect(rig.lane.speakText(dobryi).isEmpty)       // stopped
    #expect(rig.events.allSatisfy { if case .phrase = $0 { false } else { true } })
}

// MARK: - Rules (TextRules on Russian text)

@Test func textIsSplitIntoPhrasesAtSentenceEnds() {
    #expect(TextRules.phrases([dobryi, zovut, trinity].joined(separator: " ")) == [dobryi, zovut, trinity])
    // Short sentences and a short tail stay together.
    #expect(TextRules.phrases("Привет! Как дела? Да.") == ["Привет! Как дела? Да."])
    // Initials and abbreviations do not end a sentence; a decimal point neither.
    #expect(TextRules.phrases("Встреча с Д. Фёдоровым назначена на завтра. Он подтвердит время.")
        == ["Встреча с Д. Фёдоровым назначена на завтра.", "Он подтвердит время."])
    #expect(TextRules.phrases("Мы обсудили цены, сроки и т. д. Потом поговорим о доставке.").count == 1)
    #expect(TextRules.phrases("Курс сейчас 5.4 реала за доллар. Это нормально для нас.")
        == ["Курс сейчас 5.4 реала за доллар.", "Это нормально для нас."])
    // Closing quotes stay with their sentence; an empty line ends a paragraph.
    #expect(TextRules.phrases("Он сказал: «Да, конечно.» Потом мы подписали договор.")
        == ["Он сказал: «Да, конечно.»", "Потом мы подписали договор."])
    #expect(TextRules.phrases("Первый абзац без точки в конце\n\nВторой абзац тоже без точки")
        == ["Первый абзац без точки в конце", "Второй абзац тоже без точки"])
    // A tail of smileys is not said; Unicode whitespace around the text is trimmed.
    #expect(TextRules.phrases("Спасибо всем за встречу, до завтра! :) :) :) :) :) :) :) :) :)")
        == ["Спасибо всем за встречу, до завтра!"])
    #expect(TextRules.phrases("\u{00A0} Привет, коллеги! Как вы меня слышите сегодня?\u{00A0}\n")
        == ["Привет, коллеги!", "Как вы меня слышите сегодня?"])
    #expect(TextRules.phrases(" \n ").isEmpty)
}

@Test func longTextWithoutSentenceEndsIsCutWithinThePhraseLimit() {
    let text = "Нам нужны " + String(repeating: "яблоки, груши, сливы, ", count: 12) + "и вишни"
    let phrases = TextRules.phrases(text)
    #expect(phrases.count == 2)
    #expect(phrases.allSatisfy { $0.utf8.count <= TextRules.PHRASE_MAX_BYTES })
    #expect(phrases[0].hasSuffix(","))
    #expect(phrases.joined(separator: " ") == text)
    // A paste at the limit splits into phrases that together are the whole text, in order.
    var long = ""
    while long.utf8.count < TextRules.MAX_BYTES - 120 { long += "Это предложение номер \(long.count) про доставку и цены. " }
    let parts = TextRules.phrases(long)
    #expect(parts.count > 10)
    #expect(parts.joined(separator: " ") == long.trimmingCharacters(in: .whitespaces))
}

@Test func whenSayIsEnabledAndWhatTheNoteSays() {
    func check(_ text: String, running: Bool = true, lane: Bool = true) -> Int32 {
        TextRules.submitCheck(running: running, hasLane: lane, text: text)
    }
    #expect(check(dobryi) == TextRules.SUBMIT_OK)
    #expect(check(dobryi, running: false) == TextRules.SUBMIT_NOT_RUNNING)
    #expect(check(dobryi, lane: false) == TextRules.SUBMIT_NO_LANE)
    #expect(check("   ") == TextRules.SUBMIT_EMPTY)
    #expect(check(" … — !! ") == TextRules.SUBMIT_EMPTY)
    #expect(check("я") == TextRules.SUBMIT_OK)                 // two bytes, a letter
    #expect(check("a") == TextRules.SUBMIT_EMPTY)              // shorter than a phrase
    let atLimit = String(repeating: "ж", count: TextRules.MAX_BYTES / 2)
    #expect(check("  " + atLimit + "\n") == TextRules.SUBMIT_OK)      // whitespace around does not count
    #expect(check(atLimit + "ж") == TextRules.SUBMIT_TOO_LONG)
    #expect(TextRules.sayEnabled(check: TextRules.SUBMIT_OK))
    #expect(!TextRules.sayEnabled(check: TextRules.SUBMIT_TOO_LONG))

    #expect(TextRules.fieldNote(check: TextRules.SUBMIT_TOO_LONG, bytes: 5000, paused: false) == TextRules.NOTE_TOO_LONG)
    #expect(TextRules.fieldNote(check: TextRules.SUBMIT_NOT_RUNNING, bytes: 10, paused: false) == TextRules.NOTE_NEEDS_START)
    #expect(TextRules.fieldNote(check: TextRules.SUBMIT_NOT_RUNNING, bytes: 0, paused: false) == TextRules.NOTE_NONE)
    #expect(TextRules.fieldNote(check: TextRules.SUBMIT_NO_LANE, bytes: 0, paused: false) == TextRules.NOTE_NO_LANE)
    #expect(TextRules.fieldNote(check: TextRules.SUBMIT_OK, bytes: 10, paused: true) == TextRules.NOTE_PAUSED)
    #expect(TextRules.fieldNote(check: TextRules.SUBMIT_OK, bytes: 10, paused: false) == TextRules.NOTE_NONE)

    // ⌘↩ says the text only while a call runs and the field has the focus; otherwise it stays «Старт»/«Стоп».
    #expect(TextRules.commandReturn(fieldFocused: true, running: true) == TextRules.CMDRET_SAY)
    #expect(TextRules.commandReturn(fieldFocused: true, running: false) == TextRules.CMDRET_RUN)
    #expect(TextRules.commandReturn(fieldFocused: false, running: true) == TextRules.CMDRET_RUN)
    #expect(TextRules.lineMarker(typed: true) == TextRules.MARK_KEYBOARD)
    #expect(TextRules.lineMarker(typed: false) == TextRules.MARK_NONE)
    // The limits fit the buffer the rules read.
    #expect(TextRules.MAX_BYTES < TextRules.TEXT_MAX)
    #expect(TextRules.PHRASE_MIN_BYTES < TextRules.PHRASE_MAX_BYTES)
}
