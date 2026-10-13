import Foundation

/// The bookkeeping of `DeviceAudioPlayer`, without audio, so it can be tested on its own.
///
/// It keeps the player's state (no engine yet, running, rebuilding, failed), the generation of the engine
/// instance (bumped before every stop the player makes, and when the system stops the engine, so the
/// completions such a stop flushes are told apart from real playback), and the phrases not yet heard, in
/// play order, each with the generation it is scheduled on and how often a stop cut it. Every decision is
/// AudioRules (`Specs/audio_rules.t27`); this type only keeps lists and counters. Not thread-safe:
/// the player calls it with its lock held.
struct PlayerBook<Payload> {
    struct Phrase {
        let id: UInt64
        var payload: Payload
        /// The generation the phrase is scheduled on; nil while it waits for the engine.
        var generation: UInt64?
        /// How often a stop cut it.
        var cuts: Int64 = 0
        /// Where it ends on the player node's timeline (a lower bound), for AudioRules.playerCompletion.
        var endFrame: Int64 = 0
    }

    /// What the player carries out after an event.
    struct Effects {
        var action = AudioRules.playerNone
        /// Rebuild the engine after this many milliseconds.
        var rebuildAfterMs: Int64?
        /// Phrases to schedule now, in play order (each then reported with `scheduled`).
        var schedule: [Phrase] = []
        /// Phrases cut by a stop that wait for the rebuild to play again from their start.
        var requeued: [Phrase] = []
        /// Phrases completed without being heard: cut more than AudioRules.playerMaxReplays times, or the
        /// device failed. Their `play` calls return.
        var released: [Phrase] = []
    }

    private(set) var state = AudioRules.playerIdle
    private(set) var generation: UInt64 = 0
    /// Failed starts in a row (reset when the engine runs, and by a new stop).
    private(set) var failures: Int64 = 0
    private(set) var phrases: [Phrase] = []
    private var lastID: UInt64 = 0
    /// Where the audio scheduled on this generation ends on the node's timeline.
    private var queueEnd: Int64 = 0

    // MARK: Phrases

    /// A new phrase: its id and what it does (AudioRules.playerEnqueue). A refused phrase is not kept.
    mutating func add(_ payload: Payload) -> (id: UInt64, decision: Int) {
        lastID &+= 1
        let decision = AudioRules.playerEnqueue(state: state)
        if decision != AudioRules.playerEnqueueRefuse {
            phrases.append(Phrase(id: lastID, payload: payload))
        }
        return (lastID, decision)
    }

    /// The phrase went to the player node on the current generation. `frames`: its length; `position`: the
    /// frames the node has rendered so far (nil when it reports none, right after it started). It cannot
    /// start before that position nor before the audio scheduled ahead of it ends.
    mutating func scheduled(_ id: UInt64, frames: Int64, position: Int64?) {
        guard let i = phrases.firstIndex(where: { $0.id == id }) else { return }
        let start = max(queueEnd, position ?? 0)
        queueEnd = start + frames
        phrases[i].generation = generation
        phrases[i].endFrame = queueEnd
    }

    /// The payload converted again (the device format changed while the phrase waited).
    mutating func update(_ id: UInt64, payload: Payload) {
        guard let i = phrases.firstIndex(where: { $0.id == id }) else { return }
        phrases[i].payload = payload
    }

    /// Takes a phrase out unplayed (it could not be scheduled). Returns false when it is no longer here.
    mutating func remove(_ id: UInt64) -> Bool {
        guard let i = phrases.firstIndex(where: { $0.id == id }) else { return false }
        phrases.remove(at: i)
        return true
    }

    /// The completion of the phrase's last buffer, scheduled on `generation`. Returns AudioRules'
    /// completion code; `done` is the phrase when it is finished (heard, or dropped after too many cuts),
    /// `replay` the phrase to schedule again from its start now.
    mutating func completed(_ id: UInt64, generation g: UInt64, engineRunning: Bool,
                            position: Int64?) -> (code: Int, done: Phrase?, heard: Bool, replay: Phrase?) {
        guard let i = phrases.firstIndex(where: { $0.id == id }) else {
            return (AudioRules.playerCompletionIgnore, nil, false, nil)
        }
        let phrase = phrases[i]
        let code = AudioRules.playerCompletion(sameGeneration: phrase.generation == g && g == generation,
                                               engineRunning: engineRunning, position: position, endFrame: phrase.endFrame)
        switch code {
        case AudioRules.playerCompletionDone:
            phrases.remove(at: i)
            return (code, phrase, true, nil)
        case AudioRules.playerCompletionReplay:
            // The flush emptied the node's queue: what follows starts where the node is now. Forgetting the
            // queue's end keeps every end a lower bound.
            queueEnd = 0
            phrases[i].cuts += 1
            phrases[i].generation = nil
            if AudioRules.playerReplays(cuts: phrases[i].cuts) { return (code, nil, false, phrases[i]) }
            return (code, phrases.remove(at: i), false, nil)
        default:
            return (code, nil, false, nil)
        }
    }

    /// stopAll: every phrase completes now; completions already on their way find nothing.
    mutating func dropAll() -> [Phrase] {
        generation &+= 1
        queueEnd = 0
        defer { phrases.removeAll() }
        return phrases
    }

    // MARK: Engine events

    /// The engine started (a first start or a rebuild): the waiting phrases are scheduled.
    mutating func started() -> Effects {
        var effects = step(AudioRules.playerStarted, engineRunning: true)
        failures = 0
        if effects.action == AudioRules.playerScheduleWaiting {
            effects.schedule = phrases.filter { $0.generation == nil }
        }
        return effects
    }

    /// A start or a rebuild failed: retry with the backoff; after too many failures in a row the waiting
    /// phrases are completed unplayed.
    mutating func startFailed() -> Effects {
        failures += 1
        var effects = step(AudioRules.playerStartFailed, engineRunning: false)
        effects.rebuildAfterMs = AudioRules.restartDelayMs(attempt: failures)
        if effects.action == AudioRules.playerRetryRelease {
            effects.released = phrases
            phrases.removeAll()
        }
        return effects
    }

    /// AVAudioEngineConfigurationChange (`engineRunning`: the engine's isRunning then). A stop of the running
    /// engine cuts every scheduled phrase: it plays again from its start after the rebuild, or is dropped
    /// after AudioRules.playerMaxReplays cuts.
    mutating func configurationChanged(engineRunning: Bool) -> Effects {
        var effects = step(AudioRules.playerChange, engineRunning: engineRunning)
        guard effects.action == AudioRules.playerCutRetry else { return effects }
        generation &+= 1
        queueEnd = 0
        failures = 0
        effects.rebuildAfterMs = AudioRules.restartDelayMs(attempt: 0)
        var kept: [Phrase] = []
        for var phrase in phrases {
            if phrase.generation != nil {
                phrase.generation = nil
                phrase.cuts += 1
                guard AudioRules.playerReplays(cuts: phrase.cuts) else {
                    effects.released.append(phrase)
                    continue
                }
                effects.requeued.append(phrase)
            }
            kept.append(phrase)
        }
        phrases = kept
        return effects
    }

    private mutating func step(_ event: Int, engineRunning: Bool) -> Effects {
        let next = AudioRules.playerStep(state: state, event: event, engineRunning: engineRunning, failures: failures)
        state = next.state
        return Effects(action: next.action)
    }
}
