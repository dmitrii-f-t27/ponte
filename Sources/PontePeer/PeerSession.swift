import AVFoundation
import Foundation
import PonteAudio
import PonteCore

/// The other Russians' voices in the owner's ears: one player per Russian (players do not mix one stream into
/// another), each following the system output, which Ponte never lets be BlackHole (dv_output_needs_rescue), so
/// this Russian voice cannot reach the call. A jitter buffer for the internet (peer_rules.t27) smooths the frames.
public final class PeerVoices: @unchecked Sendable {
    private let lock = NSLock()
    private var voices: [UInt64: (player: DeviceAudioPlayer, relay: LiveRelay, lastAt: Date)] = [:]
    private var _speaking = false

    public static let rules = LiveRelay.Rules(
        action: { PeerRules.jitterAction(filling: $0, pendingMs: $1, queuedMs: $2, lowMs: $3, lowCount: $4) },
        windowEnds: { PeerRules.jitterWindowEnds(lowCount: $0) },
        trims: { PeerRules.jitterTrims(pendingMs: $0, oldestMs: $1) })

    public init() {}

    /// A frame from `sender`; on the link queue.
    public func play(_ buffer: AVAudioPCMBuffer, from sender: UInt64) {
        let relay: LiveRelay = lock.withLock {
            if let voice = voices[sender] {
                voices[sender]?.lastAt = Date()
                return voice.relay
            }
            let player = DeviceAudioPlayer(device: nil)
            try? player.prepare()
            let relay = LiveRelay(player: player, rules: Self.rules)
            voices[sender] = (player, relay, Date())
            return relay
        }
        relay.push(buffer)
    }

    /// Whether another Russian's voice reached the owner within the last half second (for the UI).
    public var speaking: Bool {
        lock.withLock { voices.values.contains { Date().timeIntervalSince($0.lastAt) < 0.5 } }
    }

    /// A Russian left the room.
    public func remove(_ sender: UInt64) {
        let voice = lock.withLock { voices.removeValue(forKey: sender) }
        voice?.relay.stop()
        voice?.player.stopAll()
    }

    public func stopAll() {
        let all = lock.withLock { () -> [(player: DeviceAudioPlayer, relay: LiveRelay, lastAt: Date)] in
            defer { voices.removeAll() }
            return Array(voices.values)
        }
        for voice in all {
            voice.relay.stop()
            voice.player.stopAll()
        }
    }
}

/// When another Ponte speaks into the call, and what it says: the windows that let this Ponte drop that
/// Portuguese voice instead of translating it back into Russian (PeerRules.isPeerVoice). Thread-safe.
public final class PeerWindows: @unchecked Sendable {
    private struct Window {
        let sender: UInt64
        let kind: Int
        let text: String
        let startMs: Int64
        var endMs: Int64   // -1 while it plays
    }

    private let lock = NSLock()
    private var windows: [Window] = []

    public init() {}

    public func record(_ event: PeerLink.VoiceEvent) {
        let ms = Self.ms(event.receivedAt)
        lock.withLock {
            windows.removeAll { $0.endMs >= 0 && ms - $0.endMs > PeerRules.windowKeepMs }
            if event.state == PeerRules.voiceStart {
                windows.append(Window(sender: event.sender, kind: event.kind, text: event.text, startMs: ms, endMs: -1))
            } else if let i = windows.lastIndex(where: { $0.sender == event.sender && $0.kind == event.kind && $0.endMs < 0 }) {
                windows[i].endMs = ms
            }
        }
    }

    /// Whether a Portuguese phrase the owner's Ponte heard between `start` and `end` was another Ponte's voice.
    public func isPeerVoice(_ text: String, start: Date, end: Date) -> Bool {
        let s = Self.ms(start), e = Self.ms(end)
        let snapshot = lock.withLock { windows }
        return snapshot.contains { w in
            let similarity = w.kind == PeerRules.voiceTTS ? PeerRules.wordSimilarityMilli(text, w.text) : 0
            return PeerRules.isPeerVoice(kind: w.kind, similarityMilli: similarity, phraseStartMs: s, phraseEndMs: e,
                                         windowStartMs: w.startMs, windowEndMs: w.endMs)
        }
    }

    /// A Russian left or went silent: his windows end now (an open «Свой голос» window would otherwise drop
    /// every phrase of the other side).
    public func close(sender: UInt64, at date: Date = Date()) {
        let ms = Self.ms(date)
        lock.withLock {
            for i in windows.indices where windows[i].sender == sender && windows[i].endMs < 0 { windows[i].endMs = ms }
        }
    }

    public func removeAll() { lock.withLock { windows.removeAll() } }

    static func ms(_ date: Date) -> Int64 { Int64((date.timeIntervalSince1970 * 1000).rounded()) }
}

/// The owner's microphone to the other Russians (PeerRules.sendsMic, vadSends): always with headphones, only
/// while the push-to-talk key is held without them (speakers would send the other Russian back as an echo),
/// never when muted; silence is not sent. `push` runs on the capture thread.
public final class PeerMicGate: @unchecked Sendable {
    private let lock = NSLock()
    private var link: PeerLink?
    private var linkUp = false
    private var muted = false
    private var headphonesLike = false
    private var keyHeld = false
    private var lastSignalAt: Date?
    private var sending = false

    public init() {}

    public func update(link: PeerLink?, linkUp: Bool, muted: Bool, headphonesLike: Bool, keyHeld: Bool) {
        lock.withLock {
            self.link = link
            self.linkUp = linkUp
            self.muted = muted
            self.headphonesLike = headphonesLike
            self.keyHeld = keyHeld
        }
    }

    public func push(_ buffer: AVAudioPCMBuffer, hasSignal: Bool) {
        let now = Date()
        let (target, wasSending, sends): (PeerLink?, Bool, Bool) = lock.withLock {
            if hasSignal { lastSignalAt = now }
            let since = lastSignalAt.map { Int64(now.timeIntervalSince($0) * 1000) } ?? -1
            let open = PeerRules.sendsMic(linkUp: linkUp, muted: muted, headphonesLike: headphonesLike, keyHeld: keyHeld)
            let sends = open && PeerRules.vadSends(hasSignal: hasSignal, msSinceSignal: since)
            defer { sending = sends }
            return (link, sending, sends)
        }
        if sends {
            target?.sendMicrophone(buffer)
        } else if wasSending {
            target?.flushMicrophone()
        }
    }
}
