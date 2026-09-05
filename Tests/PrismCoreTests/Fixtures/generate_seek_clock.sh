#!/bin/sh
set -eu
# Twelve vertical binary cells carry the frame index, including through B-frame
# reordering. Sampling the cell centers avoids compression ringing at edges.
ffmpeg -hide_banner -loglevel error -f lavfi -i "nullsrc=s=480x224:r=24:d=90,geq=lum='16+219*mod(floor(N/pow(2,floor(X/40))),2)':cb=128:cr=128" \
  -f lavfi -i "sine=frequency=440:sample_rate=48000:duration=90" \
  -c:v libx264 -pix_fmt yuv420p -g 48 -keyint_min 48 -sc_threshold 0 -bf 3 \
  -c:a aac -b:a 96k -y "Tests/PrismCoreTests/Fixtures/seek_clock.mkv"
