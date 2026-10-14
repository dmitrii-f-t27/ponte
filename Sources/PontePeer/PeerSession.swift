import AVFoundation
import Foundation
import PonteAudio
import PonteCore

/// The other Russians' voices in the owner's ears: one player per Russian (players do not mix one stream into
/// another), on the same output as Ponte's Russian voice (`device`, nil: the system output, which Ponte never lets be
/// BlackHole, dv_output_needs_rescue), so this Russian voice cannot reach the call. A jitter buffer for the internet
/// (peer_rules.t27) smooths the frames. `onPlay` is told on every frame (the echo guard on speakers).
public final class PeerVoices: @unchecked Sendable {
    private let lock = NSLock()
    private var voices: [UInt64: (player: DeviceAudioPlayer, relay: LiveRelay)] = [:]
    private var device: AudioDevice?
    /// When each Russian's voice last played; its own lock, never held across audio work (the UI reads it).
    private let timesLock = NSLock()
    private var lastAt: [UInt64: Date] = [:]

    /// Called on the link queue for every frame that is played.
    public var onPlay: (() -> Void)?

    public static let rules = LiveRelay.Rules(
        action: { PeerRules.jitterAction(filling: $0, pendingMs: $1, queuedMs: $2, lowMs: $3, lowCount: $4) },
        windowEnds: { PeerRules.jitterWindowEnds(lowCount: $0) },
        trims: { PeerRules.jitterTrims(pendingMs: $0, oldestMs: $1) })

    public init() {}

    /// Where the owner hears Ponte («Мои наушники», nil: the system output). Players start again there.
    public func setDevice(_ device: AudioDevice?) {
        let changed = lock.withLock { () -> Bool in
            guard self.device?.uid != device?.uid else { return false }
            self.device = device
            return true
        }
        if changed { stopAll() }
    }

    /// A frame from `sender`; on the link queue. PeerLink admits at most PeerRules.maxPeers - 1 senders.
    public func play(_ buffer: AVAudioPCMBuffer, from sender: UInt64) {
        var relay = lock.withLock { voices[sender]?.relay }
        if relay == nil {
            // Start the player without holding the lock: an engine start takes tens of milliseconds.
            let target = lock.withLock { device }
            let player = DeviceAudioPlayer(device: target)
            try? player.prepare()
            let made = LiveRelay(player: player, rules: Self.rules)
            let (kept, spare) = lock.withLock { () -> (LiveRelay, DeviceAudioPlayer?) in
                if let existing = voices[sender] { return (existing.relay, player) }
                voices[sender] = (player, made)
                return (made, nil)
            }
            spare?.stopAll()
            relay = kept
        }
        timesLock.withLock { lastAt[sender] = Date() }
        relay?.push(buffer)
        onPlay?()
    }

    /// Whether another Russian's voice reached the owner within the last half second (for the UI).
    public var speaking: Bool {
        timesLock.withLock { lastAt.values.contains { Date().timeIntervalSince($0) < 0.5 } }
    }

    /// A Russian left the room.
    public func remove(_ sender: UInt64) {
        let voice = lock.withLock { voices.removeValue(forKey: sender) }
        timesLock.withLock { _ = lastAt.removeValue(forKey: sender) }
        voice?.relay.stop()
        voice?.player.stopAll()
    }

    public func stopAll() {
        let all = lock.withLock { () -> [(player: DeviceAudioPlayer, relay: LiveRelay)] in
            defer { voices.removeAll() }
            return Array(voices.values)
        }
        timesLock.withLock { lastAt.removeAll() }
        for voice in all {
            voice.relay.stop()
            voice.player.stopAll()
        }
    }
}

/// When a Ponte speaks into the call, and what it says: the windows that let this Ponte drop that voice instead of
/// translating it back into Russian (PeerRules.isPeerVoiceV2). Windows come from the other Russians' Pontes and, with
/// sender 0, from this Ponte itself (its own voice echoed back by the far side). A window still playing is renewed by
/// every START (PeerRules.voiceRefreshMs); one that stopped being renewed ends by itself (PeerRules.windowEndMs).
/// Thread-safe.
public final class PeerWindows: @unchecked Sendable {
    private struct Window {
        let sender: UInt64
        let kind: Int
        let text: String
        let startMs: Int64
        var lastSeenMs: Int64
        var endMs: Int64   // -1 while it plays
    }

    private let lock = NSLock()
    private var windows: [Window] = []

    public init() {}

    public func record(_ event: PeerLink.VoiceEvent) {
        record(sender: event.sender, kind: event.kind, state: event.state, text: event.text, at: event.receivedAt)
    }

    public func record(sender: UInt64, kind: Int, state: Int, text: String, at date: Date) {
        let ms = Self.ms(date)
        lock.withLock {
            windows.removeAll {
                let end = PeerRules.windowEndMs(endMs: $0.endMs, lastSeenMs: $0.lastSeenMs, nowMs: ms, refreshed: $0.sender != 0)
                return end >= 0 && ms - end > PeerRules.windowKeepMs
            }
            let open = windows.lastIndex { $0.sender == sender && $0.kind == kind && $0.endMs < 0 }
            if state == PeerRules.voiceStart {
                if let i = open, windows[i].text == text {
                    windows[i].lastSeenMs = ms   // the same voice, announced again
                    return
                }
                if let i = open { windows[i].endMs = ms }   // one voice of a kind at a time: a new one ends the old
                windows.append(Window(sender: sender, kind: kind, text: text, startMs: ms, lastSeenMs: ms, endMs: -1))
            } else if let i = open {
                windows[i].endMs = ms
            }
        }
    }

    /// Whether a phrase the owner's Ponte heard between `start` and `end` was a Ponte's voice (now: `now`).
    /// Sender 0 is this Ponte itself: its windows are never refreshed, so they never go stale, and its own voice
    /// (Meet never plays the owner's microphone back) and its Portuguese words repeated later are not dropped.
    public func isPeerVoice(_ text: String, start: Date, end: Date, now: Date = Date()) -> Bool {
        let s = Self.ms(start), e = Self.ms(end), n = Self.ms(now)
        let words = PeerRules.wordCount(text)
        let snapshot = lock.withLock { windows }
        return snapshot.contains { w in
            let contained = w.kind == PeerRules.voiceTTS ? PeerRules.containmentMilli(phrase: text, said: w.text) : 0
            let own = w.sender == 0
            return PeerRules.isPeerVoice(kind: w.kind, isSelf: own, phraseWords: words, containmentMilli: contained,
                                         phraseStartMs: s, phraseEndMs: e, windowStartMs: w.startMs,
                                         windowEndMs: PeerRules.windowEndMs(endMs: w.endMs, lastSeenMs: w.lastSeenMs,
                                                                            nowMs: n, refreshed: !own))
        }
    }

    /// A Russian left or went silent: his windows end now.
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
/// never when muted; only voice is sent (the caller's voice detector), not silence or room noise. `push` runs on the
/// capture thread.
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

    public func push(_ buffer: AVAudioPCMBuffer, voice: Bool) {
        let now = Date()
        let (target, wasSending, sends): (PeerLink?, Bool, Bool) = lock.withLock {
            if voice { lastSignalAt = now }
            let since = lastSignalAt.map { Int64(now.timeIntervalSince($0) * 1000) } ?? -1
            let open = PeerRules.sendsMic(linkUp: linkUp, muted: muted, headphonesLike: headphonesLike, keyHeld: keyHeld)
            let sends = open && PeerRules.vadSends(hasSignal: voice, msSinceSignal: since)
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
