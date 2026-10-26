#!/bin/sh
set -eu
# A 14 s video whose audio ends early: AAC for the whole 14 s (the DEFAULT, stream-copied) and
# an MP2 alternate that stops at 4 s (bridged, so a lazy rendition). The planned shape cuts
# 2 + 6 + 6 s; the MP2 track has nothing for the last slot. Run from the repository root.
ffmpeg -hide_banner -loglevel error -f lavfi -i "testsrc2=size=160x90:rate=25:duration=14" \
  -f lavfi -i "sine=f=440:sample_rate=48000:duration=14" -f lavfi -i "sine=f=660:sample_rate=48000:duration=4" \
  -map 0 -map 1 -map 2 -c:v libx264 -preset veryfast -crf 40 -g 25 -pix_fmt yuv420p \
  -c:a:0 aac -b:a:0 64k -c:a:1 mp2 -b:a:1 64k -ac 2 \
  -y "Tests/PrismCoreTests/Fixtures/h264_aac_mp2short_14s.mkv"
