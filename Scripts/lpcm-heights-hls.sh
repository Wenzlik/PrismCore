#!/bin/bash
# Experimental `HeightsOutput.lpcm` device test (issue #176): serve one TrueHD Atmos
# source through `prismcore-cli serve --heights --heights-output lpcm` once per layout
# (5.1.2, 5.1.4, 7.1.2, 7.1.4) and copy each finished HLS to OUT/<layout>/, a static
# tree any HTTP server can hand to an Apple TV (see docs/LPCMHeightsDeviceTest.md).
#
#   Scripts/lpcm-heights-hls.sh SOURCE.mkv [OUT]   (OUT defaults to ./lpcm-heights-hls)
#
# Use a short clip (a minute: `ffmpeg -ss 600 -t 60 -i film.mkv -map 0 -c copy clip.mkv`):
# every segment is produced, and the copy waits for each playlist's ENDLIST.
set -euo pipefail
source=${1:?usage: $0 SOURCE [OUT]}
out=${2:-lpcm-heights-hls}
cli=${PRISMCORE_CLI:-.build/release/prismcore-cli}
[ -x "$cli" ] || swift build -c release --product prismcore-cli

# Fetch playlist $2 (relative to base URL $1) into $3, waiting for ENDLIST on media
# playlists, then everything it names; nested playlists recurse.
mirror() {
    local base=$1 rel=$2 dir=$3 body uri
    mkdir -p "$dir/$(dirname "$rel")"
    while body=$(curl -sf "$base/$rel"); grep -q '#EXTINF' <<<"$body" && ! grep -q '#EXT-X-ENDLIST' <<<"$body"; do
        sleep 1
    done
    printf '%s\n' "$body" >"$dir/$rel"
    for uri in $( (grep -o 'URI="[^"]*"' <<<"$body" | cut -d'"' -f2; grep -v '^#' <<<"$body") | sort -u); do
        local sub; sub="$(dirname "$rel")/$uri"; sub=${sub#./}
        case $uri in
            *.m3u8) mirror "$base" "$sub" "$dir" ;;
            *) curl -sf "$base/$sub" -o "$dir/$sub" ;;
        esac
    done
}

mkdir -p "$out"
for layout in 5.1.2 5.1.4 7.1.2 7.1.4; do
    log=$(mktemp)
    "$cli" serve "$source" --heights --heights-output lpcm --heights-layout "$layout" \
        --report "$out/$layout.report.json" >"$log" 2>&1 </dev/null &
    pid=$!
    until url=$(grep -o 'serving: http[^ ]*' "$log" | cut -c10-); [ -n "$url" ]; do
        kill -0 $pid 2>/dev/null || { cat "$log"; exit 1; }
        sleep 0.5
    done
    rm -rf "${out:?}/$layout"
    mirror "${url%/*}" "${url##*/}" "$out/$layout"
    kill -INT $pid; wait $pid || true
    grep -q 'CODECS="[^"]*ipcm' "$out/$layout/master.m3u8" \
        && echo "$layout: $out/$layout/master.m3u8" \
        || echo "$layout: no ipcm rendition (not TrueHD Atmos? see $out/$layout.report.json)" >&2
    rm -f "$log"
done
