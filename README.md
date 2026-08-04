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
let playlistURL = try await session.start()       // http://127.0.0.1:<port>/master.m3u8
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
instead of framing a cacheable empty `200`. That seam is where phase 5's
demand-driven producer plugs in.

The segmentation is ours: MPVKit's libavformat is built without the `hls`
muxer, so `FMP4SegmentWriter` drives the `mp4` muxer with `frag_custom` and cuts
where we say (video keyframes at/after each 6 s boundary), and
`MediaPlaylistWriter` turns those fragments into an EVENT playlist that grows
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
4. **DV + HDR signaling** — master playlist with honest `CODECS` /
   `SUPPLEMENTAL-CODECS`, `hvcC` normalization, P7→8.1 RPU conversion
   (Libdovi ships inside MPVKit already), panel-readiness gating.
   *Groundwork landed:* `SourceProbe` (what the source is, and whether
   PrismCore can take it) and `MasterPlaylistBuilder` (the signaling rules, as
   pure value-in/string-out logic with the rules pinned by unit tests). The
   master playlist is now written and served (multi-audio needs it), with the
   panel-readiness read still a caller-supplied `displayIsHDRReady` /
   `displayIsDolbyVisionCapable` pair rather than a real display query: an HDR
   or DV source keeps the media-direct shape until a host vouches for the
   panel. Still open in this phase: `hvcC` normalization, the P7 conversion,
   the actual panel read, and the master-rejection fallback (reload the media
   playlist when AVPlayer refuses a master, `-11868` / `-11848` / `-1002`).
5. **Seek & cache** — keyframe-aligned segment plan, demand-driven producer
   with restart timeline continuity, byte-budgeted retention.
6. **Subtitles** — WebVTT renditions so text survives PiP / AirPlay (the
   master + rendition plumbing multi-audio built is what they plug into); bitmap
   (PGS/DVB) rendering for the fullscreen overlay.
7. **Software decode path** — libavcodec →
   `AVSampleBufferDisplayLayer`/`AVSampleBufferAudioRenderer` for what the
   HLS-fMP4 pipeline can't carry (VP9/VP8, MPEG-2/VC-1/MPEG-4 ASP,
   interlaced H.264 + deinterlace). This is the phase that lets Prism —
   and with it the entire libmpv dependency — retire.

## Prior art & rules

The architecture follows the approach proven by
[AetherEngine](https://github.com/superuser404notfound/AetherEngine) (LGPL),
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

Early scaffold. `swift build` / `swift test` on macOS exercise the playlists,
server, and audio-bridge pieces (the bridge's decode → resample → FIFO →
encode chain runs end to end in tests over synthesized LPCM), plus end-to-end
remuxes of synthetic fixtures: a two-language master (AAC eng + AC3 ces) is
served over the loopback, re-probed through libavformat's hls demuxer with both
codecs and both languages intact, and reaches `.readyToPlay` in a real
`AVPlayer`. What fixtures can't carry still needs a device: the Atmos and Dolby
Vision claims, actual track *switching* in AVKit's audio menu, and the EAC3
output the bridge produces (which needs an FFmpeg build with that encoder
enabled).
