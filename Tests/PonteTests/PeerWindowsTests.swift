import Foundation
@testable import PontePeer
import Testing

/// «Русские в звонке»: which incoming phrases are a Ponte's own voice (PeerWindows over PeerRules.isPeerVoice).
@Suite("Peer voice windows") struct PeerWindowsTests {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func at(_ seconds: Double) -> Date { t0.addingTimeInterval(seconds) }

    private func record(_ w: PeerWindows, _ kind: Int, _ state: Int, _ text: String, at seconds: Double, sender: UInt64 = 7) {
        w.record(sender: sender, kind: kind, state: state, text: text, at: at(seconds))
    }

    @Test func ttsOfAnotherPonteIsDroppedOtherSpeechIsNot() {
        let w = PeerWindows()
        record(w, PeerRules.voiceTTS, PeerRules.voiceStart, "Oi, como você está?", at: 10)
        record(w, PeerRules.voiceTTS, PeerRules.voiceEnd, "Oi, como você está?", at: 12)
        // The other Ponte's voice, recognized here a little later.
        #expect(w.isPeerVoice("Oi como você está", start: at(10.3), end: at(12.4), now: at(13)))
        // The Portuguese side answers right after: other words.
        #expect(!w.isPeerVoice("Estou bem, obrigado", start: at(12.6), end: at(14.0), now: at(14)))
        // Much later, the same words are the other side's own.
        #expect(!w.isPeerVoice("Oi como você está", start: at(60), end: at(62), now: at(62)))
    }

    @Test func aQuickReplyThatRepeatsTheQuestionStays() {
        let w = PeerWindows()
        record(w, PeerRules.voiceTTS, PeerRules.voiceStart, "Podemos começar agora?", at: 10)
        record(w, PeerRules.voiceTTS, PeerRules.voiceEnd, "Podemos começar agora?", at: 11.5)
        // 3 of its 4 words are in the question (750 < 800): the Brazilian's reply is translated.
        #expect(!w.isPeerVoice("Sim, podemos começar agora", start: at(11.8), end: at(13), now: at(13)))
    }

    @Test func aShortTailOfALongTTSIsDropped() {
        let w = PeerWindows()
        let long = "Bom dia a todos, obrigado por virem hoje, vamos falar sobre o contrato amanhã de manhã com calma"
        record(w, PeerRules.voiceTTS, PeerRules.voiceStart, long, at: 10)
        record(w, PeerRules.voiceTTS, PeerRules.voiceEnd, long, at: 18)
        #expect(w.isPeerVoice("o contrato amanhã de manhã", start: at(16), end: at(18.3), now: at(19)))
    }

    @Test func ownVoiceFollowsSpeechAndEndsWithoutRefresh() {
        let w = PeerWindows()
        record(w, PeerRules.voiceOwn, PeerRules.voiceStart, "", at: 20)
        // Still renewed: open.
        record(w, PeerRules.voiceOwn, PeerRules.voiceStart, "", at: 25)
        #expect(w.isPeerVoice("qualquer coisa", start: at(25), end: at(27), now: at(27)))
        // The end got lost and nothing renews it: it ends by itself after PeerRules.voiceStaleMs.
        #expect(!w.isPeerVoice("bom dia", start: at(60), end: at(62), now: at(62)))
    }

    @Test func aPeerWhoLeftEndsHisWindows() {
        let w = PeerWindows()
        record(w, PeerRules.voiceOwn, PeerRules.voiceStart, "", at: 20)
        w.close(sender: 7, at: at(22))
        #expect(!w.isPeerVoice("bom dia", start: at(24), end: at(26), now: at(26)))
    }

    @Test func aNewTTSEndsThePreviousOneOfTheSameSender() {
        let w = PeerWindows()
        record(w, PeerRules.voiceTTS, PeerRules.voiceStart, "Vamos começar", at: 5, sender: 1)
        record(w, PeerRules.voiceTTS, PeerRules.voiceEnd, "Vamos começar", at: 7, sender: 2)   // another sender: ignored
        #expect(w.isPeerVoice("vamos começar", start: at(8), end: at(9), now: at(9)))
        record(w, PeerRules.voiceTTS, PeerRules.voiceStart, "Qual é o prazo?", at: 10, sender: 1)
        // The first window ended at 10 s; well after its text window it no longer matches.
        #expect(!w.isPeerVoice("vamos começar", start: at(40), end: at(41), now: at(41)))
        w.removeAll()
        #expect(!w.isPeerVoice("qual é o prazo", start: at(10.5), end: at(11), now: at(11)))
    }
}
