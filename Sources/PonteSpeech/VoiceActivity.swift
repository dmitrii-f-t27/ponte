import Foundation

/// Level-meter bookkeeping for the transcriber: current silence, voice segments, noise floor.
/// Every decision (is this window voice, how the floor moves, which pauses count) is in `SpeechRules`;
/// this struct only keeps the state. Times are seconds of stream audio.
struct VoiceActivity: Equatable {
    private(set) var silenceStart: Double?
    private(set) var voiceStart: Double?
    private(set) var floorMilli = 0
    private(set) var hasFloor = false
    /// Closed voice segments, oldest first (last 256).
    private(set) var voiceSegments: [ClosedRange<Double>] = []
    private(set) var lastEnd: Double = 0

    /// Level units of `SpeechRules`: RMS × 100 000.
    static func level(rms: Float) -> Int { Int((Double(rms) * 100_000).rounded()) }

    /// Adds one meter window. Returns true when the window is voice.
    @discardableResult
    mutating func add(level: Int, start: Double, duration: Double) -> Bool {
        let voice = SpeechRules.isVoice(level: level, floorMilli: floorMilli)
        if voice {
            if let s = silenceStart {
                if let v = voiceStart, Int(((start - s) * 1000).rounded()) >= SpeechRules.minRecordedPauseMs {
                    voiceSegments.append(v...s)
                    if voiceSegments.count > 256 { voiceSegments.removeFirst(voiceSegments.count - 256) }
                    voiceStart = start
                }
                silenceStart = nil
            }
            if voiceStart == nil { voiceStart = start }
        } else if silenceStart == nil {
            silenceStart = start
        }
        lastEnd = start + duration
        floorMilli = SpeechRules.nextNoiseFloor(floorMilli: floorMilli, hasFloor: hasFloor, level: level,
                                                durationMs: Int((duration * 1000).rounded()))
        hasFloor = true
        return voice
    }

    /// Seconds of voice inside `range` (closed segments plus the open one).
    func voiceDuration(in range: ClosedRange<Double>) -> Double {
        var segments = voiceSegments
        if let v = voiceStart { segments.append(v...max(v, silenceStart ?? lastEnd)) }
        return segments.reduce(0) { total, seg in
            total + max(0, min(seg.upperBound, range.upperBound) - max(seg.lowerBound, range.lowerBound))
        }
    }
}
