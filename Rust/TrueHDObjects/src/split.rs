// Copyright 2026 PrismCore contributors.
// Licensed under the Apache License, Version 2.0 (see LICENSE-APACHE in this directory).

//! Heights from the bed: every 7.1.4 feed is a share of the stream's own 7.1 presentation.
//!
//! Per STFT bin, each ear-level bed channel is divided between itself and the four heights, in
//! proportion to how much of that bin's energy in that channel comes from objects placed above
//! ear level. The objects are only a guide to *where* the energy is: an object contributes its
//! bin power times its ear-level (floor-projected) gain² into the bed channel, and that part
//! goes up in proportion to the object's point-panned power on each height. No object signal
//! reaches an output, so every output sample is a linear, per-bin, non-negative real gain of
//! bed samples: floor share + height shares = 1 per bed channel and bin (energy preserving),
//! after each bed channel has been brought to the level the objects predict for it (within
//! ±3 dB, over seconds; see `LEVEL_SMOOTHING`).
//! A bin no object explains stays where it is, so silence, a bed without metadata and a stream
//! whose metadata the session ignores all come out as the plain 7.1.

use crate::render::{CHANNELS, Gains};
use std::collections::VecDeque;

pub const FFT: usize = 2048;
pub const HOP: usize = 512;
/// Output frame i is input frame i − LATENCY inside the splitter; the session hides it (the
/// first LATENCY outputs are dropped and `finish` pushes the tail out), so the 7.1.4 timeline
/// stays sample for sample the input's.
pub const LATENCY: usize = FFT - HOP;
const BINS: usize = FFT / 2 + 1;
/// The floor outputs a 7.1 bed feeds one to one (7.1.4 order; 3 is the LFE, never split).
const FLOOR: [usize; 7] = [0, 1, 2, 4, 5, 6, 7];
const LFE: usize = 3;
const HEIGHTS: [usize; 4] = [8, 9, 10, 11];
/// The split outputs, in `out_spec` order.
const OUTPUTS: [usize; 11] = [0, 1, 2, 4, 5, 6, 7, 8, 9, 10, 11];
/// One-pole smoothing of the per-bin energy estimates from hop to hop (10.7 ms): a time
/// constant of about 25 ms, so a share follows a fly-over without stepping between hops.
const SMOOTHING: f32 = 0.65;
const TINY: f32 = 1e-20;
/// A height bin whose coherent sum keeps less than this fraction of its shares' energy (−20 dB)
/// is cancellation, not content: its shares stay on the floor.
const CANCELLED: f32 = 0.01;
/// The bed's bin power counts against the objects' only beyond this fraction (−3 dB): a single
/// bin's power scatters around the objects' sum even when they explain it all, and comparing
/// at par biased every share low (a synthetic scene went from 0.9 % to 7.8 % on the wrong
/// speaker). Silent objects still hand their bins back within the smoothing.
const UNEXPLAINED: f32 = 0.5;
/// Level matching: the bed's channels are not always at the level the objects put into them (a
/// TrueHD Atmos film measured its four surrounds 1.5 dB under the objects' own floor projection,
/// steady across scenes). Per floor channel, the objects' predicted energy and the bed's own are
/// averaged over about four seconds (one-pole per hop), the channel is scaled by the root of
/// their ratio, held within ±3 dB, and the applied gain follows over about half a second
/// (`LEVEL_FOLLOW`). Without a guide the gain returns to unity. A calibration, not a mix: it never
/// moves energy between channels. (A two-second average measured the same within 0.05 %.)
const LEVEL_SMOOTHING: f32 = 0.997_34;
const LEVEL_FOLLOW: f32 = 0.978_9;
const LEVEL_LIMIT_DB: f32 = 3.;

/// Where one object's energy lies: its ear-level gain² into each 7.1.4 floor output, and the
/// fraction of its point-panned power on each height (sum ≤ 1).
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct Weight {
    pub ear: Gains,
    pub up: [f32; 4],
}

impl Weight {
    /// An object at a TS 103 448 room position, as a point (no size, snap or zones), with a
    /// linear gain.
    pub fn at(position: [f32; 3], gain: f32) -> Self {
        use crate::render::point_gains;
        let [x, y, z] = position.map(|v| v.clamp(0., 1.));
        let mut ear = point_gains([x, y, 0.]);
        ear.iter_mut().for_each(|g| *g = *g * *g * gain * gain);
        let placed = point_gains([x, y, z]);
        let total: f32 = placed.iter().map(|g| g * g).sum();
        let up = if total > 0. { HEIGHTS.map(|c| placed[c] * placed[c] / total) } else { [0.; 4] };
        Self { ear, up }
    }
}

pub struct BedSplitter {
    window: Vec<f32>,
    twiddles: (Vec<(f32, f32)>, Vec<u32>),
    /// The last FFT input frames of every 7.1.4 plane the bed fills, and of every object.
    bed: Vec<Vec<f32>>,
    objects: Vec<Vec<f32>>,
    filled: usize,
    /// Weights in force at each of the last hops: the frame's centre is two hops back.
    weights: VecDeque<Vec<Weight>>,
    current: Vec<Weight>,
    den: Vec<f32>,
    top: Vec<f32>,
    /// Overlap-add accumulators, one per output plane.
    acc: Vec<Vec<f32>>,
    /// Outputs still to drop (the splitter's own delay), and input frames not yet emitted.
    skip: usize,
    pending: usize,
    re: Vec<f32>,
    im: Vec<f32>,
    /// Half spectra: two from one complex FFT (`forward2`), the bed's floor channels, and the
    /// eleven split outputs (floor first, then heights).
    pair: [Vec<f32>; 4],
    bed_spec: Vec<f32>,
    out_spec: Vec<f32>,
    /// Per bed channel, height and bin: this hop's share; and the bed's smoothed bin power.
    share: Vec<f32>,
    bed_power: Vec<f32>,
    power: Vec<f32>,
    /// Level matching per floor channel: averaged predicted and bed energy, applied gain.
    predicted: [f32; 7],
    bed_energy: [f32; 7],
    level: [f32; 7],
}

impl Default for BedSplitter {
    fn default() -> Self {
        let window = (0..FFT).map(|i| 0.5 - 0.5 * (2. * std::f32::consts::PI * i as f32 / FFT as f32).cos()).collect();
        let twiddles = twiddles();
        Self {
            window,
            twiddles,
            bed: vec![vec![0.; FFT]; CHANNELS],
            objects: Vec::new(),
            filled: 0,
            weights: VecDeque::new(),
            current: Vec::new(),
            den: vec![0.; FLOOR.len() * BINS],
            top: vec![0.; FLOOR.len() * HEIGHTS.len() * BINS],
            acc: vec![vec![0.; FFT]; CHANNELS],
            skip: LATENCY,
            pending: 0,
            re: vec![0.; FFT],
            im: vec![0.; FFT],
            pair: std::array::from_fn(|_| vec![0.; BINS]),
            bed_spec: vec![0.; 2 * FLOOR.len() * BINS],
            out_spec: vec![0.; 2 * OUTPUTS.len() * BINS],
            share: vec![0.; FLOOR.len() * HEIGHTS.len() * BINS],
            bed_power: vec![0.; FLOOR.len() * BINS],
            power: vec![0.; BINS],
            predicted: [0.; 7],
            bed_energy: [0.; 7],
            level: [1.; 7],
        }
    }
}

impl BedSplitter {
    /// The objects' weights from now on, one per object channel (empty: no guide, plain 7.1).
    pub fn set_weights(&mut self, weights: Vec<Weight>) {
        self.current = weights;
    }

    /// Takes `frames` of the bed routed into interleaved 7.1.4 (heights normally silent) and
    /// the object channels (planar; empty or shorter is silence), appends finished interleaved
    /// 7.1.4 frames to `out`.
    pub fn push(&mut self, bed: &[f32], objects: &[Vec<f32>], frames: usize, out: &mut Vec<f32>) {
        if self.objects.len() != objects.len() && !objects.is_empty() {
            self.objects = vec![vec![0.; FFT]; objects.len()];
        }
        let mut taken = 0;
        while taken < frames {
            let take = (HOP - self.filled).min(frames - taken);
            let at = FFT - HOP + self.filled;
            for c in 0..CHANNELS {
                for i in 0..take {
                    self.bed[c][at + i] = bed[(taken + i) * CHANNELS + c];
                }
            }
            for (k, history) in self.objects.iter_mut().enumerate() {
                let source = objects.get(k);
                for i in 0..take {
                    history[at + i] = source.and_then(|s| s.get(taken + i)).copied().unwrap_or(0.);
                }
            }
            self.filled += take;
            taken += take;
            self.pending += take;
            if self.filled == HOP {
                self.filled = 0;
                self.hop(out);
            }
        }
    }

    /// Pushes silence until every input frame has come out.
    pub fn finish(&mut self, out: &mut Vec<f32>) {
        let owed = self.pending * CHANNELS;
        let start = out.len();
        let silence = vec![0.; HOP * CHANNELS];
        while out.len() - start < owed {
            self.push(&silence, &[], HOP, out);
        }
        out.truncate(start + owed);
    }

    fn hop(&mut self, out: &mut Vec<f32>) {
        self.weights.push_back(self.current.clone());
        if self.weights.len() > 3 {
            self.weights.pop_front();
        }
        self.split();
        // The oldest hop of every accumulator is complete.
        for i in 0..HOP {
            if self.skip > 0 {
                self.skip -= 1;
                continue;
            }
            for c in 0..CHANNELS {
                out.push(self.acc[c][i]);
            }
            self.pending -= 1;
        }
        for c in 0..CHANNELS {
            self.acc[c].copy_within(HOP.., 0);
            self.acc[c][FFT - HOP..].fill(0.);
        }
        for plane in self.bed.iter_mut().chain(self.objects.iter_mut()) {
            plane.copy_within(HOP.., 0);
        }
    }

    fn split(&mut self) {
        let weights = self.weights.front().cloned().unwrap_or_default();
        let heights = HEIGHTS.len();
        // This frame's estimate, folded into the smoothed one.
        for v in self.den.iter_mut().chain(self.top.iter_mut()) {
            *v *= SMOOTHING;
        }
        let guided = !weights.is_empty() && weights.len() == self.objects.len();
        let mut predicted = [0f32; 7];
        if guided {
            let placed: Vec<usize> = (0..weights.len()).filter(|&k| FLOOR.iter().any(|&c| weights[k].ear[c] > 0.)).collect();
            for two in placed.chunks(2) {
                let objects = std::mem::take(&mut self.objects);
                self.forward2(&objects[two[0]], two.get(1).map(|&k| objects[k].as_slice()));
                self.objects = objects;
                for (slot, &k) in two.iter().enumerate() {
                    let w = weights[k];
                    let (re, im) = (&self.pair[2 * slot], &self.pair[2 * slot + 1]);
                    let mut total = 0.;
                    for ((p, re), im) in self.power.iter_mut().zip(re).zip(im) {
                        *p = re * re + im * im;
                        total += *p;
                    }
                    for (j, &c) in FLOOR.iter().enumerate() {
                        predicted[j] += w.ear[c] * total;
                        let a = w.ear[c] * (1. - SMOOTHING);
                        if a == 0. {
                            continue;
                        }
                        for (d, p) in self.den[j * BINS..(j + 1) * BINS].iter_mut().zip(&self.power) {
                            *d += p * a;
                        }
                        for t in 0..heights {
                            let u = a * w.up[t];
                            if u == 0. {
                                continue;
                            }
                            let row = (j * heights + t) * BINS;
                            for (d, p) in self.top[row..row + BINS].iter_mut().zip(&self.power) {
                                *d += p * u;
                            }
                        }
                    }
                }
            }
        }
        for j in (0..FLOOR.len()).step_by(2) {
            let bed = std::mem::take(&mut self.bed);
            self.forward2(&bed[FLOOR[j]], FLOOR.get(j + 1).map(|&c| bed[c].as_slice()));
            self.bed = bed;
            for slot in 0..2.min(FLOOR.len() - j) {
                let at = 2 * (j + slot) * BINS;
                self.bed_spec[at..at + BINS].copy_from_slice(&self.pair[2 * slot]);
                self.bed_spec[at + BINS..at + 2 * BINS].copy_from_slice(&self.pair[2 * slot + 1]);
            }
        }
        self.match_levels(guided, predicted);
        // Shares per bed channel, height and bin. The denominator is the larger of what the
        // objects explain and (half) what the bed itself carries, both smoothed alike: energy no
        // object accounts for stays on the floor, so when the objects fall silent their shares
        // fade with the smoothing instead of holding while both sides decay together.
        let floors = FLOOR.len();
        for j in 0..floors {
            let x = 2 * j * BINS;
            for b in 0..BINS {
                let (xr, xi) = (self.bed_spec[x + b], self.bed_spec[x + BINS + b]);
                let power = &mut self.bed_power[j * BINS + b];
                *power = SMOOTHING * *power + (1. - SMOOTHING) * (xr * xr + xi * xi);
                let den = self.den[j * BINS + b].max(*power * UNEXPLAINED);
                for t in 0..heights {
                    let at = (j * heights + t) * BINS + b;
                    self.share[at] = if den > TINY { (self.top[at] / den).clamp(0., 1.) } else { 0. };
                }
            }
        }
        // Each height sums the shares sent to it coherently, then each bin is set to the energy
        // of its shares (energy preserving where the channels correlate). Where they cancel —
        // anti-phase content in two channels feeding one height — no gain could restore that
        // energy, so those shares stay on their floor channels instead.
        self.out_spec.fill(0.);
        for t in 0..heights {
            let o = 2 * (floors + t) * BINS;
            for b in 0..BINS {
                let (mut r, mut i, mut energy) = (0f32, 0f32, 0f32);
                for j in 0..floors {
                    let share = self.share[(j * heights + t) * BINS + b];
                    if share > 0. {
                        let x = 2 * j * BINS;
                        let (xr, xi) = (self.bed_spec[x + b], self.bed_spec[x + BINS + b]);
                        let g = share.sqrt();
                        r += g * xr;
                        i += g * xi;
                        energy += share * (xr * xr + xi * xi);
                    }
                }
                let got = r * r + i * i;
                if energy <= TINY {
                    continue;
                }
                if got < CANCELLED * energy {
                    for j in 0..floors {
                        self.share[(j * heights + t) * BINS + b] = 0.;
                    }
                    continue;
                }
                let fix = (energy / got).sqrt();
                self.out_spec[o + b] = r * fix;
                self.out_spec[o + BINS + b] = i * fix;
            }
        }
        // Each floor output is its own bed channel less what went up.
        for j in 0..floors {
            let x = 2 * j * BINS;
            for b in 0..BINS {
                let up: f32 = (0..heights).map(|t| self.share[(j * heights + t) * BINS + b]).sum();
                let g = (1. - up).max(0.).sqrt();
                self.out_spec[x + b] = g * self.bed_spec[x + b];
                self.out_spec[x + BINS + b] = g * self.bed_spec[x + BINS + b];
            }
        }
        for n in (0..OUTPUTS.len()).step_by(2) {
            self.inverse2(n, n + 1);
        }
        // Unsplit planes (the LFE, and the bed's own heights, silent on a 7.1 bed) pass through:
        // the hop about to leave is the oldest of the frame.
        for c in [LFE, 8, 9, 10, 11] {
            let (acc, bed) = (&mut self.acc[c], &self.bed[c]);
            for i in 0..HOP {
                acc[i] += bed[i];
            }
        }
    }

    /// Scales each floor channel's spectrum towards the level the objects predict for it.
    fn match_levels(&mut self, guided: bool, predicted: [f32; 7]) {
        let (a, limit) = (LEVEL_SMOOTHING, 10f32.powf(LEVEL_LIMIT_DB / 20.));
        for j in 0..FLOOR.len() {
            let spec = &mut self.bed_spec[2 * j * BINS..2 * (j + 1) * BINS];
            let mut target = 1.;
            if guided {
                let bed: f32 = spec.iter().map(|v| v * v).sum();
                self.predicted[j] = a * self.predicted[j] + (1. - a) * predicted[j];
                self.bed_energy[j] = a * self.bed_energy[j] + (1. - a) * bed;
                // A channel neither side has measurably filled keeps its gain where it is.
                target = if self.predicted[j] > 1e-6 && self.bed_energy[j] > 1e-6 {
                    (self.predicted[j] / self.bed_energy[j]).sqrt().clamp(1. / limit, limit)
                } else {
                    self.level[j]
                };
            }
            self.level[j] = LEVEL_FOLLOW * self.level[j] + (1. - LEVEL_FOLLOW) * target;
            let g = self.level[j];
            if g != 1. {
                spec.iter_mut().for_each(|v| *v *= g);
            }
        }
    }

    /// Windowed FFTs of two real frames with one complex FFT, into `pair` (re, im, re, im).
    fn forward2(&mut self, x: &[f32], y: Option<&[f32]>) {
        for i in 0..FFT {
            self.re[i] = x[i] * self.window[i];
            self.im[i] = y.map_or(0., |y| y[i] * self.window[i]);
        }
        fft(&mut self.re, &mut self.im, &self.twiddles);
        let [xr, xi, yr, yi] = &mut self.pair;
        for k in 0..BINS {
            let m = (FFT - k) % FFT;
            let (zr, zi, cr, ci) = (self.re[k], self.im[k], self.re[m], -self.im[m]);
            xr[k] = 0.5 * (zr + cr);
            xi[k] = 0.5 * (zi + ci);
            yr[k] = 0.5 * (zi - ci);
            yi[k] = -0.5 * (zr - cr);
        }
    }

    /// Inverts outputs `a` and `b` (indices into `OUTPUTS`; `b` may be past the end) with one
    /// complex FFT, windows them again and overlap-adds them into their planes.
    fn inverse2(&mut self, a: usize, b: usize) {
        let spec = |n: usize, k: usize| -> (f32, f32) {
            if n >= OUTPUTS.len() {
                return (0., 0.);
            }
            let o = 2 * n * BINS;
            (self.out_spec[o + k], self.out_spec[o + BINS + k])
        };
        for k in 0..FFT {
            // Hermitian extension of both half spectra; Z = A + iB, conjugated for the inverse.
            let (m, sign) = if k < BINS { (k, 1.) } else { (FFT - k, -1.) };
            let (ar, ai) = spec(a, m);
            let (br, bi) = spec(b, m);
            let (ai, bi) = (ai * sign, bi * sign);
            self.re[k] = ar - bi;
            self.im[k] = -(ai + br);
        }
        fft(&mut self.re, &mut self.im, &self.twiddles);
        // Hann² at a quarter-frame hop sums to 1.5.
        let scale = 1. / (FFT as f32 * 1.5);
        for n in 0..FFT {
            let w = self.window[n] * scale;
            self.acc[OUTPUTS[a]][n] += self.re[n] * w;
            if b < OUTPUTS.len() {
                self.acc[OUTPUTS[b]][n] -= self.im[n] * w;
            }
        }
    }
}

/// Twiddles for `fft`, stage after stage (1, 2, 4, … FFT/2 of them), and the bit reversal.
fn twiddles() -> (Vec<(f32, f32)>, Vec<u32>) {
    let mut table = Vec::with_capacity(FFT);
    let mut half = 1;
    while half < FFT {
        for k in 0..half {
            let a = -std::f64::consts::PI * k as f64 / half as f64;
            table.push((a.cos() as f32, a.sin() as f32));
        }
        half *= 2;
    }
    let bits = FFT.trailing_zeros();
    let reverse = (0..FFT as u32).map(|i| i.reverse_bits() >> (32 - bits)).collect();
    (table, reverse)
}

/// In-place iterative radix-2 complex FFT of FFT points (forward, unnormalised).
fn fft(re: &mut [f32], im: &mut [f32], (table, reverse): &(Vec<(f32, f32)>, Vec<u32>)) {
    for (i, &j) in reverse.iter().enumerate() {
        let j = j as usize;
        if i < j {
            re.swap(i, j);
            im.swap(i, j);
        }
    }
    let (mut half, mut offset) = (1, 0);
    while half < re.len() {
        let stage = &table[offset..offset + half];
        for (r, i) in re.chunks_exact_mut(2 * half).zip(im.chunks_exact_mut(2 * half)) {
            let (ar, br) = r.split_at_mut(half);
            let (ai, bi) = i.split_at_mut(half);
            for ((((ar, ai), br), bi), &(wr, wi)) in ar.iter_mut().zip(ai.iter_mut()).zip(br.iter_mut()).zip(bi.iter_mut()).zip(stage) {
                let (xr, xi) = (*br * wr - *bi * wi, *br * wi + *bi * wr);
                *br = *ar - xr;
                *bi = *ai - xi;
                *ar += xr;
                *ai += xi;
            }
        }
        offset += half;
        half *= 2;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn noise(frames: usize, seed: u32) -> Vec<f32> {
        let mut s = seed;
        (0..frames)
            .map(|_| {
                s = s.wrapping_mul(1_664_525).wrapping_add(1_013_904_223);
                (s >> 8) as f32 / (1 << 24) as f32 - 0.5
            })
            .collect()
    }

    /// Runs `bed` (one plane per 7.1.4 output, planar) and `objects` through a splitter in
    /// uneven chunks and returns the planar output, as long as the input.
    fn run(bed: &[Vec<f32>], objects: &[Vec<f32>], weights: Vec<Weight>) -> Vec<Vec<f32>> {
        let frames = bed[0].len();
        let mut s = BedSplitter::default();
        s.set_weights(weights);
        let mut out = Vec::new();
        let mut at = 0;
        for chunk in [40, 1000, 7, 4096].iter().cycle() {
            if at >= frames {
                break;
            }
            let n = (*chunk).min(frames - at);
            let inter: Vec<f32> = (at..at + n).flat_map(|i| (0..CHANNELS).map(move |c| bed[c][i])).collect();
            let objs: Vec<Vec<f32>> = objects.iter().map(|o| o[at..at + n].to_vec()).collect();
            s.push(&inter, &objs, n, &mut out);
            at += n;
        }
        s.finish(&mut out);
        assert_eq!(out.len(), frames * CHANNELS, "output keeps the input's length");
        (0..CHANNELS).map(|c| out.iter().skip(c).step_by(CHANNELS).copied().collect()).collect()
    }

    fn energy(x: &[f32]) -> f64 {
        x.iter().map(|v| f64::from(*v).powi(2)).sum()
    }

    fn bed_with(channel: usize, signal: &[f32]) -> Vec<Vec<f32>> {
        let mut bed = vec![vec![0.; signal.len()]; CHANNELS];
        bed[channel] = signal.to_vec();
        bed
    }

    #[test]
    fn fft_round_trip_is_identity_without_a_guide() {
        // No weights: every output is its own bed channel, sample for sample, delay hidden.
        let frames = 48_000;
        let bed: Vec<Vec<f32>> = (0..CHANNELS).map(|c| if c < 8 { noise(frames, c as u32 + 1) } else { vec![0.; frames] }).collect();
        let out = run(&bed, &[], Vec::new());
        for c in 0..CHANNELS {
            // The first and last half-frame lack overlap partners.
            let worst = (FFT..frames - FFT).map(|i| (out[c][i] - bed[c][i]).abs()).fold(0., f32::max);
            assert!(worst < 1e-4, "channel {c}: {worst}");
        }
    }

    #[test]
    fn overhead_object_moves_its_bed_energy_up_and_preserves_it() {
        let frames = 96_000;
        let signal = noise(frames, 7);
        // One object straight above the front-left corner region, the same signal in the bed L.
        let bed = bed_with(0, &signal);
        let w = Weight::at([0., 0., 1.], 1.);
        let out = run(&bed, &[signal.clone()], vec![w]);
        let range = FFT..frames - FFT;
        let input = energy(&signal[range.clone()]);
        let total: f64 = out.iter().map(|p| energy(&p[range.clone()])).sum();
        assert!((total / input - 1.).abs() < 0.01, "energy preserved: {}", total / input);
        let heights: f64 = HEIGHTS.iter().map(|&c| energy(&out[c][range.clone()])).sum();
        assert!(heights / input > 0.95, "an object at the ceiling takes its energy up: {}", heights / input);
        assert!(energy(&out[8][range.clone()]) / heights > 0.95, "to the nearest height (Tfl)");
    }

    #[test]
    fn ear_level_object_and_silence_stay_on_the_floor() {
        let frames = 48_000;
        let signal = noise(frames, 3);
        let bed = bed_with(4, &signal);
        let out = run(&bed, &[signal.clone()], vec![Weight::at([0., 0.5, 0.], 1.)]);
        assert!(HEIGHTS.iter().all(|&c| energy(&out[c]) < 1e-9));
        // A silent object explains nothing: the bed stays put.
        let out = run(&bed, &[vec![0.; frames]], vec![Weight::at([0., 0.5, 1.], 1.)]);
        assert!(HEIGHTS.iter().all(|&c| energy(&out[c]) < 1e-9));
        // Silence in, silence out.
        let out = run(&vec![vec![0.; frames]; CHANNELS], &[signal], vec![Weight::at([0., 0.5, 1.], 1.)]);
        assert!(out.iter().all(|p| energy(p) == 0.));
    }

    #[test]
    fn split_follows_the_objects_energy_per_bin() {
        // Two objects in the bed L at different frequencies: the overhead one's band goes up,
        // the ear-level one's stays.
        let frames = 96_000;
        let tone = |f: f32| (0..frames).map(|i| 0.3 * (2. * std::f32::consts::PI * f * i as f32 / 48_000.).sin()).collect::<Vec<_>>();
        let (low, high) = (tone(200.), tone(5_000.));
        let bed_l: Vec<f32> = low.iter().zip(&high).map(|(a, b)| a + b).collect();
        let bed = bed_with(0, &bed_l);
        let out = run(&bed, &[low.clone(), high.clone()], vec![Weight::at([0., 0., 0.], 1.), Weight::at([0., 0., 1.], 1.)]);
        let range = FFT..frames - FFT;
        let up = energy(&out[8][range.clone()]);
        let floor = energy(&out[0][range.clone()]);
        let e = energy(&high[range.clone()]);
        assert!((up / e - 1.).abs() < 0.05, "the high tone is the height's: {}", up / e);
        assert!((floor / energy(&low[range]) - 1.).abs() < 0.05, "the low tone stays: {}", floor);
    }

    #[test]
    fn weights_of_extreme_elevations() {
        // Below the floor clamps to the floor; above the ceiling to the ceiling.
        assert_eq!(Weight::at([0.5, 0.5, -1.], 1.).up, [0.; 4]);
        let w = Weight::at([0.5, 0.5, 7.], 1.);
        assert!((w.up.iter().sum::<f32>() - 1.).abs() < 1e-5);
        // A muted object weighs nothing.
        assert!(Weight::at([0., 0., 1.], 0.).ear.iter().all(|g| *g == 0.));
        // Non-finite positions are the caller's to refuse; clamping keeps them out of NaN here.
        assert!(Weight::at([0.25, 0.25, 0.5], 1.).up.iter().all(|u| u.is_finite() && *u >= 0.));
    }

    #[test]
    fn levels_match_the_objects_within_three_decibels() {
        // The bed's surround 1.5 dB (and then 6 dB) under the object it carries: after a few
        // seconds the output plays at the object's level, the second clamped at +3 dB.
        let frames = 48_000 * 12;
        let signal = noise(frames, 11);
        let tail = frames - 48_000 * 3..frames - FFT;
        for (offset, expected) in [(-1.5f32, 0.), (-6., -3.)] {
            let g = 10f32.powf(offset / 20.);
            let bed = bed_with(4, &signal.iter().map(|x| x * g).collect::<Vec<_>>());
            let out = run(&bed, &[signal.clone()], vec![Weight::at([0., 0.5, 0.], 1.)]);
            let db = 10. * (energy(&out[4][tail.clone()]) / energy(&signal[tail.clone()])).log10();
            assert!((db - expected).abs() < 0.2, "{offset} dB bed: {db:.2} dB out");
        }
    }

    #[test]
    fn anti_phase_channels_keep_their_energy() {
        // The same signal in L and, inverted, in R, each explained by an object that sends half
        // up to each front height: the two would cancel in both heights, so their shares stay on
        // the floor and nothing is lost.
        let frames = 48_000 * 2;
        let signal = noise(frames, 5);
        let inverted: Vec<f32> = signal.iter().map(|x| -x).collect();
        let mut bed = vec![vec![0.; frames]; CHANNELS];
        bed[0] = signal.clone();
        bed[1] = inverted.clone();
        let up = [0.5, 0.5, 0., 0.];
        let weights = vec![
            Weight { ear: Weight::at([0., 0., 0.], 1.).ear, up },
            Weight { ear: Weight::at([1., 0., 0.], 1.).ear, up },
        ];
        let out = run(&bed, &[signal, inverted], weights);
        let range = FFT..frames - FFT;
        let input = energy(&bed[0][range.clone()]) + energy(&bed[1][range.clone()]);
        let total: f64 = out.iter().map(|p| energy(&p[range.clone()])).sum();
        assert!((total / input - 1.).abs() < 0.02, "energy kept: {}", total / input);
        let heights: f64 = HEIGHTS.iter().map(|&c| energy(&out[c][range.clone()])).sum();
        assert!(heights / input < 0.01, "nothing went up to cancel: {}", heights / input);
    }

    #[test]
    fn heights_return_to_the_floor_when_the_object_falls_silent() {
        // One second of an overhead object in the bed's L, then the object goes silent while
        // the bed carries on: within 0.1 s the heights are empty again.
        let frames = 48_000 * 2;
        let signal = noise(frames, 9);
        let object: Vec<f32> = signal.iter().enumerate().map(|(n, x)| if n < 48_000 { *x } else { 0. }).collect();
        let out = run(&bed_with(0, &signal), &[object], vec![Weight::at([0., 0., 1.], 1.)]);
        let before = energy(&out[8][24_000..48_000]) / energy(&signal[24_000..48_000]);
        let after = energy(&out[8][48_000 + 4_800..frames - FFT]) / energy(&signal[48_000 + 4_800..frames - FFT]);
        assert!(before > 0.9, "up while it plays: {before}");
        assert!(after < 0.01, "back on the floor 0.1 s after: {after}");
    }

    /// A synthetic scene measured against the exact point render: eight objects of
    /// overlapping coloured noise (static ones at ear level and overhead, a fly-over front to
    /// back, one circling half way up), their 7.1 fold made by panning each object's
    /// floor projection (an assumption about how the stream's own bed was made), and the split
    /// of that fold compared, per 0.25 s window, with each object point-panned in 3D.
    /// `cargo test --release scene -- --nocapture` prints the numbers.
    #[test]
    fn scene_against_the_exact_render() {
        use crate::render::point_gains;
        let frames = 48_000 * 8;
        let objects = 8;
        // Coloured noise: white through a one-pole low pass and a one-pole high pass, so the
        // objects share most of the spectrum with different tilts.
        let signals: Vec<Vec<f32>> = (0..objects)
            .map(|k| {
                let white = noise(frames, 100 + k as u32);
                let (lp, hp) = (0.02 + 0.12 * k as f32, 0.9 - 0.1 * k as f32);
                let (mut a, mut prev, mut b) = (0f32, 0f32, 0f32);
                white
                    .iter()
                    .enumerate()
                    .map(|(n, x)| {
                        a += lp * (x - a);
                        b = hp * (b + a - prev);
                        prev = a;
                        // Slow, different amplitude envelopes.
                        b * (0.6 + 0.4 * (n as f32 / 48_000. * (0.3 + 0.17 * k as f32)).sin())
                    })
                    .collect()
            })
            .collect();
        let position = |k: usize, n: usize| -> [f32; 3] {
            let t = n as f32 / frames as f32;
            match k {
                0 => [0., 0., 0.],
                1 => [1., 0., 0.],
                2 => [0.5, 0., 0.],
                3 => [0., 0.6, 0.],
                4 => [0.3, 0.2, 1.],
                5 => [0.5, t, 1.],
                6 => {
                    let a = t * 4. * std::f32::consts::PI;
                    [0.5 + 0.5 * a.cos(), 0.5 + 0.5 * a.sin(), 0.5]
                }
                _ => [1., 1., 0.],
            }
        };
        let block = 40;
        let mut bed = vec![vec![0f32; frames]; CHANNELS];
        let mut exact = vec![vec![0f32; frames]; CHANNELS];
        let mut splitter = BedSplitter::default();
        let mut out = Vec::new();
        for start in (0..frames).step_by(block) {
            let end = (start + block).min(frames);
            let mut weights = Vec::new();
            for k in 0..objects {
                let p = position(k, start);
                let floor = point_gains([p[0], p[1], 0.]);
                let placed = point_gains(p);
                for n in start..end {
                    for c in 0..CHANNELS {
                        bed[c][n] += floor[c] * signals[k][n];
                        exact[c][n] += placed[c] * signals[k][n];
                    }
                }
                weights.push(Weight::at(p, 1.));
            }
            splitter.set_weights(weights);
            let inter: Vec<f32> = (start..end).flat_map(|n| (0..CHANNELS).map(move |c| (c, n))).map(|(c, n)| bed[c][n]).collect();
            let objs: Vec<Vec<f32>> = signals.iter().map(|s| s[start..end].to_vec()).collect();
            splitter.push(&inter, &objs, end - start, &mut out);
        }
        splitter.finish(&mut out);
        let split: Vec<Vec<f32>> = (0..CHANNELS).map(|c| out.iter().skip(c).step_by(CHANNELS).copied().collect()).collect();
        let window = 12_000;
        let mut moved = Vec::new();
        let mut height_db = Vec::new();
        for w in 1..frames / window - 1 {
            let r = w * window..(w + 1) * window;
            let e: Vec<f64> = (0..CHANNELS).map(|c| energy(&exact[c][r.clone()])).collect();
            let s: Vec<f64> = (0..CHANNELS).map(|c| energy(&split[c][r.clone()])).collect();
            let (te, ts) = (e.iter().sum::<f64>(), s.iter().sum::<f64>());
            moved.push(0.5 * (0..CHANNELS).map(|c| (e[c] / te - s[c] / ts).abs()).sum::<f64>() * 100.);
            height_db.push(10. * (s[8..].iter().sum::<f64>() / e[8..].iter().sum::<f64>()).log10());
        }
        moved.sort_by(f64::total_cmp);
        height_db.sort_by(f64::total_cmp);
        let names = ["L", "R", "C", "LFE", "Ls", "Rs", "Lb", "Rb", "Tfl", "Tfr", "Tbl", "Tbr"];
        let (e, s): (Vec<f64>, Vec<f64>) = (0..CHANNELS).map(|c| (energy(&exact[c]), energy(&split[c]))).unzip();
        let (te, ts) = (e.iter().sum::<f64>(), s.iter().sum::<f64>());
        println!("scene: channel exact % / split % / diff dB");
        for c in 0..CHANNELS {
            if c != LFE {
                println!("  {:>4} {:>7.2} {:>7.2} {:>+6.2}", names[c], e[c] / te * 100., s[c] / ts * 100., 10. * (s[c] / e[c]).log10());
            }
        }
        println!(
            "scene: energy on another speaker per 0.25 s window: median {:.2} %, 90th {:.2} %, max {:.2} %; heights vs exact median {:+.2} dB (min {:+.2}, max {:+.2}); total split/exact {:+.3} dB",
            moved[moved.len() / 2],
            moved[moved.len() * 9 / 10],
            moved[moved.len() - 1],
            height_db[height_db.len() / 2],
            height_db[0],
            height_db[height_db.len() - 1],
            10. * (ts / te).log10()
        );
        // Loose guards: the split must land most energy where the exact render does.
        assert!(moved[moved.len() / 2] < 10.);
        assert!(height_db[height_db.len() / 2].abs() < 3.);
    }
}
