import Foundation

// Waits with a real time limit (the Stop and Quit paths, 2026-10-17).
// Cancelling a task and then awaiting it is not a limit: a call that ignores cancellation (Apple Translation,
// a stalled SpeechAnalyzer) keeps the awaiting code forever, and Stop stays at «Остановка…». These helpers resume
// the caller at the deadline whether or not the work has finished; the work is cancelled and left behind.
// How long each wait is stays a spec constant; this file only does the race.

/// What `waitAtMost` sees when its deadline passes first.
public struct DeadlineExceeded: Error, Sendable {
    public let ms: Int64
    public init(ms: Int64) { self.ms = ms }
}

/// Runs `work` and returns its result, or throws `onTimeout()` once `ms` have passed, without waiting for `work`
/// to notice its cancellation. Cancelling the caller ends the wait at once with `CancellationError`.
public func withDeadline<T: Sendable>(ms: Int64, onTimeout: @escaping @Sendable () -> Error,
                                      _ work: @escaping @Sendable () async throws -> T) async throws -> T {
    let race = DeadlineRace<T>()
    return try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
            let worker = Task {
                do {
                    race.finish(.success(try await work()))
                } catch {
                    race.finish(.failure(error))
                }
            }
            let timer = Task {
                try? await Task.sleep(for: .milliseconds(ms))
                race.finish(.failure(onTimeout()))
            }
            race.begin(continuation, tasks: [worker, timer])
        }
    } onCancel: {
        race.finish(.failure(CancellationError()))
    }
}

/// Waits for `task` at most `ms`. True when it finished in time; false when the deadline passed first: `task` is
/// then cancelled and left behind (it may run on until it notices).
@discardableResult
public func waitAtMost<T: Sendable>(_ task: Task<T, Never>, ms: Int64) async -> Bool {
    do {
        _ = try await withDeadline(ms: ms, onTimeout: { DeadlineExceeded(ms: ms) }) { await task.value }
        return true
    } catch {
        task.cancel()
        return false
    }
}

/// The first outcome resumes the continuation; the tasks still running are cancelled. An outcome may come before
/// `begin` (a caller cancelled before the race started): `begin` then resumes at once.
private final class DeadlineRace<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?
    private var outcome: Result<T, Error>?
    private var tasks: [Task<Void, Never>] = []

    func begin(_ continuation: CheckedContinuation<T, Error>, tasks newTasks: [Task<Void, Never>]) {
        let early: Result<T, Error>? = lock.withLock {
            if let outcome { return outcome }
            self.continuation = continuation
            tasks = newTasks
            return nil
        }
        guard let early else { return }
        newTasks.forEach { $0.cancel() }
        continuation.resume(with: early)
    }

    func finish(_ result: Result<T, Error>) {
        let won: (CheckedContinuation<T, Error>?, [Task<Void, Never>])? = lock.withLock {
            guard outcome == nil else { return nil }
            outcome = result
            defer { continuation = nil; tasks = [] }
            return (continuation, tasks)
        }
        guard let won else { return }
        let (continuation, running) = won
        running.forEach { $0.cancel() }
        continuation?.resume(with: result)
    }
}
