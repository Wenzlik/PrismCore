#!/bin/sh
set -eu
# A minute of video with two copyable audio tracks and an SRT track, keyframes
# every 2 s — long enough for a sequential session's sliding window to move
# several times at a 2 s segment target. Run from the repository root.
srt="$(mktemp -t prismcore-sliding).srt"
trap 'rm -f "$srt"' EXIT
i=0
while [ "$i" -lt 30 ]; do
  start=$((i * 2))
  printf '%d\n00:00:%02d,000 --> 00:00:%02d,500\nCue %d\n\n' "$((i + 1))" "$start" "$start" "$i" >> "$srt"
  i=$((i + 1))
done
ffmpeg -hide_banner -loglevel error \
  -f lavfi -i "testsrc2=s=160x90:r=12:d=60" \
  -f lavfi -i "sine=frequency=440:sample_rate=48000:duration=60" \
  -f lavfi -i "sine=frequency=660:sample_rate=48000:duration=60" \
  -i "$srt" \
  -map 0:v -map 1:a -map 2:a -map 3:s \
  -c:v libx264 -preset veryfast -crf 45 -pix_fmt yuv420p -g 24 -keyint_min 24 -sc_threshold 0 \
  -ac 1 -c:a:0 aac -b:a:0 24k -c:a:1 ac3 -b:a:1 32k -c:s srt \
  -metadata:s:a:0 language=eng -metadata:s:a:1 language=ces -metadata:s:s:0 language=eng \
  -y "Tests/PrismCoreTests/Fixtures/h264_aac_ac3_srt_60s.mkv"
