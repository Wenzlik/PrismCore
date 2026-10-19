# Notices

PrismCore was written by **Václav Zmrhal** ([zmrhal.cz](https://zmrhal.cz)) for
[Aether](https://aetherplayer.com).

Copyright © 2026 Václav Zmrhal.

PrismCore is licensed under the **GNU Lesser General Public License, version 2.1
or later, with an Application Store Exception** — see [`LICENSE`](LICENSE).

## The Application Store Exception, in one paragraph

LGPL section 6 asks that the users of a work built on PrismCore be able to relink
it against a modified PrismCore, and that its terms permit modifying and
reverse-engineering it for that. A signed `.ipa` cannot allow that, so plain LGPL
and the App Store are in tension — which is a poor reason for a library like this
one to be unusable by the apps it was written for. The exception releases an
adopter from those requirements *for store distribution only*. It does not release
anyone from LGPL on PrismCore itself: modify the library and those modifications
stay LGPL and have to be published. Using it unmodified asks two things — say in
your app that it includes PrismCore, with a copy of its licence and where the
source is, and honour FFmpeg's
own terms below, which are unchanged by any of this.

## Why LGPL rather than something permissive

Because one file's ancestry asks for it, and pretending otherwise would be the
kind of thing nobody notices until it matters.

Linking against FFmpeg alone would have left our own code free to carry any
licence (see below for how it is linked). But
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
| [FFmpeg](https://ffmpeg.org) | LGPL-2.1+ source; the MPVKit builds are configured `--enable-version3`, so the shipped libraries are **LGPL-3.0-or-later** | libavformat / libavcodec / libavutil / libswresample / libswscale, for demuxing, muxing and the software decode path |
| [MPVKit](https://github.com/mpvkit/MPVKit), through the [Wenzlik/MPVKit](https://github.com/Wenzlik/MPVKit) fork | LGPL-3.0 | supplies the above as prebuilt xcframeworks (static libraries); the fork rebuilds FFmpeg with the `eac3` encoder and `yadif_videotoolbox`, everything else is upstream's |
| [libdovi](https://github.com/quietvoid/dovi_tool) | MIT | Dolby Vision RPU parsing and the Profile 7 → 8.1 conversion |
| `Rust/TrueHDObjects` ([truehdd](https://github.com/truehdd/truehdd)'s `truehd` + `oamd`, a port of [SpatialAudioBridge](https://github.com/kristofferR/SpatialAudioBridge)'s renderer, a few MIT/Apache crates) | Apache-2.0 (the crate); the linked crates' terms in its `THIRD-PARTY-NOTICES.md` | TrueHD Atmos heights; part of the default package (statically linked), used only when a host turns height rendering on (off by default) |

### TrueHDObjects

The library in `Rust/TrueHDObjects` is a separate work under the **Apache
License 2.0**, statically linked into PrismCore's default package (again since
3.7.2), so every app that links PrismCore ships it. Apache-2.0 code
combines with LGPL-2.1-**or-later** code under the LGPL-3.0 option (the FSF
counts Apache-2.0 as compatible with (L)GPLv3, not with v2), which is one more
reason the "or later" matters here. Its notices and every linked crate's
licence text sit in `Rust/TrueHDObjects/THIRD-PARTY-NOTICES.md` and
`Rust/TrueHDObjects/licenses/`, and the build copies them into the
XCFramework (`licenses/`): an app that ships the library ships them in its
acknowledgements. It decodes Dolby TrueHD with an independent implementation,
and the feature is off unless a host turns it on.

**No FFmpeg source is redistributed in this repository.** The binaries arrive
through the Wenzlik/MPVKit fork of MPVKit, which is where their corresponding
sources and build recipes live: its build scripts, the FFmpeg tag they check out
(`n8.1.2`) and the configure line, which every library also carries
(`avcodec_configuration()`, `FFmpegBuild.configuration`). No GPL or nonfree
component is enabled.
How FFmpeg is linked depends on the build a host uses: MPVKit's prebuilt
xcframeworks are static libraries, so FFmpeg is linked statically into the app;
a host that supplies dynamic FFmpeg frameworks links it dynamically. Which of the
ways the LGPL offers for a combined work (version 3 §4, which is version 2.1 §6)
applies follows from that choice.

Anything built on PrismCore inherits FFmpeg's obligations: ship the licence texts,
say which versions you used, and meet the LGPL's combined-work section (3.0 §4 for
MPVKit's `version3` builds, this fork's included) for the way your build links
FFmpeg. The Application Store Exception above covers PrismCore's own code
and does not reach FFmpeg — but nothing here makes FFmpeg's terms harder than they
already are for any app that ships it.

## Attribution

The E-AC-3 walk in `EAC3Syncframe.swift` follows FFmpeg's `ac3_parser.c`. It was
first ported from Aether's own Matroska remuxer, which had solved the same problem
against a real device — and then extended here, because that version only reads
the first frame of a packet and only independent substreams, and Dolby's
Blu-ray-style DD+ carriage puts the JOC signal in a *dependent* substream behind
an AC-3 core frame.
