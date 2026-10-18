# TrueHDObjects — third-party notices

`TrueHDObjects.xcframework` is built by `build-xcframework.sh` from this directory's sources and
the crates `Cargo.lock` pins. Nothing in it is a prebuilt third-party binary. These notices, the
texts under `licenses/` and `LICENSE-APACHE` travel inside the framework (`licenses/`) and must
ship with any app that links it.

Since PrismCore 3.7.1 the framework is **not part of PrismCore's default package**: it is linked
only into a build made with `PRISMCORE_OBJECT_AUDIO=1` (see the repository's `Package.swift`), so an
app built against a released PrismCore contains none of the components below.

## This crate

`truehd-objects` (this directory) is licensed under the **Apache License 2.0** (`LICENSE-APACHE`),
Copyright 2026 PrismCore contributors. It is a separate library from PrismCore's Swift code, which
is LGPL-2.1-or-later (see the repository's `NOTICE.md` for how the two combine).

Parts are adapted from **SpatialAudioBridge** by kristofferR
(<https://github.com/kristofferR/SpatialAudioBridge>, commit `0c63341`, Apache License 2.0):

| file | what was adapted | what changed |
|---|---|---|
| `src/render.rs` | the ETSI TS 103 448 source panner (point, size, divergence, snap, zones, trims), the bed routing table and the ramped gain mixer | 7.1.4 only; the DTS:X polar panner and 9.1.6 removed; absent bed speakers routed by table |
| `src/decode.rs` | mapping TrueHD OAMD to renderer events: DAMF→room coordinates, block scheduling, trims, concealment to the next major sync, holding audio until the first metadata | TrueHD only (no DTS); unsupported presentations fall back to the bed instead of ending the session; channel-based immersive presentations are routed by label; no dialogue normalisation |
| `src/limit.rs` | the design of the peak limiter (linked gain, 2 ms linear approach, 100 ms release, −0.1 dBFS) | own implementation |
| `build-xcframework.sh`, `scripts/mark-weak.py` | prelinking each slice to one object exporting only the C API and a weak `rust_eh_personality` | own implementation |

## Linked crates

Only these are linked into the library; build-time crates (`proc-macro2`, `quote`, `syn`,
`thiserror-impl`, `unicode-ident`) are not.

| crate | version | licence (as used) | author | text |
|---|---|---|---|---|
| truehd | 0.7.2, git `harletty/truehdd` @ `5c8b880405946e7ff1aee884cf9988415fe2c3a9` | Apache-2.0 | Rainbaby (truehdd) | `licenses/truehd-0.7.2/LICENSE` |
| oamd | 0.1.0 | Apache-2.0 | Rainbaby | `licenses/oamd-0.1.0/LICENSE` |
| anyhow | 1.0.104 | MIT (of MIT OR Apache-2.0) | David Tolnay | `licenses/anyhow-1.0.104/LICENSE-MIT` |
| bitstream-io | 4.10.0 | MIT (of MIT/Apache-2.0) | Brian Langenberger | `licenses/bitstream-io-4.10.0/LICENSE-MIT` |
| log | 0.4.34 | MIT (of MIT OR Apache-2.0) | The Rust Project Developers | `licenses/log-0.4.34/LICENSE-MIT` |
| memchr | 2.8.3 | MIT (of Unlicense OR MIT) | Andrew Gallant | `licenses/memchr-2.8.3/LICENSE-MIT` |
| no_std_io2 | 0.9.4 | MIT (of Apache-2.0 OR MIT) | Brendan Molloy | `licenses/no_std_io2-0.9.4/LICENSE-MIT` |
| thiserror | 2.0.21 | MIT (of MIT OR Apache-2.0) | David Tolnay | `licenses/thiserror-2.0.21/LICENSE-MIT` |

The library also contains the **Rust standard library** (MIT OR Apache-2.0); the build copies its
notices from the toolchain that built it into `licenses/rust-std-<version>-COPYRIGHT.html`.

## Not included

No DTS decoder (`dca`, `harletty-bridge`) is a dependency, and no Dolby-encoded asset ships with
PrismCore. The truehd crate's test streams are not redistributed; `tests/vectors.rs` reads them
from Cargo's checkout when `TRUEHD_OBJECTS_VECTORS` points there.

## Status

The truehd crate describes itself as a research implementation, made without Dolby. This library
is not part of PrismCore's default package; it is built only with the opt-in
`PRISMCORE_OBJECT_AUDIO=1` flag.
