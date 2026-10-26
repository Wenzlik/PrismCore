# Object audio: the heights split against the exact object render

`.heights` (TrueHD Atmos → APAC 7.1.4) ships the **split**: every 7.1.4 feed is a
per-STFT-bin share of the stream's own 7.1 presentation, guided by where the
objects are (`Rust/TrueHDObjects/src/split.rs`). The **exact render** places the
decoded objects themselves with the ETSI TS 103 448 room-coordinate panner
(size, snap, zones, trims, ramps; `src/render.rs`, Cargo feature
`exact-render`). This page is the reproducible comparison of the two.

## Running it

```sh
Rust/TrueHDObjects/scripts/measure-heights.sh                  # synthetic scenes (+ public vectors if fetched)
Rust/TrueHDObjects/scripts/measure-heights.sh film.thd …       # plus real TrueHD Atmos
ffmpeg -i film.mkv -map 0:a:0 -c copy -f truehd film.thd       # raw TrueHD from a Matroska
```

The script runs `cargo test --release --locked --features exact-render --test
measure -- --nocapture` (`Rust/TrueHDObjects/tests/measure.rs`) and prints
Markdown tables. Real streams are never committed; the synthetic scenes are
generated in the test.

## What is measured

Both renders keep the stream's timeline sample for sample, so they are
compared directly (the first and last 2048 frames are left out: the split's
overlap-add has no partner there).

- **Per-speaker energy**: each feed's share of the total, and split − exact in dB.
- **Height level**: the four tops together, split − exact in dB, over the
  whole run and per 0.25 s window (windows where the exact render has > 1 % of
  its energy in the tops).
- **Correlation**: normalised cross-correlation at lag 0 of each feed, of the
  four tops together, and of all twelve feeds together. 1.0 is the same
  waveform; energy can agree while correlation does not (the split moves bed
  signal, which can carry other objects in the same bin).
- **Front-versus-rear separation**: (Tfl + Tfr) against (Tbl + Tbr) in dB for
  each render, and the absolute difference, per window, of the front share
  of the heights — its mean and its worst window (0 = the split puts the
  same fraction of the height energy in front as the exact render; 1 =
  everything on the wrong side).
- **Energy on another speaker**: half the L1 distance of the two per-window
  energy distributions (the 3.8.0 metric).
- **CPU** (real streams): thread CPU time per second of audio, TrueHD decode
  included, APAC encode excluded.

### Synthetic scenes

Coloured-noise objects with known TS 103 448 positions, 8 s each, metadata
every 40 samples. Every scene has a floor (dialogue in C, music in L and R,
ambience in both side surrounds) plus its height objects. The exact render
pans each object in 3D; the **7.1 bed is the same renderer with elevation off**
(each object's floor projection) — an assumption about how a stream's own 7.1
is made, which is the split's best case; the split is that bed, guided by the
same positions.

| scene | height objects |
|---|---|
| front heights | (0.2, 0.1, 1), (0.8, 0.15, 0.8) |
| rear heights | (0.2, 0.9, 1), (0.8, 0.85, 0.8) |
| mixed | (0.2, 0.1, 1), (0.8, 0.9, 1), (0.5, 0.5, 1) |
| front/rear pair over one side | (0, 0.35, 1), (0, 0.65, 1): both project onto Ls |
| moving | a fly-over front → back at the ceiling, a circle at half height |

The test asserts loose guards (heights within 1.5 dB, height correlation
above 0.7, front share within 5 % in every window, front/rear never swapped), so a
regression in the shipped split fails `cargo test --features exact-render`.

## Results (2026-10-26, Apple M2, macOS 27.0.1, rustc 1.99.0, release build)

### Synthetic scenes

| scene | heights split − exact dB (whole / window median) | corr. heights | corr. all 12 | front − rear tops, exact / split dB | front-share error (mean / worst window) | energy on another speaker (median) |
|---|---:|---:|---:|---:|---:|---:|
| front heights | −0.09 / −0.11 | 0.902 | 0.923 | > +60 / > +60 | 0.000 / 0.000 | 0.67 % |
| rear heights | −0.07 / −0.07 | 0.875 | 0.929 | < −60 / < −60 | 0.000 / 0.000 | 0.46 % |
| mixed front + rear + overhead | −0.11 / −0.13 | 0.918 | 0.902 | +0.33 / +0.33 | 0.002 / 0.007 | 0.81 % |
| front/rear pair over one side | −0.06 / −0.08 | 0.893 | 0.904 | +0.38 / +0.33 | 0.004 / 0.012 | 0.63 % |
| moving: fly-over + circle | −0.09 / −0.11 | 0.937 | 0.948 | −0.96 / −1.07 | 0.005 / 0.020 | 0.76 % |

### Real TrueHD Atmos (two film scenes, not redistributable)

| clip | heights split − exact dB (whole / window median, p10…p90) | corr. heights | corr. all 12 | front − rear tops, exact / split dB | front-share error (mean / worst window) | energy on another speaker (median / p90) | CPU exact / split |
|---|---:|---:|---:|---:|---:|---:|---:|
| action, 180 s (538 of 720 windows with heights) | −0.06 / −0.02 (−0.34…+0.24) | 0.991 | 0.999 | −11.59 / −12.25 | 0.001 / 0.151 | 1.02 % / 2.44 % | 18.5 / 63.4 ms per s |
| ambience, 120 s (147 of 480) | −0.09 / −0.06 (−0.38…+0.13) | 0.993 | 1.000 | rear only / rear only | 0.000 / 0.000 | 0.96 % / 1.78 % | 21.3 / 50.3 ms per s |

Per feed on the action scene: the floor within 0.3 dB (the side and back
surrounds 0.28 dB under, the level matching's ±3 dB clamp is not reached),
front tops −0.66/−0.69 dB at correlation 0.91, back tops −0.02/−0.01 dB at
0.996. The truehd crate's public vectors are too short (0.3 s) or carry no
height energy, so they only check the plumbing.

## Reading it

- **Levels and placement agree.** Over each run the split's heights sit
  within 0.11 dB of the exact render (per-window medians within 0.13 dB;
  single film windows spread from about −0.4 to +0.25 dB), front and rear
  tops keep their balance (a rear-only scene stays rear-only, a fly-over's
  front share is off by 0.5 % on average and 2 % in its worst window; one
  window of the action scene is 15 % off), and about 1 % of the energy lands
  on another speaker.
- **The waveforms do not, entirely.** On synthetic scenes the height feeds
  correlate 0.875–0.937 with the exact render: where a floor object and a
  height object share a bed channel and a frequency bin, the split can only
  move both up or neither. On the two film scenes the correlation is
  0.99, because their height content rarely shares a bin with the floor.
- **The exact render is cheaper.** It is a gain matrix on the decoded
  objects; the split decodes the 7.1 as well and runs 10 + ⌈objects / 2⌉
  complex 2048-point FFTs per 512-frame hop (18 for 16 objects): about
  2.5–3.5× the CPU (18–21 against 50–63 ms per second of audio).
- **What only the split has.** It keeps the stream's own 7.1 mix (its floor
  is the disc's bed, level-matched) and takes object metadata the exact
  render refuses (bed channel distribution, bed downmix metadata, objects
  with a distance, reserved zones or warp), for which the exact render falls
  back to the bed with silent heights.
