// Copyright 2026 PrismCore contributors.
// The design (one linked gain, a 2 ms linear approach that meets a peak exactly, a 100 ms
// release, a −0.1 dBFS ceiling) follows SpatialAudioBridge's limiter (Rust/SpatialAudioCore/
// src/limit.rs at 0c63341, Apache License 2.0); this implementation is PrismCore's own.
//
// Licensed under the Apache License, Version 2.0 (see LICENSE-APACHE in this directory).

//! A lookahead peak limiter for the rendered speaker feeds.
//!
//! Objects panned into one speaker add up, so a render can exceed full scale where the mix's
//! own speaker feeds never did. APAC keeps samples above full scale, but the integer PCM on the
//! way to HDMI cannot, so the feeds are held at the ceiling before encoding. One gain applies
//! to every channel, so no object moves; audio without a peak in reach passes bit for bit.

use std::collections::VecDeque;

/// −0.1 dBFS.
const CEILING: f32 = 0.988_553;
/// Frames over which the gain falls to meet a peak: 2 ms at 48 kHz.
pub const LOOKAHEAD: usize = 96;
/// Release time constant: 100 ms at 48 kHz.
const RELEASE_FRAMES: f32 = 4_800.;
/// A reduction below this snaps back to exactly unity, so quiet audio passes unchanged.
const RECOVERED: f32 = 1e-6;

pub struct Limiter {
    channels: usize,
    /// Frames waiting for their gain, interleaved, oldest first.
    pending: VecDeque<f32>,
    /// The gain each pending frame needs on its own (`CEILING / peak`, at most 1).
    needed: VecDeque<f32>,
    /// One minus the gain of the last released frame.
    reduction: f32,
    release: f32,
}

impl Limiter {
    pub fn new(channels: usize) -> Self {
        Self {
            channels,
            pending: VecDeque::with_capacity((LOOKAHEAD + 1) * channels),
            needed: VecDeque::with_capacity(LOOKAHEAD + 1),
            reduction: 0.,
            release: (-1. / RELEASE_FRAMES).exp(),
        }
    }

    /// Takes interleaved frames and appends to `out` those whose gain is now settled. Output
    /// trails input by `LOOKAHEAD` frames until `finish`; no frame is added or dropped.
    pub fn push(&mut self, input: &[f32], out: &mut Vec<f32>) {
        for frame in input.chunks_exact(self.channels) {
            let peak = frame.iter().fold(0f32, |p, x| p.max(x.abs()));
            self.pending.extend(frame);
            self.needed.push_back(if peak > CEILING { CEILING / peak } else { 1. });
            if self.needed.len() > LOOKAHEAD {
                self.release_one(out);
            }
        }
    }

    /// Releases every pending frame: the stream has ended.
    pub fn finish(&mut self, out: &mut Vec<f32>) {
        while !self.needed.is_empty() {
            self.release_one(out);
        }
    }

    fn release_one(&mut self, out: &mut Vec<f32>) {
        // Each frame `k` ahead caps the gain on a straight line from 1 (at LOOKAHEAD) down to
        // what it needs (at 0), so the gain reaches a peak's value exactly when it plays.
        let mut cap = 1f32;
        for (k, need) in self.needed.iter().enumerate() {
            if *need < 1. {
                cap = cap.min(need + (1. - need) * k as f32 / LOOKAHEAD as f32);
            }
        }
        let released = self.reduction * self.release;
        self.reduction = released.max(1. - cap);
        if self.reduction < RECOVERED {
            self.reduction = 0.;
        }
        self.needed.pop_front();
        let gain = 1. - self.reduction;
        for _ in 0..self.channels {
            let x = self.pending.pop_front().unwrap_or(0.);
            out.push(if self.reduction == 0. { x } else { x * gain });
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn run(input: &[f32], channels: usize) -> Vec<f32> {
        let mut limiter = Limiter::new(channels);
        let mut out = Vec::new();
        for chunk in input.chunks(channels * 37) {
            limiter.push(chunk, &mut out);
        }
        limiter.finish(&mut out);
        out
    }

    #[test]
    fn quiet_audio_passes_bit_for_bit_and_keeps_its_length() {
        let input: Vec<f32> = (0..2000).map(|i| (i as f32 * 0.01).sin() * 0.5).collect();
        assert_eq!(run(&input, 2), input);
    }

    #[test]
    fn peaks_are_held_at_the_ceiling_with_one_gain_for_every_channel() {
        let mut input = vec![0.25f32; 1000 * 2];
        input[500 * 2] = 2.;
        let out = run(&input, 2);
        assert_eq!(out.len(), input.len());
        assert!(out.iter().all(|x| x.abs() <= CEILING + 1e-6));
        assert!((out[500 * 2] - CEILING).abs() < 1e-5);
        // Linked: the quiet channel dips by the same factor at the peak.
        assert!((out[500 * 2 + 1] / 0.25 - CEILING / 2.).abs() < 1e-5);
        // Before the lookahead reaches the peak nothing changes.
        assert_eq!(out[(500 - LOOKAHEAD - 1) * 2], 0.25);
    }
}
