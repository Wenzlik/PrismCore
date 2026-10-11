#!/bin/sh
set -eu
# Re-anchor timeline fixtures (ReanchorTimelineTests): 60 s (past the
# producer's 30 s lead, so a late segment is only ever made by a re-anchor)
# of 24 fps H.264 with three B-frames and a keyframe every 2 s. The audio is
# a 10 ms 1 kHz click on every whole second, so where a player puts the
# audio can be read back off the decoded samples.
# - closed GOP + AAC (stream copy; its first packet is the encoder's priming,
#   at a negative timestamp, which the head muxer trims with an edit list)
# - open GOP + Opus (bridged; a later keyframe carries more composition
#   offset than the first one)
video="nullsrc=s=480x224:r=24:d=60,geq=lum='16+219*mod(floor(N/pow(2,floor(X/40))),2)':cb=128:cr=128"
clicks="aevalsrc='if(lt(mod(t\,1)\,0.01)\,0.8*sin(2*PI*1000*t)\,0)':s=48000:d=60"
x264="-c:v libx264 -pix_fmt yuv420p -g 48 -keyint_min 48 -sc_threshold 0 -bf 3"
ffmpeg -hide_banner -loglevel error -f lavfi -i "$video" -f lavfi -i "$clicks" \
  $x264 -c:a aac -b:a 96k -y "Tests/PrismCoreTests/Fixtures/reanchor_closedgop_aac.mkv"
ffmpeg -hide_banner -loglevel error -f lavfi -i "$video" -f lavfi -i "$clicks" \
  $x264 -x264-params open-gop=1 -c:a libopus -b:a 32k -y "Tests/PrismCoreTests/Fixtures/reanchor_opengop_opus.mkv"
