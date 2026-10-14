import Testing
@testable import PonteSpeech

/// The female/male switch for the Portuguese voice: the facade (generated C) against its oracle.
@Suite("Differential: voice gender switch") struct VoiceGenderTests {
    typealias F = SpeechRules
    typealias L = SpeechRulesLegacy

    @Test func pickAndShow() {
        #expect(F.genderUnspecified == 0 && F.genderMale == 1 && F.genderFemale == 2)
        #expect(F.pickGender(genders: [], want: F.genderMale) == -1)
        #expect(F.pickGender(genders: [2, 0, 1, 1], want: F.genderMale) == 2)
        #expect(F.pickGender(genders: [2, 0, 1, 1], want: F.genderFemale) == 0)
        #expect(F.switchGender(0) == F.genderFemale && F.switchGender(1) == F.genderMale)
        var seed: UInt64 = 0x9E3779B97F4A7C15
        func next(_ bound: Int) -> Int {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Int((seed >> 33) % UInt64(bound))
        }
        var mismatches = 0
        for _ in 0..<50_000 {
            let count = next(90)
            let genders = (0..<count).map { _ in next(4) - (next(10) == 0 ? 3 : 0) }
            let want = next(5) - 1
            if F.pickGender(genders: genders, want: want) != L.pickGender(genders: genders, want: want) { mismatches += 1 }
        }
        for g in -3...5 where F.switchGender(g) != L.switchGender(g) { mismatches += 1 }
        let ids = ["com.apple.eloquence.pt-BR.Eddy", "com.apple.voice.enhanced.pt-BR.Felipe", "com.apple.voice.compact.pt-BR.Luciana",
                   "com.apple.eloquence.pt-BR.Grandpa", "com.apple.eloquence.pt-BR.Grandma", "x.Reed", ".Rocko", "Rocko", "", ".Eddy.x",
                   "com.apple.siri.natural.Sandra", "ééé.Felipe", String(repeating: "a", count: 1100) + ".Eddy"]
        for id in ids {
            for g in -1...3 where F.effectiveGender(gender: g, identifierUTF8: Array(id.utf8)) != L.effectiveGender(gender: g, identifierUTF8: Array(id.utf8)) {
                mismatches += 1
            }
        }
        #expect(F.effectiveGender(gender: 0, identifierUTF8: Array("com.apple.eloquence.pt-BR.Eddy".utf8)) == F.genderMale)
        #expect(F.effectiveGender(gender: 0, identifierUTF8: Array("com.apple.voice.compact.pt-BR.Luciana".utf8)) == F.genderUnspecified)
        #expect(mismatches == 0)
    }
}
