#!/bin/sh
set -eu
# Switch-away fixture (SuspendedRenditionTests): 60 s (past the producer's
# 30 s lead, so production is still running while a test switches tracks)
# of 24 fps H.264 with a keyframe every 2 s, and TWO bridged audio tracks —
# Opus, which every build decodes and which the bridge re-encodes. The `eng`
# track is flagged default (the bridged DEFAULT), the `ces` one is not (a
# lazy alternate). Both are a 10 ms click on every whole second, 1 kHz and
# 2 kHz, so a served segment can be checked for audible audio and for where
# its first sample sits.
video="nullsrc=s=320x160:r=24:d=60,geq=lum='16+219*mod(floor(N/pow(2,floor(X/40))),2)':cb=128:cr=128"
click() { echo "aevalsrc='if(lt(mod(t\,1)\,0.01)\,0.8*sin(2*PI*$1*t)\,0)':s=48000:d=60"; }
ffmpeg -hide_banner -loglevel error -f lavfi -i "$video" -f lavfi -i "$(click 1000)" -f lavfi -i "$(click 2000)" \
  -map 0:v -map 1:a -map 2:a \
  -c:v libx264 -pix_fmt yuv420p -g 48 -keyint_min 48 -sc_threshold 0 -bf 0 \
  -c:a libopus -b:a 24k \
  -metadata:s:a:0 language=eng -metadata:s:a:1 language=ces \
  -disposition:a:0 default -disposition:a:1 0 \
  -y "Tests/PrismCoreTests/Fixtures/h264_opus_opus_60s.mkv"
