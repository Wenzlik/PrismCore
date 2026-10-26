# DTS:X heights: feasibility and design

Status: **design only — no code.** Written 2026-10-26 against PrismCore 3.8.6,
FFmpeg n8.1.2 (the source the `Wenzlik/MPVKit` fork builds) and the public
ETSI specifications listed below. The decision this asks for is at the end
(*Questions*).

## Summary

- PrismCore can already **tell** that a track claims DTS:X (FFmpeg sets
  `AV_PROFILE_DTS_HD_MA_X` / `_X_IMAX`), and it plays the DTS-HD MA
  **channel presentation** (core + XLL, usually 7.1) through the bridge —
  EAC3 5.1, or FLAC 7.1 with `.lossless` — reporting `.notPreserved`.
- What it cannot do is **render the DTS:X objects**. On a Blu-ray DTS:X
  track the object data is a payload FFmpeg finds *after* the XLL frame data
  and skips. None of the public specifications below describes that payload.
  Implementing it would mean reading an undocumented structure out of
  streams, which this project does not do.
- The part of the DTS object world that **is** fully public is **DTS-UHD**
  (ETSI TS 103 491 bitstream and metadata, ETSI TS 103 584 renderer): a
  different stream format (its own frame sync, `dtsx` sample entry), used by
  streaming and broadcast, not by Blu-ray. FFmpeg has no decoder for it.
- Recommendation: **do not start an implementation** until there is either a
  public specification of the disc payload (or a statement from DTS that disc
  DTS:X uses the TS 103 491 metadata syntax) and real material to test
  against, plus a licensing answer (see *Patents and licensing*). One small,
  fully public step is possible now (phase 0 below).

## What PrismCore does today

- `SourceProbe` (`Sources/PrismCore/Probe/SourceProbe.swift`, the
  `AV_PROFILE_DTS_HD_MA_X` / `_X_IMAX` check) reports a DTS:X claim from the
  codec parameters. As the field notes in `AGENTS.md` say for TrueHD and
  E-AC-3, a profile is a claim, not a fact: it is set only when
  `avformat_find_stream_info` decoded an XLL frame inside its read cap.
- `AudioBridge` decodes the track with FFmpeg's `dca` decoder: the core plus
  every extension FFmpeg implements (XCh, XXCH, X96, XBR, XLL, LBR), i.e. the
  lossless channel presentation. Objects never reach it.
- `ObjectAudioDelivery` says `.notPreserved` for a DTS:X claim; heights
  (`objectAudioRendering: .heights`) are TrueHD-only.

## What upstream FFmpeg (n8.1.2) exposes

- **Detection only.** `libavcodec/dca_xll.c`, `parse_frame()`: when an XLL
  frame is longer than the data the lossless decoder consumed, the next
  32-bit word (dword-aligned) is compared with `DCA_SYNCWORD_XLL_X`
  (`0x02000850`) and `DCA_SYNCWORD_XLL_X_IMAX` (`0xF14000D0`, top 31 bits),
  defined in `libavcodec/dca_syncwords.h`. A match sets `x_syncword_present` /
  `x_imax_syncword_present`, and the output frame's profile becomes
  `AV_PROFILE_DTS_HD_MA_X` / `AV_PROFILE_DTS_HD_MA_X_IMAX`
  (`dca_xll.c`, the profile switch before the PCM output). The decoder then
  seeks to the end of the frame: **the payload is never parsed, exported as
  side data, or decoded.**
- **The channel presentation.** Core, XCh, XXCH, X96, XBR, XLL, LBR and the
  extension substream (ExSS) are decoded; channel masks include the height
  positions of TS 102 114 (Lh, Rh, Lhs, Rhs, Lhr, Rhr, …), so a stream whose
  *channel sets* carry heights decodes with them. Disc DTS:X normally carries
  its heights only as objects, so this is not the common case (unverified
  here: no DTS:X material was available on the measurement Mini).
- **DTS-UHD.** Nothing in n8.1.2 (no codec id, parser, demuxer or decoder).
  A demuxer + parser + MP4 muxing patch was proposed on ffmpeg-devel in
  April 2023 and did not include a decoder; it is not in n8.1.2.

## What the public specifications cover

| Specification | Covers | DTS:X (disc) objects? |
|---|---|---|
| ETSI TS 102 114 V1.6.1 (2019-08), *DTS Coherent Acoustics; Core and Extensions with Additional Profiles* | Core, X96, XBR, XCh, XXCH, extension substream, XLL (lossless), LBR; channel masks with height speakers; DASH/CMAF annexes | **No.** No object payload, no syncword after XLL frame data, no mention of DTS:X |
| ETSI TS 103 491 V1.2.1 (2019-05), *DTS-UHD Audio Format; Delivery of Channels, Objects and Ambisonic Sound Fields* | DTS-UHD frames (sync `0x40411BF2`, frame table of contents, metadata chunks, audio chunks), object/channel/HOA metadata, the ACE codec; can carry XLL audio chunks | Describes **DTS-UHD** objects. Says nothing about embedding its metadata in a DTS-HD MA XLL frame |
| ETSI TS 103 584 V1.1.1 (2018-01), *DTS-UHD Point Source Renderer* | The renderer for TS 103 491 objects (point sources; only its table of contents was read for this note) | Renderer for DTS-UHD metadata |
| ETSI TS 103 223 V1.1.1 (2015-04), *MDA; Object-Based Audio Immersive Sound Metadata and Bitstream* | An object metadata model, a VBAP reference renderer, a bitstream, aimed at cinema and broadcast | Not stated to be the disc payload |

So the gap is precise: **the structure that follows `0x02000850` in a disc
XLL frame is not in any of these documents.** It may well reuse TS 103 491
or TS 103 223 syntax, but establishing that from streams is reverse
engineering, which is out of bounds for this project (and for a clean-room
implementation generally). The question has to be answered by a document.

## What an implementation would need, if the payload were specified

Assuming a public specification turns up that describes the disc payload as
TS 103 491 metadata + audio chunks (the most likely shape), the work splits
the way TrueHD's did:

1. **Getting the bytes.** PrismCore already has every packet, but the
   payload's *start* is not in any header: the XLL frame header gives where
   the frame ends (TS 102 114 clause 8), and the extension substream header
   where the asset's XLL data begins (clause 7.5), while the payload begins
   after the last band data — which FFmpeg finds by parsing the common
   header, every channel-set sub-header and the NAVI table of segment sizes,
   then aligning to a dword (`dca_xll.c`, `parse_frame()`). XLL frames can
   also span packets under the peak-bit-rate smoothing buffer (clause
   7.5.3.4, `nuPeakBRCntrlBuffSzkB`;
   FFmpeg's PBR path reassembles them before parsing). A walker therefore
   needs the XLL header, channel-set and NAVI parsing plus PBR reassembly —
   a real parser, not an offset lookup. Two ways to get it: a Swift/Rust
   walker (like `TrueHDAtmosScout` and `EAC3Syncframe`: keeps the MPVKit
   fork at "upstream + the `eac3` encoder", testable without a rebuild,
   fuzzable through `FuzzTargets`, but a second implementation of FFmpeg's
   XLL navigation), or the FFmpeg patch below, which reuses the location
   logic FFmpeg already gets right.
2. **Metadata.** Object positions, gains, sizes, update timing, beds — TS
   103 491 clause 7 (3D object metadata, renderer configuration, rendering
   exceptions). A parser in `Rust/TrueHDObjects`' style, Apache-2.0, from the
   spec text alone.
3. **Object audio.** The object waveforms are not extra XLL channel sets of
   the presentation: those are described by the NAVI table and FFmpeg
   already decodes or skips them; the DTS:X bytes are what is *left over*
   after them. Under the TS 103 491 assumption the waveforms would be audio
   chunks inside that leftover — XLL-coded (TS 103 491 can carry XLL audio
   chunks; FFmpeg's XLL band decoding would have to be reusable on a buffer
   that is not a whole XLL frame) or ACE-coded (a whole new decoder, TS 103
   491 clauses 8–10).
4. **Rendering.** TS 103 584 (point sources) is the matching renderer;
   reusing the TS 103 448 panner in `render.rs` is also possible but would
   need the coordinate mapping (TS 103 491 places sources by azimuth and elevation, e.g. `m_3DSrcAzimuth` / `m_3DSrcElevation`, where TS 103 448 uses room coordinates) and its own
   measurement against TS 103 584. Output 7.1.4 through the existing APAC
   path (`HeightsBridge`, 12 channels today); 9.1.6 only once a 9.1.6
   renderer and APAC rendition exist, which they do not yet.
5. **Fallback.** As for TrueHD: the channel presentation in the same
   rendition with silent heights, `.notPreserved`, never a codec change after
   the master is written.

What a **patch to the `Wenzlik/MPVKit` fork** (FFmpeg n8.1.2) would need, in
the most likely shape: in `dca_xll.c` `parse_frame()`, the one place that
already knows where the leftover starts (after band data and the dword
alignment, PBR reassembly done), copy it — from the syncword to the end of
the XLL frame — into side data on the decoded output frame (a new
`AV_FRAME_DATA_*` type, or an opaque buffer), instead of seeking past it.
The parser (`dca_parser.c`) is the wrong place: it reads only the XLL
common-header prefix for the frame duration and never walks the channel
sets or NAVI. With the patch, steps 1 and 2 of the walker shrink to reading
side data, at the cost of carrying the patch on every MPVKit rebuild; it is
only worth carrying once steps 2–4 have something to decode.

## Patents and licensing — **for Václav to decide, not decided here**

- DTS (Xperi) holds patents on DTS:X / DTS-UHD and on object rendering;
  ETSI publication does not license them. ETSI's IPR database lists the
  declarations made for TS 103 491 / TS 103 584 / TS 102 114 and should be
  read before any implementation is shipped. Commercial DTS decoders are
  normally licensed through Xperi.
- FFmpeg's `dca` decoder is LGPL; its patent status is the user's concern
  (FFmpeg's own legal notice). PrismCore already ships it via MPVKit.
- Copyright and terms of use are open too: whether code written from the
  ETSI texts (and their pseudocode) may ship under PrismCore's LGPL-2.1+ /
  the TrueHDObjects Apache-2.0 terms needs the specifications' own terms
  reviewed. Clean-room work keeps the provenance clean; it does not by
  itself settle either this question or the patent one.
- Apple's frameworks do not decode DTS:X objects; nothing on the platform
  replaces this work.

## Effort and a phased plan

| Phase | What | Needs | Estimate |
|---|---|---|---|
| 0 | Read DTS:X off the stream rather than the probe's claim: a bounded scout (like `TrueHDAtmosScout`) that decodes the first frames with FFmpeg's own `dca` decoder and reads the profile it sets — FFmpeg already locates the leftover correctly (channel sets, NAVI, PBR). A hand-written scan for `0x02000850` is not an option: the dword can occur inside band data, and PBR-split frames hide it until reassembly | FFmpeg as linked; bounded like the TrueHD scout | 2–3 days |
| 1 | A document for the disc payload (or DTS's statement that it is TS 103 491 syntax); real DTS:X test material; the licensing answer | Václav | — |
| 2 | Payload walker (XLL header, channel sets, NAVI, PBR reassembly) + metadata parser (TS 103 491 clause 7) with fixtures and fuzzing | Phase 1 | 3–4 weeks |
| 3 | Object audio decode: XLL-coded audio chunks (FFmpeg's XLL band decoding made reusable on the leftover, an FFmpeg patch) or an ACE decoder | Phase 1; ACE is the large case | 2–4 weeks (XLL) / 2–3 months (ACE) |
| 4 | Rendering (TS 103 584, or the TS 103 448 panner with a measured mapping) into 7.1.4 through `HeightsBridge` | Phases 2–3 | 2–3 weeks |
| 5 | Measurement against a reference decode (the way TrueHD's heights split is measured against its exact object render), device runs on a receiver | A licensed reference decoder or DTS-provided reference output | 1 week |

DTS-UHD sources (`dtsx` in MP4, ATSC 3.0) are fully specified but rare in
the files PrismCore opens; they would need a demuxer path, the ACE decoder
and the renderer: the largest variant, with the same patent question.

## Questions for Václav

1. **Licensing:** is shipping a DTS:X / DTS-UHD object decoder in PrismCore
   acceptable at all, given DTS/Xperi patents (see above)? Should we ask
   Xperi for a licence or for the payload documentation?
2. **Specification:** do we have (or can we get) a public document for the
   Blu-ray DTS:X payload? Without one, phases 2–5 do not start.
3. **Phase 0:** should the stream-based DTS:X detection (a bounded decode of
   the first frames, FFmpeg's own profile) be built now? It is small, uses
   only what is linked, and makes the `.notPreserved` report trustworthy.
