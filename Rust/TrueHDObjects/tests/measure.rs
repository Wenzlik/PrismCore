// Copyright 2026 PrismCore contributors. Apache License 2.0 (see LICENSE-APACHE).
//
// The heights split (what `.heights` ships) measured against the exact object render (TS 103 448,
// `exact-render`): per-speaker energy, height level, waveform correlation and front-versus-rear
// height separation. Synthetic object scenes with known positions always run; real TrueHD Atmos
// streams (raw `-f truehd`) run when listed. Prints Markdown tables; the asserts are loose guards.
//
//   cargo test --release --locked --features exact-render --test measure -- --nocapture
//   TRUEHD_OBJECTS_COMPARE=/a.thd:/b.thd cargo test … (or scripts/measure-heights.sh /a.thd …)
//
// See docs/ObjectAudioMeasurement.md.
#![cfg(feature = "exact-render")]

use truehd_objects::{
    decode::Session,
    render::{self, CHANNELS, Event, Object, Renderer},
    split::{BedSplitter, FFT, Weight},
};

const RATE: usize = 48_000;
const NAMES: [&str; CHANNELS] = ["L", "R", "C", "LFE", "Ls", "Rs", "Lb", "Rb", "Tfl", "Tfr", "Tbl", "Tbr"];
const FRONT_TOP: [usize; 2] = [8, 9];
const BACK_TOP: [usize; 2] = [10, 11];
/// 0.25 s windows, as the vectors comparison uses.
const WINDOW: usize = 12_000;

type Planar = Vec<Vec<f32>>;

fn noise(frames: usize, seed: u32) -> Vec<f32> {
    let mut s = seed;
    (0..frames)
        .map(|_| {
            s = s.wrapping_mul(1_664_525).wrapping_add(1_013_904_223);
            (s >> 8) as f32 / (1 << 24) as f32 - 0.5
        })
        .collect()
}

/// Coloured noise with its own spectral tilt and a slow envelope, so objects overlap in
/// frequency the way a mix does without being the same signal.
fn coloured(frames: usize, k: usize) -> Vec<f32> {
    let white = noise(frames, 100 + k as u32);
    let (lp, hp) = (0.03 + 0.11 * (k % 8) as f32, 0.92 - 0.09 * (k % 8) as f32);
    let (mut a, mut prev, mut b) = (0f32, 0f32, 0f32);
    white
        .iter()
        .enumerate()
        .map(|(n, x)| {
            a += lp * (x - a);
            b = hp * (b + a - prev);
            prev = a;
            b * (0.6 + 0.4 * (n as f32 / RATE as f32 * (0.3 + 0.17 * k as f32)).sin())
        })
        .collect()
}

/// An object's TS 103 448 room position at time `t` (0…1 over the scene).
type Path = fn(f32) -> [f32; 3];

struct Scene {
    name: &'static str,
    objects: Vec<Path>,
}

/// A floor the height objects sit in: dialogue in the centre, music left and right, ambience
/// in the side surrounds. Every scene has it, as films do.
fn floor() -> Vec<Path> {
    vec![|_| [0.5, 0., 0.], |_| [0., 0., 0.], |_| [1., 0., 0.], |_| [0., 0.5, 0.], |_| [1., 0.6, 0.]]
}

fn scenes() -> Vec<Scene> {
    let with = |extra: Vec<Path>| floor().into_iter().chain(extra).collect();
    vec![
        Scene { name: "front heights", objects: with(vec![|_| [0.2, 0.1, 1.], |_| [0.8, 0.15, 0.8]]) },
        Scene { name: "rear heights", objects: with(vec![|_| [0.2, 0.9, 1.], |_| [0.8, 0.85, 0.8]]) },
        Scene {
            name: "mixed front + rear + overhead",
            objects: with(vec![|_| [0.2, 0.1, 1.], |_| [0.8, 0.9, 1.], |_| [0.5, 0.5, 1.]]),
        },
        // The hard case for a split: both height objects project onto the same side surround.
        Scene { name: "front/rear pair over one side", objects: with(vec![|_| [0., 0.35, 1.], |_| [0., 0.65, 1.]]) },
        Scene {
            name: "moving: fly-over + circle",
            objects: with(vec![|t| [0.5, t, 1.], |t| {
                let a = t * 4. * std::f32::consts::PI;
                [0.5 + 0.5 * a.cos(), 0.5 + 0.5 * a.sin(), 0.6]
            }]),
        },
    ]
}

/// Renders a scene three ways, block by block as the metadata would arrive: the exact render
/// (each object panned in 3D), the 7.1 bed (the same renderer with elevation off: every object's
/// floor projection — an assumption about how a stream's own 7.1 is made), and the split of
/// that bed guided by the object positions.
fn render_scene(scene: &Scene, seconds: usize) -> (Planar, Planar) {
    let frames = RATE * seconds;
    let block = 40;
    let signals: Vec<Vec<f32>> = (0..scene.objects.len()).map(|k| coloured(frames, k)).collect();
    let (mut exact, mut bed) = (Renderer::default(), Renderer::default());
    let mut splitter = BedSplitter::default();
    let (mut exact_out, mut bed_out, mut split_out) = (Vec::new(), Vec::new(), Vec::new());
    for start in (0..frames).step_by(block) {
        let end = (start + block).min(frames);
        let t = start as f32 / frames as f32;
        let mut weights = Vec::new();
        for (k, path) in scene.objects.iter().enumerate() {
            let p = path(t);
            let ramp = block as u32 - 1;
            let placed = render::object(&render::preprocess(Object::point(p)));
            let projected = render::object(&render::preprocess(Object { elevation: false, ..Object::point(p) }));
            exact.event(Event { sample: start as u64, channel: k, gains: placed, ramp });
            bed.event(Event { sample: start as u64, channel: k, gains: projected, ramp });
            weights.push(Weight::at(p, 1.));
        }
        let input: Vec<Vec<f32>> = signals.iter().map(|s| s[start..end].to_vec()).collect();
        exact.render(&input, end - start, &mut exact_out);
        let at = bed_out.len();
        bed.render(&input, end - start, &mut bed_out);
        splitter.set_weights(weights);
        splitter.push(&bed_out[at..], &input, end - start, &mut split_out);
    }
    splitter.finish(&mut split_out);
    (planar(&exact_out), planar(&split_out))
}

fn planar(interleaved: &[f32]) -> Planar {
    (0..CHANNELS).map(|c| interleaved.iter().skip(c).step_by(CHANNELS).copied().collect()).collect()
}

fn energy(x: &[f32]) -> f64 {
    x.iter().map(|v| f64::from(*v).powi(2)).sum()
}

fn dot(a: &[f32], b: &[f32]) -> f64 {
    a.iter().zip(b).map(|(x, y)| f64::from(*x) * f64::from(*y)).sum()
}

/// Normalised cross-correlation at lag 0 (both renders keep the stream's timeline sample for
/// sample); NaN when either side is silent.
fn correlation(a: &[f32], b: &[f32]) -> f64 {
    dot(a, b) / (energy(a) * energy(b)).sqrt()
}

fn db(ratio: f64) -> f64 {
    10. * ratio.log10()
}

/// A level difference for a table: beyond ±60 dB one side is silent.
fn capped(db: f64) -> String {
    match db {
        d if d.is_nan() => "—".into(),
        d if d > 60. => "> +60".into(),
        d if d < -60. => "< −60".into(),
        d => format!("{d:+.2}"),
    }
}

/// A quantile; a −∞ dB (heights gone) is a value like any other.
fn pick(v: &[f64], q: f64) -> f64 {
    let mut v: Vec<f64> = v.iter().copied().filter(|x| !x.is_nan()).collect();
    v.sort_by(f64::total_cmp);
    v.get(((v.len() as f64 - 1.) * q).round() as usize).copied().unwrap_or(f64::NAN)
}

struct Summary {
    /// Split heights against exact heights over the whole run, and the per-window median.
    height_db: f64,
    height_db_median: f64,
    /// Correlation of the four height feeds together, and of the whole 7.1.4.
    height_correlation: f64,
    total_correlation: f64,
    /// Front tops against back tops (dB), exact and split.
    front_rear_exact: f64,
    front_rear_split: f64,
    /// Mean and worst absolute difference of the per-window front share of the heights (0…1).
    front_share_error: f64,
    front_share_worst: f64,
    moved_median: f64,
}

/// Prints the comparison of one run and returns its headline numbers. Only the middle is
/// measured: the first and last FFT frames lack the split's overlap partners.
fn compare(name: &str, exact: &Planar, split: &Planar) -> Summary {
    let frames = exact[0].len().min(split[0].len());
    let range = FFT.min(frames / 4)..frames - FFT.min(frames / 4);
    let cut = |p: &Planar| -> Planar { p.iter().map(|c| c[range.clone()].to_vec()).collect() };
    let (e, s) = (cut(exact), cut(split));
    let ee: Vec<f64> = e.iter().map(|c| energy(c)).collect();
    let se: Vec<f64> = s.iter().map(|c| energy(c)).collect();
    let (te, ts) = (ee.iter().sum::<f64>(), se.iter().sum::<f64>());
    println!("\n#### {name} ({:.1} s)\n", frames as f64 / RATE as f64);
    println!("| speaker | exact % | split % | split − exact dB | correlation |");
    println!("|---|---:|---:|---:|---:|");
    for c in 0..CHANNELS {
        // A feed under −60 dB of the whole in both renders is silence; its ratios are noise.
        if ee[c] < te * 1e-6 && se[c] < ts * 1e-6 {
            println!("| {} | 0.00 | 0.00 | — | — |", NAMES[c]);
            continue;
        }
        println!(
            "| {} | {:.2} | {:.2} | {} | {:.3} |",
            NAMES[c],
            ee[c] / te * 100.,
            se[c] / ts * 100.,
            capped(db(se[c] / ee[c])),
            correlation(&e[c], &s[c])
        );
    }
    let sum = |v: &[f64], cs: &[usize]| cs.iter().map(|c| v[*c]).sum::<f64>();
    let tops = [8, 9, 10, 11];
    let joint = |cs: &[usize]| {
        let d: f64 = cs.iter().map(|c| dot(&e[*c], &s[*c])).sum();
        d / (sum(&ee, cs) * sum(&se, cs)).sqrt()
    };
    // Per window: height level, energy on another speaker, front share of the heights.
    let (mut level, mut moved, mut share_error) = (Vec::new(), Vec::new(), Vec::new());
    for w in 0..e[0].len() / WINDOW {
        let r = w * WINDOW..(w + 1) * WINDOW;
        let we: Vec<f64> = e.iter().map(|c| energy(&c[r.clone()])).collect();
        let ws: Vec<f64> = s.iter().map(|c| energy(&c[r.clone()])).collect();
        let (wte, wts) = (we.iter().sum::<f64>(), ws.iter().sum::<f64>());
        // Windows are chosen by the exact render alone: a split that went silent
        // where the exact render has heights must count, not drop out.
        if wte <= 0. || sum(&we, &tops) / wte < 0.01 {
            continue;
        }
        level.push(db(sum(&ws, &tops) / sum(&we, &tops)));
        moved.push(if wts > 0. { 50. * (0..CHANNELS).map(|c| (we[c] / wte - ws[c] / wts).abs()).sum::<f64>() } else { 100. });
        // Split heights silent: no front share at all, which is as wrong as it gets.
        let front = |v: &[f64]| sum(v, &FRONT_TOP) / sum(v, &tops);
        share_error.push(if sum(&ws, &tops) > 0. { (front(&we) - front(&ws)).abs() } else { 1. });
    }
    let summary = Summary {
        height_db: db(sum(&se, &tops) / sum(&ee, &tops)),
        height_db_median: pick(&level, 0.5),
        height_correlation: joint(&tops),
        total_correlation: joint(&(0..CHANNELS).collect::<Vec<_>>()),
        front_rear_exact: db(sum(&ee, &FRONT_TOP) / sum(&ee, &BACK_TOP)),
        front_rear_split: db(sum(&se, &FRONT_TOP) / sum(&se, &BACK_TOP)),
        front_share_worst: share_error.iter().copied().fold(f64::NAN, f64::max),
        front_share_error: if share_error.is_empty() { f64::NAN } else { share_error.iter().sum::<f64>() / share_error.len() as f64 },
        moved_median: pick(&moved, 0.5),
    };
    println!(
        "\nheights split − exact: {:+.2} dB whole, per 0.25 s window median {:+.2} dB (p10 {:+.2}, p90 {:+.2}; {} of {} windows have heights)",
        summary.height_db,
        summary.height_db_median,
        pick(&level, 0.1),
        pick(&level, 0.9),
        level.len(),
        e[0].len() / WINDOW
    );
    println!(
        "correlation with the exact render: heights {:.3}, all 12 feeds {:.3}; energy on another speaker per window: median {:.2} % (p90 {:.2} %)",
        summary.height_correlation,
        summary.total_correlation,
        summary.moved_median,
        pick(&moved, 0.9)
    );
    println!(
        "front vs rear tops: exact {} dB, split {} dB; front share of the heights per window off by {:.3} on average, {:.3} at worst",
        capped(summary.front_rear_exact),
        capped(summary.front_rear_split),
        summary.front_share_error,
        summary.front_share_worst
    );
    summary
}

#[test]
fn synthetic_scenes_against_the_exact_render() {
    println!("\n### Synthetic object scenes (8 s each; bed = the objects' floor projection)");
    let mut rows = Vec::new();
    for scene in scenes() {
        let (exact, split) = render_scene(&scene, 8);
        let s = compare(scene.name, &exact, &split);
        rows.push((scene.name, s));
    }
    println!("\n| scene | heights dB (whole / window median) | corr. heights | corr. all | front−rear exact / split dB | front-share error (mean / worst window) | moved % |");
    println!("|---|---:|---:|---:|---:|---:|---:|");
    for (name, s) in &rows {
        println!(
            "| {name} | {:+.2} / {:+.2} | {:.3} | {:.3} | {} / {} | {:.3} / {:.3} | {:.2} |",
            s.height_db,
            s.height_db_median,
            s.height_correlation,
            s.total_correlation,
            capped(s.front_rear_exact),
            capped(s.front_rear_split),
            s.front_share_error,
            s.front_share_worst,
            s.moved_median
        );
    }
    // Loose guards on the shipped split, so a regression shows: heights within 1.5 dB, the
    // heights' front share within 5 % per window, and front and rear tops on the same side of
    // each other as the exact render puts them.
    for (name, s) in &rows {
        assert!(s.height_db.abs() < 1.5, "{name}: heights {:+.2} dB", s.height_db);
        assert!(s.height_correlation > 0.7, "{name}: height correlation {:.3}", s.height_correlation);
        assert!(s.front_share_worst < 0.05, "{name}: front share of the heights off by {:.3} in a window", s.front_share_worst);
        if s.front_rear_exact.abs() > 6. {
            assert_eq!(s.front_rear_split.signum(), s.front_rear_exact.signum(), "{name}: front/rear swapped");
        }
    }
}

/// Real TrueHD Atmos, both sessions over the same bytes. `TRUEHD_OBJECTS_COMPARE` lists raw
/// TrueHD files (colon-separated); `TRUEHD_OBJECTS_VECTORS` adds the truehd crate's own Atmos
/// vectors. Without either, nothing runs.
#[test]
fn real_streams_against_the_exact_render() {
    let mut files: Vec<std::path::PathBuf> = Vec::new();
    if let Some(dir) = std::env::var("TRUEHD_OBJECTS_VECTORS").ok().filter(|d| !d.is_empty()) {
        files.extend(["fba_atmos_obj.mlp", "fba_atmos_dimtrim.mlp"].map(|n| std::path::Path::new(&dir).join(n)));
    }
    if let Ok(list) = std::env::var("TRUEHD_OBJECTS_COMPARE") {
        files.extend(list.split(':').filter(|s| !s.is_empty()).map(std::path::PathBuf::from));
    }
    if files.is_empty() {
        return;
    }
    println!("\n### Real TrueHD Atmos streams");
    for path in files {
        let data = std::fs::read(&path).expect("stream");
        let run = |mut session: Session| {
            let mut pcm = Vec::new();
            let start = cpu();
            for bytes in data.chunks(4096) {
                session
                    .push(bytes, false, &mut |b: &[f32]| {
                        pcm.extend_from_slice(b);
                        Ok(())
                    })
                    .unwrap();
            }
            session
                .push(&[], true, &mut |b: &[f32]| {
                    pcm.extend_from_slice(b);
                    Ok(())
                })
                .unwrap();
            (planar(&pcm), cpu() - start, session.mode())
        };
        let (exact, exact_cpu, exact_mode) = run(Session::exact());
        let (split, split_cpu, split_mode) = run(Session::default());
        assert_eq!(exact[0].len(), split[0].len(), "both keep the stream's length");
        let name = path.file_name().unwrap().to_string_lossy().to_string();
        if exact.iter().all(|c| energy(c) == 0.) {
            println!("\n{name}: silent, nothing to compare");
            continue;
        }
        compare(&format!("{name} (exact {exact_mode:?}, split {split_mode:?})"), &exact, &split);
        let seconds = exact[0].len() as f64 / RATE as f64;
        println!(
            "CPU of this thread per second of audio (decode included): exact {:.1} ms, split {:.1} ms",
            exact_cpu * 1e3 / seconds,
            split_cpu * 1e3 / seconds
        );
    }
}

unsafe extern "C" {
    fn clock_gettime_nsec_np(clock: u32) -> u64;
}

/// CPU seconds of this thread (CLOCK_THREAD_CPUTIME_ID): a loaded machine still measures the work.
fn cpu() -> f64 {
    unsafe { clock_gettime_nsec_np(16) as f64 / 1e9 }
}
