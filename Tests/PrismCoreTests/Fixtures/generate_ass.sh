#!/bin/sh
set -eu
# A 4 s video with one ASS track (S_TEXT/ASS): a Default-style line with an italic
# override at 0.5–2 s, and a top-aligned "Sign" style with a red \c override at
# 2.5–3.5 s. No font attachment: the only redistributable fonts are big, and the
# attachment path is unit-tested from an in-memory context instead
# (ASSRenderingTests). Run from the repository root.
script="$(mktemp -t prismcore-ass).ass"
cat > "$script" <<'ASS'
[Script Info]
ScriptType: v4.00+
PlayResX: 640
PlayResY: 360

[V4+ Styles]
Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
Style: Default,Helvetica Neue,36,&H00FFFFFF,&H000000FF,&H00000000,&H80000000,0,0,0,0,100,100,0,0,1,2,1,2,20,20,20,1
Style: Sign,Helvetica Neue,30,&H0000FFFF,&H000000FF,&H00000000,&H80000000,-1,0,0,0,100,100,0,0,1,2,0,8,20,20,20,1

[Events]
Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
Dialogue: 0,0:00:00.50,0:00:02.00,Default,,0,0,0,,Ahoj {\i1}světe{\i0}
Dialogue: 0,0:00:02.50,0:00:03.50,Sign,,0,0,0,,{\c&H0000FF&}Nápis
ASS
ffmpeg -hide_banner -loglevel error -f lavfi -i "testsrc2=size=320x180:rate=25:duration=4" \
  -f lavfi -i "sine=f=440:sample_rate=48000:duration=4" -i "$script" \
  -map 0 -map 1 -map 2 -c:v libx264 -preset veryfast -crf 40 -g 25 -pix_fmt yuv420p \
  -c:a aac -b:a 64k -c:s copy -metadata:s:s:0 language=ces \
  -y "Tests/PrismCoreTests/Fixtures/h264_aac_ass.mkv"
rm -f "$script"

# 80 s with two overlapping events: a long bottom sign at 50–65 s and a short
# top line at 58–59 s, in 1 s clusters. FFmpeg writes subtitle Cues, and its
# own seek backtrack reaches only the LATEST one before a target — so a seek
# to 60 s finds the top line and misses the sign unless PrismCore's preroll
# walks to the earliest indexed event (review r3 P1.1). Long enough that a
# producer parked at its 30 s lead has not read 50 s yet.
script="$(mktemp -t prismcore-ass).ass"
cat > "$script" <<'ASS'
[Script Info]
ScriptType: v4.00+
PlayResX: 640
PlayResY: 360

[V4+ Styles]
Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
Style: Default,Helvetica Neue,36,&H00FFFFFF,&H000000FF,&H00000000,&H80000000,0,0,0,0,100,100,0,0,1,2,0,2,20,20,20,1

[Events]
Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
Dialogue: 0,0:00:50.00,0:01:05.00,Default,,0,0,0,,Long bottom sign
Dialogue: 0,0:00:58.00,0:00:59.50,Default,,0,0,0,,{\an8}Short top line
ASS
ffmpeg -hide_banner -loglevel error -f lavfi -i "testsrc2=size=96x54:rate=25:duration=80" \
  -f lavfi -i "sine=f=440:sample_rate=48000:duration=80" -i "$script" \
  -map 0 -map 1 -map 2 -c:v libx264 -preset veryfast -crf 40 -g 25 -pix_fmt yuv420p \
  -c:a aac -ac 1 -b:a 12k -c:s copy -cluster_time_limit 1000 \
  -y "Tests/PrismCoreTests/Fixtures/h264_aac_ass_overlap_80s.mkv"
rm -f "$script"
