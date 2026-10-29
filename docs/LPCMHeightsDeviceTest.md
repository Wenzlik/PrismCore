# `HeightsOutput.lpcm` on Apple TV + AV receiver (issue #176)

`.lpcm` is experimental. On macOS 27 AVPlayer refuses LPCM with height
channels (`'fmt?'`); whether tvOS hands it to an AV receiver over HDMI (as
Dolby MAT) is the open question this test answers. `.apac` stays the
default, and AirPlay stays on it.

## What you need

- Apple TV 4K on tvOS 26 or later, HDMI into an Atmos-capable AVR.
  Settings → Video and Audio → Audio Format: Dolby Atmos on, Change Format
  allowed.
- A Mac on the same network, this branch built
  (`swift build -c release --product prismcore-cli`).
- A TrueHD **Atmos** source, cut to a minute with the Atmos track as its only
  audio, so the player picks it by default
  (`ffmpeg -ss 600 -t 60 -i film.mkv -map 0:v:0 -map 0:a:N -c copy clip.mkv`, N = the Atmos track). A channel-check
  clip with overhead content makes the result unambiguous. The test fixtures
  in `Tests/` are TrueHD without objects and produce no `ipcm` rendition.
- A tvOS app that plays an HLS URL with AVPlayer (a minimal
  `AVPlayerViewController` app, or a host app's debug URL field).

## Steps

1. Generate the four layouts:
   `Scripts/lpcm-heights-hls.sh clip.mkv out`
   Each prints `5.1.2: out/5.1.2/master.m3u8` (… 5.1.4, 7.1.2, 7.1.4) once its
   audio init segment carries `ipcm`. A line on stderr means that
   layout produced no `ipcm` rendition; its `out/<layout>.report.json` says why.
2. Serve the tree: `cd out && python3 -m http.server 8000`.
3. On the Apple TV open `http://<mac-ip>:8000/<layout>/master.m3u8` for each
   of 5.1.2, 5.1.4, 7.1.2, 7.1.4.
4. Optional, the real pipeline: a host app built against this branch on the
   Apple TV itself, `PrismCoreSession(…, objectAudioRendering: .heights,
   allowsAtmosOutput: true, heightsLayout: <layout>, heightsOutput: .lpcm)`; the same with the default `.apac` is the baseline.

## Record per layout

| Layout | Plays? (or `AVPlayerItem.error` domain/code) | AVR input format shown | Heights audible on the right speakers? |
| --- | --- | --- | --- |
| 5.1.2 (8 ch) | | | |
| 5.1.4 (10 ch) | | | |
| 7.1.2 (10 ch) | | | |
| 7.1.4 (12 ch) | | | |

Post the table to issue #176. Any layout that plays with its heights on the
right speakers is the evidence `.lpcm` needs to stop being experimental; a
`'fmt?'` (or equivalent) refusal on all four parks it for good.
