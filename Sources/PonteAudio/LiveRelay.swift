import AVFoundation
import Foundation
import PonteCore

/// «Свой голос»: forwards live buffers (the microphone) to a player as they arrive, through a small jitter
/// buffer, with no recognition and no translation. AudioRules.relayAction (audio_rules.t27) decides each
/// step: fill RELAY_TARGET_MS (40 ms) first, then send every buffer; drop one that would leave the output more
/// than RELAY_MAX_MS (80 ms) behind, and one buffer per window of RELAY_WINDOW buffers whose queue never came
/// down to RELAY_TARGET_MS + RELAY_SLACK_MS (the output started late after a rebuild); fill again after the
/// output ran dry; while the output is not running (a device change, or a rebuilt engine that has not
/// rendered yet) keep only the newest RELAY_TARGET_MS, and go on once it runs again. Thread-safe: `push` runs
/// on the capture queue.
public final class LiveRelay: @unchecked Sendable {
    public struct Stats: Sendable, Equatable {
        /// Buffers handed to the output, dropped (output too far behind), trimmed (output not running), and how
        /// often the jitter buffer was filled again after the output ran dry.
        public var sent = 0
        public var dropped = 0
        public var trimmed = 0
        public var refills = 0
        /// The most the output had still to play after a send, in milliseconds.
        public var maxQueuedMs: Double = 0
    }

    private let lock = NSLock()
    private let player: AudioPlayer
    private var pending: [(buffer: AVAudioPCMBuffer, ms: Double)] = []
    private var pendingMs: Double = 0
    private var filling = true
    private var active = true
    // The current window: the lowest queue seen while flowing, and how many buffers it has seen.
    private var lowMs = Double.infinity
    private var lowCount = 0
    private var _stats = Stats()

    public init(player: AudioPlayer) {
        self.player = player
    }

    public var stats: Stats { lock.withLock { _stats } }

    /// One live buffer, in order.
    public func push(_ buffer: AVAudioPCMBuffer) {
        guard buffer.frameLength > 0, buffer.format.sampleRate > 0 else { return }
        let ms = Double(buffer.frameLength) / buffer.format.sampleRate * 1000
        lock.lock()
        defer { lock.unlock() }
        guard active else { return }
        pending.append((buffer, ms))
        pendingMs += ms
        let queued = player.streamQueuedMs()
        if !filling, let queued {
            lowMs = min(lowMs, queued)
            lowCount += 1
        } else {
            lowMs = .infinity
            lowCount = 0
        }
        let action = AudioRules.relayAction(filling: filling, pendingMs: pendingMs, queuedMs: queued, lowMs: lowMs, lowCount: lowCount)
        if AudioRules.relayWindowEnds(lowCount: lowCount) {
            lowMs = .infinity
            lowCount = 0
        }
        switch action {
        case AudioRules.relaySend:
            if let queued = player.stream(pending.map(\.buffer)) {
                _stats.sent += pending.count
                _stats.maxQueuedMs = max(_stats.maxQueuedMs, queued)
                pending.removeAll()
                pendingMs = 0
                filling = false
            } else {
                filling = true   // the output stopped in between: keep the audio for when it runs again
            }
        case AudioRules.relayDrop:
            pending.removeLast()
            pendingMs -= ms
            _stats.dropped += 1
        case AudioRules.relayTrim:
            while pending.count > 1, AudioRules.relayTrims(pendingMs: pendingMs, oldestMs: pending[0].ms) {
                pendingMs -= pending.removeFirst().ms
                _stats.trimmed += 1
            }
            filling = true
        case AudioRules.relayRefill:
            _stats.refills += 1
            filling = true
        default:
            break   // relayKeep: the jitter buffer fills
        }
    }

    /// Stops forwarding at once and empties the jitter buffer (the caller flushes the player). Returns the stats.
    @discardableResult
    public func stop() -> Stats {
        lock.withLock {
            active = false
            pending.removeAll()
            pendingMs = 0
            return _stats
        }
    }
}
