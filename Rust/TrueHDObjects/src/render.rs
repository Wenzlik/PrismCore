// Copyright 2026 PrismCore contributors.
// Portions adapted from SpatialAudioBridge (https://github.com/kristofferR/SpatialAudioBridge,
// Rust/SpatialAudioCore/src/render.rs at 0c63341), Apache License 2.0. Changes: 7.1.4 only, the
// DTS:X polar panner and 9.1.6 removed, absent bed speakers routed by table instead of by angle.
//
// Licensed under the Apache License, Version 2.0 (see LICENSE-APACHE in this directory).

//! Speaker gains for Atmos objects, and the ramped gain mixer.
//!
//! Objects follow the room-coordinate source panner of ETSI TS 103 448 (the AC-4 consumer
//! object renderer, which shares its metadata model with TrueHD's OAMD, ETSI TS 103 420).
//! This is an implementation of the published pseudocode, not a licensed Dolby renderer.

use std::{collections::VecDeque, f32::consts::FRAC_1_SQRT_2, f32::consts::FRAC_PI_2};

/// Output channels, in `kAudioChannelLayoutTag_Atmos_7_1_4` order:
/// L R C LFE Ls Rs Lb Rb Tfl Tfr Tbl Tbr.
pub const CHANNELS: usize = 12;
pub type Gains = [f32; CHANNELS];

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Speaker {
    L,
    R,
    C,
    Lfe,
    Ls,
    Rs,
    Lb,
    Rb,
    Tfl,
    Tfr,
    Tbl,
    Tbr,
    // Absent from 7.1.4; a bed channel on one of these is routed by `bed`.
    Lw,
    Rw,
    Tsl,
    Tsr,
    Tc,
    Tfc,
    Lsc,
    Rsc,
    Cb,
}

const OUTPUT: [Speaker; CHANNELS] = {
    use Speaker::*;
    [L, R, C, Lfe, Ls, Rs, Lb, Rb, Tfl, Tfr, Tbl, Tbr]
};

// Speaker classes for zone constraints and elevation (TS 103 448 tables 4 and 5).
const FRONT: u8 = 1;
const CENTRE: u8 = 2;
const WIDE: u8 = 4;
const SIDE: u8 = 8;
const BACK: u8 = 16;
const ELEVATED: u8 = 32;

/// Panner target and class of each 7.1.4 output channel except LFE (the 3/4/4 table, A.5).
/// Ceiling targets sit a quarter of the room in from the walls.
const ROOM: [(usize, [f32; 3], u8); 11] = [
    (0, [0., 0., 0.], FRONT),
    (1, [1., 0., 0.], FRONT),
    (2, [0.5, 0., 0.], CENTRE),
    (4, [0., 0.5, 0.], SIDE),
    (5, [1., 0.5, 0.], SIDE),
    (6, [0., 1., 0.], BACK),
    (7, [1., 1., 0.], BACK),
    (8, [0.25, 0.25, 1.], ELEVATED),
    (9, [0.75, 0.25, 1.], ELEVATED),
    (10, [0.25, 0.75, 1.], ELEVATED),
    (11, [0.75, 0.75, 1.], ELEVATED),
];

/// Snap locations: the 22.2 panner targets of TS 103 448 table A.9, in the order clause 5.1.4.2
/// breaks ties (centre first, then descending z, descending y, ascending x).
const SNAP: [([f32; 3], u8); 22] = [
    ([0.5, 0., 0.], CENTRE),
    ([0.5, 0., -1.], ELEVATED),
    ([0.25, 0.75, 1.], ELEVATED),
    ([0.5, 0.75, 1.], ELEVATED),
    ([0.75, 0.75, 1.], ELEVATED),
    ([0.25, 0.5, 1.], ELEVATED),
    ([0.5, 0.5, 1.], ELEVATED),
    ([0.75, 0.5, 1.], ELEVATED),
    ([0.25, 0.25, 1.], ELEVATED),
    ([0.5, 0.25, 1.], ELEVATED),
    ([0.75, 0.25, 1.], ELEVATED),
    ([0., 1., 0.], BACK),
    ([0.5, 1., 0.], BACK),
    ([1., 1., 0.], BACK),
    ([0., 0.5, 0.], SIDE),
    ([1., 0.5, 0.], SIDE),
    ([0., 0.2929, 0.], WIDE),
    ([1., 0.2929, 0.], WIDE),
    ([0., 0., 0.], FRONT),
    ([1., 0., 0.], FRONT),
    ([0., 0., -1.], ELEVATED),
    ([1., 0., -1.], ELEVATED),
];

/// Speaker classes excluded by `zone_constraints_idx` and `b_enable_elevation`.
fn excluded(zone: u8, elevation: bool) -> u8 {
    let zone = match zone {
        1 => BACK,
        2 => SIDE | WIDE,
        3 => FRONT | WIDE | SIDE,
        4 => SIDE | WIDE | BACK,
        5 => FRONT | CENTRE | WIDE,
        _ => 0,
    };
    if elevation { zone } else { zone | ELEVATED }
}

/// Mid-layer (non-front) and top speakers left after zone constraints; they select the trim
/// configuration (TS 103 448 table 7).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct TrimLayout {
    pub mid: usize,
    pub top: usize,
}

impl TrimLayout {
    /// Trim configuration index; 8 for the full 7.1.4 layout.
    pub fn index(self) -> usize {
        let row = match self.mid {
            0 => 0,
            1..=3 => 1,
            _ => 2,
        };
        let column = match self.top {
            0 => 0,
            1..=2 => 3,
            _ => 6,
        };
        row + column
    }

    /// Default trim in decibels at a preprocessed position (pseudocode 16).
    pub fn default_db(self, [_, y, z]: [f32; 3]) -> f32 {
        let fraction = |count: usize| (count as f32 / 4.).min(1.);
        let max_trim = (-4.5 + 3. * fraction(self.mid) + 1.5 * fraction(self.top)).min(0.);
        let depth = (y / 0.6).clamp(0., 1.);
        let height = ((z.abs() - 0.2) / 0.8).clamp(0., 1.);
        max_trim * (depth + height).clamp(0., 1.)
    }
}

/// Object metadata in TS 103 448 room coordinates: x left→right and y front→back in [0, 1],
/// z from the bed plane (0) to the ceiling (1).
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Object {
    pub position: [f32; 3],
    pub size: [f32; 3],
    pub divergence: f32,
    pub snap: bool,
    pub zone: u8,
    pub elevation: bool,
}

impl Object {
    pub fn point(position: [f32; 3]) -> Self {
        Self { position, size: [0.; 3], divergence: 0., snap: false, zone: 0, elevation: true }
    }
}

fn unit(channel: usize) -> Gains {
    let mut gains = [0.; CHANNELS];
    gains[channel] = 1.;
    gains
}

/// Speaker-anchored routing of a bed channel (TS 103 448 clause 5.2.5, the 3/4/4 column of
/// table 6): present speakers route straight through, a wide plays from the front speaker on
/// its side and a top middle from the front and back tops on its side, each at −3 dB.
pub fn bed(speaker: Speaker) -> Gains {
    use Speaker::*;
    if let Some(index) = OUTPUT.iter().position(|s| *s == speaker) {
        return unit(index);
    }
    let route: &[usize] = match speaker {
        Lw => &[0],
        Rw => &[1],
        Tsl => &[8, 10],
        Tsr => &[9, 11],
        Tfc => &[8, 9],
        Lsc => &[0, 2],
        Rsc => &[1, 2],
        Cb => &[6, 7],
        Tc => return [0., 0., 0., 0., 0., 0., 0., 0., 0.5, 0.5, 0.5, 0.5],
        _ => unreachable!("every 7.1.4 speaker is in OUTPUT"),
    };
    // A single-target route keeps the table's −3 dB; a pair splits power equally.
    let mut gains = [0.; CHANNELS];
    for &channel in route {
        gains[channel] = FRAC_1_SQRT_2;
    }
    gains
}

/// Metadata preprocessing (clauses 5.1.3 and 5.1.4): elevation off drops to the bed plane,
/// then snap moves to the nearest allowed location and cancels size and divergence.
pub fn preprocess(mut object: Object) -> Object {
    if !object.elevation {
        object.position[2] = 0.;
    }
    if object.snap {
        let excluded = excluded(object.zone, object.elevation);
        let distance = |(p, _): &&([f32; 3], u8)| {
            let d = [0, 1, 2].map(|i| (object.position[i] - p[i]).powi(2));
            d[0] / 16. + 4. * d[1] + 32. * d[2]
        };
        // `min_by` keeps the first of equal minima, which is the table's tie order.
        if let Some((position, _)) = SNAP
            .iter()
            .filter(|(_, class)| class & excluded == 0)
            .min_by(|a, b| distance(a).total_cmp(&distance(b)))
        {
            object.position = *position;
        }
        object.size = [0.; 3];
        object.divergence = 0.;
    }
    object
}

/// Speaker counts selecting an object's trim configuration, after its zone constraints.
pub fn trim_layout(object: &Object) -> TrimLayout {
    let excluded = excluded(object.zone, object.elevation);
    let count = |classes: u8| {
        ROOM.iter().filter(|(_, _, class)| class & classes != 0 && class & excluded == 0).count()
    };
    TrimLayout { mid: count(WIDE | SIDE | BACK), top: count(ELEVATED) }
}

/// Source panner (clause 5.2) for preprocessed metadata.
pub fn object(object: &Object) -> Gains {
    let excluded = excluded(object.zone, object.elevation);
    let (channels, targets): (Vec<usize>, Vec<[f32; 3]>) = ROOM
        .iter()
        .filter(|(_, _, class)| class & excluded == 0)
        .map(|(channel, position, _)| (*channel, *position))
        .unzip();
    let gains = if object.divergence > 0. {
        divergence(&targets, object)
    } else if object.size.iter().any(|s| *s > 0.) {
        size(&targets, object)
    } else {
        point(&targets, object.position)
    };
    let mut result = [0.; CHANNELS];
    for (channel, gain) in channels.into_iter().zip(gains) {
        result[channel] = gain;
    }
    result
}

fn sign(value: f32) -> i8 {
    i8::from(value > 0.) - i8::from(value < 0.)
}

/// Gain of the target at `this` along one axis, given the coordinates of the targets sharing
/// its plane or row (pseudocode 4 to 6): cosine/sine of the normalized distance to the
/// neighbour on the other side of `position`; a target with no neighbour keeps the whole.
fn axis(this: f32, others: impl Iterator<Item = f32>, position: f32) -> f32 {
    let other = if this >= position {
        others.filter(|v| *v < this).reduce(f32::max)
    } else {
        others.filter(|v| *v > this).reduce(f32::min)
    };
    match other {
        None => 1.,
        Some(other) if sign(other - position) == sign(this - position) => 0.,
        Some(other) => ((this - position) / (other - this) * FRAC_PI_2).cos().max(0.),
    }
}

fn same(a: f32, b: f32) -> bool {
    (a - b).abs() < 0.001
}

fn pan_z(targets: &[[f32; 3]], z: f32) -> Vec<f32> {
    targets.iter().map(|t| axis(t[2], targets.iter().map(|o| o[2]), z)).collect()
}

fn pan_y(targets: &[[f32; 3]], y: f32) -> Vec<f32> {
    targets
        .iter()
        .map(|t| axis(t[1], targets.iter().filter(|o| same(o[2], t[2])).map(|o| o[1]), y))
        .collect()
}

fn pan_x(targets: &[[f32; 3]], x: f32) -> Vec<f32> {
    targets
        .iter()
        .map(|t| {
            let row = targets.iter().filter(|o| same(o[2], t[2]) && same(o[1], t[1]));
            axis(t[0], row.map(|o| o[0]), x)
        })
        .collect()
}

/// Point source panner (pseudocode 3): separable z, then y, then x; unit power.
fn point(targets: &[[f32; 3]], [x, y, z]: [f32; 3]) -> Vec<f32> {
    let (gx, gy, gz) = (pan_x(targets, x), pan_y(targets, y), pan_z(targets, z));
    (0..targets.len()).map(|j| gx[j] * gy[j] * gz[j]).collect()
}

fn normalized(gains: &[f64]) -> Vec<f64> {
    let total = gains.iter().map(|g| g * g).sum::<f64>().sqrt();
    gains.iter().map(|g| g / total.max(1e-5)).collect()
}

/// Divergence panner (pseudocode 15): two sources at x ± divergence/2, kept inside the room.
fn divergence(targets: &[[f32; 3]], object: &Object) -> Vec<f32> {
    let [x, y, z] = object.position;
    let spread = object.divergence.min(1. - (x - 0.5).abs() * 2.);
    let (left, right) = (pan_x(targets, x - spread / 2.), pan_x(targets, x + spread / 2.));
    let (gy, gz) = (pan_y(targets, y), pan_z(targets, z));
    let gains: Vec<f64> =
        (0..targets.len()).map(|j| f64::from(gz[j] * gy[j] * (left[j] + right[j]))).collect();
    normalized(&gains).into_iter().map(|g| g as f32).collect()
}

/// Object width to the size panner's scale (pseudocode 7).
fn size_scale(width: f64) -> f64 {
    match width {
        w if w < 1e-5 => 0.,
        w if w <= 0.2 => 1.5 * w,
        w if w <= 0.5 => 7. / 3. * w - 1. / 6.,
        w if w <= 0.75 => 3.2 * w - 0.6,
        w => 4. * w - 1.2,
    }
}

/// Weight of a virtual source at `a` for an object at `b` of scaled size `c` (pseudocode 8).
fn weight(a: f64, b: f64, c: f64) -> f64 {
    if c > 0. { 10f64.powf(-(1.5 * (a - b) / c).powi(4)) } else { 0. }
}

/// Fade of the inside sources near the room boundaries (pseudocode 13).
fn fade(position: f64, size: f64) -> f64 {
    let distance = position.min(1. - position);
    if distance < size || distance < 0.2 { distance / size.max(0.2) } else { 1. }
}

/// Size panner (clause 5.2.3) for a layout without bottom speakers: weighted sums over 20×20×8
/// equidistant virtual sources plus sources on the six room boundaries, crossfaded from the
/// point panner for small objects.
fn size(targets: &[[f32; 3]], object: &Object) -> Vec<f32> {
    const COUNTS: [usize; 3] = [20, 20, 8];
    let position = object.position.map(|p| f64::from(p).max(0.));
    let scaled = object.size.map(|w| size_scale(w.into()));
    let lb: [f64; 3] = std::array::from_fn(|a| scaled[a].max(2. / (COUNTS[a] - 1) as f64));

    // Pseudocode 9: effective size and exponent.
    let mut sorted = scaled;
    sorted.sort_by(|a, b| b.total_cmp(a));
    let effective = 2. / 3. * sorted[0] + 2. / 9. * sorted[1] + 1. / 9. * sorted[2];
    let p = if effective > 0.5 { 6. - (effective - 0.5) * 4. / 2.3 } else { 6. };

    let pan = |axis: usize, v: f32| match axis {
        0 => pan_x(targets, v),
        1 => pan_y(targets, v),
        _ => pan_z(targets, v),
    };
    // Pseudocode 10: per-axis weighted sums over the virtual sources.
    let w: Vec<Vec<f64>> = (0..3)
        .map(|axis| {
            let mut sums = vec![0.; targets.len()];
            for s in 0..COUNTS[axis] {
                let v = s as f64 / (COUNTS[axis] - 1) as f64;
                let weight = weight(v, position[axis], lb[axis]);
                for (sum, gain) in sums.iter_mut().zip(pan(axis, v as f32)) {
                    *sum += (f64::from(gain) * weight).powf(p);
                }
            }
            sums
        })
        .collect();
    let inside: Vec<f64> =
        (0..targets.len()).map(|j| (w[0][j] * w[1][j] * w[2][j]).powf(1. / p)).collect();
    let inside = normalized(&inside);

    // Pseudocode 11: boundary sources, each weighted by the other two axes' sums.
    let mut boundary = vec![0.; targets.len()];
    for axis in 0..3 {
        for at in [0., 1.] {
            let weight = weight(at, position[axis], lb[axis]);
            for (j, gain) in pan(axis, at as f32).into_iter().enumerate() {
                let across = w[(axis + 1) % 3][j] * w[(axis + 2) % 3][j];
                boundary[j] += (f64::from(gain) * weight).powf(p) * across;
            }
        }
    }
    let boundary = normalized(&boundary);

    // Pseudocode 12: inside sources fade out towards the walls.
    let out = fade(position[0], lb[0]) * fade(position[1], lb[1]) * fade(position[2], lb[2]);
    let sized: Vec<f64> =
        (0..targets.len()).map(|j| (boundary[j] + out * inside[j]).powf(1. / p)).collect();
    let sized = normalized(&sized);

    // Pseudocode 14: small objects crossfade from the point panner.
    let (alpha, beta) = if effective < 0.2 {
        let angle = effective / 0.2 * std::f64::consts::FRAC_PI_2;
        (angle.cos(), angle.sin())
    } else {
        (0., 1.)
    };
    let point = point(targets, object.position);
    let gains: Vec<f64> =
        (0..targets.len()).map(|j| alpha * f64::from(point[j]) + beta * sized[j]).collect();
    normalized(&gains).into_iter().map(|g| g as f32).collect()
}

/// A gain change for one input channel at an absolute sample, ramped over `ramp` + 1 samples.
#[derive(Clone)]
pub struct Event {
    pub sample: u64,
    pub channel: usize,
    pub gains: Gains,
    pub ramp: u32,
}

#[derive(Default, Clone)]
struct Route {
    current: Gains,
    target: Gains,
    step: Gains,
    remaining: u32,
}

/// Mixes input channels into the 7.1.4 feeds through per-channel gains that metadata events
/// change sample-accurately.
#[derive(Default)]
pub struct Renderer {
    routes: Vec<Route>,
    events: VecDeque<Event>,
    /// Absolute index of the next sample to render.
    pub sample: u64,
}

impl Renderer {
    pub fn event(&mut self, event: Event) {
        let i = self.events.iter().position(|e| e.sample > event.sample).unwrap_or(self.events.len());
        self.events.insert(i, event);
    }

    /// Sets a channel's gains now, without a ramp.
    pub fn route(&mut self, channel: usize, gains: Gains) {
        self.routes.resize_with(self.routes.len().max(channel + 1), Route::default);
        self.routes[channel] = Route { current: gains, target: gains, ..Default::default() };
    }

    /// Renders `frames` samples of `input` (one Vec per channel) into interleaved 7.1.4.
    pub fn render(&mut self, input: &[Vec<f32>], frames: usize, out: &mut Vec<f32>) {
        self.routes.resize_with(self.routes.len().max(input.len()), Route::default);
        let base = out.len();
        out.resize(base + frames * CHANNELS, 0.);
        for frame in 0..frames {
            while self.events.front().is_some_and(|e| e.sample <= self.sample) {
                let event = self.events.pop_front().unwrap();
                self.routes.resize_with(self.routes.len().max(event.channel + 1), Route::default);
                let route = &mut self.routes[event.channel];
                route.target = event.gains;
                route.remaining = event.ramp + 1;
                if event.ramp == 0 {
                    route.current = event.gains;
                } else {
                    for i in 0..CHANNELS {
                        route.step[i] = (event.gains[i] - route.current[i]) / (event.ramp + 1) as f32;
                    }
                }
            }
            let row = &mut out[base + frame * CHANNELS..base + (frame + 1) * CHANNELS];
            for (channel, pcm) in input.iter().enumerate() {
                let route = &mut self.routes[channel];
                if route.remaining > 0 {
                    for i in 0..CHANNELS {
                        route.current[i] += route.step[i];
                    }
                    route.remaining -= 1;
                    if route.remaining == 0 {
                        route.current = route.target;
                    }
                }
                let x = pcm[frame];
                if x != 0. {
                    for i in 0..CHANNELS {
                        row[i] += x * route.current[i];
                    }
                }
            }
            self.sample += 1;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    const M: f32 = FRAC_1_SQRT_2;

    fn power(gains: &[f32]) -> f32 {
        gains.iter().map(|g| g * g).sum()
    }
    fn close(actual: &Gains, expected: &[(usize, f32)]) -> bool {
        (0..CHANNELS).all(|i| {
            let gain = expected.iter().find(|(c, _)| *c == i).map_or(0., |(_, g)| *g);
            (actual[i] - gain).abs() < 1e-5
        })
    }
    fn at(position: [f32; 3]) -> Gains {
        object(&Object::point(position))
    }

    // TS 103 448 point panner: each A.5 target lands on its own speaker alone.
    #[test]
    fn panner_targets_route_to_their_own_speaker() {
        for (channel, position, _) in ROOM {
            assert!(close(&at(position), &[(channel, 1.)]), "{position:?}");
        }
    }

    // Pseudocode 3 between rows: halfway to the listener is C at −3 dB and the side pair at
    // −6 dB each, nothing behind; the room centre is the side pair.
    #[test]
    fn interior_positions_pan_between_neighbouring_rows() {
        assert!(close(&at([0.5, 0.25, 0.]), &[(2, M), (4, 0.5), (5, 0.5)]));
        assert!(close(&at([0.5, 0.5, 0.]), &[(4, M), (5, M)]));
    }

    #[test]
    fn ceiling_targets_are_inset_from_the_walls() {
        assert!(close(&at([0., 0., 1.]), &[(8, 1.)]));
        assert!(close(&at([0.5, 0.5, 1.]), &[(8, 0.5), (9, 0.5), (10, 0.5), (11, 0.5)]));
        // No floor speakers: below the bed plane plays on the bed.
        assert!(close(&at([0., 0., -0.5]), &[(0, 1.)]));
    }

    #[test]
    fn point_gains_have_unit_power_and_never_feed_lfe() {
        for x in 0..=10 {
            for y in 0..=10 {
                for z in -2..=10 {
                    let g = at([x as f32 / 10., y as f32 / 10., z as f32 / 10.]);
                    assert!((power(&g) - 1.).abs() < 1e-5);
                    assert!(g.iter().all(|g| g.is_finite() && *g >= 0.));
                    assert_eq!(g[3], 0.);
                }
            }
        }
    }

    #[test]
    fn bed_channels_follow_the_speaker_anchored_table() {
        assert!(close(&bed(Speaker::Ls), &[(4, 1.)]));
        assert!(close(&bed(Speaker::Lw), &[(0, M)]));
        assert!(close(&bed(Speaker::Tsr), &[(9, M), (11, M)]));
    }

    #[test]
    fn zones_and_elevation_exclude_speakers() {
        let zoned = |zone, position| object(&Object { zone, ..Object::point(position) });
        // Screen only: a rear-left object plays from the front left.
        assert!(close(&zoned(4, [0., 1., 0.]), &[(0, 1.)]));
        // No backs: a rear-right object plays from the right side.
        assert!(close(&zoned(1, [1., 1., 0.]), &[(5, 1.)]));
        let low = preprocess(Object { elevation: false, ..Object::point([0., 0., 1.]) });
        assert!(close(&object(&low), &[(0, 1.)]));
    }

    #[test]
    fn trim_configuration_follows_the_remaining_speakers() {
        let rear = [0., 1., 0.];
        assert_eq!(trim_layout(&Object::point(rear)).index(), 8);
        let flat = trim_layout(&Object { elevation: false, ..Object::point(rear) });
        assert_eq!(flat.index(), 2);
        assert!((flat.default_db(rear) + 1.5).abs() < 1e-6);
        let screen = trim_layout(&Object { zone: 4, ..Object::point(rear) });
        assert_eq!(screen.index(), 6);
        assert!((screen.default_db(rear) + 3.).abs() < 1e-6);
    }

    #[test]
    fn snap_moves_to_the_nearest_allowed_location() {
        let snapped = |position, zone, elevation| {
            preprocess(Object { snap: true, zone, elevation, size: [0.5; 3], divergence: 0.5, ..Object::point(position) })
        };
        let near_left = snapped([0.1, 0.05, 0.], 0, true);
        assert_eq!(near_left.position, [0., 0., 0.]);
        assert_eq!((near_left.size, near_left.divergence), ([0.; 3], 0.));
        // The overhead centre is a snap location with no speaker: it pans over the four tops.
        let overhead = snapped([0.45, 0.55, 0.9], 0, true);
        assert_eq!(overhead.position, [0.5, 0.5, 1.]);
        assert_eq!(snapped([0.1, 0.05, 0.], 5, true).position, [0., 0.5, 0.]);
    }

    #[test]
    fn divergence_splits_along_x_within_the_room() {
        let diverged = |d, p| object(&Object { divergence: d, ..Object::point(p) });
        assert!(close(&diverged(1., [0.5, 0., 0.]), &[(0, M), (1, M)]));
        assert!(close(&diverged(1., [0.9, 0., 0.]), &[(1, 0.951057), (2, 0.309017)]));
    }

    #[test]
    fn size_spreads_with_unit_power_and_converges_to_a_point() {
        let sized = |s, p| object(&Object { size: s, ..Object::point(p) });
        for width in [0.05, 0.3, 0.6, 1.] {
            for p in [[0.5, 0.5, 0.], [0.5, 0.1, 0.7], [0.2, 0.8, 0.3], [0., 0., 1.]] {
                let g = sized([width; 3], p);
                assert!((power(&g) - 1.).abs() < 1e-4, "{width} {p:?}");
                assert!(g[3] == 0.);
            }
        }
        let p = [0.3, 0.2, 0.4];
        let d: f32 = sized([1e-4; 3], p).iter().zip(at(p)).map(|(a, b)| (a - b).powi(2)).sum();
        assert!(d.sqrt() < 0.01);
        let active = |g: Gains| g.iter().filter(|g| **g > 0.05).count();
        assert!(active(sized([0.8; 3], p)) > active(sized([0.1; 3], p)));
    }

    #[test]
    fn metadata_event_is_sample_accurate_and_ramped() {
        let mut r = Renderer::default();
        r.route(0, unit(0));
        r.event(Event { sample: 2, channel: 0, gains: unit(8), ramp: 1 });
        let mut pcm = Vec::new();
        r.render(&[vec![1.; 5]], 5, &mut pcm);
        assert_eq!(pcm[CHANNELS], 1.);
        assert_eq!(pcm[2 * CHANNELS], 0.5);
        assert_eq!(pcm[2 * CHANNELS + 8], 0.5);
        assert_eq!(pcm[3 * CHANNELS], 0.);
        assert_eq!(pcm[3 * CHANNELS + 8], 1.);
    }
}
