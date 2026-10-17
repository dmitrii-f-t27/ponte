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

// MARK: - Deadlines (the Stop and Quit waits, 2026-10-17)
// The work waits on a TestGate the test opens only after its checks: if a helper waited for the work, the test
// would hang and hit its time limit. No wall-clock thresholds, so a busy machine cannot make them flaky.

@Test func deadlineReturnsTheResultInTime() async throws {
    let value = try await withDeadline(ms: 2_000, onTimeout: { DeadlineExceeded(ms: 2_000) }) { 42 }
    #expect(value == 42)
}

@Test(.timeLimit(.minutes(1))) func deadlineDoesNotWaitForWorkThatIgnoresCancellation() async {
    let gate = TestGate()
    await #expect(throws: DeadlineExceeded.self) {
        try await withDeadline(ms: 100, onTimeout: { DeadlineExceeded(ms: 100) }) { () -> Int in
            await gate.wait()
            return 1
        }
    }
    #expect(gate.passed == 0)   // the deadline answered while the work was still stuck
    gate.open()
}

@Test(.timeLimit(.minutes(1))) func deadlineEndsAtOnceWhenTheCallerIsCancelled() async {
    let gate = TestGate()
    let caller = Task {
        try await withDeadline(ms: 600_000, onTimeout: { DeadlineExceeded(ms: 600_000) }) { () -> Int in
            await gate.wait()
            return 1
        }
    }
    await gate.waitForWaiter()
    caller.cancel()
    let result = await caller.result
    #expect(throws: CancellationError.self) { try result.get() }
    #expect(gate.passed == 0)
    gate.open()
}

@Test(.timeLimit(.minutes(1))) func waitAtMostSaysWhetherTheTaskEndedInTime() async {
    let quick = Task { 7 }
    #expect(await waitAtMost(quick, ms: 600_000))
    let gate = TestGate()
    let slow = Task { () -> Bool in
        await gate.wait()
        return Task.isCancelled
    }
    #expect(await waitAtMost(slow, ms: 100) == false)
    #expect(gate.passed == 0)
    gate.open()
    #expect(await slow.value == true)   // cancelled at the deadline, and left to end by itself
}
