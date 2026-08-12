import Foundation

/// One remux running on a thread of its own, with an `async` way to wait for it.
///
/// `HLSRemuxer.run()` is synchronous by design: it blocks in FFmpeg reads for as
/// long as production takes, and parks at EOF for the rest of the session. Run
/// on a `Task.detached` it therefore occupies one thread of the global
/// cooperative pool permanently — a quarter of an Apple TV's pool for the length
/// of a film, and, with several sessions alive at once, enough parked producers
/// to saturate the pool outright. The async work that would release them
/// (`stop()`, a demand fetch) then has nowhere to run, which is exactly the
/// deadlock the suite hit on 2026-08-10 (#44).
///
/// So the producer gets a real thread. Nothing here is a general-purpose task
/// primitive — it does what a blocking producer needs and no more: carry the
/// thrown error out, and let an actor `await` the exit without blocking.
final class ProducerThread: @unchecked Sendable {

    /// Guards `finished`, `failure` and `waiters`, and is what a `join` sleeps
    /// on when the body is still running.
    private let lock = NSLock()
    private var finished = false
    private var failure: Error?
    private var waiters: [CheckedContinuation<Void, Never>] = []

    /// Starts `body` immediately on a new thread named `name`.
    init(name: String, body: @escaping @Sendable () throws -> Void) {
        let thread = Thread { [self] in
            var thrown: Error?
            do {
                try body()
            } catch {
                thrown = error
            }
            finish(with: thrown)
        }
        thread.name = name
        // The producer feeds a playing AVPlayer; it is as user-initiated as the
        // work gets. Not `.userInteractive` — nothing here draws.
        thread.qualityOfService = .userInitiated
        thread.start()
    }

    /// Whether the body has returned (or thrown).
    var isFinished: Bool { lock.withLock { finished } }

    /// The error the body threw, once it has finished. `nil` while it runs and
    /// after a clean exit.
    var failureIfAny: Error? { lock.withLock { failure } }

    /// Suspend until the body exits. Resumes immediately if it already has.
    ///
    /// Nothing here cancels the body — the caller is expected to have asked it
    /// to stop first (`HLSRemuxer.cancel()`), exactly as it had to with the task
    /// this replaced: a `Task.cancel()` never interrupted a blocking FFmpeg read
    /// either.
    func join() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if finished {
                lock.unlock()
                continuation.resume()
                return
            }
            waiters.append(continuation)
            lock.unlock()
        }
    }

    private func finish(with error: Error?) {
        let toResume: [CheckedContinuation<Void, Never>] = lock.withLock {
            finished = true
            failure = error
            defer { waiters = [] }
            return waiters
        }
        // Resumed outside the lock: a continuation may run its awaiting code
        // synchronously, and that code is entitled to call back in here.
        for continuation in toResume { continuation.resume() }
    }
}
