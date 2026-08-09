import Foundation
import Libavformat

/// A source that has been opened and read once, holding both the answer
/// (`info`) and the **open context that produced it**.
///
/// A playback used to open its source twice: the host probes to decide how to
/// play, then the remuxer opens again to produce. Over a network that second
/// open is a real round trip and a real download — measured at a median of
/// 54 ms even capped, on a link with no latency at all — and it happens inside
/// the wait a user is watching.
///
/// The tempting shortcut is to keep the first open's *conclusions* and let the
/// second context skip its analysis. That was tried in 1.1.2 and reverted:
/// `avformat_find_stream_info` also fills fields the **muxer** needs (an EAC3
/// track's frame size, most sharply), so a context that never ran it produces
/// a correct-looking manifest and a failing `av_interleaved_write_frame`. The
/// analysis isn't redundant knowledge — it is state that lives in the context.
///
/// So the context itself moves. `consumeContext()` hands it over exactly once;
/// whoever takes it owns closing it, and a `ProbedSource` that is never
/// consumed (the host declined the source, or never started a session) closes
/// its own on the way out.
///
/// **Threading**: an `AVFormatContext` is not safe for concurrent use, and this
/// deliberately does not make it so. The handover is a *move* across threads —
/// the probing side must be finished with it, which consuming it exactly once
/// enforces structurally — not a share.
public final class ProbedSource: @unchecked Sendable {

    /// What the probe found. Safe to read after the context has been consumed:
    /// it is a value, copied out at probe time.
    public let info: SourceInfo

    /// The source this describes, so a consumer that needs to re-open (a
    /// fallback session, whose context was already taken) knows what to open.
    public let url: URL
    let httpHeaders: [String: String]

    private let lock = NSLock()
    private var context: UnsafeMutablePointer<AVFormatContext>?

    init(
        info: SourceInfo,
        url: URL,
        httpHeaders: [String: String],
        context: UnsafeMutablePointer<AVFormatContext>
    ) {
        self.info = info
        self.url = url
        self.httpHeaders = httpHeaders
        self.context = context
    }

    /// Take the open context, transferring ownership. Returns `nil` on every
    /// call after the first — a context cannot be handed to two producers, and
    /// a caller that gets `nil` must open its own.
    ///
    /// The position is **not** rewound here: the probe left it wherever its
    /// reads ended (the interlace verification decodes a handful of frames),
    /// and only the new owner knows where it wants to start. Adopting code
    /// seeks.
    func consumeContext() -> UnsafeMutablePointer<AVFormatContext>? {
        lock.withLock {
            defer { context = nil }
            return context
        }
    }

    /// Whether the context is still here — a source that was probed and then
    /// declined still holds one until it is released.
    var holdsContext: Bool { lock.withLock { context != nil } }

    deinit {
        // Nobody took it: the probe was for a routing decision that went
        // elsewhere. Closing here is what keeps a declined probe from leaking
        // a connection.
        if let context {
            var closing: UnsafeMutablePointer<AVFormatContext>? = context
            avformat_close_input(&closing)
        }
    }
}
