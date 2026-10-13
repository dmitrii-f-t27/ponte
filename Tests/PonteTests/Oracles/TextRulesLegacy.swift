// Test oracle for Specs/text_rules.t27 (the «Сказать» text field). Written in plain Swift from the same
// rules, independently of the t27 (collect every boundary first, then choose), so the differential tests
// compare two implementations of one rule set, bit for bit.

enum TextRulesLegacy {
    static let TEXT_MAX = 8192
    static let MAX_BYTES = 4000
    static let PHRASE_MIN_BYTES = 24
    static let PHRASE_MAX_BYTES = 400

    static let SUBMIT_OK: Int32 = 0
    static let SUBMIT_NOT_RUNNING: Int32 = 1
    static let SUBMIT_NO_LANE: Int32 = 2
    static let SUBMIT_EMPTY: Int32 = 3
    static let SUBMIT_TOO_LONG: Int32 = 4

    static let NOTE_NONE: Int32 = 0
    static let NOTE_TOO_LONG: Int32 = 1
    static let NOTE_NEEDS_START: Int32 = 2
    static let NOTE_NO_LANE: Int32 = 3
    static let NOTE_PAUSED: Int32 = 4

    static let MARK_NONE: Int32 = 0
    static let MARK_KEYBOARD: Int32 = 1

    static let CMDRET_RUN: Int32 = 0
    static let CMDRET_SAY: Int32 = 1

    // MARK: - Small rules

    static func submitCheck(running: Bool, hasLane: Bool, bytes: Int, hasContent: Bool) -> Int32 {
        guard running else { return SUBMIT_NOT_RUNNING }
        guard hasLane else { return SUBMIT_NO_LANE }
        guard hasContent else { return SUBMIT_EMPTY }
        return bytes > MAX_BYTES ? SUBMIT_TOO_LONG : SUBMIT_OK
    }

    static func sayEnabled(check: Int32) -> Bool { check == SUBMIT_OK }

    static func fieldNote(check: Int32, bytes: Int, paused: Bool) -> Int32 {
        switch check {
        case SUBMIT_TOO_LONG: return NOTE_TOO_LONG
        case SUBMIT_NOT_RUNNING: return bytes > 0 ? NOTE_NEEDS_START : NOTE_NONE
        case SUBMIT_NO_LANE: return NOTE_NO_LANE
        default: return paused ? NOTE_PAUSED : NOTE_NONE
        }
    }

    static func commandReturn(fieldFocused: Bool, running: Bool) -> Int32 {
        fieldFocused && running ? CMDRET_SAY : CMDRET_RUN
    }

    static func lineMarker(typed: Bool) -> Int32 { typed ? MARK_KEYBOARD : MARK_NONE }

    static func pieceSaid(hasContent: Bool, bytes: Int) -> Bool { hasContent && bytes > 0 }

    // MARK: - Splitting

    private static func isSpace(_ b: UInt8) -> Bool { b == 0x20 || b == 0x09 || b == 0x0A || b == 0x0D }
    private static func isContinuation(_ b: UInt8) -> Bool { b & 0xC0 == 0x80 }
    private static func isAlnum(_ b: UInt8) -> Bool {
        (0x30...0x39).contains(b) || (0x41...0x5A).contains(b) || (0x61...0x7A).contains(b)
    }

    /// The bytes the rules read: the first TEXT_MAX.
    private static func readable(_ utf8: [UInt8]) -> [UInt8] { Array(utf8.prefix(TEXT_MAX)) }

    static func phraseStart(utf8: [UInt8], at: Int) -> Int {
        let t = readable(utf8)
        var i = max(at, 0)
        if i >= t.count { return t.count }
        while i < t.count, isSpace(t[i]) { i += 1 }
        return i
    }

    /// The word before position `i` (a dot) is one letter or digit with whitespace or the text start before it.
    private static func oneLetterWordBefore(_ t: [UInt8], _ i: Int) -> Bool {
        func startsWord(_ k: Int) -> Bool { k == 0 || isSpace(t[k - 1]) }
        if i >= 1, isAlnum(t[i - 1]) { return startsWord(i - 1) }
        if i >= 2, (0xC3...0xDF).contains(t[i - 2]), isContinuation(t[i - 1]) { return startsWord(i - 2) }
        return false
    }

    private enum Kind { case sentence, line, clause, space }

    private static let ellipsis: [UInt8] = [0xE2, 0x80, 0xA6]
    private static let guillemet: [UInt8] = [0xC2, 0xBB]
    private static let curly: [UInt8] = [0xE2, 0x80, 0x9D]
    private static let emDash: [UInt8] = [0xE2, 0x80, 0x94]
    private static let enDash: [UInt8] = [0xE2, 0x80, 0x93]

    /// Every boundary in the text: (kind, end index), in order of the byte that makes it.
    private static func boundaries(_ t: [UInt8], from s: Int, below limit: Int) -> [(Kind, Int)] {
        let n = t.count
        func has(_ seq: [UInt8], at k: Int) -> Bool {
            guard k + seq.count <= n else { return false }
            for (o, v) in seq.enumerated() where t[k + o] != v { return false }
            return true
        }
        func spaceOrEnd(_ k: Int) -> Bool { k == n || isSpace(t[k]) }
        var found: [(Kind, Int)] = []
        for i in s..<limit {
            let b = t[i]
            // Sentence mark, then closing marks, then whitespace or the end.
            var mark: Int?
            if b == 0x21 || b == 0x3F { mark = i + 1 }
            if b == 0x2E, !oneLetterWordBefore(t, i) { mark = i + 1 }
            if has(ellipsis, at: i) { mark = i + 3 }
            if var e = mark {
                while e < n {
                    if t[e] == 0x22 || t[e] == 0x27 || t[e] == 0x29 { e += 1 }
                    else if has(guillemet, at: e) { e += 2 }
                    else if has(curly, at: e) { e += 3 }
                    else { break }
                }
                if spaceOrEnd(e) { found.append((.sentence, e)) }
            } else if b == 0x0A {
                var j = i + 1
                while j < n, t[j] == 0x20 || t[j] == 0x09 || t[j] == 0x0D { j += 1 }
                if j < n, t[j] == 0x0A { found.append((.sentence, i)) }
            }
            if b == 0x0A { found.append((.line, i)) }
            var clause: Int?
            if b == 0x2C || b == 0x3B || b == 0x3A { clause = i + 1 }
            if has(emDash, at: i) || has(enDash, at: i) { clause = i + 3 }
            if let e = clause, e < n, isSpace(t[e]) { found.append((.clause, e)) }
            if isSpace(b) { found.append((.space, i)) }
        }
        return found
    }

    static func phraseEnd(utf8: [UInt8], start: Int) -> Int {
        let t = readable(utf8)
        let n = t.count
        let s = max(start, 0)
        if s >= n { return n }
        let limit = min(n, s + PHRASE_MAX_BYTES)
        let all = boundaries(t, from: s, below: limit).filter { $0.1 <= limit && $0.1 - s >= PHRASE_MIN_BYTES }
        for (kind, e) in all where kind == .sentence {
            let tail = phraseStart(utf8: t, at: e)
            if tail >= n || n - tail >= PHRASE_MIN_BYTES { return e }
        }
        if limit == n { return n }
        for kind in [Kind.line, .clause, .space] {
            if let last = all.last(where: { $0.0 == kind }) { return last.1 }
        }
        var j = limit
        while j > s, isContinuation(t[j]) { j -= 1 }
        return j > s ? j : limit
    }

    static func phraseRanges(utf8: [UInt8]) -> [Range<Int>] {
        let n = min(utf8.count, TEXT_MAX)
        var ranges: [Range<Int>] = []
        var start = phraseStart(utf8: utf8, at: 0)
        while start < n {
            let end = phraseEnd(utf8: utf8, start: start)
            ranges.append(start..<end)
            start = phraseStart(utf8: utf8, at: end)
        }
        return ranges
    }
}
