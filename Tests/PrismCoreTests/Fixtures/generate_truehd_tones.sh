#!/bin/sh
set -eu
# 5.1 TrueHD (FFmpeg's own encoder: two substreams, no Atmos) with a different tone in
# every channel, so a rendered bed can be checked channel by channel: asked for as L 220 Hz,
# R 330, C 440, LFE 55, Ls 550, Rs 660 — but the experimental encoder rotates the front three,
# and both FFmpeg's decoder and the truehd crate read L 330, R 440, C 220 back. The tests pin
# what the decoders read. Run from the repository root.
ffmpeg -hide_banner -loglevel error -f lavfi -i "testsrc2=size=320x180:rate=24:duration=3" \
  -filter_complex "sine=f=220:d=3[a0];sine=f=330:d=3[a1];sine=f=440:d=3[a2];sine=f=55:d=3[a3];sine=f=550:d=3[a4];sine=f=660:d=3[a5];[a0][a1][a2][a3][a4][a5]join=inputs=6:channel_layout=5.1(side)[a]" \
  -map 0:v -map "[a]" -c:v libx264 -preset veryfast -g 24 -keyint_min 24 -sc_threshold 0 -pix_fmt yuv420p \
  -c:a truehd -strict experimental -ar 48000 -y "Tests/PrismCoreTests/Fixtures/h264_truehd51_tones_3s.mkv"
