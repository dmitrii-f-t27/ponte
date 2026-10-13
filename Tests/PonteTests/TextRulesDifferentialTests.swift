// The «Сказать» text rules (Specs/text_rules.t27, through the TextRules facade) against their Swift oracle
// (TextRulesLegacy), bit for bit: exhaustive over the codes and flags, seeded random texts for the splitting
// (sentence-like Russian, the shared random pieces, random and invalid bytes, texts beyond the buffer).
import Foundation
import PonteSpecs
import Testing
@testable import PonteApp

private typealias F = TextRules
private typealias L = TextRulesLegacy

@Suite("Differential: text rules") struct TextRulesDifferentialTests {

    @Test func constantsAndCodes() {
        let log = DiffLog("text constants and codes")
        log.check([F.TEXT_MAX, F.MAX_BYTES, F.PHRASE_MIN_BYTES, F.PHRASE_MAX_BYTES],
                  [L.TEXT_MAX, L.MAX_BYTES, L.PHRASE_MIN_BYTES, L.PHRASE_MAX_BYTES], "limits")
        log.check([F.SUBMIT_OK, F.SUBMIT_NOT_RUNNING, F.SUBMIT_NO_LANE, F.SUBMIT_EMPTY, F.SUBMIT_TOO_LONG],
                  [L.SUBMIT_OK, L.SUBMIT_NOT_RUNNING, L.SUBMIT_NO_LANE, L.SUBMIT_EMPTY, L.SUBMIT_TOO_LONG], "submit codes")
        log.check([F.NOTE_NONE, F.NOTE_TOO_LONG, F.NOTE_NEEDS_START, F.NOTE_NO_LANE, F.NOTE_PAUSED],
                  [L.NOTE_NONE, L.NOTE_TOO_LONG, L.NOTE_NEEDS_START, L.NOTE_NO_LANE, L.NOTE_PAUSED], "note codes")
        log.check([F.MARK_NONE, F.MARK_KEYBOARD, F.CMDRET_RUN, F.CMDRET_SAY],
                  [L.MARK_NONE, L.MARK_KEYBOARD, L.CMDRET_RUN, L.CMDRET_SAY], "marker and Command-Return codes")
        log.finish(minimumCases: 4)
    }

    @Test func smallRules() {
        let log = DiffLog("submitCheck, sayEnabled, fieldNote, commandReturn, lineMarker, pieceSaid")
        let bools = [false, true]
        let bytes = Array(-3...40) + Array(3990...4010) + [8191, 8192, 8193, 1_000_000, Int.max, Int.min, Int.min + 1]
        for running in bools {
            for lane in bools {
                for content in bools {
                    for b in bytes {
                        log.check(F.submitCheck(running: running, hasLane: lane, bytes: b, hasContent: content),
                                  L.submitCheck(running: running, hasLane: lane, bytes: b, hasContent: content),
                                  describe(running, lane, b, content))
                    }
                }
            }
        }
        for check: Int32 in -3...8 {
            log.check(F.sayEnabled(check: check), L.sayEnabled(check: check), "\(check)")
            for b in bytes {
                for paused in bools {
                    log.check(F.fieldNote(check: check, bytes: b, paused: paused),
                              L.fieldNote(check: check, bytes: b, paused: paused), describe(check, b, paused))
                }
            }
        }
        for check in [Int32.min, Int32.max] {
            log.check(F.sayEnabled(check: check), L.sayEnabled(check: check), "\(check)")
            log.check(F.fieldNote(check: check, bytes: 1, paused: true), L.fieldNote(check: check, bytes: 1, paused: true), "\(check)")
        }
        for focused in bools {
            for running in bools {
                log.check(F.commandReturn(fieldFocused: focused, running: running),
                          L.commandReturn(fieldFocused: focused, running: running), describe(focused, running))
            }
        }
        for typed in bools {
            log.check(F.lineMarker(typed: typed), L.lineMarker(typed: typed), "\(typed)")
            for b in bytes {
                log.check(F.pieceSaid(hasContent: typed, bytes: b), L.pieceSaid(hasContent: typed, bytes: b), describe(typed, b))
            }
        }
        log.finish(minimumCases: 2000)
    }

    @Test func phraseSplitting() {
        let log = DiffLog("phraseStart, phraseEnd, phraseRanges")
        var r = DiffRandom(seed: 2710)
        var texts: [[UInt8]] = Self.fixtures()
        for _ in 0..<800 { texts.append(Array(Self.speech(&r, maxBytes: r.pick([60, 300, 900, 2500])).utf8)) }
        for _ in 0..<400 { texts.append(Array(r.text(maxPieces: r.pick([20, 120, 500])).utf8)) }
        for _ in 0..<300 { texts.append(r.bytes(maxCount: r.pick([40, 500, 1500]))) }
        // Beyond the buffer: the rules read the first TX_TEXT_MAX bytes.
        for _ in 0..<6 { texts.append(Array(Self.speech(&r, maxBytes: 9500).utf8)) }
        texts.append([UInt8](repeating: 0x20, count: 9000))
        texts.append([UInt8](repeating: 0x2E, count: 9000))

        for (k, text) in texts.enumerated() {
            let n = text.count
            var starts: [Int] = [-5, -1, 0, 1, n - 1, n, n + 3, F.TEXT_MAX - 1, F.TEXT_MAX, F.TEXT_MAX + 1]
            if n <= 120 {
                starts += Array(0..<n)
            } else {
                starts += (0..<16).map { _ in r.int(0...(n - 1)) }
            }
            for start in starts {
                log.check(F.phraseStart(utf8: text, at: start), L.phraseStart(utf8: text, at: start), "text \(k) n \(n) at \(start)")
                log.check(F.phraseEnd(utf8: text, start: start), L.phraseEnd(utf8: text, start: start), "text \(k) n \(n) start \(start)")
            }
            let ranges = F.phraseRanges(utf8: text)
            log.check(ranges, L.phraseRanges(utf8: text), "ranges of text \(k) n \(n)")
            // Every phrase start (where the app actually calls the rule) once more, as the facade's loop sees it.
            for range in ranges {
                log.check(F.phraseEnd(utf8: text, start: range.lowerBound), L.phraseEnd(utf8: text, start: range.lowerBound),
                          "text \(k) phrase at \(range.lowerBound)")
            }
        }
        log.finish(minimumCases: 40_000)
    }

    /// The spec's own test texts (tx_fixture).
    static func fixtures() -> [[UInt8]] {
        (0..<Int64(TX_FX_COUNT)).map { index in
            var out = [UInt8](repeating: 0, count: TextRules.TEXT_MAX)
            let n = Int(tx_fixture(index, &out, 0))
            return Array(out[0..<n])
        }
    }

    /// Sentence-like text: Russian and Portuguese words, one-letter words, numbers with dots, every sentence and
    /// clause mark, closing quotes and brackets, line feeds and empty lines, runs of spaces.
    static func speech(_ r: inout DiffRandom, maxBytes: Int) -> String {
        let words = ["Добрый", "день", "коллеги", "цена", "доставка", "договор", "завтра", "т", "д", "Д", "г", "а", "и",
                     "Trinity", "ok", "Bom", "dia", "você", "ação", "5.4", "2026", "10", "A", "x", "ж", "Ёлка", "É"]
        let ends = [".", "!", "?", "?!", "…", "...", ".»", ".\"", "!)", ".”", ".'", ""]
        let clauses = [",", ";", ":", " —", " –", ""]
        let gaps = [" ", " ", " ", "  ", "\n", "\n\n", "\n \r\n", "\t", "\r\n"]
        var s = ""
        while s.utf8.count < maxBytes {
            let sentenceWords = r.int(1...14)
            for w in 0..<sentenceWords {
                s += r.pick(words)
                if w + 1 < sentenceWords {
                    if r.int(0...4) == 0 { s += r.pick(clauses) }
                    s += r.int(0...9) == 0 ? r.pick(gaps) : " "
                }
            }
            s += r.pick(ends)
            if r.int(0...19) == 0 { s += ":) :) :) :) :) :) :) :) :)" }
            s += r.pick(gaps)
            if r.int(0...29) == 0 { break }
        }
        return s
    }
}
