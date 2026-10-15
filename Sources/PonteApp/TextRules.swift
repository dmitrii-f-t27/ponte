import Foundation
import PonteSpecs
import PonteSpeech

// Text the owner types or pastes into «Я → по-португальски» and has said into the call.
//
// The decisions are written in t27 (Specs/text_rules.t27) and compiled to C (Sources/PonteSpecs). This facade
// only marshals: Bool and Int32 codes pass straight through, text goes into the fixed buffer the C takes
// (TX_TEXT_MAX bytes) and byte ranges come back. Constants come from the C #defines. Swift keeps what is
// Unicode (trimming whitespace and newlines) and the speech-content fact comes from SpeechRules
// (sg_has_speech_content in segment_rules.t27). The test oracle is TextRulesLegacy (Tests/PonteTests/Oracles);
// the differential tests compare both bit for bit.
// Domain: texts are split up to TX_TEXT_MAX bytes (the field refuses more than TX_MAX_BYTES first).

enum TextRules {
    // MARK: - Limits

    static let TEXT_MAX = Int(TX_TEXT_MAX)
    /// The longest text said at once (UTF-8 bytes after trimming).
    static let MAX_BYTES = Int(TX_MAX_BYTES)
    /// The note under the field counts Russian letters (two bytes each).
    static let MAX_LETTERS = Int(TX_MAX_LETTERS)
    /// A phrase is at least this many bytes (a shorter sentence joins the next one)…
    static let PHRASE_MIN_BYTES = Int(TX_PHRASE_MIN_BYTES)
    /// …and at most this many (a longer sentence is cut at a line break, a clause end or a space).
    static let PHRASE_MAX_BYTES = Int(TX_PHRASE_MAX_BYTES)

    // MARK: - Can the text be said?

    static let SUBMIT_OK: Int32 = TX_SUBMIT_OK
    static let SUBMIT_NOT_RUNNING: Int32 = TX_SUBMIT_NOT_RUNNING
    static let SUBMIT_NO_LANE: Int32 = TX_SUBMIT_NO_LANE
    static let SUBMIT_EMPTY: Int32 = TX_SUBMIT_EMPTY
    static let SUBMIT_TOO_LONG: Int32 = TX_SUBMIT_TOO_LONG

    static func submitCheck(running: Bool, hasLane: Bool, bytes: Int, hasContent: Bool) -> Int32 {
        tx_submit_check(running, hasLane, Int64(bytes), hasContent)
    }

    /// The check for the text in the field: trimmed, measured in UTF-8 bytes, content per SpeechRules.
    static func submitCheck(running: Bool, hasLane: Bool, text: String) -> Int32 {
        let utf8 = trimmedUTF8(text)
        return submitCheck(running: running, hasLane: hasLane, bytes: utf8.count,
                           hasContent: SpeechRules.hasSpeechContent(utf8: utf8))
    }

    static func sayEnabled(check: Int32) -> Bool { tx_say_enabled(check) }

    // MARK: - Note under the field

    static let NOTE_NONE: Int32 = TX_NOTE_NONE
    static let NOTE_TOO_LONG: Int32 = TX_NOTE_TOO_LONG
    static let NOTE_NEEDS_START: Int32 = TX_NOTE_NEEDS_START
    static let NOTE_NO_LANE: Int32 = TX_NOTE_NO_LANE
    static let NOTE_PAUSED: Int32 = TX_NOTE_PAUSED

    static func fieldNote(check: Int32, bytes: Int, paused: Bool) -> Int32 {
        tx_field_note(check, Int64(bytes), paused)
    }

    // MARK: - Command-Return, line marker, pieces

    static let CMDRET_RUN: Int32 = TX_CMDRET_RUN      // «Старт» / «Стоп»
    static let CMDRET_SAY: Int32 = TX_CMDRET_SAY      // «Сказать»

    static func commandReturn(fieldFocused: Bool, running: Bool) -> Int32 { tx_command_return(fieldFocused, running) }

    static let MARK_NONE: Int32 = TX_MARK_NONE
    static let MARK_KEYBOARD: Int32 = TX_MARK_KEYBOARD

    static func lineMarker(typed: Bool) -> Int32 { tx_line_marker(typed) }

    static func pieceSaid(hasContent: Bool, bytes: Int) -> Bool { tx_piece_said(hasContent, Int64(bytes)) }

    // MARK: - Splitting into phrases (UTF-8 byte indexes)

    /// The first non-whitespace byte at or after `at` (the readable length when none).
    static func phraseStart(utf8: [UInt8], at: Int) -> Int {
        var t = TextBuffer(utf8)
        return Int(tx_phrase_start(&t.bytes, t.length, Int64(at)))
    }

    /// Where the phrase that starts at `start` ends (see `tx_phrase_end`).
    static func phraseEnd(utf8: [UInt8], start: Int) -> Int {
        var t = TextBuffer(utf8)
        return Int(tx_phrase_end(&t.bytes, t.length, Int64(start)))
    }

    /// The byte ranges of the phrases of a text, in order (untrimmed; whitespace between them is skipped).
    static func phraseRanges(utf8: [UInt8]) -> [Range<Int>] {
        var t = TextBuffer(utf8)
        var ranges: [Range<Int>] = []
        var start = Int(tx_phrase_start(&t.bytes, t.length, 0))
        while start < t.readable {
            let end = Int(tx_phrase_end(&t.bytes, t.length, Int64(start)))
            ranges.append(start..<end)
            start = Int(tx_phrase_start(&t.bytes, t.length, Int64(end)))
        }
        return ranges
    }

    /// The phrases said for a text, in order: trimmed pieces that `pieceSaid` keeps.
    static func phrases(_ text: String) -> [String] {
        let utf8 = trimmedUTF8(text)
        return phraseRanges(utf8: utf8).compactMap { range in
            let piece = String(decoding: utf8[range], as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            let bytes = Array(piece.utf8)
            return pieceSaid(hasContent: SpeechRules.hasSpeechContent(utf8: bytes), bytes: bytes.count) ? piece : nil
        }
    }

    /// The text without leading and trailing Unicode whitespace and newlines, as UTF-8.
    static func trimmedUTF8(_ text: String) -> [UInt8] {
        Array(text.trimmingCharacters(in: .whitespacesAndNewlines).utf8)
    }
}

/// A text in the fixed buffer the C takes: the first TX_TEXT_MAX bytes, with the whole text's length.
private struct TextBuffer {
    var bytes = [UInt8](repeating: 0, count: TextRules.TEXT_MAX)
    let length: Int64
    /// Bytes the C can read.
    let readable: Int

    init(_ utf8: [UInt8]) {
        readable = min(utf8.count, TextRules.TEXT_MAX)
        bytes.replaceSubrange(0..<readable, with: utf8[0..<readable])
        length = Int64(utf8.count)
    }
}
