// Splitter CPU on its own: 16 objects, CPU time of this thread (a loaded machine still measures
// the work). `cargo run --release --example splitbench`
use truehd_objects::split::{BedSplitter, Weight};

unsafe extern "C" {
    fn clock_gettime_nsec_np(clock: u32) -> u64;
}
const CLOCK_THREAD_CPUTIME_ID: u32 = 16;

fn main() {
    let mut s = BedSplitter::default();
    let seconds = 20;
    let bed = vec![0.1f32; 40 * 12];
    let objects: Vec<Vec<f32>> = (0..16).map(|_| vec![0.05f32; 40]).collect();
    s.set_weights((0..16).map(|k| Weight::at([k as f32 / 16., 0.3, (k % 2) as f32], 1.)).collect());
    let mut out = Vec::new();
    let start = unsafe { clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) };
    for _ in 0..48_000 * seconds / 40 {
        s.push(&bed, &objects, 40, &mut out);
        out.clear();
    }
    let cpu = unsafe { clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) } - start;
    println!("splitter: {:.1} ms CPU per second of audio (16 objects)", cpu as f64 / 1e6 / seconds as f64);
}
