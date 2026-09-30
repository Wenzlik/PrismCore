#if os(macOS)
import Foundation
import PrismCore

/// Probe, route, and start a remux session the way a host does — the probed
/// context is handed to the session, never re-opened — then run `body` with
/// the playlist URL and stop the session on every way out.
func withServedSession<T>(
    _ options: SourceOptions,
    _ body: (URL) async throws -> T
) async throws -> T {
    let (probed, decision) = try probeAndRoute(options)
    guard decision.engine == .remux else {
        throw CLIFailure(
            code: .notRemuxable,
            message: "routes to the \(decision.engine.rawValue) path, not remux — nothing to serve (\(decision.reason))"
        )
    }
    let session = try PrismCoreSession(
        url: probed.url,
        httpHeaders: options.headers,
        display: options.display,
        probed: probed,
        coordinatedHTTP: options.coordinatedHTTP
    )
    let playlist: URL
    do {
        playlist = try await session.start()
    } catch {
        await session.stop()
        throw CLIFailure(code: .checkFailed, message: "session failed to start: \(error)")
    }
    do {
        let result = try await body(playlist)
        await session.stop()
        return result
    } catch {
        await session.stop()
        throw error
    }
}

/// The probe plus `PrismCoreEngine.decide`, with both failures mapped to
/// the exit code that says which of the two it was.
func probeAndRoute(
    _ options: SourceOptions,
    structure: SourceStructureExport = .none
) throws -> (ProbedSource, PrismCoreEngine.Decision) {
    let probed: ProbedSource
    do {
        probed = try SourceProbe.open(
            url: options.source!,
            httpHeaders: options.headers,
            budget: options.budget ?? SourceOpenTuning.probeBudget,
            coordinatedHTTP: options.coordinatedHTTP,
            structure: structure
        )
    } catch {
        throw CLIFailure(code: .probeFailed, message: "probe failed: \(PrismCoreError.classify(error))")
    }
    do {
        return (probed, try PrismCoreEngine.decide(for: probed.info))
    } catch {
        throw CLIFailure(code: .notRemuxable, message: "declined: \(error)")
    }
}

/// Fires once, on the first of: Ctrl-C, SIGTERM, Enter on stdin (when
/// watched), or a deadline. Any number of tasks may wait on it; a waiter
/// whose task is cancelled returns `nil` instead of hanging.
///
/// stdin at EOF is deliberately *not* a stop: `serve` run from a script or
/// with `< /dev/null` would otherwise tear the session down the instant it
/// came up.
final class StopSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var waiters: [UUID: CheckedContinuation<String?, Never>] = [:]
    private var reason: String?
    private var sources: [DispatchSourceSignal] = []

    init(watchStdin: Bool) {
        for number in [SIGINT, SIGTERM] {
            // Ignored at the process level so the dispatch source, not the
            // default handler, sees it — the default would exit without
            // `stop()`, leaving the session's work directory behind in tmp.
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
            source.setEventHandler { [weak self] in
                self?.fire(number == SIGINT ? "interrupted" : "terminated")
            }
            source.resume()
            sources.append(source)
        }
        if watchStdin {
            Thread.detachNewThread { [weak self] in
                if readLine() != nil { self?.fire("Enter pressed") }
            }
        }
    }

    func fire(after delay: Duration, _ why: String) {
        Task { [weak self] in
            try? await Task.sleep(for: delay)
            self?.fire(why)
        }
    }

    func fire(_ why: String) {
        let released: [CheckedContinuation<String?, Never>] = lock.withLock {
            guard reason == nil else { return [] }
            reason = why
            defer { waiters.removeAll() }
            return Array(waiters.values)
        }
        released.forEach { $0.resume(returning: why) }
    }

    /// The stop's reason, or `nil` when the waiting task was cancelled first.
    func wait() async -> String? {
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let immediate: String?? = lock.withLock {
                    if let reason { return .some(reason) }
                    if Task.isCancelled { return .some(nil) }
                    waiters[id] = continuation
                    return .none
                }
                if let immediate { continuation.resume(returning: immediate) }
            }
        } onCancel: {
            let waiting = lock.withLock { waiters.removeValue(forKey: id) }
            waiting?.resume(returning: nil)
        }
    }
}

/// Run `work` until it finishes or `stop` fires, whichever is first. A stop
/// cancels the work — a URLSession fetch throws on cancellation — and the
/// caller unwinds through `withServedSession`, which is what stops the
/// session and removes its work directory.
func interruptible<T: Sendable>(
    _ stop: StopSignal,
    _ work: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T?.self) { group in
        group.addTask { try await work() }
        group.addTask { _ = await stop.wait(); return nil }
        // Cancelling on every way out is what releases whichever child lost:
        // the group cannot end while one is still suspended.
        defer { group.cancelAll() }
        if let first = try await group.next()! { return first }
        throw CLIFailure(code: .interrupted, message: "interrupted")
    }
}
#endif
