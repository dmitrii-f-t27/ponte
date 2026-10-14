import Foundation
@testable import PontePeer
import Testing

/// «Русские в звонке»: which incoming phrases are another Ponte's voice (PeerWindows over PeerRules.isPeerVoice).
@Suite("Peer voice windows") struct PeerWindowsTests {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func event(_ kind: Int, _ state: Int, _ text: String, at seconds: Double, sender: UInt64 = 7) -> PeerLink.VoiceEvent {
        PeerLink.VoiceEvent(sender: sender, kind: kind, state: state, text: text, receivedAt: t0.addingTimeInterval(seconds))
    }

    private func at(_ seconds: Double) -> Date { t0.addingTimeInterval(seconds) }

    @Test func ttsOfAnotherPonteIsDroppedOtherSpeechIsNot() {
        let w = PeerWindows()
        w.record(event(PeerRules.voiceTTS, PeerRules.voiceStart, "Oi, como você está?", at: 10))
        w.record(event(PeerRules.voiceTTS, PeerRules.voiceEnd, "Oi, como você está?", at: 12))
        // The other Ponte's voice, recognized here a little later.
        #expect(w.isPeerVoice("Oi como você está", start: at(10.3), end: at(12.4)))
        // The Portuguese side answers right after: other words.
        #expect(!w.isPeerVoice("Estou bem, obrigado", start: at(12.6), end: at(14.0)))
        // Much later, the same words are the other side's own.
        #expect(!w.isPeerVoice("Oi como você está", start: at(60), end: at(62)))
    }

    @Test func ownVoiceWindowDropsOverlapAndEndsWhenThePeerLeaves() {
        let w = PeerWindows()
        w.record(event(PeerRules.voiceOwn, PeerRules.voiceStart, "", at: 20))
        #expect(w.isPeerVoice("qualquer coisa", start: at(25), end: at(27)))
        // The peer vanished without an end event: his window must close, not drop everything forever.
        w.close(sender: 7, at: at(30))
        #expect(!w.isPeerVoice("bom dia", start: at(40), end: at(42)))
    }

    @Test func endPairsWithTheSameSenderAndKind() {
        let w = PeerWindows()
        w.record(event(PeerRules.voiceTTS, PeerRules.voiceStart, "Vamos começar", at: 5, sender: 1))
        w.record(event(PeerRules.voiceTTS, PeerRules.voiceEnd, "Vamos começar", at: 7, sender: 2))   // another sender
        // Sender 1's window is still open: a matching phrase much later still counts.
        #expect(w.isPeerVoice("vamos começar", start: at(40), end: at(41)))
        w.removeAll()
        #expect(!w.isPeerVoice("vamos começar", start: at(40), end: at(41)))
    }
}
