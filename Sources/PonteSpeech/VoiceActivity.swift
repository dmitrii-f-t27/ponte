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
    static func level(rms: Float) -> Int { SpeechRules.level(rms: rms) }

    /// Adds one meter window. Returns true when the window is voice.
    @discardableResult
    mutating func add(level: Int, start: Double, duration: Double) -> Bool {
        let voice = SpeechRules.isVoice(level: level, floorMilli: floorMilli)
        switch SpeechRules.activityStep(voice: voice, silenceStart: silenceStart, hasVoice: voiceStart != nil, start: start) {
        case SpeechRules.activitySegmentCloses:
            if let v = voiceStart, let s = silenceStart { voiceSegments.append(v...s) }
            voiceSegments.removeFirst(SpeechRules.segmentsToDrop(count: voiceSegments.count))
            voiceStart = start
            silenceStart = nil
        case SpeechRules.activitySilenceEnds:
            silenceStart = nil
        case SpeechRules.activitySilenceEndsVoiceStarts:
            silenceStart = nil
            voiceStart = start
        case SpeechRules.activityVoiceStarts:
            voiceStart = start
        case SpeechRules.activitySilenceStarts:
            silenceStart = start
        default:
            break
        }
        lastEnd = start + duration
        floorMilli = SpeechRules.nextNoiseFloor(floorMilli: floorMilli, hasFloor: hasFloor, level: level,
                                                durationMs: SpeechRules.millis(duration))
        hasFloor = true
        return voice
    }

    /// Seconds of voice inside `range` (closed segments plus the open one).
    func voiceDuration(in range: ClosedRange<Double>) -> Double {
        var segments = voiceSegments
        if let v = voiceStart { segments.append(v...SpeechRules.openSegmentEnd(voiceStart: v, silenceStart: silenceStart, lastEnd: lastEnd)) }
        return segments.reduce(0) { total, seg in
            total + SpeechRules.overlapSeconds(lower: seg.lowerBound, upper: seg.upperBound,
                                               rangeLower: range.lowerBound, rangeUpper: range.upperBound)
        }
    }
}
