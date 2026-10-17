// Copyright 2026 PrismCore contributors. Apache License 2.0 (see LICENSE-APACHE).
//
// Runs the truehd crate's own small public test streams through the session. They are not
// redistributable here, so the test reads them from the pinned checkout Cargo fetched:
//
//   TRUEHD_OBJECTS_VECTORS="$CARGO_HOME/git/checkouts/truehdd-*/5c8b880/truehd/tests/assets" cargo test
//
// Without the variable the test passes without asserting anything.

use truehd_objects::decode::{Mode, Session};

fn decode(name: &str, chunk: usize) -> Option<(Result<(), String>, Vec<f32>, Mode)> {
    let dir = std::env::var("TRUEHD_OBJECTS_VECTORS").ok()?;
    let data = std::fs::read(std::path::Path::new(&dir).join(name)).expect("vector");
    let mut session = Session::default();
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
fn a_stream_without_objects_falls_back_to_its_bed() {
    let Some((result, pcm, mode)) = decode("fbb_6ch.mlp", 4096) else { return };
    assert!(result.is_ok(), "{result:?}");
    assert_eq!(mode, Mode::Bed);
    // Heights stay silent; the bed carries the audio.
    assert!((8..12).all(|c| energy(&pcm, c) == 0.));
    assert!((0..8).map(|c| energy(&pcm, c)).sum::<f64>() > 0.);
}
