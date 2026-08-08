# Changelog

All notable changes to PrismCore. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project follows
[Semantic Versioning](https://semver.org). (Releases before 1.0.0 carried the
usual pre-1.0 caveat: **minor** bumps could break API, **patch** bumps stayed
source-compatible.)

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
