# Notices

PrismCore is licensed under the **GNU Lesser General Public License, version 2.1
or later** — see [`LICENSE`](LICENSE).

## Why LGPL rather than something permissive

Because one file's ancestry asks for it, and pretending otherwise would be the
kind of thing nobody notices until it matters.

PrismCore *links* FFmpeg dynamically (see below), and dynamic linking alone would
have left our own code free to carry any licence. But
`Sources/PrismCore/Remux/EAC3Syncframe.swift` is a different case: its E-AC-3
bitstream walk was written **by reading FFmpeg's `libavcodec/ac3_parser.c`**,
field order and widths included, because the placement of the JOC signal in
`addbsi` cannot be derived reliably from the specification alone — three separate
attempts from the spec produced a confidently wrong answer. That file is
realistically a derivative of LGPL-2.1+ code, so LGPL-2.1-or-later is the honest
licence for it, and applying it to the whole package keeps the boundary somewhere
a reader can find it.

If a permissive licence is ever wanted, that file is the thing that would have to
be written again from ETSI TS 102 366 and TS 103 420 by someone who hasn't read
FFmpeg's version.

## Dependencies

| | licence | how it is used |
|---|---|---|
| [FFmpeg](https://ffmpeg.org) | LGPL-2.1+ | libavformat / libavcodec / libavutil / libswresample / libswscale, for demuxing, muxing and the software decode path |
| [MPVKit](https://github.com/mpvkit/MPVKit) | LGPL-3.0 | supplies the above as prebuilt **dynamic** xcframeworks |
| [libdovi](https://github.com/quietvoid/dovi_tool) | MIT | Dolby Vision RPU parsing and the Profile 7 → 8.1 conversion |

**No FFmpeg source is redistributed in this repository.** The binaries arrive
through MPVKit, which is where their corresponding sources and build recipes live,
and they are linked dynamically — so the LGPL's relinking requirement is satisfied
by replacing the xcframeworks in MPVKit.

Anything built on PrismCore inherits those obligations: ship the licence texts,
say which versions you used, and keep the FFmpeg libraries replaceable.

## Attribution

The E-AC-3 walk in `EAC3Syncframe.swift` follows FFmpeg's `ac3_parser.c`. It was
first ported from Aether's own Matroska remuxer, which had solved the same problem
against a real device — and then extended here, because that version only reads
the first frame of a packet and only independent substreams, and Dolby's
Blu-ray-style DD+ carriage puts the JOC signal in a *dependent* substream behind
an AC-3 core frame.
