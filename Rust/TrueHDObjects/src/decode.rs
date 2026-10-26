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
    render::{self, CHANNELS, Gains, Layout, Renderer, Speaker},
    split::{BedSplitter, Weight},
};
use crate::render::{Event, Object};
use truehd::structs::oamd::TrimElement;
use truehd::{
    process::{
        decode::{DecodedAccessUnit, Decoder},
        extract::Extractor,
        parse::Parser,
    },
    structs::{
        channel::ChannelLabel,
        oamd::ObjectAudioMetadataPayload,
    },
    utils::errors::ExtractError,
};

/// How long a session waits for the first object metadata: half a second at 48 kHz. Atmos
/// repeats its metadata every few tens of milliseconds, and a stream entered at a later major
/// sync carries its first block a few access units in. The exact render holds its audio that
/// long (with the 7.1 decoded beside it, in the shipped session); the split plays the plain 7.1
/// meanwhile and reports the bed after it — and so does the shipped session when that time runs
/// out, from the held 7.1.
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
    /// The exact object render; otherwise the 7.1 presentation is split per bin, guided by
    /// where the objects' energy lies (`split`).
    exact: bool,
    /// What the exact render leaves to when it meets metadata it does not place: the split
    /// (the shipped session) or the bed (`exact()`, for measurement).
    split_fallback: bool,
    /// The bed asked for from outside (`request_bed`), applied at the next major sync.
    bed_request: Option<String>,
    /// While the shipped session holds audio for its first object metadata (and up to the next
    /// major sync after it), the 7.1 is decoded beside the objects: the latest unit's, and each
    /// held unit's. Should the render give way then, the split plays them from the first held
    /// sample on, as 3.8 did, instead of silence.
    dual: bool,
    bed_unit: Option<(Vec<Vec<f32>>, Vec<Speaker>)>,
    held_beds: Vec<(Vec<Vec<f32>>, Vec<Speaker>)>,
    /// The split took over for want of metadata: metadata the render places brings the render
    /// back, at the next major sync (`rejoining`).
    may_rejoin: bool,
    rejoining: bool,
    split: Option<BedSplitter>,
    /// Whether the split has had an object guide (readable metadata, or a channel-based
    /// immersive presentation), and the frames it has played without one before that.
    guided: bool,
    unguided_frames: usize,
    /// The output layout, and the split's 7.1.4 routed into it by table 6 (row per 7.1.4
    /// channel; `None` for 7.1.4 itself).
    layout: Layout,
    split_routing: Option<[Gains; CHANNELS]>,
    compact: Vec<f32>,
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
            exact: false,
            split_fallback: false,
            bed_request: None,
            dual: false,
            bed_unit: None,
            held_beds: Vec::new(),
            may_rejoin: false,
            rejoining: false,
            split: None,
            guided: false,
            unguided_frames: 0,
            layout: Layout::L714,
            split_routing: None,
            compact: Vec::new(),
        }
    }
}

impl Session {
    /// The exact object render alone: metadata it does not place sends it to the bed. What the
    /// split is measured against.
    pub fn exact() -> Self {
        Self { exact: true, ..Self::default() }
    }

    /// The shipped session: the exact object render, and the split of the 7.1 presentation
    /// from the next major sync when the render meets metadata it does not place (the split
    /// reads object positions only as points, so it takes what the render refuses). The split
    /// has its own bed fallback, as before.
    pub fn exact_with_split_fallback() -> Self {
        Self { exact: true, split_fallback: true, dual: true, ..Self::default() }
    }

    /// The same session rendering into another layout: objects are panned onto its own
    /// loudspeakers (TS 103 448 tables A.5–A.8), bed channels routed by table 6, and the split
    /// fallback's 7.1.4 folded into it by the same table.
    pub fn in_layout(mut self, layout: Layout) -> Self {
        self.layout = layout;
        self.split_routing = (layout != Layout::L714).then(|| {
            let mut rows = [[0.; CHANNELS]; CHANNELS];
            for (row, speaker) in rows.iter_mut().zip(Layout::L714.speakers()) {
                *row = render::bed_in(layout, *speaker, true);
            }
            rows
        });
        self
    }

    /// Channels per output frame.
    pub fn channels(&self) -> usize {
        self.layout.channels()
    }

    /// The bed, whatever is rendering, for a host whose heights chain cannot keep up (the bed
    /// decodes one presentation and renders nothing). What is playing goes on up to the next
    /// major sync (at most 107 ms), where what the split still holds comes out (its last 32 ms,
    /// heights included) and the bed starts, with no gap. One way: a new session is how heights
    /// come back.
    pub fn request_bed(&mut self, reason: &str) {
        self.bed_request = Some(reason.into());
    }

    fn renders_objects(&self) -> bool {
        self.exact
    }

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
            if major_sync {
                self.apply_bed_request(output)?;
            }
            let parsed = self.parser.parse(&frame);
            drop(self.parser.take_branches());
            let mut au = match parsed {
                Ok(au) => au,
                Err(e) => {
                    self.lose(restarting, format!("TrueHD parsing: {e}"), output)?;
                    continue;
                }
            };
            if (self.mode != Mode::Bed || self.split.is_some())
                && au.major_sync_info.as_ref().is_some_and(|sync| sync.substreams < 4)
            {
                self.fall_back("the stream has no Atmos presentation", output)?;
                // This unit is a major sync: the bed starts right here, parsed again by the
                // parser `fall_back` restarted (parsed by the old one, the units after it
                // failed to parse until the next major sync, as silence).
                self.switching = false;
                let parsed = self.parser.parse(&frame);
                drop(self.parser.take_branches());
                au = match parsed {
                    Ok(au) => au,
                    Err(e) => {
                        self.lose(restarting, format!("TrueHD parsing: {e}"), output)?;
                        continue;
                    }
                };
            }
            if let Some(sync) = &au.major_sync_info {
                // The widest channel presentation below the object one: 7.1 on Atmos.
                self.bed_presentation = (sync.substreams as usize).clamp(1, 3) - 1;
            }
            if major_sync {
                self.at_major_sync(output)?;
            }
            // An unguided split reports the bed but keeps splitting (`note_guide`).
            if !self.renders_objects() && (self.mode != Mode::Bed || self.split.is_some()) {
                self.decode_from_bed(&au, restarting, output)?;
                continue;
            }
            let presentation = if self.mode == Mode::Bed { self.bed_presentation } else { ATMOS_PRESENTATION };
            self.bed_unit = None;
            let decoded = if self.dual && self.mode != Mode::Bed {
                self.decode_with_bed(&au)
            } else {
                self.decoder.decode_presentation_into(&au, presentation, &mut self.decoded).map_err(|e| e.to_string())
            };
            if let Err(e) = decoded {
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
            // A stream ending in a loss is an error, but what is held, in the split and in the
            // limiter is audio from before the loss: it comes out first.
            let lost = self.lost.take();
            // Audio still held for metadata that never came plays as the split of its 7.1 (or,
            // without it, keeps its time as silence).
            if self.held_frames > 0 {
                if self.held_beds.len() == self.held.len() {
                    self.split_held(output)?;
                } else {
                    self.fall_back("the stream ended before its first object metadata", output)?;
                }
            }
            // A split still waiting for its first guide (or about to take over from the render
            // at a major sync that never came) played the plain 7.1 or silence: say so.
            if self.mode == Mode::Pending && !self.exact && !self.guided && self.unit_frames.is_some() {
                self.mode = Mode::Bed;
                self.fallback_reason.get_or_insert_with(|| "the stream ended before the split had object metadata".into());
            }
            self.drain_split(output)?;
            self.limiter.finish(&mut self.limited);
            self.flush(output)?;
            if let Some((error, _)) = lost {
                return Err(error);
            }
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
        if self.mode == Mode::Bed && self.split.is_none() {
            return Ok(());
        }
        // Audio held with its 7.1 plays as 3.8 played it, the split's plain 7.1, up to here.
        if self.held_frames > 0 && self.held_beds.len() == self.held.len() {
            self.split_held(output)?;
        }
        self.drain_split(output)?;
        self.fallback_reason = Some(reason.into());
        self.mode = Mode::Bed;
        self.switching = true;
        (self.may_rejoin, self.rejoining) = (false, false);
        let sample = self.renderer.sample;
        self.renderer = Renderer::default();
        self.renderer.sample = sample;
        let held = std::mem::take(&mut self.held_frames);
        self.held.clear();
        self.held_beds.clear();
        if held > 0 {
            self.silence(held, output)?;
        }
        self.parser.reset_for_next_major_sync();
        self.decoder.reset_for_next_major_sync();
        Ok(())
    }

    /// A requested bed starts at a major sync, before the parser sees it: `fall_back` restarts
    /// parser and decoder, which start again right at this unit (review r3: restarted after it,
    /// the next units failed to parse, ~100 ms of silence).
    fn apply_bed_request(&mut self, output: &mut impl FnMut(&[f32]) -> Result<(), String>) -> Result<(), String> {
        if let Some(reason) = self.bed_request.take() {
            self.fall_back(&reason, output)?;
            self.switching = false;
        }
        Ok(())
    }

    /// Every substream restarts at a major sync, so the session changes what it decodes there:
    /// the split hands back to the render, and the render stops decoding the 7.1 beside the
    /// objects once it no longer holds audio.
    fn at_major_sync(&mut self, output: &mut impl FnMut(&[f32]) -> Result<(), String>) -> Result<(), String> {
        if std::mem::take(&mut self.rejoining) && self.split.is_some() {
            // The split's last 32 ms out, then the render, holding audio until the metadata in
            // force (it repeats every few tens of milliseconds) as at the start.
            self.drain_split(output)?;
            self.exact = true;
            self.dual = true;
            self.mode = Mode::Pending;
            self.fallback_reason = None;
            // The split that was guided is gone: should the render give way again before its
            // metadata repeats, a new split starts from no guide (review r2).
            self.guided = false;
            self.unguided_frames = 0;
            let sample = self.renderer.sample;
            self.renderer = Renderer::default();
            self.renderer.sample = sample;
        }
        if self.dual && self.mode != Mode::Pending {
            // The objects alone from here, by a decoder restarted at this major sync: carried over
            // from decoding two presentations, the one-presentation decode's PCM differs
            // (measured on film); from a restart it is the same as if it had decoded alone.
            self.dual = false;
            self.decoder.reset_for_next_major_sync();
        }
        Ok(())
    }

    /// The object presentation into `decoded`, and the 7.1 beside it into `bed_unit`.
    fn decode_with_bed(&mut self, au: &truehd::structs::access_unit::AccessUnit) -> Result<(), String> {
        let mut wanted = [false; 4];
        wanted[self.bed_presentation] = true;
        wanted[ATMOS_PRESENTATION] = true;
        let mut decoded = self.decoder.decode_presentations(au, &wanted).map_err(|e| e.to_string())?;
        let (Some(bed), Some(objects)) = (decoded[self.bed_presentation].take(), decoded[ATMOS_PRESENTATION].take()) else {
            return Err("a presentation is missing".into());
        };
        if !bed.is_duplicate {
            self.bed_unit = Some(bed_feeds(&bed));
        }
        self.decoded = objects;
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
        if self.held_frames > 0 {
            // Audio held for its first metadata comes out later: the gap joins it, as silence
            // (with silent 7.1 beside it), so nothing overtakes it.
            let channels = self.held.last().map_or(0, Vec::len);
            if self.held_beds.len() == self.held.len()
                && let Some((bed, labels)) = self.held_beds.last()
            {
                self.held_beds.push((vec![vec![0.; frames]; bed.len()], labels.clone()));
            }
            self.held.push(vec![vec![0.; frames]; channels]);
            self.held_frames += frames;
            return Ok(());
        }
        self.silence(frames, output)
    }

    fn silence(&mut self, frames: usize, output: &mut impl FnMut(&[f32]) -> Result<(), String>) -> Result<(), String> {
        self.renderer.sample += frames as u64;
        self.rendered.clear();
        if let Some(split) = self.split.as_mut() {
            // Through the splitter, which delays what it holds: silence takes its turn.
            split.push(&vec![0.; frames * CHANNELS], &[], frames, &mut self.rendered);
            self.route_split();
        } else {
            self.rendered.resize(frames * CHANNELS, 0.);
        }
        self.limit_and_flush(output)
    }

    /// One access unit of heights from the bed: the bed and object presentations decoded
    /// together (the objects only to learn where their energy lies), the bed routed by its labels
    /// and split.
    fn decode_from_bed(
        &mut self,
        au: &truehd::structs::access_unit::AccessUnit,
        restarting: Option<String>,
        output: &mut impl FnMut(&[f32]) -> Result<(), String>,
    ) -> Result<(), String> {
        let mut wanted = [false; 4];
        wanted[self.bed_presentation] = true;
        wanted[ATMOS_PRESENTATION] = true;
        let decoded = match self.decoder.decode_presentations(au, &wanted) {
            Ok(d) => d,
            Err(e) => return self.lose(restarting, format!("TrueHD decoding: {e}"), output),
        };
        let (Some(bed), Some(objects)) = (&decoded[self.bed_presentation], &decoded[ATMOS_PRESENTATION]) else {
            return self.lose(restarting, "TrueHD decoding: a presentation is missing".into(), output);
        };
        if bed.is_duplicate {
            return Ok(());
        }
        if bed.sampling_frequency != 48_000 {
            return Err("only 48 kHz TrueHD is rendered".into());
        }
        let frames = bed.sample_length;
        let (mut bed_pcm, mut labels) = bed_feeds(bed);
        let mut object_pcm = planar(objects);
        // A channel-based immersive presentation (every channel labelled, 7.1.4-style, no
        // object metadata) is already speaker feeds: it plays as itself, through the splitter
        // without a guide so the timeline is the same, and nothing is split.
        let immersive = objects.channel_labels.len() == object_pcm.len() && objects.oamd.is_empty();
        if immersive {
            labels = objects.channel_labels.iter().map(|l| speaker(*l)).collect();
            bed_pcm = std::mem::take(&mut object_pcm);
        }
        self.play_split(bed_pcm, labels, object_pcm, frames, objects.oamd.last(), immersive, output)
    }

    /// One access unit through the split: the bed routed by its speakers, split by where the
    /// objects' energy lies.
    #[allow(clippy::too_many_arguments)]
    fn play_split(
        &mut self,
        bed_pcm: Vec<Vec<f32>>,
        labels: Vec<Speaker>,
        object_pcm: Vec<Vec<f32>>,
        frames: usize,
        metadata: Option<&ObjectAudioMetadataPayload>,
        immersive: bool,
        output: &mut impl FnMut(&[f32]) -> Result<(), String>,
    ) -> Result<(), String> {
        let split = self.split.get_or_insert_with(BedSplitter::default);
        // Metadata comes every few access units; the last one read stays in force until the
        // next. Anything this reading does not accept leaves no guide: the plain 7.1.
        let mut unreadable = false;
        let mut guided = immersive;
        if let Some(metadata) = metadata {
            let weights = point_weights(metadata, object_pcm.len());
            unreadable = weights.is_none();
            guided = !unreadable;
            split.set_weights(weights.unwrap_or_default());
            if self.may_rejoin && for_each_block(self.layout, self.renderer.sample, metadata, object_pcm.len(), |_| ()).is_ok() {
                self.may_rejoin = false;
                self.rejoining = true;
            }
        } else if immersive {
            split.set_weights(Vec::new());
        }
        for (channel, speaker) in labels.into_iter().enumerate() {
            self.renderer.route(channel, render::bed(speaker));
        }
        let mut routed = Vec::with_capacity(frames * CHANNELS);
        self.renderer.render(&bed_pcm, frames, &mut routed);
        self.rendered.clear();
        split.push(&routed, &object_pcm, frames, &mut self.rendered);
        self.route_split();
        self.unit_frames = Some(frames);
        self.note_guide(guided, frames);
        self.limit_and_flush(output)?;
        if unreadable {
            // This unit already played unsplit; from the next major sync on, the plain bed, and
            // the host is told the heights are gone.
            self.fall_back("object metadata the split does not read (ISF, several beds or a count mismatch)", output)?;
        }
        Ok(())
    }

    /// Heights are reported only once the split has something to go by: until the first object
    /// metadata the mode stays pending (the plain 7.1 plays), and after half a second without
    /// any it reports the bed, until metadata does come.
    fn note_guide(&mut self, guided: bool, frames: usize) {
        if guided || self.guided {
            if !self.guided {
                self.fallback_reason = None;
            }
            self.guided = true;
            self.mode = Mode::Objects;
            return;
        }
        self.unguided_frames += frames;
        if self.unguided_frames > MAX_HELD_FRAMES && self.mode != Mode::Bed {
            self.mode = Mode::Bed;
            self.fallback_reason = Some("no object metadata within 0.5 s; the 7.1 plays without heights".into());
        }
    }

    /// Whatever the splitter still holds, out; the session continues without it.
    fn drain_split(&mut self, output: &mut impl FnMut(&[f32]) -> Result<(), String>) -> Result<(), String> {
        let Some(mut split) = self.split.take() else { return Ok(()) };
        self.rendered.clear();
        split.finish(&mut self.rendered);
        self.route_split();
        self.limit_and_flush(output)
    }

    /// The split's 7.1.4 (`rendered`) into the session's layout, frame by frame.
    fn route_split(&mut self) {
        let Some(rows) = &self.split_routing else { return };
        for frame in self.rendered.chunks_exact_mut(CHANNELS) {
            let mut out = [0.; CHANNELS];
            for (input, row) in frame.iter().zip(rows) {
                if *input != 0. {
                    out.iter_mut().zip(row).for_each(|(o, g)| *o += input * g);
                }
            }
            frame.copy_from_slice(&out);
        }
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
            let labels: Vec<Speaker> = if labelled {
                self.decoded.channel_labels.iter().map(|l| speaker(*l)).collect()
            } else {
                default_speakers(input.len())
            };
            let backs = labels.iter().any(|s| matches!(s, Speaker::Lb | Speaker::Rb));
            for (channel, speaker) in labels.into_iter().enumerate() {
                self.renderer.route(channel, render::bed_in(self.layout, speaker, backs));
            }
            if self.mode == Mode::Pending {
                self.mode = Mode::Objects;
            }
            self.renderer.render(&input, frames, &mut self.rendered);
            return self.limit_and_flush(output);
        }
        {
            let oamd = std::mem::take(&mut self.decoded.oamd);
            let channels = input.len();
            let result = self.emit_objects(&input, frames, &oamd, output);
            self.decoded.oamd = oamd;
            match result {
                Err(Unsupported(reason)) => {
                    // Nothing of this unit was rendered. The split (or the bed) takes over;
                    // metadata the split refuses too (ISF, several beds, a count mismatch) goes
                    // to the bed at once, not via the split's own refusal one major sync later.
                    let split_takes = self.decoded.oamd.iter().all(|m| point_weights(m, channels).is_some());
                    if self.split_fallback && split_takes {
                        // For want of metadata (none within 0.5 s), metadata later brings the
                        // render back; metadata it refused does not.
                        self.may_rejoin = self.decoded.oamd.is_empty();
                        self.leave_exact(&reason, &input, frames, output)
                    } else if self.split_fallback && self.has_7_1() {
                        // With the 7.1 decoded beside the objects, as 3.8: the split plays it up
                        // to and with this unit, then refuses the metadata itself (the bed).
                        self.split_from_here(&input, frames, output)
                    } else {
                        self.fall_back(&reason, output)?;
                        self.silence(frames, output)
                    }
                }
                Ok(r) => r,
            }
        }
    }

    /// The exact render gives way to the split, `input` (this unit) included. Where the 7.1
    /// was decoded beside the objects (`dual`), the split plays it from the first held unit on,
    /// with no gap: a stream without metadata in its first half second plays and reports as in
    /// 3.8. Otherwise the split takes over at the next major sync, and this unit and the audio
    /// held for metadata play as silence, as in `fall_back`. Heights stay: the split reports
    /// them once it has a guide, and the bed after half a second without one.
    fn leave_exact(
        &mut self,
        reason: &str,
        input: &[Vec<f32>],
        frames: usize,
        output: &mut impl FnMut(&[f32]) -> Result<(), String>,
    ) -> Result<(), String> {
        self.exact = false;
        self.fallback_reason = Some(format!("{reason}; heights from the 7.1 split"));
        // Heights again only once the split has a guide (`note_guide`); the bed after half a
        // second without one.
        self.mode = Mode::Pending;
        self.guided = false;
        self.unguided_frames = 0;
        let sample = self.renderer.sample;
        self.renderer = Renderer::default();
        self.renderer.sample = sample;
        if self.has_7_1() {
            return self.split_from_here(input, frames, output);
        }
        self.may_rejoin = false;
        self.switching = true;
        let held = std::mem::take(&mut self.held_frames);
        self.held.clear();
        self.held_beds.clear();
        if held > 0 {
            self.silence(held, output)?;
        }
        self.parser.reset_for_next_major_sync();
        self.decoder.reset_for_next_major_sync();
        self.silence(frames, output)
    }

    /// Whether this unit's 7.1, and every held unit's, was decoded beside the objects.
    fn has_7_1(&self) -> bool {
        self.bed_unit.is_some() && self.held_beds.len() == self.held.len()
    }

    /// The split from the first held unit on (`has_7_1`), this unit included with its metadata.
    fn split_from_here(
        &mut self,
        input: &[Vec<f32>],
        frames: usize,
        output: &mut impl FnMut(&[f32]) -> Result<(), String>,
    ) -> Result<(), String> {
        let (bed, labels) = self.bed_unit.take().expect("has_7_1");
        let sample = self.renderer.sample;
        self.renderer = Renderer::default();
        self.renderer.sample = sample;
        self.split_held(output)?;
        let metadata = self.decoded.oamd.last().cloned();
        self.play_split(bed, labels, input.to_vec(), frames, metadata.as_ref(), false, output)
    }

    /// The held units through the split, from their 7.1 (unguided: they had no metadata).
    fn split_held(&mut self, output: &mut impl FnMut(&[f32]) -> Result<(), String>) -> Result<(), String> {
        self.exact = false;
        self.held_frames = 0;
        let beds = std::mem::take(&mut self.held_beds);
        for (objects, (bed, labels)) in std::mem::take(&mut self.held).into_iter().zip(beds) {
            let frames = bed.first().map_or(0, Vec::len);
            self.play_split(bed, labels, objects, frames, None, false, output)?;
        }
        Ok(())
    }

    fn emit_objects(
        &mut self,
        input: &[Vec<f32>],
        frames: usize,
        oamd: &[ObjectAudioMetadataPayload],
        output: &mut impl FnMut(&[f32]) -> Result<(), String>,
    ) -> Result<Result<(), String>, Unsupported> {
        let channels = input.len();
        let mut events = Vec::new();
        let mut first = Vec::new();
        for metadata in oamd {
            for_each_block(self.layout, self.renderer.sample, metadata, channels, |e| {
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
                self.held.push(input.to_vec());
                if let Some(bed) = self.bed_unit.take() {
                    self.held_beds.push(bed);
                }
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
            self.held_beds.clear();
            // The held units advanced the renderer's clock; schedule against it again.
            events.clear();
            for metadata in oamd {
                for_each_block(self.layout, self.renderer.sample, metadata, channels, |e| events.push(e.event))?;
            }
        }
        for event in events {
            self.renderer.event(event);
        }
        self.renderer.render(input, frames, &mut self.rendered);
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
        let channels = self.channels();
        let result = if channels == CHANNELS {
            output(&self.limited)
        } else {
            // Every layout renders its own channels first in a 7.1.4-wide frame.
            self.compact.clear();
            self.compact.extend(self.limited.chunks_exact(CHANNELS).flat_map(|f| f[..channels].iter().copied()));
            output(&self.compact)
        };
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

fn planar(d: &DecodedAccessUnit) -> Vec<Vec<f32>> {
    (0..d.channel_count).map(|ch| (0..d.sample_length).map(|s| d.pcm_data[s][ch] as f32 / 8_388_608.).collect()).collect()
}

/// A channel presentation's PCM and the speaker of each channel.
fn bed_feeds(bed: &DecodedAccessUnit) -> (Vec<Vec<f32>>, Vec<Speaker>) {
    let pcm = planar(bed);
    let labels = if bed.channel_labels.len() == pcm.len() {
        bed.channel_labels.iter().map(|l| speaker(*l)).collect()
    } else {
        default_speakers(pcm.len())
    };
    (pcm, labels)
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
    layout: Layout,
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
                let backs = beds.iter().any(|b| matches!(BED.get(*b), Some(Lb | Rb)));
                render::bed_in(layout, *BED.get(index).ok_or("unknown bed speaker")?, backs)
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
                let mut gains = render::object_in(layout, &object);
                let trim = trim_gain(trim, channel, render::trim_layout_in(layout, &object), object.position);
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

/// Where each object of one OAMD payload sits at its last update block, as a point: no size,
/// snap, zones, screen anchoring, elevation switch or ramps (the split only needs to know where
/// energy lies). `None` for metadata this reading does not take; the caller then plays the 7.1.
fn point_weights(metadata: &ObjectAudioMetadataPayload, channels: usize) -> Option<Vec<Weight>> {
    let program = &metadata.program_assignment;
    if program.num_isf_objects != 0 || program.bed_assignment.len() > 1 {
        return None;
    }
    let element = metadata.object_element.as_ref()?;
    if metadata.object_count != channels || element.object_data.len() != channels {
        return None;
    }
    let beds = program.bed_assignment.first().map(|b| b.to_index_vec()).unwrap_or_default();
    let positions = metadata.get_damf_pos();
    // Room positions of the OAMD bed channel indices (TS 103 420); the LFEs carry no place.
    const BED: [Option<[f32; 3]>; 17] = [
        Some([0., 0., 0.]),
        Some([1., 0., 0.]),
        Some([0.5, 0., 0.]),
        None,
        Some([0., 0.5, 0.]),
        Some([1., 0.5, 0.]),
        Some([0., 1., 0.]),
        Some([1., 1., 0.]),
        Some([0.25, 0.25, 1.]),
        Some([0.75, 0.25, 1.]),
        Some([0.25, 0.5, 1.]),
        Some([0.75, 0.5, 1.]),
        Some([0.25, 0.75, 1.]),
        Some([0.75, 0.75, 1.]),
        Some([0., 0.2929, 0.]),
        Some([1., 0.2929, 0.]),
        None,
    ];
    (0..channels)
        .map(|channel| {
            let blocks = &element.object_data[channel];
            let last = blocks.len().checked_sub(1)?;
            let block = &blocks[last];
            if block.b_object_not_active || block.object_basic_info.object_gain == -128 {
                return Some(Weight::default());
            }
            let gain = 10f32.powf(block.object_basic_info.object_gain as f32 / 20.);
            let position = if block.b_object_in_bed_or_isf {
                match BED.get(*beds.get(channel)?)? {
                    Some(p) => *p,
                    None => return Some(Weight::default()),
                }
            } else {
                let [x, y, z] = *positions.get(channel)?.get(last)?;
                if ![x, y, z].iter().all(|v| v.is_finite()) {
                    return None;
                }
                // DAMF coordinates to TS 103 448 room coordinates.
                [x / 2. + 0.5, 0.5 - y / 2., z].map(|v| v as f32)
            };
            Some(Weight::at(position, gain))
        })
        .collect()
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
        for_each_block(Layout::L714, 0, metadata, 1, |e| out = Some(e.gains))?;
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
    fn the_shipped_session_leaves_unplaceable_metadata_to_the_split() {
        // Bed channel distribution: the exact render does not place it, the split reads past it;
        // the shipped session hands the stream to the split (heights stay), the measurement one
        // to the bed. Mid-stream, without the 7.1 beside the objects (`bed_unit` unset), the
        // switch waits for the next major sync; with it, see `run`'s tests below.
        let mut distributed = point([0., 0., 1.]);
        distributed.program_assignment.b_bed_chan_distribute = true;
        let mut sink = |_: &[f32]| Ok(());
        for (mut session, split) in [(Session::exact_with_split_fallback(), true), (Session::exact(), false)] {
            session.decoded.oamd = vec![distributed.clone()];
            session.emit(vec![vec![0.1; 40]], 40, &mut sink).unwrap();
            assert_eq!(session.exact, !split);
            assert_eq!(session.mode(), if split { Mode::Pending } else { Mode::Bed }, "the split reports once guided");
            assert!(session.switching, "the switch waits for the next major sync");
            assert!(session.fallback_reason.as_deref().unwrap().contains("bed channel distribution"));
        }
    }

    #[test]
    fn metadata_both_layers_refuse_goes_straight_to_the_bed() {
        // A count mismatch: the render refuses it and so would the split.
        let mut mismatch = point([0., 0., 1.]);
        mismatch.object_count = 2;
        let mut session = Session::exact_with_split_fallback();
        session.decoded.oamd = vec![mismatch];
        let mut sink = |_: &[f32]| Ok(());
        session.emit(vec![vec![0.1; 40]], 40, &mut sink).unwrap();
        assert_eq!(session.mode(), Mode::Bed);
    }

    #[test]
    fn a_session_that_ends_waiting_for_the_split_reports_the_bed() {
        let mut distributed = point([0., 0., 1.]);
        distributed.program_assignment.b_bed_chan_distribute = true;
        let mut session = Session::exact_with_split_fallback();
        session.decoded.oamd = vec![distributed];
        let mut sink = |_: &[f32]| Ok(());
        session.emit(vec![vec![0.1; 40]], 40, &mut sink).unwrap();
        assert_eq!(session.mode(), Mode::Pending, "bed channel distribution: the split takes it");
        session.unit_frames = Some(40);
        session.push(&[], true, &mut sink).unwrap();
        assert_eq!(session.mode(), Mode::Bed);
    }

    #[test]
    fn the_split_tail_reaches_another_layout_routed_even_through_concealment() {
        // A second of the 7.1.4 split's back-left (slot 6) in a 5.1.2 session, then concealment:
        // what the splitter still held comes out folded into Ls (slot 4), never in a top middle.
        let mut session = Session::default().in_layout(Layout::L512);
        session.split = Some(BedSplitter::default());
        let mut frames = vec![0f32; 48_000 * CHANNELS];
        frames.iter_mut().skip(6).step_by(CHANNELS).enumerate().for_each(|(n, x)| *x = (n as f32 * 0.05).sin() * 0.3);
        session.rendered.clear();
        session.split.as_mut().unwrap().push(&frames, &[], 48_000, &mut session.rendered);
        session.route_split();
        session.limit_and_flush(&mut |_: &[f32]| Ok(())).unwrap();
        let mut tail = Vec::new();
        session
            .silence(4_096, &mut |pcm: &[f32]| {
                tail.extend_from_slice(pcm);
                Ok(())
            })
            .unwrap();
        let energy = |c: usize| tail.iter().skip(c).step_by(8).map(|x| f64::from(*x).powi(2)).sum::<f64>();
        assert!(energy(4) > 1., "the held back-left comes out in Ls: {}", energy(4));
        assert_eq!(energy(6) + energy(7), 0., "nothing of it in the top middles");
    }

    #[test]
    fn a_requested_bed_applies_at_the_next_major_sync() {
        let mut session = Session::exact_with_split_fallback();
        session.request_bed("the renderer fell behind real time");
        let mut sink = |_: &[f32]| Ok(());
        session.push(&[], false, &mut sink).unwrap();
        assert_eq!(session.mode(), Mode::Pending, "what plays goes on until the next major sync");
        session.apply_bed_request(&mut sink).unwrap();
        assert_eq!(session.mode(), Mode::Bed);
        assert!(!session.switching, "the bed starts at that major sync, no silence");
        assert!(session.fallback_reason.as_deref().unwrap().contains("fell behind"));
    }

    // Synthetic streams for the timeline tests: 40-sample access units, a major sync every 32,
    // one object at the front-left ceiling whose signal is also the 7.1's L (the bed is the
    // objects' floor projection). The signal is low noise with a 0.9 click every 1000 samples:
    // the clicks must come out exactly where they went in, whatever renders them.
    const UNIT: usize = 40;
    const SYNC_EVERY: usize = 32;

    fn signal(at: usize) -> f32 {
        let noise = ((at as u32).wrapping_mul(2_654_435_761) >> 8) as f32 / (1u32 << 24) as f32 - 0.5;
        if at % 1000 == 500 { 0.9 } else { 0.1 * noise }
    }

    /// What one unit's output and the mode after it look like.
    struct Run {
        pcm: Vec<f32>,
        modes: Vec<Mode>,
        exact_at_end: bool,
        mode_at_end: Mode,
        result: Result<(), String>,
    }

    /// `units` access units through `session`, as `push` hands decoded ones on (the render gets
    /// the objects, with the 7.1 beside them while `dual`; the split and the bed get the 7.1):
    /// `metadata(unit)` says whether a unit carries OAMD, `bed_at` asks for the bed before a unit.
    fn run(session: Session, units: usize, metadata: impl Fn(usize) -> Option<ObjectAudioMetadataPayload>, bed_at: Option<usize>) -> Run {
        let run = run_losing(session, units, metadata, bed_at, |_| false);
        assert!(run.result.is_ok(), "{:?}", run.result);
        run
    }

    /// `run`, where `lost(unit)` makes a unit fail to decode (`lose`, as `push` does).
    fn run_losing(
        mut session: Session,
        units: usize,
        metadata: impl Fn(usize) -> Option<ObjectAudioMetadataPayload>,
        bed_at: Option<usize>,
        lost: impl Fn(usize) -> bool,
    ) -> Run {
        let mut pcm = Vec::new();
        let mut modes = Vec::new();
        let mut sink = |block: &[f32]| {
            pcm.extend_from_slice(block);
            Ok(())
        };
        for unit in 0..units {
            if bed_at == Some(unit) {
                session.request_bed("the chain fell behind");
            }
            let sync = unit % SYNC_EVERY == 0;
            let objects: Vec<Vec<f32>> = vec![(unit * UNIT..(unit + 1) * UNIT).map(signal).collect()];
            let mut bed = vec![vec![0.; UNIT]; 8];
            bed[0] = objects[0].clone();
            let oamd = metadata(unit);
            if !sync && (session.lost.is_some() || session.switching) {
                session.conceal(&mut sink).unwrap();
            } else {
                session.switching = false;
                let restarting = session.lost.take().map(|(error, _)| error);
                if sync {
                    session.apply_bed_request(&mut sink).unwrap();
                    session.at_major_sync(&mut sink).unwrap();
                }
                if lost(unit) {
                    session.lose(restarting, "lost".into(), &mut sink).unwrap();
                } else if !session.renders_objects() && (session.mode != Mode::Bed || session.split.is_some()) {
                    session.play_split(bed, default_speakers(8), objects, UNIT, oamd.as_ref(), false, &mut sink).unwrap();
                } else {
                    let bed_mode = session.mode == Mode::Bed;
                    session.bed_unit = (session.dual && !bed_mode).then(|| (bed.clone(), default_speakers(8)));
                    session.decoded.oamd = if bed_mode { Vec::new() } else { oamd.into_iter().collect() };
                    session.unit_frames = Some(UNIT);
                    session.emit(if bed_mode { bed } else { objects }, UNIT, &mut sink).unwrap();
                }
            }
            modes.push(session.mode());
        }
        let result = session.push(&[], true, &mut sink);
        Run { pcm, modes, exact_at_end: session.exact, mode_at_end: session.mode(), result }
    }

    fn from(units: usize) -> impl Fn(usize) -> Option<ObjectAudioMetadataPayload> {
        move |unit| (unit >= units).then(|| point([0., 0., 1.]))
    }

    fn first(modes: &[Mode], mode: Mode) -> Option<usize> {
        modes.iter().position(|m| *m == mode)
    }

    /// Every input sample comes out once, in place: the same length, each click on its own
    /// sample, and (outside `gap`) no 10 ms of silence.
    fn assert_in_place(run: &Run, units: usize, gap: Option<std::ops::Range<usize>>) {
        let frames = run.pcm.len() / CHANNELS;
        assert_eq!(frames, units * UNIT, "every input sample comes out exactly once");
        let energy = |i: usize| run.pcm[i * CHANNELS..(i + 1) * CHANNELS].iter().map(|x| x * x).sum::<f32>();
        for click in (500..frames).step_by(1000) {
            if gap.as_ref().is_some_and(|g| g.contains(&click)) {
                continue;
            }
            let peak = (click - 200..(click + 200).min(frames)).max_by(|a, b| energy(*a).total_cmp(&energy(*b))).unwrap();
            assert_eq!(peak, click, "the click at {click} came out at {peak}");
        }
        for window in (0..frames).step_by(480) {
            if gap.as_ref().is_some_and(|g| g.contains(&window) || g.contains(&(window + 479))) {
                continue;
            }
            let e: f32 = (window..(window + 480).min(frames)).map(energy).sum();
            assert!(e > 1e-3, "silence at {window} ({:.1} ms)", window as f64 / 48.);
        }
    }

    fn assert_same(a: &[f32], b: &[f32]) {
        assert_eq!(a.len(), b.len());
        if let Some(i) = a.iter().zip(b).position(|(x, y)| x != y) {
            panic!("differs from frame {} (channel {}): {} vs {}", i / CHANNELS, i % CHANNELS, a[i], b[i]);
        }
    }

    #[test]
    fn a_loss_while_audio_is_held_keeps_its_place() {
        // Units 20–22 lost while the first 20 are held for metadata (which comes at unit 32, a
        // major sync): the held audio comes out first, the loss as silence after it.
        let lost = run_losing(Session::exact_with_split_fallback(), 100, from(32), None, |u| u == 20);
        assert!(lost.result.is_ok());
        assert!(lost.exact_at_end);
        assert_in_place(&lost, 100, Some(20 * UNIT..32 * UNIT));
        assert!(lost.pcm[20 * UNIT * CHANNELS..32 * UNIT * CHANNELS].iter().all(|x| x.abs() < 0.02));
    }

    #[test]
    fn a_stream_ending_in_a_loss_still_releases_what_came_before() {
        // The last unit fails: an error, but the limiter's 2 ms (and the split's 32 ms) before it
        // come out, so the audio keeps its length.
        for open in [Session::exact_with_split_fallback as fn() -> Session, Session::default] {
            let lost = run_losing(open(), 100, from(0), None, |u| u == 99);
            assert!(lost.result.is_err());
            assert_in_place(&lost, 100, Some(99 * UNIT..100 * UNIT));
        }
    }

    #[test]
    fn no_metadata_in_the_first_half_second_plays_and_reports_as_the_split_did() {
        // Review r4 of #170: such a stream played 0.5 s of silence and reported the bed after
        // 1 s. It must play from its first sample, report the bed when 3.8's split did (once
        // more than 0.5 s went by without metadata), and, when metadata comes, heights.
        let units = 2400;
        for metadata_from in [900, usize::MAX] {
            let shipped = run(Session::exact_with_split_fallback(), units, from(metadata_from), None);
            let split = run(Session::default(), units, from(metadata_from), None);
            assert_in_place(&shipped, units, None);
            // Onset: the first click (10 ms in) is in place, and until the render takes over again
            // (the major sync after the metadata) the output is the split as 3.8 played it,
            // sample for sample, short of the split's last 2048 samples there: they see silence
            // after them.
            let rejoin = metadata_from.min(units).next_multiple_of(SYNC_EVERY).min(units);
            let until = (rejoin * UNIT - crate::split::FFT) * CHANNELS;
            assert_same(&shipped.pcm[..until], &split.pcm[..until]);
            // The bed is reported after the same unit: the 601st (24 040 samples > 0.5 s).
            assert_eq!(first(&shipped.modes, Mode::Bed), Some(600));
            assert_eq!(first(&split.modes, Mode::Bed), Some(600));
            if metadata_from == usize::MAX {
                assert_same(&shipped.pcm, &split.pcm);
                assert_eq!(shipped.modes, split.modes);
                assert_eq!(*shipped.modes.last().unwrap(), Mode::Bed);
            } else {
                // Heights as soon as metadata comes (the split, guided), then the render again
                // from the next major sync.
                assert_eq!(first(&shipped.modes[600..], Mode::Objects).map(|u| u + 600), Some(metadata_from));
                assert_eq!(first(&split.modes[600..], Mode::Objects).map(|u| u + 600), Some(metadata_from));
                assert_eq!(*shipped.modes.last().unwrap(), Mode::Objects);
                assert!(shipped.exact_at_end, "the render took over again");
            }
        }
    }

    #[test]
    fn a_stream_ending_while_the_render_waits_to_take_back_over_reports_the_bed() {
        // Review r2: metadata once, at unit 900; the render takes over at 928 and holds for
        // metadata that never repeats; the stream ends at 940. Those units play as the plain 7.1
        // of a fresh split, so the session must not report heights for them.
        let once = |unit: usize| (unit == 900).then(|| point([0., 0., 1.]));
        let ended = run(Session::exact_with_split_fallback(), 940, once, None);
        assert_in_place(&ended, 940, None);
        assert_eq!(ended.modes[927], Mode::Objects, "heights from the split until the render takes over");
        assert_eq!(ended.mode_at_end, Mode::Bed);
    }

    #[test]
    fn no_metadata_at_first_hands_over_the_same_way_in_every_layout() {
        // The held 7.1 through the split, routed into the layout: what that layout's split plays
        // from the first sample, with the bed reported after the same unit.
        for layout in [Layout::L512, Layout::L514, Layout::L712] {
            let shipped = run(Session::exact_with_split_fallback().in_layout(layout), 800, from(usize::MAX), None);
            let split = run(Session::default().in_layout(layout), 800, from(usize::MAX), None);
            assert_eq!(shipped.pcm.len(), 800 * UNIT * layout.channels(), "{layout:?}");
            assert_same(&shipped.pcm, &split.pcm);
            assert_eq!(first(&shipped.modes, Mode::Bed), Some(600), "{layout:?}");
        }
    }

    #[test]
    fn a_stream_ending_before_its_first_metadata_plays_its_7_1() {
        let shipped = run(Session::exact_with_split_fallback(), 300, from(usize::MAX), None);
        let split = run(Session::default(), 300, from(usize::MAX), None);
        assert_in_place(&shipped, 300, None);
        assert_same(&shipped.pcm, &split.pcm);
        assert_eq!(*shipped.modes.last().unwrap(), Mode::Pending);
    }

    #[test]
    fn a_refusal_before_the_render_stops_decoding_the_7_1_switches_at_once() {
        // Review r1: metadata from unit 6 (the held units render), refused from unit 10 — still
        // before the major sync (32) where the render stops decoding the 7.1 beside it. The split
        // takes over at unit 10 itself, with no silence.
        let refused_from_10 = |unit: usize| {
            (unit >= 6).then(|| {
                let mut m = point([0., 0., 1.]);
                m.program_assignment.b_bed_chan_distribute = unit >= 10;
                m
            })
        };
        let shipped = run(Session::exact_with_split_fallback(), 200, refused_from_10, None);
        assert_in_place(&shipped, 200, None);
        assert!(!shipped.exact_at_end);
        assert!(shipped.modes[10..].iter().all(|m| *m == Mode::Objects), "heights from the split");
    }

    #[test]
    fn metadata_both_layers_refuse_during_the_hold_plays_as_3_8() {
        // Review r1: ISF in the first metadata (unit 6), and a bed asked for during the hold: the
        // held 7.1 plays, then the bed, exactly as 3.8's split played the same stream.
        let isf = |unit: usize| {
            (unit >= 6).then(|| {
                let mut m = point([0., 0., 1.]);
                m.program_assignment.num_isf_objects = 1;
                m
            })
        };
        let shipped = run(Session::exact_with_split_fallback(), 200, isf, None);
        let split = run(Session::default(), 200, isf, None);
        assert_same(&shipped.pcm, &split.pcm);
        assert_eq!(shipped.modes, split.modes);
        assert_eq!(*shipped.modes.last().unwrap(), Mode::Bed);
        let shipped = run(Session::exact_with_split_fallback(), 200, from(usize::MAX), Some(10));
        let split = run(Session::default(), 200, from(usize::MAX), Some(10));
        assert_same(&shipped.pcm, &split.pcm);
        assert_in_place(&shipped, 200, None);
        assert_eq!(first(&shipped.modes, Mode::Bed), Some(32));
    }

    #[test]
    fn early_metadata_the_render_refuses_hands_the_held_audio_to_the_split() {
        // Bed channel distribution in the first metadata, five units in: no silence either.
        let refused = |unit: usize| {
            (unit >= 5).then(|| {
                let mut m = point([0., 0., 1.]);
                m.program_assignment.b_bed_chan_distribute = true;
                m
            })
        };
        let shipped = run(Session::exact_with_split_fallback(), 200, refused, None);
        let split = run(Session::default(), 200, refused, None);
        assert_in_place(&shipped, 200, None);
        assert_same(&shipped.pcm, &split.pcm);
        assert_eq!(first(&shipped.modes, Mode::Objects), Some(5));
        assert!(!shipped.exact_at_end, "metadata the render refused does not bring it back");
    }

    #[test]
    fn switches_keep_every_sample_in_place() {
        // The heights' timestamps are the epoch's anchor plus a sample count (`HeightsBridge`),
        // so a path or a switch that dropped, added or delayed samples would shift the audio
        // against the video. Each path and each switch keeps every sample on its own index.
        let units = 2000;
        // (a) the render throughout, (b) 3.8's split throughout.
        let exact = run(Session::exact_with_split_fallback(), units, from(0), None);
        assert_in_place(&exact, units, None);
        assert!(exact.exact_at_end && exact.modes.iter().all(|m| *m == Mode::Objects));
        // The shipped session's logic against the exact render's (the decoder's PCM is pinned by
        // `the_shipped_session_renders_*` in tests/vectors.rs, on real streams).
        assert_same(&exact.pcm, &run(Session::exact(), units, from(0), None).pcm);
        let split = run(Session::default(), units, from(0), None);
        assert_in_place(&split, units, None);
        // (c) the load guard's bed, from the render and from the split: at the next major sync,
        // with no gap.
        for open in [Session::exact_with_split_fallback as fn() -> Session, Session::default] {
            let guarded = run(open(), units, from(0), Some(1000));
            assert_in_place(&guarded, units, None);
            assert_eq!(first(&guarded.modes, Mode::Bed), Some(1024), "the major sync after the request");
        }
        // The split taking over for want of metadata, and the render taking over again when it
        // comes (the major sync after unit 900): see also the test above.
        let rejoined = run(Session::exact_with_split_fallback(), units, from(900), None);
        assert_in_place(&rejoined, units, None);
        // Metadata the render refuses mid-stream: the split from the next major sync; until then
        // silence of the units' own length, every later sample still in place.
        let refused = |unit: usize| {
            let mut m = point([0., 0., 1.]);
            m.program_assignment.b_bed_chan_distribute = unit >= 1000;
            Some(m)
        };
        let left = run(Session::exact_with_split_fallback(), units, refused, None);
        assert_in_place(&left, units, Some(1000 * UNIT..1024 * UNIT));
        let gap = &left.pcm[1000 * UNIT * CHANNELS..1024 * UNIT * CHANNELS];
        assert!(gap.iter().all(|x| x.abs() < 0.02), "silence (the limiter's 2 ms tail aside)");
    }

    #[test]
    fn heights_are_reported_only_with_a_guide() {
        let mut session = Session::default();
        session.split = Some(BedSplitter::default());
        // Object audio without metadata: pending, then the bed after half a second.
        for _ in 0..600 {
            session.note_guide(false, 40);
        }
        assert_eq!(session.mode(), Mode::Pending);
        session.note_guide(false, 40);
        assert_eq!(session.mode(), Mode::Bed);
        assert!(session.fallback_reason.as_deref().unwrap().contains("no object metadata"));
        // Metadata after all: heights, for good.
        session.note_guide(true, 40);
        assert_eq!(session.mode(), Mode::Objects);
        assert!(session.fallback_reason.is_none());
        session.note_guide(false, 40);
        assert_eq!(session.mode(), Mode::Objects);
    }

    #[test]
    fn metadata_the_split_does_not_read_gives_no_guide() {
        let mut isf = ObjectAudioMetadataPayload { object_count: 1, ..Default::default() };
        isf.program_assignment.num_isf_objects = 1;
        assert!(point_weights(&isf, 1).is_none());
        // No object element at all: nothing to place either.
        let empty = ObjectAudioMetadataPayload { object_count: 1, ..Default::default() };
        assert!(point_weights(&empty, 1).is_none());
    }

    #[test]
    fn garbage_is_an_error_not_a_panic() {
        let mut session = Session::default();
        let mut sink = |_: &[f32]| Ok(());
        let junk: Vec<u8> = (0..70_000u32).map(|i| (i.wrapping_mul(2654435761) >> 24) as u8).collect();
        assert!(session.push(&junk, true, &mut sink).is_err());
    }
}
