# Changelog

All notable changes to PrismCore. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project follows
[Semantic Versioning](https://semver.org). (Releases before 1.0.0 carried the
usual pre-1.0 caveat: **minor** bumps could break API, **patch** bumps stayed
source-compatible.)

## [1.4.0] — 2026-08-10

### Fixed

- **Retention can no longer evict a demanded segment before its serve reads
  it** (#43). Under a tight `segmentCacheBytes` budget, a demand fetch of an
  evicted segment could fail outright: the producer re-anchors, re-produces
  the segment, runs on past it — and `recordAndEvict`, seeing the budget
  exceeded, evicts the farthest-from-producer segment, which by then is
  exactly the one just re-produced. The provider's poll finds nothing, times
  out at 15 s, and AVPlayer reports a lost connection (`-1005`). The 1.3.1
  cadence change made the race hard to lose (19–34 ms serve vs. a 100 ms
  poll); it never removed it.

  Now the provider tells the coordinator when a demand serve begins and ends
  (`beginServing`/`endServing`, refcounted — the variant and each rendition of
  an index fetch separately), and eviction skips any index with a serve
  outstanding, exactly like the keep window: the budget may stay exceeded for
  the serve's duration rather than answer a promise the playlist made with a
  404. Protection is installed at the moment of the miss, not when the queued
  serve first runs, so there is no gap for production to land the file and
  eviction to take it back.

## [1.3.1] — 2026-08-10

### Changed

- **The polling cadences stopped being the latency.** Three waits in the
  session's hot paths polled at 100 ms (readiness gate, the provider's
  wait-for-file) and 50 ms (the parked producer's wake), and on a warm source
  the polls cost more than the work they were waiting for. All three now run
  at 10 ms. Measured over local HTTP (3 min H.264/AC3 MKV, planned mode,
  three runs): `session.start()` 103–109 ms → **13–25 ms**; a parked cold
  seek of an evicted segment (re-anchor → produce → serve) 114 ms →
  **19–34 ms**. The checks are a couple of small file reads each — at 10 ms
  they are still noise.

### Fixed

- **The bounded index-load seek works now.** 1.1.1 shipped it and its own
  correction: the wall-clock guard was installed on the `AVFormatContext`
  *after* `avformat_open_input`, but the blocking reads check the
  `URLContext`'s copy of the callback, taken when that context is created
  during the open — so the guard never reached the reads and a cue-less
  source still stalled the whole startup (#39).

  The guard (`ReadInterruptGuard`) now exists **before** the open, on every
  open site — `SourceProbe.open`, the remuxer's fallback open, and the plan
  probe — permanently installed and disarmed, armed only around the
  index-load seek. Both sites matter: since 1.2.0 the remuxer usually adopts
  the probe's context, so the probe's open is the one that decides whether a
  bound is possible at all, and the guard travels with the context inside
  `ProbedSource`. An aborted read latches `AVERROR_EXIT` in the
  `AVIOContext`; the planner clears it after disarming, so the session
  carries on with the uniform plan instead of dying on its first real read.

  Verified the way the correction asked: against a transport that actually
  blocks. The test serves a fixture's head over local HTTP and then holds
  every read open forever — with a 0.5 s budget the plan comes back in
  ~0.5 s on the uniform basis, covering the full source from the head.
  Before the fix that test hangs, which is precisely what the field case
  (5.4 GB cue-less MKV, 20 s session timeout) looked like.

## [1.3.0] — 2026-08-09

### Changed

- **Deinterlacing no longer costs the hardware decode.** `bwdif` reads planar
  YUV, so asking for it forced the whole decode onto the CPU — on an Apple TV,
  for interlaced broadcast content, the worst combination available. When the
  FFmpeg build carries `yadif_videotoolbox`, the filter now runs on the
  VideoToolbox frames the decoder already produced and the zero-copy route
  survives deinterlacing.

  The choice is made per frame, from what the frame *is*: a hardware frame
  carries a `hw_frames_ctx` and gets the GPU filter (handed to the graph via
  `av_buffersrc_parameters_set`, without which configuration fails with "No
  hardware frames context provided"); a planar frame gets `bwdif` exactly as
  before.

### Added

- `SoftwareVideoDecoder.gpuDeinterlaceName` — the GPU deinterlacer this build
  carries, or `nil`. Resolved at runtime because it is a property of the
  **build**, not the code: the filter needs Metal, which is a separate Xcode
  component, and a host on an FFmpeg without it still deinterlaces correctly on
  the CPU route. `routeDescription` names whichever one is in use.

### Notes

- The GPU path needs an FFmpeg built with `--enable-filter=yadif_videotoolbox`
  — [aether-ffmpeg `n8.0.1-eac3-vt.1`](https://github.com/Wenzlik/aether-ffmpeg/releases/tag/n8.0.1-eac3-vt.1)
  or later. PrismCore's own dependency is upstream MPVKit, which does not carry
  it, so this repository's tests exercise the fallback branch; the GPU graph is
  verified by a host on that build, or on a device.

## [1.2.0] — 2026-08-09

### Added

- **`SourceProbe.open(url:httpHeaders:)` → `ProbedSource`, and
  `PrismCoreSession(url:display:probed:)`.** A playback used to open its
  source twice — once for the host's routing decision, once for production —
  and over a network the second open is a real round trip inside the wait the
  user is watching. The probe can now keep its context, and a session over the
  same source adopts it.

  Measured against a 5.4 GB HEVC/EAC3 remux over HTTP, warm, three runs:
  probe + `start()` goes from **~522 ms to ~135 ms** (probe 21–24 ms,
  start 109–115 ms). `SourceProbe.probe` is unchanged for callers that only
  want the answer.

  The context **moves**: `ProbedSource` hands it over exactly once, the
  adopting session owns closing it, and a probe nobody adopts (the source
  routed elsewhere) closes its own. An `AVFormatContext` is not safe for
  concurrent use and this does not pretend otherwise — consuming it once is
  what makes the handover a move rather than a share.

  This is the shape 1.1.2 explicitly did *not* ship. Passing the probe's
  conclusions and skipping the second `find_stream_info` breaks muxing,
  because that call also fills fields the muxer needs; passing the context
  carries the analysis with it, which is the whole difference. The test that
  caught the earlier attempt now guards this one: an adopted context must
  produce a byte-identical master and init segment **and** mux through to
  `EXT-X-ENDLIST` on an EAC3 source.

## [1.1.2] — 2026-08-09

### Fixed

- **Opening a source no longer reads more of it than it has to.** Every open
  now carries explicit read caps (4 MB probe, 2 s of analysis) instead of
  libavformat's defaults, which are sized for containers that hide their
  structure — Matroska and MP4 describe themselves in their header. Measured
  against a 5.4 GB HEVC/EAC3 remux served over HTTP, warm, five runs: the open
  drops from a median of 126 ms to 54 ms, and the spikes (168 ms) disappear
  along with the analysis that produced them. A playback pays this twice — the
  routing probe and the remuxer each open the source — so it is the part of a
  host's "Preparing…" that PrismCore actually controls. The caps are a
  ceiling, not a target: a well-formed file stops well short of both.

### Notes

- The companion idea — hand the remuxer the routing probe's answer so it can
  skip its own `find_stream_info` — was implemented, caught by a new test, and
  reverted. That call is also what fills fields the *muxer* needs (an EAC3
  track's frame size), and a context that never ran it produces a correct-
  looking manifest with a failing `av_interleaved_write_frame`. Making the
  second open cheap has to mean sharing the first one's **context**, not
  trusting its conclusions; that is a 1.2 change, not a patch.
- `StartupCostBenchmark` (opt-in via `PRISMCORE_BENCH`, a path or an http URL)
  measures the phases end to end, so the next change to this area starts from
  numbers rather than intuition.

## [1.1.1] — 2026-08-08

### Fixed

- **A source with no seek index can't eat the startup budget.** The nudge seek
  that makes a demuxer load its index is only *bounded* when an index exists:
  a Matroska without Cues turns it into a linear scan of the whole file, and
  over a slow transport that is the entire session startup (field case: a
  5.4 GB webrip on an SMB mount — one seek took 66 s, and `start()` timed out
  before the master playlist was ever written, so the host fell back to its
  other engine). The seek now runs under a 3 s wall-clock guard
  (`interrupt_callback`); on expiry the plan degrades to the uniform basis —
  the same path an untrusted index already took — and the session starts.
  Sources with an index load it in a fraction of a second and are unaffected.

  > **Correction (2026-08-09): this fix does not work.** Re-measured against
  > the same file, the session still times out at 20 s. The guard is installed
  > on the `AVFormatContext` *after* `avformat_open_input`, but the read path
  > checks `URLContext.interrupt_callback` (`libavformat/avio.c:515`), which is
  > populated when the context is created (`avio.c:189`) — so it never reaches
  > the blocking reads. The callback has to be set before the open — which is
  > what [1.3.1] does; the capping in 1.1.2 and the single open in 1.2.0 are
  > unaffected.

## [1.1.0] — 2026-08-08

### Changed

- **An HDR settle no longer trusts the ambiguous clear.** On an HDR target,
  the display-switch in-progress flag clearing is not a "done": a panel that
  finished quietly and one that ABORTED the switch (staying SDR) look
  identical at that moment, and returning on the clear is exactly how a
  slow-but-willing panel's master got validated against the old SDR mode
  (`-11868`). The wait now notes the clear and spends the rest of the settle
  cap watching for a real HDR signal (mode-switch-end, raised headroom).
  Rate-only writes keep the clear as their exit. Found on a panel that takes
  HDR10 fine when parked there, yet cleared its runtime switch at ~2.9 s with
  the mode never engaging.

### Added

- `SettleReport.Outcome.clearedWithoutHDRSignal` + `clearedAfterMilliseconds`
  — the report line that says the panel probably stayed SDR and a master
  rejection may follow: "switch cleared at 2913ms but HDR never signalled;
  watched to 6000ms".

## [1.0.0] — 2026-08-07

Identical in content to 0.1.13 — the bump is the declaration. The engine has
been shipping in a real app across the 0.1.x line: remux with multi-audio,
Atmos carriage, Dolby Vision (including 7 → 8.1 conversion), text and OCR
bitmap subtitle renditions, the tvOS display-criteria contract, demand-driven
production with seek re-anchoring, deinterlace verification and the software
pipeline. From here the public API is stable: breaking changes mean a major
bump, features a minor, fixes a patch.

## [0.1.13] — 2026-08-07

### Added

- `VideoTrackInfo.sampleAspectRatio` — the pixel aspect ratio a display should
  honor, kept rational, container-level over bitstream. What a host needs to
  size a surface for anamorphic content.

### Fixed

- **Anamorphic SD plays at its intended shape.** The container-level aspect
  ratio (an MKV's DisplayWidth/Height — how anamorphic DVD rips are usually
  tagged) lives on the stream, not in codecpar, and the codecpar-only copy
  dropped it: 720×576/16:9 sources played distorted. The remux now propagates
  it into the `pasp` box AVPlayer honors. (Found and pinned byte-level because
  FFmpeg's own hls demuxer has the same codecpar-only bug and a playlist
  re-probe can never see the value.)

### Changed

- **OCR arms on demand.** Bitmap renditions used to decode and OCR every track
  from the first packet; a Blu-ray-class remux can carry dozens of PGS tracks
  of which the player selects at most one. A track now does nothing — decode
  included — until a fetch of one of its own `.vtt` segments arms it, and
  segments cut while unarmed are re-produced on that fetch through the same
  re-anchor machinery a seek uses, so subtitles enabled mid-film still get
  their cues. Text renditions stay always-on — they are cheap.

## [0.1.12] — 2026-08-07

### Added

- **Application Store Exception** on the licence. LGPL section 6 asks that users
  be able to relink a work against a modified PrismCore, which a signed `.ipa`
  cannot allow — so plain LGPL and the App Store were in tension, which is a poor
  reason for a library like this to be unusable by the apps it was written for.
  The exception releases an adopter from that requirement for store distribution
  only; modifications to PrismCore itself stay LGPL and still have to be
  published. FFmpeg's own terms are untouched and unchanged.
- `CHANGELOG.md` — this file. Releases up to 0.1.11 are reconstructed from their
  tags.

### Changed

- **README rewritten for adopters.** It described a v0 scaffold whose Aether
  integration was "parked on two build-level prerequisites"; both were solved
  weeks ago and the engine has been shipping since. It now leads with what the
  engine handles, how to call it, and what integrating it asks of you, with the
  hard-won findings (the `dec3` box, `hvc1` parameter sets, the three Dolby Vision
  claims that must agree, WebVTT timing, lying interlace flags) kept as design
  notes rather than buried in a phase list.

## [0.1.11] — 2026-08-07

### Added

- `SoftwarePlaybackPipeline.durationSeconds` and `.volume` — the two numbers a
  host transport needs and the pipeline was keeping to itself. Duration is `nil`
  for sources whose container honestly doesn't know, rather than a fabricated
  zero.

## [0.1.10] — 2026-08-07

### Fixed

- **OCR speaks Vision's language.** Containers carry ISO 639 (Matroska metadata
  uses the three-letter 639-2 form — `cze`, `ger`), Vision wants BCP-47 (`cs-CZ`).
  The raw pass-through matched nothing, so exactly the tracks that most needed
  recognition got the default language instead of their own.
- The OCR text corrector is allowed to work where it helps, instead of being
  disabled wholesale.

## [0.1.9] — 2026-08-07

### Added

- **Bitmap subtitles become renditions through on-device OCR.** PGS / DVB / DVD
  tracks — the forced-subtitle and SDH form every Blu-ray remux carries — used to
  be reported and dropped, because a rendition needs text and a bitmap track has
  pictures. Vision reads them into the same WebVTT rendition machinery, which is
  the only form that rides PiP, AirPlay and the system subtitle menu at all.
  Lossy by design: typography dies, text survives, and the raw tracks stay
  surfaced for a host that wants to draw them pixel-accurately.
  Verified against a real Blu-ray remux.

## [0.1.8] — 2026-08-07

### Added

- **Deinterlacing.** AVPlayer never deinterlaces, so a stream-copied interlaced
  source — IPTV and DVB captures are where they live — played with combing on the
  native path. Verified-interlaced H.264 now routes to the software path and CPU
  `bwdif` at field rate.

### Fixed

- A *declared* interlaced stream is verified against a dozen decoded frames before
  it is believed. Broadcast H.264 is routinely flagged interlaced around
  progressive frames, and evicting those from the native path would trade hardware
  decode and Atmos passthrough for deinterlacing nothing.

## [0.1.7] — 2026-08-07

### Fixed

- **Same-format skip across sessions.** Hosts build a `DisplayCriteriaController`
  per playback and the redundancy baseline was per-instance, so replaying a title
  re-wrote identical criteria. That is not a no-op: it starts a redundant HDMI
  negotiation, and on panels whose switch is unobservable it made every settle run
  to its cap. The baseline is now class-wide, which is honest — there is one HDMI
  output to describe.
- Settle logs report the time actually spent rather than the budget, so switch
  latency can be measured instead of guessed at.

## [0.1.6] — 2026-08-07

### Fixed

- **A dynamic-range switch gets room for a real handshake.** The flat bounds (1 s
  start grace, 2 s settle cap) lost the race on living-room chains: a DV / HDR10
  renegotiation — HDCP re-auth, mode engage, often through an AVR — routinely
  takes over a second to visibly start and 2–5 s to end. When the wait gave up
  early the master loaded against the panel's old mode, tvOS refused the DV claim
  (`-11868`), and the tiered fallback silently replayed the title as HDR10.

## [0.1.5] — 2026-08-06

### Added

- **The rejection fallback learns tiers.** `makeMasterRejectionFallbackSession()`
  — a refused master that claimed Dolby Vision retries once *without* the claim
  (same renditions, same subtitles, same `VIDEO-RANGE`, playing as plain HDR10)
  before falling to the muxed shape. That middle tier exists for the one panel
  state no read can prove: Match Content off with the output parked in HDR10. The
  muxed shape stays the safe floor.

## [0.1.4] — 2026-08-06

### Fixed

- **Subtitles reach the master playlist.** The WebVTT renditions were produced but
  never published — the master write set the audio renditions and left the
  subtitle list empty, so AVPlayer's legible group only ever held the video
  stream's own CEA captions. The served master now declares every rendition
  (embedded text tracks and registered externals) and `start()` waits for the
  subtitle playlists it references.

## [0.1.3] — 2026-08-06

### Added

- **The tvOS playback contract.** `DisplayCriteriaController` programs
  `preferredDisplayCriteria` and waits the HDMI handshake out *before* the host
  loads the playlist, which is the only ordering tvOS accepts for HDR HLS — AVKit's
  automatic criteria derive from a format description that only exists after the
  variant passes the validation the switch has to precede. The `dvh1` fourcc is
  what negotiates Dolby Vision; SDR writes codec + rate only, which is what makes
  **Match Frame Rate** engage on SDR content.
- `PrismCoreSession.displayCriteria` publishes the per-source choice, clamped to
  the display it was built for.
- `DisplayCapabilities.panelIsCurrentlyHDR` — a panel already out of SDR takes an
  HDR master even when `availableHDRModes` came back empty.

### Fixed

- Dolby Vision Profile 5 on a non-DV display routes media-direct proactively. A
  bare `dvh1.05` master has no fallback variant for the filter to pick, so serving
  one bought a guaranteed `-11868`. Profile 8.x keeps its master: the `hvc1`
  primary *is* the fallback.

## [0.1.2] — 2026-08-05

### Fixed

- `BridgeClock`'s initializer is reachable on Xcode 26.6 / Swift 6.1, which is
  what Xcode Cloud builds with.

## [0.1.1] — 2026-08-05

### Fixed

- Authorship and copyright lines (0.1.0 shipped without them), and this package's
  own `Package.resolved` restored after a host-app resolve had overwritten it.

## [0.1.0] — 2026-08-05

First public release. Stream-copyable A/V (HEVC / H.264 / AV1 with hardware +
AAC / AC3 / EAC3 / FLAC / ALAC) remuxed to HLS-fMP4 and served from a loopback
HTTP server, with:

- **Multi-audio** — every viable track as an HLS alternate rendition, so the host
  gets a real `AVMediaSelectionGroup`;
- **Dolby Atmos** — EAC3+JOC stream-copied, with the `dec3` box's TS 103 420
  type-A extension re-applied to the init segment;
- **Dolby Vision** — honest `CODECS` / `SUPPLEMENTAL-CODECS`, the `dvh1` sample
  entry for Profile 5, Profile 7 → 8.1 RPU conversion through libdovi;
- **Subtitles** — text tracks and external files as segmented WebVTT renditions;
- **Seek & cache** — keyframe-aligned plan, demand-driven production with
  re-anchoring, byte-budgeted retention;
- **Software path** — libavcodec into `AVSampleBufferDisplayLayer` for the video
  AVPlayer cannot decode at all.

[1.4.0]: https://github.com/Wenzlik/PrismCore/releases/tag/1.4.0
[1.3.1]: https://github.com/Wenzlik/PrismCore/releases/tag/1.3.1
[1.3.0]: https://github.com/Wenzlik/PrismCore/releases/tag/1.3.0
[1.2.0]: https://github.com/Wenzlik/PrismCore/releases/tag/1.2.0
[1.1.2]: https://github.com/Wenzlik/PrismCore/releases/tag/1.1.2
[1.1.1]: https://github.com/Wenzlik/PrismCore/releases/tag/1.1.1
[1.1.0]: https://github.com/Wenzlik/PrismCore/releases/tag/1.1.0
[1.0.0]: https://github.com/Wenzlik/PrismCore/releases/tag/1.0.0
[0.1.13]: https://github.com/Wenzlik/PrismCore/releases/tag/0.1.13
[0.1.12]: https://github.com/Wenzlik/PrismCore/releases/tag/0.1.12
[0.1.11]: https://github.com/Wenzlik/PrismCore/releases/tag/0.1.11
[0.1.10]: https://github.com/Wenzlik/PrismCore/releases/tag/0.1.10
[0.1.9]: https://github.com/Wenzlik/PrismCore/releases/tag/0.1.9
[0.1.8]: https://github.com/Wenzlik/PrismCore/releases/tag/0.1.8
[0.1.7]: https://github.com/Wenzlik/PrismCore/releases/tag/0.1.7
[0.1.6]: https://github.com/Wenzlik/PrismCore/releases/tag/0.1.6
[0.1.5]: https://github.com/Wenzlik/PrismCore/releases/tag/0.1.5
[0.1.4]: https://github.com/Wenzlik/PrismCore/releases/tag/0.1.4
[0.1.3]: https://github.com/Wenzlik/PrismCore/releases/tag/0.1.3
[0.1.2]: https://github.com/Wenzlik/PrismCore/releases/tag/0.1.2
[0.1.1]: https://github.com/Wenzlik/PrismCore/releases/tag/0.1.1
[0.1.0]: https://github.com/Wenzlik/PrismCore/releases/tag/0.1.0
