// Copyright 2026 PrismCore contributors.
// The OAMD-to-renderer mapping (coordinate conversion, block scheduling, trims, concealment up
// to the next major sync, holding audio until the first metadata) is adapted from
// SpatialAudioBridge (Rust/SpatialAudioCore/src/decode.rs at 0c63341), Apache License 2.0.
// Changes: TrueHD only (no DTS), a bed fallback instead of terminal errors for presentations
// the renderer does not support, no dialogue normalisation, output into one reused buffer.
//
// Licensed under the Apache License, Version 2.0 (see LICENSE-APACHE in this directory).

//! TrueHD access units in, rendered 7.1.4 out.

use crate::{
    limit::Limiter,
    render::{self, CHANNELS, Event, Gains, Object, Renderer, Speaker},
};
use truehd::{
    process::{
        decode::{DecodedAccessUnit, Decoder},
        extract::Extractor,
        parse::Parser,
    },
    structs::{
        channel::ChannelLabel,
        oamd::{ObjectAudioMetadataPayload, TrimElement},
    },
    utils::errors::ExtractError,
};

/// Audio held before the first object metadata: half a second at 48 kHz. Atmos repeats its
/// metadata every few tens of milliseconds, and a stream entered at a later major sync carries
/// its first block a few access units in.
const MAX_HELD_FRAMES: usize = 24_000;
/// FBA streams repeat their major sync at least every 128 access units.
const MAX_SYNC_INTERVAL: usize = 128;
/// The 16-channel object presentation.
const ATMOS_PRESENTATION: usize = 3;

/// What the session is delivering.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
#[repr(u32)]
pub enum Mode {
    /// Nothing decoded yet (or audio held until the first object metadata).
    Pending = 0,
    /// The Atmos presentation rendered to 7.1.4 — objects placed by their metadata, or a
    /// channel-based immersive presentation routed by its labels: heights included.
    Objects = 1,
    /// The stream's own channel presentation (at most 7.1), routed into 7.1.4 with silent
    /// heights — what the session falls back to for anything the renderer cannot place.
    Bed = 2,
}

pub struct Session {
    extractor: Extractor,
    parser: Parser,
    decoder: Decoder,
    decoded: DecodedAccessUnit,
    renderer: Renderer,
    limiter: Limiter,
    mode: Mode,
    /// Why the session left `Objects` (or never reached it).
    pub fallback_reason: Option<String>,
    /// A bed switch waits for the next major sync; access units until then play as silence.
    switching: bool,
    /// The bed's presentation index, read at each major sync.
    bed_presentation: usize,
    bytes: u64,
    consumed: u64,
    held: Vec<Vec<Vec<f32>>>,
    held_frames: usize,
    /// The error that lost an access unit, and how many have been concealed since.
    lost: Option<(String, usize)>,
    /// Length of the latest decoded access unit, for concealment.
    unit_frames: Option<usize>,
    rendered: Vec<f32>,
    limited: Vec<f32>,
}

impl Default for Session {
    fn default() -> Self {
        Self {
            extractor: Extractor::default(),
            parser: Parser::default(),
            decoder: Decoder::default(),
            decoded: DecodedAccessUnit::default(),
            renderer: Renderer::default(),
            limiter: Limiter::new(CHANNELS),
            mode: Mode::Pending,
            fallback_reason: None,
            switching: false,
            bed_presentation: 2,
            bytes: 0,
            consumed: 0,
            held: Vec::new(),
            held_frames: 0,
            lost: None,
            unit_frames: None,
            rendered: Vec::new(),
            limited: Vec::new(),
        }
    }
}

impl Session {
    pub fn mode(&self) -> Mode {
        self.mode
    }

    /// Decodes `data` and hands every settled block of interleaved 7.1.4 to `output`. The
    /// stream must start at a major sync and carry this track only. `end` releases the
    /// limiter's last 2 ms.
    pub fn push(
        &mut self,
        data: &[u8],
        end: bool,
        output: &mut impl FnMut(&[f32]) -> Result<(), String>,
    ) -> Result<(), String> {
        self.bytes += data.len() as u64;
        self.extractor.push_bytes(data);
        while let Some(frame) = self.extractor.next() {
            let frame = match frame {
                Ok(f) => f,
                Err(ExtractError::InsufficientData) => break,
                Err(e) => return Err(format!("TrueHD framing: {e}")),
            };
            if frame.offset != self.consumed {
                return Err("TrueHD stream skipped bytes; start at a major sync".into());
            }
            self.consumed = frame.offset + frame.as_ref().len() as u64;
            let major_sync = frame.is_major_sync();
            // After a lost unit, or while switching to the bed, nothing decodes until the
            // stream restarts at its next major sync.
            if !major_sync && (self.lost.is_some() || self.switching) {
                self.conceal(output)?;
                continue;
            }
            let restarting = self.lost.take().map(|(error, _)| error);
            self.switching = false;
            let parsed = self.parser.parse(&frame);
            drop(self.parser.take_branches());
            let au = match parsed {
                Ok(au) => au,
                Err(e) => {
                    self.lose(restarting, format!("TrueHD parsing: {e}"), output)?;
                    continue;
                }
            };
            if self.mode != Mode::Bed
                && let Some(sync) = &au.major_sync_info
                && sync.substreams < 4
            {
                self.fall_back("the stream has no Atmos presentation", output)?;
                // This unit is a major sync: the bed starts right here.
                self.switching = false;
            }
            if let Some(sync) = &au.major_sync_info {
                // The widest channel presentation below the object one: 7.1 on Atmos.
                self.bed_presentation = (sync.substreams as usize).clamp(1, 3) - 1;
            }
            let presentation = if self.mode == Mode::Bed { self.bed_presentation } else { ATMOS_PRESENTATION };
            if let Err(e) = self.decoder.decode_presentation_into(&au, presentation, &mut self.decoded) {
                self.lose(restarting, format!("TrueHD decoding: {e}"), output)?;
                continue;
            }
            if self.decoded.is_duplicate {
                continue;
            }
            if self.decoded.sampling_frequency != 48_000 {
                return Err("only 48 kHz TrueHD is rendered".into());
            }
            let frames = self.decoded.sample_length;
            let input: Vec<Vec<f32>> = (0..self.decoded.channel_count)
                .map(|ch| (0..frames).map(|s| self.decoded.pcm_data[s][ch] as f32 / 8_388_608.).collect())
                .collect();
            self.unit_frames = Some(frames);
            self.emit(input, frames, output)?;
        }
        if self.extractor.error_count() != 0 {
            return Err("TrueHD extractor lost synchronization".into());
        }
        if self.bytes - self.consumed > 64 * 1024 {
            return Err("no TrueHD sync within 64 KiB".into());
        }
        if end {
            if let Some((error, _)) = self.lost.take() {
                return Err(error);
            }
            // Audio still held for metadata that never came keeps its time, as silence.
            if self.held_frames > 0 {
                self.fall_back("the stream ended before its first object metadata", output)?;
            }
            self.limiter.finish(&mut self.limited);
            self.flush(output)?;
        }
        Ok(())
    }

    /// Leaves object rendering for the bed at the next major sync. Audio held for metadata
    /// plays as silence, so the timeline keeps every sample.
    fn fall_back(
        &mut self,
        reason: &str,
        output: &mut impl FnMut(&[f32]) -> Result<(), String>,
    ) -> Result<(), String> {
        if self.mode == Mode::Bed {
            return Ok(());
        }
        self.fallback_reason = Some(reason.into());
        self.mode = Mode::Bed;
        self.switching = true;
        let sample = self.renderer.sample;
        self.renderer = Renderer::default();
        self.renderer.sample = sample;
        let held = std::mem::take(&mut self.held_frames);
        self.held.clear();
        if held > 0 {
            self.silence(held, output)?;
        }
        self.parser.reset_for_next_major_sync();
        self.decoder.reset_for_next_major_sync();
        Ok(())
    }

    /// An access unit that failed to parse or decode, and those after it up to the next major
    /// sync, play as silence of their length (discs join clips this way). A failure at that
    /// major sync, or one before any audio decoded, ends the session.
    fn lose(
        &mut self,
        restarting: Option<String>,
        error: String,
        output: &mut impl FnMut(&[f32]) -> Result<(), String>,
    ) -> Result<(), String> {
        if let Some(first) = restarting {
            return Err(first);
        }
        if self.unit_frames.is_none() {
            return Err(error);
        }
        self.parser.reset_for_next_major_sync();
        self.decoder.reset_for_next_major_sync();
        self.lost = Some((error, 0));
        self.conceal(output)
    }

    fn conceal(&mut self, output: &mut impl FnMut(&[f32]) -> Result<(), String>) -> Result<(), String> {
        if let Some((error, count)) = &mut self.lost {
            *count += 1;
            if *count > MAX_SYNC_INTERVAL {
                return Err(error.clone());
            }
        }
        // Before any unit decoded, a TrueHD access unit at 48 kHz is 40 samples.
        let frames = self.unit_frames.unwrap_or(40);
        self.silence(frames, output)
    }

    fn silence(&mut self, frames: usize, output: &mut impl FnMut(&[f32]) -> Result<(), String>) -> Result<(), String> {
        self.renderer.sample += frames as u64;
        self.rendered.clear();
        self.rendered.resize(frames * CHANNELS, 0.);
        self.limit_and_flush(output)
    }

    fn emit(
        &mut self,
        input: Vec<Vec<f32>>,
        frames: usize,
        output: &mut impl FnMut(&[f32]) -> Result<(), String>,
    ) -> Result<(), String> {
        self.rendered.clear();
        // A presentation whose every channel names its speaker is channel-based: the bed, or a
        // channel-based immersive (7.1.4-style) Atmos presentation, which keeps its heights
        // without object metadata. An object presentation labels only its bed (LFE).
        let labelled = self.decoded.channel_labels.len() == input.len();
        if self.mode == Mode::Bed || (labelled && self.decoded.oamd.is_empty() && self.held.is_empty()) {
            let labels = if labelled {
                self.decoded.channel_labels.iter().map(|l| speaker(*l)).collect()
            } else {
                default_speakers(input.len())
            };
            for (channel, speaker) in labels.into_iter().enumerate() {
                self.renderer.route(channel, render::bed(speaker));
            }
            if self.mode == Mode::Pending {
                self.mode = Mode::Objects;
            }
            self.renderer.render(&input, frames, &mut self.rendered);
            return self.limit_and_flush(output);
        }
        let oamd = std::mem::take(&mut self.decoded.oamd);
        let result = self.emit_objects(input, frames, &oamd, output);
        self.decoded.oamd = oamd;
        match result {
            Err(Unsupported(reason)) => {
                // Nothing of this unit was rendered; it plays as silence and the bed takes
                // over at the next major sync.
                self.fall_back(&reason, output)?;
                self.silence(frames, output)
            }
            Ok(r) => r,
        }
    }

    fn emit_objects(
        &mut self,
        input: Vec<Vec<f32>>,
        frames: usize,
        oamd: &[ObjectAudioMetadataPayload],
        output: &mut impl FnMut(&[f32]) -> Result<(), String>,
    ) -> Result<Result<(), String>, Unsupported> {
        let channels = input.len();
        let mut events = Vec::new();
        let mut first = Vec::new();
        for metadata in oamd {
            for_each_block(self.renderer.sample, metadata, channels, |e| {
                if e.block == 0 && first.len() < channels {
                    first.push((e.channel, e.gains));
                }
                events.push(e.event);
            })?;
        }
        if self.mode == Mode::Pending {
            if oamd.is_empty() {
                // Checked before this unit joins the held audio: on a refusal `fall_back` plays
                // the held units as silence and `emit` this one, so counting it here too would
                // play it twice and push the bed one unit late (review r2).
                if self.held_frames + frames > MAX_HELD_FRAMES {
                    return Err(Unsupported("no object metadata within 0.5 s".into()));
                }
                self.held_frames += frames;
                self.held.push(input);
                return Ok(Ok(()));
            }
            // Held audio, and the start of this unit, take the first known object state.
            for (channel, gains) in first {
                self.renderer.route(channel, gains);
            }
            self.mode = Mode::Objects;
            for held in std::mem::take(&mut self.held) {
                let n = held.first().map_or(0, Vec::len);
                self.renderer.render(&held, n, &mut self.rendered);
            }
            self.held_frames = 0;
            // The held units advanced the renderer's clock; schedule against it again.
            events.clear();
            for metadata in oamd {
                for_each_block(self.renderer.sample, metadata, channels, |e| events.push(e.event))?;
            }
        }
        for event in events {
            self.renderer.event(event);
        }
        self.renderer.render(&input, frames, &mut self.rendered);
        Ok(self.limit_and_flush(output))
    }

    fn limit_and_flush(&mut self, output: &mut impl FnMut(&[f32]) -> Result<(), String>) -> Result<(), String> {
        let rendered = std::mem::take(&mut self.rendered);
        self.limiter.push(&rendered, &mut self.limited);
        self.rendered = rendered;
        self.flush(output)
    }

    fn flush(&mut self, output: &mut impl FnMut(&[f32]) -> Result<(), String>) -> Result<(), String> {
        if self.limited.is_empty() {
            return Ok(());
        }
        if self.limited.iter().any(|v| !v.is_finite()) {
            return Err("renderer produced non-finite PCM".into());
        }
        let result = output(&self.limited);
        self.limited.clear();
        result
    }
}

/// Metadata the renderer does not place; the session falls back to the bed.
pub struct Unsupported(pub String);

impl From<&str> for Unsupported {
    fn from(reason: &str) -> Self {
        Self(reason.into())
    }
}

/// Speakers for an unlabelled presentation (MLP-style FBB streams), by channel count.
fn default_speakers(count: usize) -> Vec<Speaker> {
    use Speaker::*;
    let order = [L, R, C, Lfe, Ls, Rs, Lb, Rb];
    match count {
        1 => vec![C],
        n => order.iter().copied().take(n.min(8)).collect(),
    }
}

fn speaker(label: ChannelLabel) -> Speaker {
    use ChannelLabel as C;
    use Speaker::*;
    match label {
        C::L => L,
        C::R => R,
        C::C => Speaker::C,
        C::LFE | C::LFE2 => Lfe,
        C::Ls | C::Lsd => Ls,
        C::Rs | C::Rsd => Rs,
        C::Lb => Lb,
        C::Rb => Rb,
        C::Cb => Cb,
        C::Tfl => Tfl,
        C::Tfr => Tfr,
        C::Tsl => Tsl,
        C::Tsr => Tsr,
        C::Tbl => Tbl,
        C::Tbr => Tbr,
        C::Tc => Tc,
        C::Tfc => Tfc,
        C::Lw => Lw,
        C::Rw => Rw,
        C::Lsc => Lsc,
        C::Rsc => Rsc,
    }
}

struct BlockEvent {
    block: usize,
    channel: usize,
    gains: Gains,
    event: Event,
}

/// Validates one OAMD payload and yields the target gains of every channel in every update
/// block, scheduled from `sample` (the renderer's position at the start of this unit).
fn for_each_block(
    sample: u64,
    metadata: &ObjectAudioMetadataPayload,
    channels: usize,
    mut visit: impl FnMut(BlockEvent),
) -> Result<(), Unsupported> {
    let program = &metadata.program_assignment;
    if program.num_isf_objects != 0 || program.bed_assignment.len() > 1 {
        return Err("intermediate spatial format or multiple beds".into());
    }
    if program.b_bed_chan_distribute {
        return Err("bed channel distribution".into());
    }
    if metadata.bed_object_element.is_some() {
        return Err("bed downmix metadata".into());
    }
    let trim = metadata.trim_element.as_ref();
    // warp_mode 1 (TS 103 420 table 32) is the Dolby renderer's 5.1 "warp"; 7.1.4 has side and
    // back surrounds, so positions stay as transmitted. Higher values are reserved.
    if trim.is_some_and(|t| t.warp_mode > 1) {
        return Err("reserved warp mode".into());
    }
    let element = metadata.object_element.as_ref().ok_or("metadata without an object element")?;
    let update = &element.md_update_info;
    if update.num_obj_info_blocks == 0 || update.block_update_info.len() != update.num_obj_info_blocks {
        return Err("update block count mismatch".into());
    }
    if metadata.object_count != channels || element.object_data.len() != channels {
        return Err("PCM / metadata channel count mismatch".into());
    }
    let beds = program.bed_assignment.first().map(|b| b.to_index_vec()).unwrap_or_default();
    let positions = metadata.get_damf_pos();
    let divergence = metadata.extended_object_element.as_ref();
    use Speaker::*;
    // OAMD bed channel indices (TS 103 420).
    const BED: [Speaker; 17] = [L, R, C, Lfe, Ls, Rs, Lb, Rb, Tfl, Tfr, Tsl, Tsr, Tbl, Tbr, Lw, Rw, Lfe];
    for (block_index, timing) in update.block_update_info.iter().enumerate() {
        let at = sample
            + metadata.evo_sample_offset
            + update.sample_offset as u64
            + u64::from(timing.block_offset_factor_bits) * 32;
        for channel in 0..channels {
            let block = element.object_data[channel].get(block_index).ok_or("missing object block")?;
            let mut gains = if block.b_object_not_active {
                // Inactive blocks can keep stale controls; their target is silence.
                [0.; CHANNELS]
            } else if block.b_object_in_bed_or_isf {
                let index = *beds.get(channel).ok_or("bed assignment mismatch")?;
                render::bed(*BED.get(index).ok_or("unknown bed speaker")?)
            } else {
                let [x, y, z] = *positions
                    .get(channel)
                    .and_then(|v| v.get(block_index))
                    .ok_or("missing object position")?;
                if [x, y, z].iter().any(|v| !v.is_finite()) {
                    return Err("invalid object position".into());
                }
                let info = &block.object_render_info;
                if info.b_object_distance_specified {
                    return Err("objects outside the room".into());
                }
                if info.zone_constraints_idx > 5 {
                    return Err("reserved zone constraint".into());
                }
                let object = render::preprocess(Object {
                    // DAMF coordinates to TS 103 448 room coordinates.
                    position: [x / 2. + 0.5, 0.5 - y / 2., z].map(|v| v as f32),
                    size: info.object_size.map(|s| s as f32),
                    divergence: divergence
                        .and_then(|e| e.object_div_block.get(channel)?.get(block_index))
                        .filter(|d| d.b_object_divergence)
                        .map_or(0., |d| d.object_divergence as f32),
                    // Screen anchoring with an unknown screen leaves positions as they are,
                    // but still cancels snap (TS 103 448 clause 5.1.2.2).
                    snap: info.b_object_snap && !info.b_object_use_screen_ref,
                    zone: info.zone_constraints_idx,
                    elevation: info.b_enable_elevation,
                });
                let mut gains = render::object(&object);
                let trim = trim_gain(trim, channel, render::trim_layout(&object), object.position);
                gains.iter_mut().for_each(|g| *g *= trim);
                gains
            };
            let gain = if block.b_object_not_active || block.object_basic_info.object_gain == -128 {
                0.
            } else {
                10f32.powf(block.object_basic_info.object_gain as f32 / 20.)
            };
            gains.iter_mut().for_each(|g| *g *= gain);
            visit(BlockEvent {
                block: block_index,
                channel,
                gains,
                event: Event { sample: at, channel, gains, ramp: timing.ramp_duration as u32 },
            });
        }
    }
    Ok(())
}

/// Trim gain at a preprocessed position (TS 103 448 clause 5.3). Without trim metadata the
/// default trim applies; balance metadata has no TS 103 448 equivalent and is ignored.
fn trim_gain(trim: Option<&TrimElement>, object: usize, layout: render::TrimLayout, position: [f32; 3]) -> f32 {
    let default = layout.default_db(position);
    let decibels = match trim {
        None => default,
        Some(trim) if trim.b_disable_trim.get(object) == Some(&true) => 0.,
        Some(trim) => match (trim.global_trim_mode, &trim.trims[layout.index()]) {
            (1, _) => 0.,
            (2, Some(custom)) if custom.b_disable_trim => 0.,
            (2, Some(custom)) if !custom.b_default_trim => {
                let [_, y, z] = position;
                let surround = custom.trim_surround.unwrap_or(0.) as f32;
                let height = custom.trim_height.unwrap_or(0.) as f32;
                let front_to_back = if y >= 0.5 { surround } else { surround * 2. * y };
                front_to_back + height * z.abs()
            }
            _ => default,
        },
    };
    10f32.powf(decibels / 20.)
}

#[cfg(test)]
mod tests {
    use super::*;
    use truehd::structs::oamd::{
        BlockUpdateInfo, MDUpdateInfo, ObjectBasicInfo, ObjectElement, ObjectInfoBlock, ObjectRenderInfo, Trim,
    };

    fn point(pos3d: [f64; 3]) -> ObjectAudioMetadataPayload {
        ObjectAudioMetadataPayload {
            object_count: 1,
            object_element: Some(ObjectElement {
                md_update_info: MDUpdateInfo {
                    num_obj_info_blocks: 1,
                    block_update_info: vec![BlockUpdateInfo::default()],
                    ..Default::default()
                },
                object_data: vec![vec![ObjectInfoBlock {
                    object_basic_info: ObjectBasicInfo { object_gain: 0, ..Default::default() },
                    object_render_info: ObjectRenderInfo { pos3d, ..Default::default() },
                    ..Default::default()
                }]],
                ..Default::default()
            }),
            ..Default::default()
        }
    }

    fn gains(metadata: &ObjectAudioMetadataPayload) -> Result<Gains, Unsupported> {
        let mut out = None;
        for_each_block(0, metadata, 1, |e| out = Some(e.gains))?;
        Ok(out.unwrap())
    }

    // DAMF (x −1…1 left→right, y 1…−1 front→back, z 0…1) lands on the TS 103 448 targets.
    #[test]
    fn damf_positions_reach_the_expected_speakers() {
        let ceiling_front_left = gains(&point([0., 0., 1.])).ok().unwrap();
        assert_eq!(ceiling_front_left[8], 1.);
        assert_eq!(ceiling_front_left[..8].iter().sum::<f32>(), 0.);
        let mut grounded = point([0., 0., 1.]);
        grounded.object_element.as_mut().unwrap().object_data[0][0].object_render_info.b_enable_elevation = false;
        let g = gains(&grounded).ok().unwrap();
        assert_eq!(g[0], 1.);
        assert_eq!(g[8..].iter().sum::<f32>(), 0.);
    }

    #[test]
    fn custom_trim_attenuates_surround_and_height_positions() {
        let mut metadata = point([0., 1., 1.]);
        let mut trims: [Option<Trim>; 9] = Default::default();
        trims[8] = Some(Trim { b_default_trim: false, trim_surround: Some(-6.), trim_height: Some(-3.), ..Default::default() });
        metadata.trim_element = Some(TrimElement { global_trim_mode: 2, trims, ..Default::default() });
        let peak = gains(&metadata).ok().unwrap().into_iter().fold(0., f32::max);
        assert!((peak - 10f32.powf(-9. / 20.)).abs() < 1e-6);
    }

    #[test]
    fn unsupported_metadata_is_reported_not_rendered() {
        let mut isf = point([0., 0., 0.]);
        isf.program_assignment.num_isf_objects = 1;
        assert!(gains(&isf).is_err());
        let mut far = point([0., 0., 0.]);
        far.object_element.as_mut().unwrap().object_data[0][0].object_render_info.b_object_distance_specified = true;
        assert!(gains(&far).is_err());
        // An inactive block with the same controls is silence, not a refusal.
        far.object_element.as_mut().unwrap().object_data[0][0].b_object_not_active = true;
        assert!(gains(&far).ok().unwrap().iter().all(|g| *g == 0.));
    }

    #[test]
    fn bed_labels_route_without_heights_on_a_7_1_presentation() {
        use ChannelLabel as C;
        for (label, channel) in [(C::L, 0), (C::R, 1), (C::C, 2), (C::LFE, 3), (C::Ls, 4), (C::Rs, 5), (C::Lb, 6), (C::Rb, 7)] {
            let g = render::bed(speaker(label));
            assert_eq!(g[channel], 1.);
            assert_eq!(g.iter().sum::<f32>(), 1.);
        }
    }

    #[test]
    fn metadata_timeout_keeps_every_sample_exactly_once() {
        // 601 object units of 40 samples with no OAMD: 600 are held (24 000, the limit), the
        // 601st refuses — and the output must be exactly 601 × 40 samples, no more.
        let mut session = Session::default();
        let mut frames = 0usize;
        let mut sink = |pcm: &[f32]| {
            frames += pcm.len() / CHANNELS;
            Ok(())
        };
        for _ in 0..601 {
            session.emit(vec![vec![0.1; 40]; 16], 40, &mut sink).unwrap();
        }
        assert_eq!(session.mode(), Mode::Bed);
        session.limiter.finish(&mut session.limited);
        session.flush(&mut sink).unwrap();
        assert_eq!(frames, 601 * 40);
    }

    #[test]
    fn garbage_is_an_error_not_a_panic() {
        let mut session = Session::default();
        let mut sink = |_: &[f32]| Ok(());
        let junk: Vec<u8> = (0..70_000u32).map(|i| (i.wrapping_mul(2654435761) >> 24) as u8).collect();
        assert!(session.push(&junk, true, &mut sink).is_err());
    }
}
