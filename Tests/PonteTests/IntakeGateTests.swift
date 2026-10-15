import AVFoundation
import Foundation
@testable import PonteApp
import PonteAudio
import PonteCore
import Testing

/// What the outgoing lane's microphone may feed (AudioIntake + EchoGuard): the call («Свой голос» relay into
/// BlackHole) never gets a Russian voice the microphone may have heard; the other Russians never get Ponte's own
/// Russian voice from speakers; «Свой голос» start/stop follow speech and end even when the mic goes silent.
@Suite("Microphone gate") struct IntakeGateTests {
    /// Counts what a «Свой голос» relay hands to the call output.
    final class CountingPlayer: AudioPlayer, @unchecked Sendable {
        var device: AudioDevice? { nil }
        private let lock = NSLock()
        private var _streamed = 0
        var streamed: Int { lock.withLock { _streamed } }
        func play(_ buffer: AVAudioPCMBuffer) async {}
        func stopAll() {}
        func stream(_ buffers: [AVAudioPCMBuffer]) -> Double? {
            lock.withLock { _streamed += buffers.count }
            return 0
        }
        func streamQueuedMs() -> Double? { 0 }
    }

    final class Box<T>: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [T] = []
        func add(_ item: T) { lock.withLock { items.append(item) } }
        var all: [T] { lock.withLock { items } }
    }

    private func loud(_ seconds: Double = 0.02) -> AVAudioPCMBuffer {
        PCM.buffer([Float](repeating: 0.3, count: Int(48_000 * seconds)), sampleRate: 48_000)
    }
    /// The hum of a quiet room through a raw microphone: never exact zeros, about -54 dBFS.
    private func roomNoise(_ seconds: Double = 0.02) -> AVAudioPCMBuffer {
        let n = Int(48_000 * seconds)
        return PCM.buffer((0..<n).map { i in i % 2 == 0 ? 0.002 : -0.002 }, sampleRate: 48_000)
    }

    private final class Clock: @unchecked Sendable {
        var now = Date(timeIntervalSince1970: 1_800_000_000)
    }

    @Test func peerVoiceOnAnUnsealedOutputNeverReachesTheCall() {
        let clock = Clock()
        let intake = AudioIntake(clock: { clock.now })
        let echo = EchoGuard()
        echo.setOutput(speakerOutput: false, sealed: false)   // a Bluetooth speaker with the Mac's own microphone
        intake.setEchoGuard(echo)
        let player = CountingPlayer()
        intake.setRelay(LiveRelay(player: player))
        let toPeers = Box<Bool>()
        intake.setPeerSink { _, signal in toPeers.add(signal) }

        // The other Russian speaks: his frames play, the mic hears them.
        echo.notePeerAudio(at: clock.now)
        for _ in 0..<20 { intake.handle(loud()) }
        #expect(player.streamed == 0)               // nothing into the call
        #expect(toPeers.all.isEmpty)                // and no echo of him back to the Russians

        // 0.7 s after his last frame the mic belongs to the owner again.
        clock.now = clock.now.addingTimeInterval(0.8)
        for _ in 0..<10 { intake.handle(loud()) }
        #expect(player.streamed > 0)
        #expect(toPeers.all.count == 10)
    }

    @Test func aSealedHeadsetKeepsTheCallOpen() {
        let clock = Clock()
        let intake = AudioIntake(clock: { clock.now })
        let echo = EchoGuard()
        echo.setOutput(speakerOutput: false, sealed: true)    // AirPods with their own microphone
        intake.setEchoGuard(echo)
        let player = CountingPlayer()
        intake.setRelay(LiveRelay(player: player))
        echo.notePeerAudio(at: clock.now)
        for _ in 0..<10 { intake.handle(loud()) }
        #expect(player.streamed > 0)
    }

    @Test func russianVoiceOnSpeakersGoesNowhere() {
        let clock = Clock()
        let intake = AudioIntake(clock: { clock.now })
        let echo = EchoGuard()
        echo.configure(speakerOutput: true)
        echo.setOutput(speakerOutput: true, sealed: false)
        intake.setEchoGuard(echo)
        let player = CountingPlayer()
        intake.setRelay(LiveRelay(player: player))
        let toPeers = Box<Bool>()
        intake.setPeerSink { _, signal in toPeers.add(signal) }
        echo.setSpeaking(true, at: clock.now)                 // Ponte's Russian voice plays through the speakers
        for _ in 0..<10 { intake.handle(loud()) }
        #expect(player.streamed == 0)
        #expect(toPeers.all.isEmpty)
    }

    @Test func ownVoiceTalkFollowsSpeechAndEndsWhenTheMicStops() {
        let clock = Clock()
        let intake = AudioIntake(clock: { clock.now })
        let events = Box<(Bool, Date)>()
        intake.onOwnTalk = { on, at in events.add((on, at)) }
        intake.setRelay(LiveRelay(player: CountingPlayer()))

        intake.handle(loud())
        #expect(events.all.map(\.0) == [true])
        let lastSignal = clock.now
        // The microphone stops delivering (its device went away): the poll ends the speech after the hangover,
        // stamped at the last sound, not at the time the hangover ran out.
        clock.now = clock.now.addingTimeInterval(2)
        intake.expireOwnTalk(at: clock.now)
        #expect(events.all.map(\.0) == [true, false])
        #expect(abs((events.all.last?.1 ?? .distantPast).timeIntervalSince(lastSignal)) < 0.001)
        // Turning «Свой голос» off while silent sends nothing more.
        intake.setRelay(nil)
        #expect(events.all.count == 2)
    }

    @Test func roomNoiseIsNotSpeech() {
        let clock = Clock()
        let intake = AudioIntake(clock: { clock.now })
        let events = Box<(Bool, Date)>()
        intake.onOwnTalk = { on, at in events.add((on, at)) }
        intake.setRelay(LiveRelay(player: CountingPlayer()))
        let toPeers = Box<Bool>()
        intake.setPeerSink { _, voice in toPeers.add(voice) }

        // A live microphone in a quiet room: every buffer has a little signal, none of it is the owner's voice.
        for _ in 0..<100 {
            intake.handle(roomNoise())
            clock.now = clock.now.addingTimeInterval(0.02)
        }
        #expect(events.all.isEmpty)
        #expect(toPeers.all.count == 100 && !toPeers.all.contains(true))

        // The owner speaks, then the room is quiet again: «Свой голос» ends after the hangover.
        intake.handle(loud())
        #expect(events.all.map(\.0) == [true])
        #expect(toPeers.all.last == true)
        let spoke = clock.now
        for _ in 0..<50 {
            clock.now = clock.now.addingTimeInterval(0.02)
            intake.handle(roomNoise())
        }
        #expect(events.all.map(\.0) == [true, false])
        // Stamped at the last word, on whole milliseconds (AppRules.ownTalkChangeMs).
        #expect(abs((events.all.last?.1 ?? .distantPast).timeIntervalSince(spoke)) < 0.001)
        #expect(toPeers.all.last == false)
    }

    @Test func turningOwnVoiceOffWhileSpeakingEndsIt() {
        let clock = Clock()
        let intake = AudioIntake(clock: { clock.now })
        let events = Box<(Bool, Date)>()
        intake.onOwnTalk = { on, at in events.add((on, at)) }
        intake.setRelay(LiveRelay(player: CountingPlayer()))
        intake.handle(loud())
        intake.setRelay(nil)
        #expect(events.all.map(\.0) == [true, false])
        // Buffers after the relay is gone never start a new speech.
        intake.handle(loud())
        #expect(events.all.count == 2)
    }
}
