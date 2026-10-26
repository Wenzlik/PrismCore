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

1. **Getting the bytes.** PrismCore already has every packet. The payload
   can be located without touching FFmpeg: an XLL frame's length is in its
   header (TS 102 114 clause 8), the extension substream header gives the
   asset's XLL offset (TS 102 114 clause 7.5). A Swift/Rust walker, like
   `TrueHDAtmosScout` and `EAC3Syncframe`, is preferable to an FFmpeg patch:
   it keeps the MPVKit fork at "upstream + the `eac3` encoder", it is
   testable without a rebuild, and it is fuzzable (`FuzzTargets`).
2. **Metadata.** Object positions, gains, sizes, update timing, beds — TS
   103 491 clause 7 (3D object metadata, renderer configuration, rendering
   exceptions). A parser in `Rust/TrueHDObjects`' style, Apache-2.0, from the
   spec text alone.
3. **Object audio.** Decoding the object waveforms: if they are XLL channel
   sets, FFmpeg's XLL code decodes channel sets but only for the channel
   presentation it outputs; exporting the extra channel sets would need an
   FFmpeg patch (`dca_xll.c` decodes per channel set; a patch would add the
   object channel sets as extra planes or as frame side data). If they are
   ACE-coded, a whole new decoder (TS 103 491 clauses 8–10).
4. **Rendering.** TS 103 584 (point sources) is the matching renderer;
   reusing the TS 103 448 panner in `render.rs` is also possible but would
   need the coordinate mapping (TS 103 491 places sources by azimuth and elevation, e.g. `m_3DSrcAzimuth` / `m_3DSrcElevation`, where TS 103 448 uses room coordinates) and its own
   measurement against TS 103 584. Output 7.1.4 (or 9.1.6, see the APAC
   layout work) and the existing APAC path (`HeightsBridge`) unchanged.
5. **Fallback.** As for TrueHD: the channel presentation in the same
   rendition with silent heights, `.notPreserved`, never a codec change after
   the master is written.

What a **patch to the `Wenzlik/MPVKit` fork** (FFmpeg n8.1.2) would need, in
the most likely shape: in `dca_xll.c`, instead of seeking past the payload,
copy it (from the dword after the syncword to the end of the XLL frame) into
`AV_FRAME_DATA_*` side data on the output frame, or into packet side data in
`dca_parser.c`. That is small and mechanical, and only worth carrying if the
payload is then decoded somewhere — which is steps 2–4. Since PrismCore can
find the same bytes itself (step 1), the patch is optional.

## Patents and licensing — **for Václav to decide, not decided here**

- DTS (Xperi) holds patents on DTS:X / DTS-UHD and on object rendering;
  ETSI publication does not license them. ETSI's IPR database lists the
  declarations made for TS 103 491 / TS 103 584 / TS 102 114 and should be
  read before any implementation is shipped. Commercial DTS decoders are
  normally licensed through Xperi.
- FFmpeg's `dca` decoder is LGPL; its patent status is the user's concern
  (FFmpeg's own legal notice). PrismCore already ships it via MPVKit.
- A clean-room implementation from the ETSI texts is a copyright question
  answered (own code from public specs); the patent question is separate and
  is not answered by clean-room work.
- Apple's frameworks do not decode DTS:X objects; nothing on the platform
  replaces this work.

## Effort and a phased plan

| Phase | What | Needs | Estimate |
|---|---|---|---|
| 0 | Read DTS:X off the bitstream (the XLL trailing syncword, as FFmpeg does) in a bounded scout, so `.notPreserved` and the DTS:X label stop depending on the profile claim | Only TS 102 114 + the syncword FFmpeg publishes; fuzz target | 2–3 days |
| 1 | A document for the disc payload (or DTS's statement that it is TS 103 491 syntax); real DTS:X test material; the licensing answer | Václav | — |
| 2 | Payload walker + metadata parser (TS 103 491 clause 7) with fixtures and fuzzing | Phase 1 | 2–3 weeks |
| 3 | Object audio decode: XLL channel sets via a small FFmpeg patch, or an ACE decoder | Phase 1; ACE is the large case | 1–2 weeks (XLL) / 2–3 months (ACE) |
| 4 | Rendering (TS 103 584, or the TS 103 448 panner with a measured mapping) into 7.1.4 / 9.1.6, through `HeightsBridge` | Phases 2–3 | 2–3 weeks |
| 5 | Measurement against a reference decode (as `docs/ObjectAudioMeasurement.md` does for TrueHD), device runs on a receiver | A licensed reference decoder or DTS-provided reference output | 1 week |

DTS-UHD sources (`dtsx` in MP4, ATSC 3.0) are fully specified but rare in
the files PrismCore opens; they would need a demuxer path, the ACE decoder
and the renderer: the largest variant, with the same patent question.

## Questions for Václav

1. **Licensing:** is shipping a DTS:X / DTS-UHD object decoder in PrismCore
   acceptable at all, given DTS/Xperi patents (see above)? Should we ask
   Xperi for a licence or for the payload documentation?
2. **Specification:** do we have (or can we get) a public document for the
   Blu-ray DTS:X payload? Without one, phases 2–5 do not start.
3. **Phase 0:** should the bitstream-based DTS:X detection be built now? It
   is small, public, and makes the `.notPreserved` report trustworthy.
