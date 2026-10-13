// The bookkeeping of DeviceAudioPlayer without audio (PlayerBook), fed with the events a real engine
// produces: starts, configuration changes, completions of a phrase's last buffer (real or flushed).
// Live 2026-10-13: engine stops came in bursts and cut the phrase that was playing.
import Foundation
import Testing
@testable import PonteAudio

private typealias R = AudioRules

@Suite("PlayerBook: the call output heals itself") struct PlayerBookTests {

    /// A started book with one phrase of `frames` scheduled at the start of the node's timeline.
    private func runningBook(frames: Int64 = 48_000) -> (PlayerBook<String>, UInt64) {
        var book = PlayerBook<String>()
        let (id, decision) = book.add("a")
        #expect(decision == R.playerEnqueueStart)
        let effects = book.started()
        #expect(effects.action == R.playerScheduleWaiting)
        #expect(effects.schedule.map(\.id) == [id])
        book.scheduled(id, frames: frames, position: nil)
        return (book, id)
    }

    @Test func phraseHeardCompletesOnce() {
        var (book, id) = runningBook()
        #expect(book.state == R.playerRunning)
        #expect(book.phrases.first?.endFrame == 48_000)
        let result = book.completed(id, generation: book.generation, engineRunning: true, position: 48_512)
        #expect(result.code == R.playerCompletionDone)
        #expect(result.heard && result.done?.id == id && result.replay == nil)
        #expect(book.phrases.isEmpty)
        // A second completion for the same phrase finds nothing.
        #expect(book.completed(id, generation: book.generation, engineRunning: true, position: 96_000).code == R.playerCompletionIgnore)
    }

    @Test func phrasesQueueBackToBackOnTheNodeTimeline() {
        var (book, a) = runningBook(frames: 48_000)
        let (b, decision) = book.add("b")
        #expect(decision == R.playerEnqueueSchedule)
        book.scheduled(b, frames: 24_000, position: 10_000)          // queued behind a: starts at 48 000
        #expect(book.phrases.map(\.endFrame) == [48_000, 72_000])
        _ = book.completed(a, generation: book.generation, engineRunning: true, position: 48_000)
        _ = book.completed(b, generation: book.generation, engineRunning: true, position: 72_000)
        let (c, _) = book.add("c")
        book.scheduled(c, frames: 1_000, position: 200_000)           // the node idled: starts where it is
        #expect(book.phrases.map(\.endFrame) == [201_000])
    }

    @Test func changeWhileRunningIsIgnored() {
        var (book, id) = runningBook()
        let effects = book.configurationChanged(engineRunning: true)
        #expect(effects.action == R.playerNone && effects.rebuildAfterMs == nil && effects.requeued.isEmpty)
        #expect(book.state == R.playerRunning)
        #expect(book.phrases.first?.generation == book.generation)
        #expect(book.completed(id, generation: book.generation, engineRunning: true, position: nil).heard)
    }

    /// The live case: the engine stops while a phrase plays; it plays again from its start after the rebuild.
    @Test func phraseCutByAStopPlaysAgainAfterTheRebuild() {
        var (book, id) = runningBook()
        let old = book.generation
        let stop = book.configurationChanged(engineRunning: false)
        #expect(stop.action == R.playerCutRetry)
        #expect(stop.rebuildAfterMs == R.restartDelayMs(attempt: 0))
        #expect(stop.requeued.map(\.id) == [id] && stop.requeued.first?.cuts == 1)
        #expect(stop.released.isEmpty)
        #expect(book.state == R.playerRebuilding && book.generation != old)
        // The old node's flush (or a late real completion) no longer completes the phrase.
        for running in [false, true] {
            let late = book.completed(id, generation: old, engineRunning: running, position: 96_000)
            #expect(late.code == R.playerCompletionIgnore && late.done == nil)
        }
        // The rest of the burst changes nothing; a new phrase waits for the rebuild.
        #expect(book.configurationChanged(engineRunning: false).action == R.playerNone)
        let (waiter, decision) = book.add("b")
        #expect(decision == R.playerEnqueueWait)
        // The rebuild schedules the cut phrase first, then the one that waited, from their start.
        let rebuilt = book.started()
        #expect(rebuilt.schedule.map(\.id) == [id, waiter])
        #expect(rebuilt.schedule.map(\.cuts) == [1, 0])
        book.scheduled(id, frames: 48_000, position: nil)
        book.scheduled(waiter, frames: 1_000, position: nil)
        let heard = book.completed(id, generation: book.generation, engineRunning: true, position: 48_000)
        #expect(heard.heard && heard.done?.cuts == 1)
    }

    /// A stop flushes completions while the engine still reports running: the node has not rendered the
    /// phrase's end, so it is played again now.
    @Test func flushOnTheRunningEngineReplaysNow() {
        var (book, id) = runningBook()
        let flushed = book.completed(id, generation: book.generation, engineRunning: true, position: 20_000)
        #expect(flushed.code == R.playerCompletionReplay)
        #expect(flushed.replay?.id == id && flushed.replay?.cuts == 1 && flushed.done == nil)
        #expect(book.phrases.first?.generation == nil)
        book.scheduled(id, frames: 48_000, position: 20_000)          // starts where the node is now
        #expect(book.phrases.first?.endFrame == 68_000)
        #expect(book.completed(id, generation: book.generation, engineRunning: true, position: 68_000).heard)
        // Rendered at all: a completion without a position counts as heard.
        let (b, _) = book.add("b")
        book.scheduled(b, frames: 1_000, position: 70_000)
        #expect(book.completed(b, generation: book.generation, engineRunning: true, position: nil).heard)
    }

    @Test func aPhraseIsReplayedAtMostMaxReplaysTimes() {
        var (book, id) = runningBook()
        for cut in 1...R.playerMaxReplays {
            let stop = book.configurationChanged(engineRunning: false)
            #expect(stop.requeued.map(\.cuts) == [cut])
            let rebuilt = book.started()
            #expect(rebuilt.schedule.map(\.id) == [id])
            book.scheduled(id, frames: 48_000, position: nil)
        }
        let last = book.configurationChanged(engineRunning: false)
        #expect(last.requeued.isEmpty)
        #expect(last.released.map(\.id) == [id] && last.released.first?.cuts == R.playerMaxReplays + 1)
        #expect(book.phrases.isEmpty)
    }

    @Test func failingRebuildsBackOffThenReleaseAndRefuse() {
        var (book, id) = runningBook()
        _ = book.configurationChanged(engineRunning: false)
        var delays: [Int64] = []
        for failure in 1..<R.restartAttempts {
            let effects = book.startFailed()
            #expect(effects.action == R.playerRetry && effects.released.isEmpty)
            #expect(book.state == R.playerRebuilding && book.failures == failure)
            delays.append(effects.rebuildAfterMs ?? -1)
        }
        #expect(delays == [600, 1200, 2400, 4800, 5000])
        let failed = book.startFailed()
        #expect(failed.action == R.playerRetryRelease && failed.rebuildAfterMs == 5000)
        #expect(failed.released.map(\.id) == [id])
        #expect(book.state == R.playerFailed && book.phrases.isEmpty)
        // A phrase is refused at once while failed; a successful rebuild runs again and resets the count.
        #expect(book.add("x").decision == R.playerEnqueueRefuse)
        #expect(book.phrases.isEmpty)
        #expect(book.started().action == R.playerScheduleWaiting)
        #expect(book.state == R.playerRunning && book.failures == 0)
        #expect(book.add("y").decision == R.playerEnqueueSchedule)
    }

    @Test func firstStartThatFailsKeepsThePhraseAndRetries() {
        var book = PlayerBook<String>()
        let (id, decision) = book.add("a")
        #expect(decision == R.playerEnqueueStart)
        let failed = book.startFailed()
        #expect(failed.action == R.playerRetry && failed.rebuildAfterMs == R.restartDelayMs(attempt: 1))
        #expect(book.state == R.playerRebuilding && book.phrases.map(\.id) == [id])
        #expect(book.started().schedule.map(\.id) == [id])
    }

    @Test func stopAllDropsEverythingAndIgnoresTheFlush() {
        var (book, id) = runningBook()
        let (b, _) = book.add("b")
        book.scheduled(b, frames: 1_000, position: nil)
        let old = book.generation
        let dropped = book.dropAll()
        #expect(dropped.map(\.id) == [id, b])
        #expect(book.phrases.isEmpty && book.generation != old && book.state == R.playerRunning)
        #expect(book.completed(id, generation: old, engineRunning: true, position: 0).code == R.playerCompletionIgnore)
        // The node's timeline restarts at 0 after stop and play.
        let (c, _) = book.add("c")
        book.scheduled(c, frames: 500, position: nil)
        #expect(book.phrases.first?.endFrame == 500)
    }

    @Test func aNewStopResetsTheFailureCount() {
        var (book, _) = runningBook()
        _ = book.configurationChanged(engineRunning: false)
        _ = book.startFailed()
        _ = book.startFailed()
        #expect(book.failures == 2)
        _ = book.started()
        let stop = book.configurationChanged(engineRunning: false)
        #expect(book.failures == 0 && stop.rebuildAfterMs == 300)
    }
}
