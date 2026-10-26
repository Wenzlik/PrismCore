#!/bin/sh
set -eu
# FLAC whose STREAMINFO declares 128-sample blocks, which CoreMedia refuses to open (it wants a
# min_blocksize of at least 192): the track has to be bridged, not stream-copied. Run from the
# repository root.
ffmpeg -hide_banner -loglevel error -f lavfi -i "testsrc2=size=320x180:rate=25:duration=2" \
  -f lavfi -i "sine=f=440:sample_rate=48000:duration=2" \
  -c:v libx264 -preset veryfast -g 25 -pix_fmt yuv420p -c:a flac -frame_size 128 -ac 2 \
  -y "Tests/PrismCoreTests/Fixtures/h264_flac128_2s.mkv"
