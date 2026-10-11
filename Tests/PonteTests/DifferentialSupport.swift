// Owned by the t27 agent. Support for the differential tests: every facade function (Swift calling the
// C generated from Specs/*.t27) against its legacy Swift oracle (Tests/PonteTests/Oracles), bit for bit.
// Inputs are exhaustive over small domains and seeded random elsewhere (no clocks, no system randomness).
import Foundation
import Testing

/// SplitMix64: a small deterministic generator.
struct DiffRandom {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func int(_ range: ClosedRange<Int>) -> Int {
        let span = UInt64(bitPattern: Int64(range.upperBound) &- Int64(range.lowerBound)) &+ 1
        if span == 0 { return Int(bitPattern: UInt(next())) }
        return range.lowerBound &+ Int(bitPattern: UInt(next() % span))
    }

    mutating func int64(_ range: ClosedRange<Int64>) -> Int64 { Int64(int(Int(range.lowerBound)...Int(range.upperBound))) }
    mutating func int32(_ range: ClosedRange<Int32>) -> Int32 { Int32(int(Int(range.lowerBound)...Int(range.upperBound))) }
    mutating func bool() -> Bool { next() & 1 == 1 }
    mutating func pick<T>(_ values: [T]) -> T { values[int(0...(values.count - 1))] }

    /// Mostly ordinary values in -2…2, then edges, then any bit pattern (NaN, infinities, subnormals).
    mutating func float() -> Float {
        switch int(0...9) {
        case 0...4: return Float(Double(int(-2_000_000...2_000_000)) / 1_000_000)
        case 5: return pick(Self.floatEdges)
        case 6: return Float(bitPattern: UInt32(truncatingIfNeeded: next()))
        case 7: return Float(int(-40_000...40_000))
        default: return Float(Double(int(-1_000_000...1_000_000)) / 1e9)
        }
    }

    mutating func double() -> Double {
        switch int(0...9) {
        case 0...4: return Double(int(-2_000_000...2_000_000)) / 1000
        case 5: return pick(Self.doubleEdges)
        case 6: return Double(bitPattern: next())
        default: return Double(int(0...400_000))
        }
    }

    /// A Double that Swift can turn into an Int without trapping (no NaN, no infinity, no huge values).
    mutating func finiteDouble(_ limit: Double = 1e9) -> Double {
        Double(int(-1_000_000_000...1_000_000_000)) / 1_000_000_000 * limit
    }

    static let floatEdges: [Float] = [0, -0.0, 1, -1, 0.5, -0.5, 2, -2, .infinity, -.infinity, .nan, -.nan,
                                      .leastNonzeroMagnitude, -.leastNonzeroMagnitude, .leastNormalMagnitude,
                                      .greatestFiniteMagnitude, -.greatestFiniteMagnitude, 1e-9, 1e-6, 0.001, 0.0005]
    static let doubleEdges: [Double] = [0, -0.0, 1, -1, 0.5, .infinity, -.infinity, .nan, .leastNonzeroMagnitude,
                                        .greatestFiniteMagnitude, 44_100, 48_000, 16_000, 22_050, 11_025, 8_000]

    mutating func floats(_ count: Int) -> [Float] { (0..<count).map { _ in float() } }

    /// Text built from pieces that matter to the byte rules: ASCII letters and digits, punctuation, spaces,
    /// quotes, Portuguese and Cyrillic letters, typographic marks (« » “ ” … — –), Markdown specials, CR/LF.
    mutating func text(maxPieces: Int) -> String {
        let n = int(0...maxPieces)
        var s = ""
        for _ in 0..<n { s += pick(Self.pieces) }
        return s
    }

    /// Any bytes, including invalid UTF-8 and continuation bytes on their own.
    mutating func bytes(maxCount: Int) -> [UInt8] {
        (0..<int(0...maxCount)).map { _ in
            switch int(0...3) {
            case 0: return UInt8(truncatingIfNeeded: next())
            case 1: return pick(Self.specialBytes)
            default: return UInt8(int(0x20...0x7E))
            }
        }
    }

    static let pieces: [String] = [
        "a", "b", "Z", "x", "ok", "Bom", "dia", "sim", "não", "você", "ação", "então", "Preço", "É", "é", "ç",
        "Я", "да", "конец", "привет", "Ж", "ё", "1", "2", "10", "3", "2026", " ", "  ", "\t", "\n", "\r", "\r\n",
        ".", ",", "!", "?", ";", ":", "\"", "'", ")", "(", "«", "»", "“", "”", "…", "—", "–", "-", "+", "=",
        "*", "_", "#", "|", "~", "&", "<", ">", "[", "]", "`", "\\", "/", "\u{00A0}", "👍", "€", "™",
    ]
    static let specialBytes: [UInt8] = [0x20, 0x09, 0x0A, 0x0D, 0x22, 0x27, 0x29, 0x2E, 0x21, 0x3F, 0x2C, 0x3B, 0x3A,
                                        0xC2, 0xBB, 0xAB, 0xE2, 0x80, 0x81, 0x9D, 0xA6, 0x94, 0x93, 0xC3, 0xD0, 0xBF,
                                        0x30, 0x39, 0x2D, 0x2B, 0x3D, 0x5C, 0x60, 0x2A, 0x5F, 0x5B, 0x5D, 0x3C, 0x3E,
                                        0x23, 0x7C, 0x7E, 0x26, 0x41, 0x5A, 0x61, 0x7A, 0x00, 0xFF]
}

/// Collects comparisons of facade (C) and legacy (Swift) results and reports the first mismatches.
final class DiffLog {
    let name: String
    private(set) var cases = 0
    private(set) var failures: [String] = []

    init(_ name: String) { self.name = name }

    func check<T: Equatable>(_ facade: T, _ legacy: T, _ input: @autoclosure () -> String) {
        cases += 1
        if facade != legacy, failures.count < 5 { failures.append("\(input()): facade \(facade), legacy \(legacy)") }
        else if facade != legacy { failures.append("") }
    }

    /// Floats compare by bit pattern; two NaNs compare equal whatever their payload.
    func check(_ facade: Float, _ legacy: Float, _ input: @autoclosure () -> String) {
        check(Self.bits(facade), Self.bits(legacy), input())
    }

    func check(_ facade: Double, _ legacy: Double, _ input: @autoclosure () -> String) {
        check(facade.isNaN && legacy.isNaN ? 0 : facade.bitPattern, facade.isNaN && legacy.isNaN ? 0 : legacy.bitPattern, input())
    }

    func check(_ facade: [Float], _ legacy: [Float], _ input: @autoclosure () -> String) {
        check(facade.map(Self.bits), legacy.map(Self.bits), input())
    }

    static func bits(_ x: Float) -> UInt32 { x.isNaN ? 0x7FC0_0000 : x.bitPattern }

    /// Records the totals in the test log and fails the test on any mismatch.
    func finish(minimumCases: Int = 1, sourceLocation: SourceLocation = #_sourceLocation) {
        print("differential \(name): \(cases) cases, \(failures.count) mismatches")
        DiffTotals.add(cases)
        #expect(cases >= minimumCases, "\(name): only \(cases) cases", sourceLocation: sourceLocation)
        #expect(failures.isEmpty, "\(name): \(failures.filter { !$0.isEmpty }.joined(separator: "; "))",
                sourceLocation: sourceLocation)
    }
}

enum DiffTotals {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var total = 0
    static func add(_ n: Int) { lock.withLock { total += n } }
    static var cases: Int { lock.withLock { total } }
}

func describe(_ values: Any...) -> String { values.map { "\($0)" }.joined(separator: ", ") }
