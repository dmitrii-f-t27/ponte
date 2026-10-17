// Stop and Quit always end (2026-10-17): every wait on their path has a real limit, and the quit ceiling
// (ui_rules.t27 UI_QUIT_WAIT_MAX_MS) stays above the slowest normal quit.
import Foundation
@testable import PonteApp
import PonteCore
import PontePeer
import PonteSpeech
import Testing

/// Work that ends only when the test opens the gate, whatever cancellation says (a stalled Apple call).
/// A test checks its result first and opens the gate last. Code that waited for the work would get its answer
/// only when the gate opens by itself after `autoOpenSeconds`, and `passed == 0` then fails instead of hanging.
final class TestGate: @unchecked Sendable {
    private let lock = NSLock()
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var arrived: [CheckedContinuation<Void, Never>] = []
    private var _passed = 0

    init(autoOpenSeconds: Int = 30) {
        DispatchQueue.global().asyncAfter(deadline: .now() + .seconds(autoOpenSeconds)) { [weak self] in self?.open() }
    }

    /// How many waits have ended.
    var passed: Int { lock.withLock { _passed } }

    func wait() async {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            let (now, notify): (Bool, [CheckedContinuation<Void, Never>]) = lock.withLock {
                defer { arrived = [] }
                if opened { return (true, arrived) }
                waiters.append(done)
                return (false, arrived)
            }
            notify.forEach { $0.resume() }
            if now { done.resume() }
        }
        lock.withLock { _passed += 1 }
    }

    /// Returns once some work is waiting at the gate.
    func waitForWaiter() async {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            let now: Bool = lock.withLock {
                if !waiters.isEmpty || opened { return true }
                arrived.append(done)
                return false
            }
            if now { done.resume() }
        }
    }

    func open() {
        let all: [CheckedContinuation<Void, Never>] = lock.withLock {
            opened = true
            defer { waiters = []; arrived = [] }
            return waiters + arrived
        }
        all.forEach { $0.resume() }
    }
}

/// Stop with a translator that ignores cancellation: the wait for pending translations ends at its limit and the
/// stuck translation is left behind, so «Остановка…» ends. Before, Stop cancelled it and then waited for it.
@MainActor @Test(.timeLimit(.minutes(1))) func stopLeavesAStuckTranslationBehind() async throws {
    let rig = AppTestRig(direction: .outgoing, stopTranslateWaitMs: 100)
    let gate = TestGate()
    rig.translator.stuck = gate
    try await rig.lane.start()
    rig.source.push()
    rig.current?.say("фраза")
    await gate.waitForWaiter()
    await rig.lane.stop()
    #expect(!rig.lane.isRunning)
    #expect(gate.passed == 0)   // Stop returned while the translation was still stuck
    gate.open()
}

/// The quit ceiling is a safety net, not a normal path: it is longer than two lanes stopping one after the other
/// (each with one open session), the goodbye on the Russians' link and a report still being written.
@Test func quitCeilingIsAboveTheSlowestNormalQuit() {
    let lane = AppRules.SESSION_FINISH_WAIT_MS + AppRules.STOP_SEGMENT_WAIT_MS + AppRules.STOP_TRANSLATE_WAIT_MS
    let normal = 2 * lane + Int64(PeerRules.quitWaitMs) + Int64(AnalysisRules.quitWaitLimitMs)
    #expect(AppRules.QUIT_WAIT_MAX_MS == 60_000)
    #expect(AppRules.QUIT_WAIT_MAX_MS > normal)
}
