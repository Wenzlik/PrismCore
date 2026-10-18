#!/bin/bash
# Builds TrueHDObjects.xcframework from this crate's pinned sources (Cargo.lock, --locked) for
# every platform PrismCore supports, plus a release zip and its SwiftPM checksum.
#
#   Rust/TrueHDObjects/build-xcframework.sh           # all slices
#   Rust/TrueHDObjects/build-xcframework.sh --mac     # this Mac's slice only (fast, for tests)
#
# Output: Rust/TrueHDObjects/build/ (git-ignored). Package.swift links the framework when it is
# there; without it PrismCore builds as before and TrueHD keeps its 7.1 bridge.
#
# Needs rustup's stable toolchain with the Apple targets below (`rustup target add …`); tvOS and
# visionOS are installable rustup targets, so no nightly or -Zbuild-std is involved. Honours
# CARGO_HOME, CARGO_TARGET_DIR and TMPDIR from the environment.
set -euo pipefail

CRATE="$(cd "$(dirname "$0")" && pwd)"
OUT="$CRATE/build"
TARGET_DIR="${CARGO_TARGET_DIR:-$CRATE/target}"
TARGETS=(aarch64-apple-darwin x86_64-apple-darwin aarch64-apple-ios aarch64-apple-ios-sim x86_64-apple-ios
    aarch64-apple-tvos aarch64-apple-tvos-sim aarch64-apple-visionos aarch64-apple-visionos-sim)
[[ "${1:-}" == "--mac" ]] && TARGETS=("$(uname -m | sed 's/arm64/aarch64/')-apple-darwin")

# Deployment floors match Package.swift, so the linker never meets a newer object than the app.
export MACOSX_DEPLOYMENT_TARGET=14.0 IPHONEOS_DEPLOYMENT_TARGET=16.0 TVOS_DEPLOYMENT_TARGET=17.0 XROS_DEPLOYMENT_TARGET=1.0
# Paths of this machine never reach the binary: the same sources give the same library anywhere.
SYSROOT="$(rustc --print sysroot)"
COMMIT="$(rustc -vV | sed -n 's/^commit-hash: //p')"
REMAPS=("--remap-path-prefix=${CARGO_HOME:-$HOME/.cargo}=/cargo"
    "--remap-path-prefix=$SYSROOT/lib/rustlib/src/rust=/rustc/$COMMIT"
    "--remap-path-prefix=$CRATE=/truehd-objects")
export CARGO_ENCODED_RUSTFLAGS="$(IFS=$'\x1f'; echo "${REMAPS[*]}")"

# Each library becomes one relocatable object whose only globals are the C API and a WEAK
# rust_eh_personality. The app already links another Rust static library (libdovi, through
# MPVKit), and two copies of the Rust standard library would collide on every std symbol; a
# private personality would be a fourth personality routine in the image (Rust, Objective-C,
# C++), which the compact unwinder cannot hold. Weak, it merges with the other copy; every C
# entry point catches panics, so nothing unwinds across it. Technique as in SpatialAudioBridge's
# scripts/build-core.sh (Apache-2.0).
prelink() {
    local release="$TARGET_DIR/$1/release" work
    work="$release/prelink"
    rm -rf "$work"
    mkdir -p "$work/members"
    (cd "$work/members" && ar -x "$release/libtruehd_objects.a" && rm -f __.SYMDEF*)
    printf '%s\n' '_truehd_objects_*' _rust_eh_personality > "$work/exports"
    local members=("$work"/members/*.o) version
    # The platform and minimum OS the crate was built for; `ld -r` would record a default.
    read -r -a version < <(otool -l "${members[@]}" | awk '$1 == "platform" {p = $2} $1 == "minos" {m = $2}
        $1 == "sdk" && p != "" {print p, m, ($2 == "n/a" ? "0.0" : $2); exit}')
    [[ ${#version[@]} -eq 3 ]] || { echo "no LC_BUILD_VERSION in the $1 library" >&2; exit 1; }
    ld -r -platform_version "${version[@]}" -exported_symbols_list "$work/exports" -o "$work/objects.o" "${members[@]}"
    strip -S "$work/objects.o"
    python3 -I "$CRATE/scripts/mark-weak.py" "$work/objects.o" _rust_eh_personality
    libtool -static -D -o "$work/libtruehd_objects.a" "$work/objects.o"
}

for target in "${TARGETS[@]}"; do
    # Only the staticlib: next to the rlib that `cargo test` uses, Cargo would skip LTO.
    cargo rustc --release --locked --manifest-path "$CRATE/Cargo.toml" --target "$target" --lib --crate-type staticlib
    prelink "$target"
done

rm -rf "$OUT"
mkdir -p "$OUT"
# One library per platform; Macs and the iOS simulator are universal.
PLATFORMS=("aarch64-apple-darwin x86_64-apple-darwin" aarch64-apple-ios "aarch64-apple-ios-sim x86_64-apple-ios"
    aarch64-apple-tvos aarch64-apple-tvos-sim aarch64-apple-visionos aarch64-apple-visionos-sim)
ARGS=()
for platform in "${PLATFORMS[@]}"; do
    built=()
    for target in $platform; do
        [[ " ${TARGETS[*]} " == *" $target "* ]] && built+=("$TARGET_DIR/$target/release/prelink/libtruehd_objects.a")
    done
    [[ ${#built[@]} -eq 0 ]] && continue
    library="${built[0]}"
    if [[ ${#built[@]} -gt 1 ]]; then
        library="$TARGET_DIR/universal/${platform%% *}/libtruehd_objects.a"
        mkdir -p "$(dirname "$library")"
        lipo -create "${built[@]}" -output "$library"
    fi
    ARGS+=(-library "$library" -headers "$CRATE/include")
done
xcodebuild -create-xcframework "${ARGS[@]}" -output "$OUT/TrueHDObjects.xcframework" >/dev/null

# The export list is the contract: anything else global would collide in the app.
for library in "$OUT"/TrueHDObjects.xcframework/*/libtruehd_objects.a; do
    for arch in $(lipo -archs "$library"); do
        globals="$(nm -gUm -arch "$arch" "$library" | sed -n -e 's/\[no dead strip\] //' -e 's/.*) //p' | LC_ALL=C sort | paste -sd ' ' -)"
        [[ "$globals" =~ ^(external\ _truehd_objects_[a-z_]+\ )+weak\ external\ _rust_eh_personality$ ]] ||
            { echo "$library ($arch) exports more than the C API: $globals" >&2; exit 1; }
    done
done
# xcodebuild lists the libraries in a different order on each run.
python3 -I - "$OUT/TrueHDObjects.xcframework/Info.plist" <<'EOF'
import plistlib, sys
with open(sys.argv[1], "rb") as f: info = plistlib.load(f)
info["AvailableLibraries"].sort(key=lambda library: library["LibraryIdentifier"])
with open(sys.argv[1], "wb") as f: plistlib.dump(info, f)
EOF

# The notices travel with the binary: in the framework itself and in the zip.
mkdir -p "$OUT/TrueHDObjects.xcframework/licenses"
cp "$CRATE/LICENSE-APACHE" "$CRATE/THIRD-PARTY-NOTICES.md" "$OUT/TrueHDObjects.xcframework/licenses/"
cp -R "$CRATE/licenses/" "$OUT/TrueHDObjects.xcframework/licenses/"
cp "$SYSROOT/share/doc/rust/COPYRIGHT-library.html" "$OUT/TrueHDObjects.xcframework/licenses/rust-std-$(rustc -vV | sed -n 's/^release: //p')-COPYRIGHT.html"

# Release archive with stable timestamps and order, and the checksum Package.swift needs for a
# `.binaryTarget(url:checksum:)`.
find "$OUT/TrueHDObjects.xcframework" -exec touch -h -t 202601010000 {} +
(cd "$OUT" && find TrueHDObjects.xcframework | LC_ALL=C sort | zip -X -q -@ TrueHDObjects.xcframework.zip)
if command -v swift >/dev/null; then
    (cd "$CRATE/../.." && swift package compute-checksum "$OUT/TrueHDObjects.xcframework.zip") > "$OUT/TrueHDObjects.xcframework.zip.checksum"
fi
echo "built $OUT/TrueHDObjects.xcframework (${TARGETS[*]})"
# SwiftPM caches the evaluated manifest, including Package.swift's check for this framework.
echo "first PrismCore build after this one: swift build --manifest-cache none"
