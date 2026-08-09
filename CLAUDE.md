# PrismCore — agent instructions

The canonical instructions for this repository live in
**[`AGENTS.md`](AGENTS.md)**. Read it first; this file exists so it gets loaded
automatically.

Then, as needed: [`README.md`](README.md) → [`CHANGELOG.md`](CHANGELOG.md).

## The four that bite hardest

1. **`avformat_find_stream_info` cannot be skipped** by reusing an earlier
   probe's answer — it also fills fields the *muxer* needs. Hand over the
   **context** (`ProbedSource`), never the conclusions.
2. **`interrupt_callback` must be set before `avformat_open_input`**, or it
   never reaches the blocking reads. (1.1.1's bounded seek gets this wrong and
   is still broken — see AGENTS.md.)
3. **Benchmark over HTTP, not a mounted share.** A local mount hides the exact
   cost hosts pay, and has already produced a confidently wrong conclusion.
4. **`swift test --filter` matches function names**, not `@Test("…")` titles —
   filtering on a title runs nothing and says so quietly.

## Non-negotiables

- Never copy code from AetherEngine; study the approach, write our own.
- Comments record *why* — especially the failure a line prevents.
- A performance claim needs a measurement in the PR; a correctness claim needs
  a test or a named device run.
- Tags are always three-component semver (`1.2.0`), or SPM cannot see them.
