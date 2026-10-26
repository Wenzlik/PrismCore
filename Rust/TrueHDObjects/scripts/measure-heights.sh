#!/bin/bash
# The heights split against the exact object render (tests/measure.rs): synthetic object scenes,
# the truehd crate's public Atmos vectors when Cargo has fetched them, and any raw TrueHD Atmos
# files given as arguments. Prints Markdown tables. See docs/ObjectAudioMeasurement.md.
#
#   Rust/TrueHDObjects/scripts/measure-heights.sh [film.thd …]
#
# Raw TrueHD from a Matroska: ffmpeg -i film.mkv -map 0:a:0 -c copy -f truehd film.thd
set -euo pipefail
CRATE="$(cd "$(dirname "$0")/.." && pwd)"
vectors="$(ls -d "${CARGO_HOME:-$HOME/.cargo}"/git/checkouts/truehdd-*/5c8b880/truehd/tests/assets 2>/dev/null | head -1 || true)"
files=""
for f in "$@"; do files="${files:+$files:}$(cd "$(dirname "$f")" && pwd)/$(basename "$f")"; done
cd "$CRATE"
TRUEHD_OBJECTS_VECTORS="$vectors" TRUEHD_OBJECTS_COMPARE="$files" \
    cargo test --release --locked --features exact-render --test measure -- --nocapture --test-threads=1
