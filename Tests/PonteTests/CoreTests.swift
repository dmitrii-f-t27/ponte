import AVFoundation
import Testing
@testable import PonteCore

@Test func directionLanguages() {
    #expect(Direction.incoming.source == .ptBR)
    #expect(Direction.outgoing.target == .ptBR)
}

// Default implementations of the additive contract requirements.

private final class CoreTestPlayer: AudioPlayer {
    let device: AudioDevice? = nil
    var played: [AVAudioFrameCount] = []
    func play(_ buffer: AVAudioPCMBuffer) async { played.append(buffer.frameLength) }
    func stopAll() {}
}

private final class CoreTestSynth: SpeechSynth {
    var calls = 0
    func synthesize(_ text: String, lang: Lang) async throws -> [AVAudioPCMBuffer] {
        calls += 1
        return []
    }
}

private final class CoreTestTranscriber: Transcriber {
    let language = Lang.ru
    func prepare() async throws {}
    func start() throws -> AsyncStream<TranscriptEvent> { AsyncStream { $0.finish() } }
    func append(_ buffer: AVAudioPCMBuffer) {}
    func finish() async {}
}

@Test func contractDefaults() async throws {
    let format = AVAudioFormat(standardFormatWithSampleRate: 22_050, channels: 1)!
    let buffers = [100, 200].map { n -> AVAudioPCMBuffer in
        let b = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(n))!
        b.frameLength = AVAudioFrameCount(n)
        return b
    }
    let player = CoreTestPlayer()
    await player.play(buffers)                       // default: one after another, in order
    #expect(player.played == [100, 200])

    let synth = CoreTestSynth()
    _ = try await synth.synthesize("x", lang: .ru, ratePercent: 130)   // default: rate ignored
    #expect(synth.calls == 1)

    #expect(CoreTestTranscriber().timing(for: UUID()) == nil)

    let line = ConversationLine(direction: .incoming, original: "Olá")
    let decoded = try JSONDecoder().decode(ConversationLine.self, from: JSONEncoder().encode(line))
    #expect(decoded.translationError == nil && decoded.original == "Olá")
}
