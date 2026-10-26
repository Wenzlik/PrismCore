// Copyright 2026 PrismCore contributors. Apache License 2.0 (see LICENSE-APACHE).
//
// Runs the truehd crate's own small public test streams through the session. They are not
// redistributable here, so the test reads them from the pinned checkout Cargo fetched:
//
//   TRUEHD_OBJECTS_VECTORS="$CARGO_HOME/git/checkouts/truehdd-*/5c8b880/truehd/tests/assets" cargo test
//
// Without the variable the test passes without asserting anything.

use truehd_objects::{
    decode::{Mode, Session},
    render::Layout,
};

fn decode(name: &str, chunk: usize) -> Option<(Result<(), String>, Vec<f32>, Mode)> {
    decode_with(name, chunk, Session::default)
}

fn decode_with(name: &str, chunk: usize, open: fn() -> Session) -> Option<(Result<(), String>, Vec<f32>, Mode)> {
    let dir = std::env::var("TRUEHD_OBJECTS_VECTORS").ok()?;
    let data = std::fs::read(std::path::Path::new(&dir).join(name)).expect("vector");
    let mut session = open();
    let mut pcm = Vec::new();
    let mut sink = |block: &[f32]| {
        pcm.extend_from_slice(block);
        Ok(())
    };
    let result = (|| {
        for bytes in data.chunks(chunk) {
            session.push(bytes, false, &mut sink)?;
        }
        session.push(&[], true, &mut sink)
    })();
    Some((result, pcm, session.mode()))
}

fn energy(pcm: &[f32], channel: usize) -> f64 {
    pcm.iter().skip(channel).step_by(12).map(|x| f64::from(*x).powi(2)).sum()
}

#[test]
fn atmos_vector_renders_objects_and_is_independent_of_chunking() {
    let Some((result, pcm, mode)) = decode("fba_atmos_obj.mlp", 4096) else { return };
    assert!(result.is_ok(), "{result:?}");
    assert_eq!(mode, Mode::Objects);
    assert!(!pcm.is_empty() && pcm.len() % 12 == 0);
    assert!(pcm.iter().all(|x| x.is_finite() && x.abs() <= 1.));
    let (_, again, _) = decode("fba_atmos_obj.mlp", 317).unwrap();
    assert_eq!(pcm, again, "output must not depend on how the bytes are split");
    let per_channel: Vec<f64> = (0..12).map(|c| energy(&pcm, c)).collect();
    println!("fba_atmos_obj: {} frames, channel energy {per_channel:?}", pcm.len() / 12);
}

#[test]
fn each_presentation_kind_takes_its_path() {
    // cbi: a channel-based immersive presentation (labelled 7.1.4.2-style channels, no OAMD);
    // dimtrim: objects with trim metadata; spliced: a 2-channel stream joined mid-way.
    for (name, expected) in [("fba_atmos_cbi.mlp", Mode::Objects), ("fba_atmos_dimtrim.mlp", Mode::Objects), ("fba_spliced.mlp", Mode::Bed)] {
        let Some((result, pcm, mode)) = decode(name, 4096) else { return };
        println!("{name}: {mode:?}, {} frames", pcm.len() / 12);
        assert!(result.is_ok(), "{name}: {result:?}");
        assert_eq!(mode, expected, "{name}");
    }
}

#[test]
fn the_shipped_session_renders_the_objects_exactly() {
    // The public object vector has nothing the exact render refuses: the shipped session is the
    // exact render, sample for sample.
    let Some((result, pcm, mode)) = decode_with("fba_atmos_obj.mlp", 4096, Session::exact_with_split_fallback) else { return };
    assert!(result.is_ok(), "{result:?}");
    assert_eq!(mode, Mode::Objects);
    assert_eq!(pcm, decode_with("fba_atmos_obj.mlp", 4096, Session::exact).unwrap().1);
}

#[test]
fn a_stream_without_objects_falls_back_to_its_bed() {
    let Some((result, pcm, mode)) = decode("fbb_6ch.mlp", 4096) else { return };
    assert!(result.is_ok(), "{result:?}");
    assert_eq!(mode, Mode::Bed);
    // Heights stay silent; the bed carries the audio.
    assert!((8..12).all(|c| energy(&pcm, c) == 0.));
    assert!((0..8).map(|c| energy(&pcm, c)).sum::<f64>() > 0.);
}

#[test]
fn heights_keep_the_timeline_and_fall_back_to_the_plain_bed() {
    for name in ["fba_atmos_dimtrim.mlp", "fba_atmos_cbi.mlp", "fba_spliced.mlp", "fbb_6ch.mlp"] {
        let Some((result, pcm, mode)) = decode(name, 4096) else { return };
        assert!(result.is_ok(), "{name}: {result:?}");
        assert!(pcm.iter().all(|x| x.is_finite() && x.abs() <= 1.), "{name}");
        let (_, again, _) = decode(name, 317).unwrap();
        assert_eq!(pcm, again, "{name}: independent of chunking");
        {
            let (_, exact, _) = decode_with(name, 4096, Session::exact).unwrap();
            assert_eq!(pcm.len(), exact.len(), "{name}: same length as the exact render");
        }
        println!("{name}: {mode:?}");
    }
    // No objects: the plain bed, heights silent.
    let (_, pcm, mode) = decode("fbb_6ch.mlp", 4096).unwrap();
    assert_eq!(mode, Mode::Bed);
    assert!((8..12).all(|c| energy(&pcm, c) == 0.));
    assert_eq!(pcm, decode_with("fbb_6ch.mlp", 4096, Session::exact).unwrap().1, "exactly the exact render's fallback");
    // Channel-based immersive: it plays as its own speaker feeds, as the exact render routes
    // them (the public vector's content is all in L, so this pins the routing, not heights).
    let (_, cbi, _) = decode("fba_atmos_cbi.mlp", 4096).unwrap();
    assert!(energy(&cbi, 0) > 0.);
    {
        let (_, exact, _) = decode_with("fba_atmos_cbi.mlp", 4096, Session::exact).unwrap();
        let worst = cbi.iter().zip(&exact).map(|(a, b)| (a - b).abs()).fold(0f32, f32::max);
        assert!(worst < 1e-4, "CBI through the splitter is the routed presentation: {worst}");
    }
}

#[cfg(target_vendor = "apple")]
unsafe extern "C" {
    fn clock_gettime_nsec_np(clock: u32) -> u64;
}

/// CPU seconds of this thread (CLOCK_THREAD_CPUTIME_ID): a loaded machine still measures the work.
#[cfg(target_vendor = "apple")]
fn cpu() -> f64 {
    unsafe { clock_gettime_nsec_np(16) as f64 / 1e9 }
}

/// Heights from the bed against the exact object render, on the same stream: how much of the
/// energy lands on another speaker, per channel and over windows, plus CPU and the input it
/// takes before the first output. Measurement only (prints; asserts nothing about quality).
/// Extra raw TrueHD files (`-f truehd`): `TRUEHD_OBJECTS_COMPARE=/a.thd:/b.thd`. Apple
/// platforms only (the thread CPU clock).
#[cfg(target_vendor = "apple")]
#[test]
fn compare_heights_with_the_exact_render() {
    let mut files: Vec<std::path::PathBuf> = Vec::new();
    if let Ok(dir) = std::env::var("TRUEHD_OBJECTS_VECTORS") {
        for name in ["fba_atmos_obj.mlp", "fba_atmos_dimtrim.mlp"] {
            files.push(std::path::Path::new(&dir).join(name));
        }
    }
    if let Ok(list) = std::env::var("TRUEHD_OBJECTS_COMPARE") {
        files.extend(list.split(':').filter(|s| !s.is_empty()).map(std::path::PathBuf::from));
    }
    const NAMES: [&str; 12] = ["L", "R", "C", "LFE", "Ls", "Rs", "Lb", "Rb", "Tfl", "Tfr", "Tbl", "Tbr"];
    for path in files {
        let data = std::fs::read(&path).expect("stream");
        let run = |mut session: Session| {
            let mut pcm = Vec::new();
            let mut first: Option<usize> = None;
            let start = cpu();
            let mut fed = 0;
            for bytes in data.chunks(4096) {
                fed += bytes.len();
                session
                    .push(bytes, false, &mut |b: &[f32]| {
                        pcm.extend_from_slice(b);
                        Ok(())
                    })
                    .unwrap();
                if first.is_none() && !pcm.is_empty() {
                    first = Some(fed);
                }
            }
            session.push(&[], true, &mut |b: &[f32]| {
                pcm.extend_from_slice(b);
                Ok(())
            })
            .unwrap();
            (pcm, cpu() - start, first.unwrap_or(fed), session.mode())
        };
        let (exact, exact_time, exact_first, exact_mode) = run(Session::exact());
        let (bed, bed_time, bed_first, bed_mode) = run(Session::default());
        assert_eq!(exact.len(), bed.len(), "both keep the stream's length");
        let frames = exact.len() / 12;
        let seconds = frames as f64 / 48_000.;
        let total = |pcm: &[f32]| -> Vec<f64> { (0..12).map(|c| energy(pcm, c)).collect() };
        let (e, b) = (total(&exact), total(&bed));
        let (se, sb) = (e.iter().sum::<f64>(), b.iter().sum::<f64>());
        if se == 0. || sb == 0. {
            println!("\n{}: silent, nothing to compare", path.display());
            continue;
        }
        println!("\n{} ({:.2} s; exact {exact_mode:?}, from bed {bed_mode:?})", path.file_name().unwrap().to_string_lossy(), seconds);
        println!("  channel   exact %   bed %   diff dB");
        for c in 0..12 {
            let (pe, pb) = (e[c] / se * 100., b[c] / sb * 100.);
            println!("  {:>4}   {:>8.2}  {:>7.2}  {:>+7.2}", NAMES[c], pe, pb, 10. * ((b[c] + 1e-12) / (e[c] + 1e-12)).log10());
        }
        // Energy on another speaker: half the L1 distance between the two distributions, per
        // 0.25 s window, over windows where the exact render has heights (> 1 % of energy).
        let window = 12_000;
        let mut moved = Vec::new();
        let mut height_db = Vec::new();
        for w in 0..frames / window {
            let slice = |pcm: &[f32]| total(&pcm[w * window * 12..(w + 1) * window * 12]);
            let (we, wb) = (slice(&exact), slice(&bed));
            let (te, tb) = (we.iter().sum::<f64>(), wb.iter().sum::<f64>());
            if te <= 0. || tb <= 0. || we[8..].iter().sum::<f64>() / te < 0.01 {
                continue;
            }
            moved.push(0.5 * (0..12).map(|c| (we[c] / te - wb[c] / tb).abs()).sum::<f64>() * 100.);
            height_db.push(10. * (wb[8..].iter().sum::<f64>() / we[8..].iter().sum::<f64>()).log10());
        }
        moved.sort_by(f64::total_cmp);
        height_db.sort_by(f64::total_cmp);
        let pick = |v: &[f64], q: f64| v.get(((v.len() as f64 - 1.) * q).round() as usize).copied().unwrap_or(f64::NAN);
        let no_lfe = |v: &[f64]| -> Vec<f64> {
            let s: f64 = v.iter().enumerate().filter(|(c, _)| *c != 3).map(|(_, x)| x).sum();
            v.iter().enumerate().map(|(c, x)| if c == 3 { 0. } else { x / s }).collect()
        };
        let (ne, nb) = (no_lfe(&e), no_lfe(&b));
        println!("  energy on another speaker without the LFE: {:.2} %", 0.5 * (0..12).map(|c| (ne[c] - nb[c]).abs()).sum::<f64>() * 100.);
        let whole = 0.5 * (0..12).map(|c| (e[c] / se - b[c] / sb).abs()).sum::<f64>() * 100.;
        let heights = |v: &[f64], s: f64| v[8..].iter().sum::<f64>() / s * 100.;
        println!(
            "  energy on another speaker: whole {whole:.2} %, windows with heights {} of {} (median {:.2} %, p90 {:.2} %, max {:.2} %); heights from bed vs exact per window: median {:+.2} dB (p10 {:+.2}, p90 {:+.2})",
            moved.len(),
            frames / window,
            pick(&moved, 0.5),
            pick(&moved, 0.9),
            pick(&moved, 1.),
            pick(&height_db, 0.5),
            pick(&height_db, 0.1),
            pick(&height_db, 0.9)
        );
        println!("  heights share: exact {:.2} %, from bed {:.2} %; total level bed/exact {:+.2} dB", heights(&e, se), heights(&b, sb), 10. * (sb / se).log10());
        println!(
            "  CPU (this thread) per second of audio: exact {:.2} ms, from bed {:.2} ms; input before the first output: exact {exact_first} B, from bed {bed_first} B",
            exact_time * 1e3 / seconds,
            bed_time * 1e3 / seconds
        );
    }
}

#[test]
fn every_layout_renders_the_same_timeline_and_energy() {
    // The object vector rendered (and the dimtrim vector split) into each layout: the same
    // frames, the layout's channel count, the LFE untouched, and the energy within 1 dB.
    for (name, open) in [("fba_atmos_obj.mlp", Session::exact_with_split_fallback as fn() -> Session), ("fba_atmos_dimtrim.mlp", Session::default)] {
        let Some((_, reference, _)) = decode_with(name, 4096, open) else { return };
        let frames = reference.len() / 12;
        let total = |pcm: &[f32]| pcm.iter().map(|x| f64::from(*x).powi(2)).sum::<f64>();
        for layout in [Layout::L512, Layout::L514, Layout::L712, Layout::L714] {
            let dir = std::env::var("TRUEHD_OBJECTS_VECTORS").unwrap();
            let data = std::fs::read(std::path::Path::new(&dir).join(name)).unwrap();
            let mut session = open().in_layout(layout);
            let mut pcm = Vec::new();
            for bytes in data.chunks(4096) {
                session.push(bytes, false, &mut |b: &[f32]| { pcm.extend_from_slice(b); Ok(()) }).unwrap();
            }
            session.push(&[], true, &mut |b: &[f32]| { pcm.extend_from_slice(b); Ok(()) }).unwrap();
            let channels = layout.channels();
            assert_eq!(pcm.len(), frames * channels, "{name} {layout:?}");
            let lfe = |p: &[f32], n: usize| -> Vec<f32> { p.iter().skip(3).step_by(n).copied().collect() };
            assert_eq!(lfe(&pcm, channels), lfe(&reference, 12), "{name} {layout:?}: LFE");
            // (The public object vector renders silence; the dimtrim one carries the energy.)
            if total(&reference) > 0. {
                let db = 10. * (total(&pcm) / total(&reference)).log10();
                assert!(db.abs() < 1., "{name} {layout:?}: {db:+.2} dB");
            }
            if layout == Layout::L714 {
                assert_eq!(pcm, reference, "{name}: 7.1.4 is the default session");
            }
        }
    }
}
