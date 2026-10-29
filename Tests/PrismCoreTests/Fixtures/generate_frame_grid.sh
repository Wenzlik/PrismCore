#!/bin/sh
set -eu
# Frame grid fixture (FrameGridTests): 12 s of 23.976 fps H.264 with three
# B-frames and a keyframe every 2 s, plus AAC, in Matroska — whose millisecond
# timestamps carry the frames as 41/42 ms steps.
ffmpeg -hide_banner -loglevel error \
  -f lavfi -i "testsrc2=s=160x96:r=24000/1001:d=12" -f lavfi -i "sine=f=1000:r=48000:d=12" \
  -c:v libx264 -pix_fmt yuv420p -g 48 -keyint_min 48 -sc_threshold 0 -bf 3 \
  -c:a aac -b:a 64k -y "Tests/PrismCoreTests/Fixtures/grid_23976_bframes.mkv"
