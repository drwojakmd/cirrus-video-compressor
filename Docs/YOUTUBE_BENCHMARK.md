# Benchmarking against YouTube

YouTube's encoder pipeline is proprietary: it uses per-title/per-shot optimisation, custom encoder builds
and, for popular videos, extra encoding passes. We can't reproduce it. We **can** measure its public output
and compare it with ours on equal terms.

## What "equal terms" means

* **Same source.** Upload the exact file you compress locally (ideally the highest-quality master you have).
  YouTube re-encodes from your upload, so the upload is the reference for both.
* **Same resolution and frame rate.** Compare YouTube's 1080p rendition with our 1080p output. YouTube keeps
  frame rate up to 60 fps. Check that `ffprobe` shows the same rate.
* **Same metric and reference.** Both are scored with VMAF v0.6.1 against the original, scaled to the
  compared resolution with the same Lanczos scaler.
* **Video and audio counted separately.** YouTube serves video and audio as separate streams (DASH).
  Sizes are measured as elementary-stream bytes, not file sizes, so container overhead doesn't skew them.
* **Pick the right YouTube format.** A video can have several 1080p renditions:

  | itag | codec | notes |
  |---|---|---|
  | 399 | AV1 | Most efficient. Not always generated (more likely on popular or long-processed videos) |
  | 248 | VP9 | Common |
  | 137 | H.264 | Always present, least efficient |
  | 251 / 140 | Opus ~130 kbps / AAC 128 kbps | Audio |

  Compare like with like (YouTube AV1 against our *Smallest File*; YouTube H.264 against *Plays Everywhere*),
  and also compare against YouTube's best rendition.
* **Wait for processing to finish.** The AV1/VP9 renditions often appear hours after upload.
* **Account and playback conditions.** YouTube may give higher-bitrate encodes to some videos (e.g. "1080p
  Premium") and serves different formats to different clients. Record which itags you downloaded.

## Procedure

```bash
# 1. upload original.mp4 to YouTube as Unlisted, wait for processing to complete
# 2. list and download the renditions (yt-dlp, https://github.com/yt-dlp/yt-dlp)
yt-dlp -F "https://youtu.be/<id>"
yt-dlp -f 399 -o yt_1080_av1.mp4 "https://youtu.be/<id>"
yt-dlp -f 251 -o yt_audio.webm   "https://youtu.be/<id>"
# 3. compare
Benchmarks/youtube_compare.py original.mp4 --yt-video yt_1080_av1.mp4 --yt-audio yt_audio.webm \
    --cirrus "/Applications/Cirrus Video Compressor.app/Contents/Helpers/cirrus"
```

The script reports:

1. **YouTube**: codec, video kbps, VMAF, worst-5% VMAF, PSNR.
2. **Cirrus at equal size**: we encode with a target equal to YouTube's video + audio bytes, then compare quality.
3. **Cirrus at equal quality**: we encode with `--vmaf` set to YouTube's measured VMAF, then compare size.
   *This answers "is our file smaller than YouTube's at the same perceived quality?"*
4. Side-by-side PNGs (original | encode) at YouTube's weakest frame, and 10-second WAV clips of each audio
   track for blind listening. There is no trustworthy open perceptual audio metric bundled with FFmpeg,
   so audio is compared by codec, bitrate and ear.

Results go to `Benchmarks/results/youtube/report.md`.

## Interpreting results

* A VMAF difference under ~1 point is generally not visible. Under ~2–3 points it's hard to see in motion.
* Look at the worst-5% column, not just the mean. Averages hide ugly moments.
* Check the PNGs for text and fine detail. VMAF is weakest there.
* YouTube has a structural advantage on very long or very popular videos (more encoding effort). We have one
  on short videos, because Cirrus runs the encoder at a slower preset than YouTube can afford across its
  catalogue, and searches quality per video.

## Status

This needs a video uploaded from your own account, so it can't be run automatically. The tooling is in
place and tested end-to-end on a locally simulated "YouTube-like" rendition (SVT-AV1 at a typical YouTube
1080p AV1 bitrate). Real YouTube results will be added to this file when you run it on your own uploads.
