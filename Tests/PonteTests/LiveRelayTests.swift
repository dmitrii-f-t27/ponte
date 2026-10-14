// «Свой голос» (2026-10-13): the relay from the microphone to the call output, against a fake player whose
// queue the test controls. The decisions are AudioRules.relayAction / relayTrims (audio_rules.t27).
import AVFoundation
import Foundation
import PonteCore
import Testing
@testable import PonteAudio

private final class RelayTestPlayer: AudioPlayer {
    let device: AudioDevice? = nil
    /// What the output still has to play; nil = not running.
    var queuedMs: Double? = 0
    private(set) var streamed: [AVAudioPCMBuffer] = []
    private(set) var sends = 0

    func play(_ buffer: AVAudioPCMBuffer) async {}
    func stopAll() {}
    func stream(_ buffers: [AVAudioPCMBuffer]) -> Double? {
        guard let queued = queuedMs else { return nil }
        sends += 1
        streamed += buffers
        let added = buffers.reduce(0.0) { $0 + Double($1.frameLength) / $1.format.sampleRate * 1000 }
        queuedMs = queued + added
        return queuedMs
    }
    func streamQueuedMs() -> Double? { queuedMs }
}

/// 10 ms of mono at 48 kHz.
private func tenMs() -> AVAudioPCMBuffer {
    let b = AVAudioPCMBuffer(pcmFormat: PCM.monoFormat(sampleRate: 48_000), frameCapacity: 480)!
    b.frameLength = 480
    return b
}

@Suite("LiveRelay: the own voice into the call") struct LiveRelayTests {

    @Test func fillsTheJitterBufferThenSendsAsItComes() {
        let player = RelayTestPlayer()
        let relay = LiveRelay(player: player)
        let first = (0..<4).map { _ in tenMs() }
        for (i, b) in first.enumerated() {
            relay.push(b)
            #expect(player.sends == (i < 3 ? 0 : 1))                      // 40 ms gathered, then sent at once
        }
        #expect(player.streamed.map(ObjectIdentifier.init) == first.map(ObjectIdentifier.init))
        // The output plays as the microphone delivers: every later buffer goes out on its own, in order.
        var all = first
        for _ in 0..<100 {
            player.queuedMs = max((player.queuedMs ?? 0) - 10, 0)
            let b = tenMs()
            all.append(b)
            relay.push(b)
        }
        #expect(player.streamed.map(ObjectIdentifier.init) == all.map(ObjectIdentifier.init))
        #expect(player.sends == 101)
        #expect(relay.stats == LiveRelay.Stats(sent: 104, dropped: 0, trimmed: 0, refills: 0, maxQueuedMs: 40))
    }

    @Test func dropsWhatWouldLeaveTheOutputTooFarBehind() {
        let player = RelayTestPlayer()
        let relay = LiveRelay(player: player)
        for _ in 0..<4 { relay.push(tenMs()) }
        player.queuedMs = 75                                              // the output fell behind
        relay.push(tenMs())
        #expect(relay.stats.dropped == 1 && player.streamed.count == 4)
        player.queuedMs = 60
        relay.push(tenMs())
        #expect(relay.stats.dropped == 1 && player.streamed.count == 5)
    }

    /// After a rebuild the output started late and holds 30 ms too much: one buffer goes per half second until
    /// the queue comes down to the target plus the slack.
    @Test func comesBackDownWhenTheQueueStaysTooDeep() {
        let player = RelayTestPlayer()
        let relay = LiveRelay(player: player)
        for _ in 0..<4 { relay.push(tenMs()) }
        player.queuedMs = 70
        for _ in 0..<300 {
            relay.push(tenMs())
            player.queuedMs = max((player.queuedMs ?? 0) - 10, 0)
        }
        #expect(relay.stats.dropped == 2)
        #expect(player.queuedMs == 50)
    }

    @Test func refillsAfterTheOutputRanDry() {
        let player = RelayTestPlayer()
        let relay = LiveRelay(player: player)
        for _ in 0..<4 { relay.push(tenMs()) }
        player.queuedMs = 0                                               // played everything: a gap
        relay.push(tenMs())
        #expect(relay.stats.refills == 1 && player.streamed.count == 4)
        for _ in 0..<2 { relay.push(tenMs()) }
        #expect(player.streamed.count == 4)
        relay.push(tenMs())                                               // 40 ms again
        #expect(player.streamed.count == 8)
    }

    /// A device change: the output is rebuilding. Only the newest 40 ms wait; forwarding goes on afterwards.
    @Test func keepsTheNewestAudioWhileTheOutputRebuilds() {
        let player = RelayTestPlayer()
        let relay = LiveRelay(player: player)
        for _ in 0..<4 { relay.push(tenMs()) }
        player.queuedMs = nil
        let during = (0..<20).map { _ in tenMs() }
        for b in during { relay.push(b) }
        #expect(player.streamed.count == 4)
        #expect(relay.stats.trimmed == 16)
        player.queuedMs = 0                                               // rebuilt
        let next = tenMs()
        relay.push(next)                                                  // 50 ms waiting: sent
        #expect(player.streamed.map(ObjectIdentifier.init).suffix(5) == (during.suffix(4) + [next]).map(ObjectIdentifier.init))
    }

    @Test func stopForwardsNothingMore() {
        let player = RelayTestPlayer()
        let relay = LiveRelay(player: player)
        for _ in 0..<3 { relay.push(tenMs()) }
        let stats = relay.stop()
        #expect(stats.sent == 0)
        for _ in 0..<10 { relay.push(tenMs()) }
        #expect(player.streamed.isEmpty)
    }
}
