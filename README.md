<p align="center">
  <img src=".github/prismcore-logo.png" alt="PrismCore" width="360">
</p>

# PrismCore

Aether's native playback engine core: **FFmpeg demuxes, Apple plays.**

Any container libavformat can read (MKV, MPEG-TS, AVI, …) is remuxed on the
fly into **HLS-fMP4**, served from a loopback HTTP server on `127.0.0.1`, and
handed to a plain `AVPlayer` as a playlist URL. Apple's stack then does what
only it can do on its own platforms:

- **hardware decode** (VideoToolbox),
- **Dolby Atmos passthrough** — EAC3+JOC is stream-copied, never decoded to PCM,
- **Dolby Vision** display engagement and the HDMI handshake,
- **Match Content** (frame rate + dynamic range) on tvOS,
- system-side HDR10/HLG tone-mapping.

The engines Aether ships today split this down the middle: Lumen (AVPlayer)
has all of the above but only Apple's containers; Prism (libmpv) plays
everything but renders its own frames and decodes audio to PCM, so Atmos and
DV die at its door. PrismCore exists to close that gap.

## v0 shape: a remux proxy

The first integration is deliberately narrow — a *service*, not a player:

```swift
let session = try PrismCoreSession(url: mkvURL)   // or with HTTP headers

// optional, before start(): a sidecar joins the WebVTT renditions (phase 6)
try await session.addExternalSubtitle(url: srtURL, language: "cs", name: "Čeština")

let playlistURL = try await session.start()       // .../master.m3u8 or .../index.m3u8
// hand playlistURL to AVPlayer (Aether: the Lumen path plays it)
…
await session.stop()
```

The URL is a **master** playlist when the source has audio (that is where the
selectable audio renditions live) and the media playlist when it hasn't. Treat
it as opaque: the shape is a property of the source.

No view, no transport, no published state — the host's existing AVPlayer
infrastructure stays in charge. The engine grows inward from there (see
Roadmap).

## Architecture (v0)

```
                                    ┌─► video ──► fMP4 segments + index.m3u8
Source URL ──► libavformat demux ───┼─► audio 0 ─► audio0/{init.mp4,seg*.m4s,index.m3u8}
                                    └─► audio N ─► audioN/…        │  tmp dir
                                              master.m3u8 ─────────┤
                                                                   ▼
                                                    LoopbackHTTPServer ──► AVPlayer
```

Every viable audio track of the source becomes an HLS **alternate rendition**:
its own fMP4 writer, its own media playlist, its own subdirectory, all wrapped
by a `master.m3u8` whose `EXT-X-MEDIA` lines carry the tracks' names, languages
and channel counts. That is what gives AVPlayer an `AVMediaSelectionGroup` to
switch on — parity with the libmpv player PrismCore replaces, whose track menu
the host app already exposes. Audio cuts follow the **video's** segment
boundaries so the renditions stay comparable, which is what HLS asks of them.

A source whose master playlist can't be written honestly (no derivable `CODECS`
string, or a dynamic range this display hasn't been vouched for — see
`PrismCoreSession`'s `displayIsHDRReady`) falls back to v0's shape: one audio
track muxed into the video's own segments, media playlist served directly.
Renditions only exist inside a master, so no master means the audio rides
inside the variant.

The loopback server speaks HTTP/1.1 with keep-alive (bounded per connection and
by an idle timeout), `GET` + `HEAD`, and pipelined requests. Payloads come from a
`SegmentProvider` rather than straight off disk: `DirectorySegmentProvider` is
the v0 implementation, and a provider that answers `.pending` gets an early
`200` + `Transfer-Encoding: chunked` once a serve passes 2 s — keeping response
headers inside AVPlayer's ~3.5 s media watchdog window. A pending serve that
ultimately fails aborts the connection (truncated transfer → AVPlayer retries)
instead of framing a cacheable empty `200`. Phase 5's `PlanSegmentProvider`
plugs into that seam: a fetch of a planned-but-unproduced segment becomes a
producer re-anchor (via `DemandCoordinator`) plus a pending serve that waits
for the file to land.

The segmentation is ours: MPVKit's libavformat is built without the `hls`
muxer, so `FMP4SegmentWriter` drives the `mp4` muxer with `frag_custom` and cuts
where we say (video keyframes at/after each 6 s boundary), and
`MediaPlaylistWriter` turns those fragments into a playlist. Two production
modes exist:

- **Planned (demand-driven, phase 5)** — the default for seekable VOD.
  `SegmentPlan` maps every segment upfront from the demuxer's keyframe index
  (trusted only past two witnesses: max keyframe gap 60 s, coverage ≥ one
  target duration), complete `PLAYLIST-TYPE:VOD` playlists are published
  before the first packet, and a fetch outside the producer's window
  re-anchors it — `av_seek_frame` to the anchor keyframe, fresh muxers with
  `frag_discont` + `avoid_negative_ts=disabled` so `tfdt` carries absolute
  time and the produced segment sits exactly where the playlist promised.
  After EOF the producer parks and keeps answering demand for segments a
  re-anchor skipped, until the session stops.
- **Sequential (v0, kept)** — EVENT playlist growing head-to-EOF, gaining
  `EXT-X-ENDLIST` at the end. Used when no trustworthy plan exists (live /
  unknown duration / junk index → uniform basis) and for the
  muxed-with-bridge shape (re-anchoring would reset an encoder mid-fragment).

### Subtitle timing (`X-TIMESTAMP-MAP`)

WebVTT cue times are local to their file, so HLS bridges them to the media
timeline with `X-TIMESTAMP-MAP=MPEGTS:<t>,LOCAL:<local>`, where `t` sits on a
90 kHz axis whatever timescale the media segments use. Our fMP4 segments carry
the source's own stream-copied timestamps, so the media timeline starts at the
first video PTS — there is no MPEG-TS 10 s convention to honour, and assuming one
is exactly what makes fMP4 subtitle tracks render ten seconds late in other
implementations. PrismCore therefore writes cue times **relative to the
presentation origin** and repeats
`MPEGTS:round(origin × 90000),LOCAL:00:00:00.000` in every segment: `MPEGTS:0`
for an ordinary file starting at PTS 0, `MPEGTS:900000` for a mid-stream capture
that really does start at 10 s. The map states a fact about the output rather
than a convention.

## Roadmap

**End goal: replace Prism (libmpv) in Aether.** Until every phase lands,
routing is additive — sources PrismCore can't take yet keep falling back to
Prism, and Prism retires only at parity.

1. **v0 (this)** — stream-copyable A/V (HEVC/H.264 + AAC/AC3/EAC3/FLAC/ALAC),
   loopback server, event playlist. Plays an MKV remux with Atmos intact —
   which is already the bulk of what Prism handles in the wild. **Multi-audio**
   landed here rather than later: every viable audio track is served as an
   alternate rendition behind a master playlist, because a host whose track menu
   can only offer one track is not at parity with the player it replaces.
2. **Aether integration** — `PlayerTransport` routing behind a developer
   toggle; HTTP headers for server sources; teardown discipline.
3. **Audio bridge** *(implemented, needs a media fixture + a device)* — TrueHD /
   DTS / DTS-HD MA / MP3 / MP2 / Opus / Vorbis / PCM → EAC3 (decode +
   re-encode, 128 kbps per channel) so non-streamable audio still surrounds on
   the native path. Requires an FFmpeg built with the `eac3` **encoder**: stock
   MPVKit ships only the ac3/eac3 decoders, so until Aether's MPVKit fork adds
   `--enable-encoder=eac3` the bridge reports itself unavailable and routing
   keeps v0's fallback to a copyable audio track.
4. **DV + HDR signaling** *(implemented; the DV claims need a device)* — the
   master playlist carries honest `CODECS` / `SUPPLEMENTAL-CODECS`, and all four
   of the phase's parts are in:
   - `SourceProbe` reports what the source is and whether PrismCore can take it;
     `MasterPlaylistBuilder` holds the signaling rules as pure
     value-in/string-out logic pinned by unit tests.
   - **`hvcC` normalization** (`HVCCNormalizer`) — a stream-copied HEVC track
     gets a `hvc1` sample entry, which asserts every parameter set lives in that
     entry. Matroska `CodecPrivate` routinely says otherwise
     (`array_completeness=0`) and carries SEI arrays besides, so the record is
     rewritten to VPS/SPS/PPS in order with completeness asserted. The 22-byte
     profile_tier_level header is copied verbatim — it is what the `CODECS`
     string is printed from, so the declaration keeps matching the init segment.
   - **P7 → 8.1 RPU conversion** (`DolbyVisionRPUConverter`) — Profile 7 is
     dual-layer with an HDR10 base no Apple platform decodes as DV. libdovi
     (already linked into MPVKit's `_FFmpeg`) rewrites each RPU NAL to its
     single-layer 8.1 form and the enhancement layer's NALs are dropped, so the
     stream becomes a `dvh1.08.xx/db1p` claim over its own untouched base
     pictures. Behind `canImport(Libdovi)`: a build without the module reports
     the converter unavailable and P7 keeps routing to Prism.
   - **The panel read** (`DisplayCapabilities.current()`) — `AVPlayer
     .availableHDRModes` on iOS/tvOS/visionOS, `NSScreen`'s potential EDR
     headroom on macOS, replacing the caller-supplied `displayIsHDRReady` /
     `displayIsDolbyVisionCapable` guess. Use
     `PrismCoreSession.readingCurrentDisplay(url:)`. macOS never claims DV on
     purpose (no HDMI handshake to engage, and the 8.1 base already plays
     through EDR).
   - **Master-rejection fallback** (`MasterRejection`) — `-11868` / `-11848` /
     `-1002`, matched across error domains and through
     `NSUnderlyingErrorKey`. `PrismCoreSession.isMasterRejection(_:)` tells a
     refused master apart from an unplayable source, and
     `makeMuxedFallbackSession()` mints the media-direct retry (external
     subtitle registrations replayed). This is the half that catches the panel
     read being optimistic: no API distinguishes a Match-Content display from an
     HDR-capable one parked in SDR.
5. **Seek & cache** *(implemented)* — keyframe-aligned `SegmentPlan`,
   planned VOD playlists, demand-driven producer with re-anchoring and
   absolute-`tfdt` restart continuity, EOF parking, byte-budgeted retention
   (`segmentCacheBytes`, default 1 GiB; planned mode only — an evicted
   segment is reproduced on demand, so the budget bounds disk, not
   seekability). `forceMuxedShape` is the host's master-rejection fallback:
   on -11868 / -11848 / -1002, make a NEW session with it set. Still open:
   subtitle backfill after a re-anchor (a skipped range's `.vtt` serves as
   an honest empty segment — cues resume from the anchor).
6. **Subtitles** *(text half implemented)* — every text subtitle stream
   (SubRip / ASS / SSA / WebVTT / mov_text) is converted during the remux read
   loop into a segmented WebVTT rendition (`subs<N>/seg%05d.vtt` +
   `subs<N>/index.m3u8`) cut on the video's own segment boundaries, so text
   survives PiP / AirPlay instead of living in a host overlay. External `.srt` /
   `.vtt` files register with `PrismCoreSession.addExternalSubtitle(url:…)`
   before `start()` and become renditions the same way. The renditions are
   declared `DEFAULT=NO,AUTOSELECT=NO` in a `SUBTITLES` group so AVKit never
   engages one by itself — the host selects it in the legible
   `AVMediaSelectionGroup`. Bitmap subtitles (PGS/DVB/DVD) are out of scope
   here: `SourceProbe` reports them (`SourceInfo.bitmapSubtitleTracks`) so the
   host can render them in its own overlay, and an OCR-fed rendition is a later
   idea, not this phase.
7. **Software decode path** *(skeleton implemented; no session integration yet)*
   — libavcodec → `AVSampleBufferDisplayLayer`/`AVSampleBufferAudioRenderer`
   under an `AVSampleBufferRenderSynchronizer` for what the HLS-fMP4 pipeline
   can't carry (VP9/VP8, MPEG-2/VC-1/MPEG-4 ASP, interlaced H.264 +
   deinterlace). This is the phase that lets Prism — and with it the entire
   libmpv dependency — retire.
   *Landed:* `Sources/PrismCore/Software/` — `SoftwareVideoDecoder` (frames as
   `CMSampleBuffer`s of `CVPixelBuffer`s; zero-copy through the VideoToolbox
   hwaccel where MPVKit's build has one, which includes VP9, with a CPU decode
   + NV12/P010 conversion fallback), `SoftwareAudioDecoder` (LPCM buffers whose
   timestamps come from a running sample count, not from container-quantized
   PTS — see `AudioClock`), and `SoftwarePlaybackPipeline` (demux + both
   decoders + renderers + master clock, with `load/play/pause/seek/stop`).
   Still open in this phase: wiring it into `PrismCoreSession` and the host's
   routing, deinterlacing, subtitles, track switching, and frame-accurate seek.

## Dependencies

FFmpeg arrives through [MPVKit](https://github.com/mpvkit/MPVKit)'s LGPL
dynamic xcframeworks — the same dependency Aether already ships, with the
same LGPL obligations already met.

## Status

Early scaffold. `swift build` / `swift test` on macOS exercise the playlists,
server, subtitle-rendition, and audio-bridge pieces (the bridge's decode →
resample → FIFO → encode chain runs end to end in tests over synthesized LPCM),
plus end-to-end remuxes of synthetic fixtures: a two-language master (AAC eng +
AC3 ces) is served over the loopback, re-probed through libavformat's hls demuxer
with both codecs and both languages intact, and reaches `.readyToPlay` in a real
`AVPlayer`. What fixtures can't carry still needs a device: the Atmos and Dolby
Vision claims, actual track *switching* in AVKit's audio menu, and the EAC3
output the bridge produces (which needs an FFmpeg build with that encoder
enabled).

The software path (phase 7) is exercised headless as far as it can be: the VP9
fixture decodes to `CVPixelBuffer`s of the right shape on a monotonic,
source-anchored timeline, the pipeline runs demux → decode → stamp →
back-pressure → enqueue against renderer stand-ins (including the case where a
stalled video renderer must not starve audio), and the clock arithmetic is
unit-tested on its own. What no headless test can assert is that a frame reached
a display or a speaker — that needs a device, and so does the A/V sync the
synchronizer is supposed to be maintaining.
