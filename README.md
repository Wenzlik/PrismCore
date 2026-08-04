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
let playlistURL = try await session.start()       // http://127.0.0.1:<port>/index.m3u8
// hand playlistURL to AVPlayer (Aether: the Lumen path plays it)
…
await session.stop()
```

No view, no transport, no published state — the host's existing AVPlayer
infrastructure stays in charge. The engine grows inward from there (see
Roadmap).

## Architecture (v0)

```
Source URL ──► libavformat demux ──► hls muxer (fMP4 segments, event playlist)
                                              │  tmp dir
                                              ▼
                                      LoopbackHTTPServer ──► AVPlayer
```

The loopback server speaks HTTP/1.1 with keep-alive (bounded per connection and
by an idle timeout), `GET` + `HEAD`, and pipelined requests. Payloads come from a
`SegmentProvider` rather than straight off disk: `DirectorySegmentProvider` is
the v0 implementation, and a provider that answers `.pending` gets an early
`200` + `Transfer-Encoding: chunked` once a serve passes 2 s — keeping response
headers inside AVPlayer's ~3.5 s media watchdog window. A pending serve that
ultimately fails aborts the connection (truncated transfer → AVPlayer retries)
instead of framing a cacheable empty `200`. That seam is where phase 5's
demand-driven producer plugs in.

v0 lets FFmpeg's own `hls` muxer do the segmentation (equivalent to
`ffmpeg -f hls -hls_segment_type fmp4`), writing an EVENT playlist that grows
as segments land and gains `EXT-X-ENDLIST` when the remux finishes. AVPlayer
starts playback as soon as the first segments exist. Demand-driven seeking
(producing segments *at* the seek target instead of from the start) is the
single biggest piece of the later phases.

## Roadmap

**End goal: replace Prism (libmpv) in Aether.** Until every phase lands,
routing is additive — sources PrismCore can't take yet keep falling back to
Prism, and Prism retires only at parity.

1. **v0 (this)** — stream-copyable A/V (HEVC/H.264 + AAC/AC3/EAC3/FLAC/ALAC),
   loopback server, event playlist. Plays an MKV remux with Atmos intact —
   which is already the bulk of what Prism handles in the wild.
2. **Aether integration** — `PlayerTransport` routing behind a developer
   toggle; HTTP headers for server sources; teardown discipline.
3. **Audio bridge** — TrueHD / DTS / DTS-HD MA → EAC3 5.1 (decode + re-encode)
   so non-streamable audio still surrounds on the native path.
4. **DV + HDR signaling** — master playlist with honest `CODECS` /
   `SUPPLEMENTAL-CODECS`, `hvcC` normalization, P7→8.1 RPU conversion
   (Libdovi ships inside MPVKit already), panel-readiness gating.
   *Groundwork landed:* `SourceProbe` (what the source is, and whether
   PrismCore can take it) and `MasterPlaylistBuilder` (the signaling rules, as
   pure value-in/string-out logic with the rules pinned by unit tests). Still
   open in this phase: `hvcC` normalization, the P7 conversion, and wiring the
   master playlist into `PrismCoreSession` behind the panel-readiness read.
5. **Seek & cache** — keyframe-aligned segment plan, demand-driven producer
   with restart timeline continuity, byte-budgeted retention.
6. **Subtitles** — WebVTT renditions so text survives PiP / AirPlay; bitmap
   (PGS/DVB) rendering for the fullscreen overlay.
7. **Software decode path** — libavcodec →
   `AVSampleBufferDisplayLayer`/`AVSampleBufferAudioRenderer` for what the
   HLS-fMP4 pipeline can't carry (VP9/VP8, MPEG-2/VC-1/MPEG-4 ASP,
   interlaced H.264 + deinterlace). This is the phase that lets Prism —
   and with it the entire libmpv dependency — retire.

## Prior art & rules

The architecture follows the approach proven by
an established external engine (LGPL),
whose docs generously describe both the mechanism and the potholes
(AVPlayer's HLS-fMP4 quirks, the `-12889` media watchdog, `tfdt` timeline
continuity across producer restarts, DV profile signaling). **We study how it
does things and build our own similarly; no code is copied from it.** If a
piece of it is ever wanted verbatim, the correct route is depending on the
LGPL package, not transplanting source.

FFmpeg arrives through [MPVKit](https://github.com/mpvkit/MPVKit)'s LGPL
dynamic xcframeworks — the same dependency Aether already ships, with the
same LGPL obligations already met.

## Status

Early scaffold. `swift build` / `swift test` on macOS exercise the playlist
and server pieces; the remux path needs a real media fixture and a device for
the Atmos/DV claims.
