import Foundation
import Libavformat

/// Keeps the callback on the context before any I/O, without erasing the
/// callers' different error contracts or ownership at the analysis boundary.
enum SourceOpener {
    enum Phase {
        case open, noContext, streamInfo, interrupted
    }

    enum Policy {
        case remux, software, probe, preview

        var interruptOperation: String? {
            switch self {
            case .remux: "avformat_find_stream_info"
            case .software: "open budget exhausted"
            case .probe: "probe budget exhausted"
            case .preview: nil
            }
        }

        var noContextFailure: (any Error)? {
            switch self {
            case .remux: HLSRemuxer.Failure.openProducedNoContext
            case .probe: SourceProbe.Failure.noStreams
            case .preview: SeekPreviewService.Failure.undecodable("open failed")
            case .software: nil
            }
        }

        func closesOnFailure(_ phase: Phase) -> Bool {
            switch self {
            case .remux: true
            case .probe: phase == .streamInfo || phase == .interrupted
            case .software, .preview: false
            }
        }

        func failure(_ error: any Error, phase: Phase, guard readGuard: ReadInterruptGuard) -> any Error {
            if self == .software || (phase == .noContext && self != .remux) { return error }
            let cause = readGuard.customInputFailure ?? readGuard.originFailure ?? error
            if self == .probe && (phase == .open || phase == .interrupted) {
                return SourceProbe.Failure.openFailed(cause)
            }
            return cause
        }
    }

    /// On success the caller owns the context. Software/preview publish it
    /// before analysis, so their existing teardown also owns an analysis failure.
    /// The caller disarms the guard at its original scope boundary: a probe or
    /// preview still has bounded work to do after analysis.
    static func open(
        url: URL,
        httpHeaders: [String: String],
        coordinatedHTTP: Bool,
        inputFactory: PrismCoreInputFactory? = nil,
        hints: SourceOpenHints? = nil,
        interruptGuard: ReadInterruptGuard,
        budget: Duration,
        policy: Policy,
        prepared: () -> Void = {},
        armed: () -> Void = {},
        opened: (UnsafeMutablePointer<AVFormatContext>?) -> Void = { _ in }
    ) throws -> UnsafeMutablePointer<AVFormatContext>? {
        // Only the probe includes option assembly in its measured open phase.
        var options = policy == .probe ? nil : SourceOpenTuning.makeOptions(httpHeaders: httpHeaders)
        defer { av_dict_free(&options) }
        var input = interruptGuard.makeContext()
        if let inputFactory, let input {
            do { try interruptGuard.installCustomInput(on: input, factory: inputFactory) }
            catch { avformat_free_context(input); throw error }
        } else if coordinatedHTTP, ["http", "https"].contains(url.scheme?.lowercased() ?? ""), let input {
            do { try interruptGuard.installHTTPInput(on: input, url: url, headers: httpHeaders, hints: hints) }
            catch { avformat_free_context(input); throw error }
        }
        prepared()
        interruptGuard.arm(budget: budget)
        armed()
        if policy == .probe { options = SourceOpenTuning.makeOptions(httpHeaders: httpHeaders) }
        let spec = url.isFileURL ? url.path : url.absoluteString
        var phase = Phase.open
        do {
            try FFmpegError.check(
                avformat_open_input(&input, spec, nil, &options),
                policy == .preview ? "avformat_open_input(preview)" : "avformat_open_input"
            )
            phase = .noContext
            if input == nil, let failure = policy.noContextFailure { throw failure }
            opened(input)
            phase = .streamInfo
            // Analysis fills muxer-required fields too; the resulting context,
            // rather than just its description, must survive probe handover.
            try FFmpegError.check(
                avformat_find_stream_info(input, nil),
                policy == .preview ? "avformat_find_stream_info(preview)" : "avformat_find_stream_info"
            )
            phase = .interrupted
            // FFmpeg can swallow an aborted analysis and return success with
            // half-filled parameters. Preview historically omits this check.
            if let operation = policy.interruptOperation, interruptGuard.shouldInterrupt {
                throw FFmpegError(code: swift_AVERROR_EXIT(), operation: operation)
            }
            return input
        } catch {
            // Probe captures the cause before closing; remux asks afterwards,
            // since teardown itself can read and update the transport failure.
            let failure = policy == .probe ? policy.failure(error, phase: phase, guard: interruptGuard) : error
            if policy.closesOnFailure(phase) {
                withExtendedLifetime(interruptGuard) { avformat_close_input(&input) }
            }
            if policy == .probe { throw failure }
            throw policy.failure(error, phase: phase, guard: interruptGuard)
        }
    }
}
