# Encoding study and decisions

Every encoder decision in Cirrus Video Compressor comes from encodes measured on this Mac
(Apple M1 Max, 10 cores, macOS 26.3, FFmpeg 9.0.2, SVT-AV1 4.3.0, x265 4.3, x264 r3222, libvpx 1.17,
libvmaf 3.x), not from published codec comparisons. The harness is in `Benchmarks/`:

* `make_clips.py`: deterministic synthetic clips, stored as near-lossless ProRes 422 HQ 10-bit:
  an animated talking head (static gradient room, lip-sync, blinking, gesture, captions), a screen
  recording (code editor, typing, scrolling, live chart, window drag) and a fast flat-colour cartoon
  (parallax pan, bouncing sprites).
* Real camera footage: three uncompressed Xiph.org 1080p50 test sequences (crowd_run, park_joy,
  ducks_take_off). These are notoriously hard, with dense detail, grain, water and fast motion. Also a
  camera talking head and a landscape taken from media that ships with macOS.
* `bench.py`: encodes every clip at 4–6 quality points per encoder, one encode at a time, then measures
  VMAF (v0.6.1 and NEG), PSNR-Y and SSIM against the lossless master, frame-paired through Y4M pipes.
* `report.py`: bitrate needed for VMAF 90/93/95 and **BD-rate** (average bitrate difference at equal
  VMAF over the overlapping range; negative means smaller files).
* `ratecontrol.py`: how accurately each encoder hits a size target, and what bitrate-targeted encoding
  costs against constant quality.

Raw results: `Benchmarks/results/*.jsonl`. Speeds come from a separate run on an idle machine (below).
The quality runs overlapped with other work, so their fps columns are only indicative.

## 1. Camera footage (Xiph 1080p50)

BD-rate vs x264 *slow* at equal VMAF, averaged over the three sequences:

| encoder | BD-rate | notes |
|---|---:|---|
| **SVT-AV1 preset 4** | **−23.2 %** | best on every clip |
| x265 *slow* | −18.5 % | ~4× slower than SVT-AV1 p4 on this machine |
| SVT-AV1 preset 6 | −16.8 % | |
| SVT-AV1 preset 8 | −9.5 % | |
| VP9 (libvpx, cpu-used 2) | −1.5 % | slow, no advantage → not used automatically |
| x264 *slow* | 0 | reference |
| SVT-AV1 preset 10 | +1.6 % | fast presets lose AV1's advantage on hard footage |
| x265 *medium* | +3.2 % | |
| VideoToolbox HEVC (`-q:v`) | **+51.5 %** | hardware: very fast, very inefficient |

Per clip, SVT-AV1 p4 vs x264 slow: crowd_run −19.6 %, park_joy −19.3 %, ducks_take_off −30.8 %.
On extremely detailed, grainy footage the AV1 advantage is modest, and x265 *slow* comes close.
That is why **Best Possible** compares AV1 and HEVC on samples of the actual video instead of assuming.

## 2. Synthetic content (animation, talking-head animation, screen)

| encoder | BD-rate vs x264 slow |
|---|---:|
| **SVT-AV1 p4** | **−78.7 %** |
| SVT-AV1 p6 | −72.4 % |
| SVT-AV1 p8 | −63.0 % |
| VP9 cpu-used 2 | −43.8 % |
| SVT-AV1 p10 | −43.6 % |
| x265 slow | −39.1 % |
| x265 medium | −24.2 % |
| VideoToolbox HEVC | +157 % |
| VideoToolbox H.264 | +208 % |

AV1's tools for flat content (palette mode, intra block copy, large blocks, strong temporal prediction)
make an enormous difference on animation and screen content: **a 60-second static talking-head
animation reached VMAF 95 at about 30–40 kbps of video.** Treat the exact percentages with care. These
clips are very easy to compress and VMAF saturates around 97–98, but the ranking is unambiguous.

## 2b. Encoding speed (idle machine, `Benchmarks/speed.py`, median of 2 runs, 1080p)

| encoder | park_joy (camera, 50 fps) | talking-head animation (30 fps) |
|---|---:|---:|
| SVT-AV1 p4 | 21.3 fps | 78.8 fps |
| SVT-AV1 p6 | 34.9 | 112.7 |
| SVT-AV1 p8 | 52.8 | 183.1 |
| SVT-AV1 p10 | 74.6 | 274.5 |
| x265 slow | **7.9** | 35.5 |
| x265 medium | 18.9 | 89.7 |
| x264 slow | 28.5 | 176.2 |
| VP9 cpu-used 2 | 9.2 | 54.8 |
| VideoToolbox HEVC | 141.3 | 297.5 |
| VideoToolbox H.264 | 145.6 | 326.8 |

On this M1, **SVT-AV1 preset 4 is ~2.5× faster than x265 *slow* and produces smaller files.**
Rough wall-clock for a 10-minute 1080p30 video at preset 4: about 4 minutes for an animated talking
head, and about 15 minutes for hard camera footage, plus the sample search and quality check.

SVT-AV1 notes from its own log: screen-content tools are disabled at presets ≥ 9 (the screen profile
uses p4–p6), and its integrated scene-change handling replaces `scd` keyframe insertion.

## 3. Decisions that follow

| Question | Measured answer | Decision |
|---|---|---|
| Default encoder | SVT-AV1 best on all 8 clips, and p4 beats x265 *slow* on quality **and** speed | **SVT-AV1** for *Smallest File* |
| HEVC for Apple compatibility | x265 *slow* −18.5 % (live) / −39 % (synthetic); *medium* ≈ x264 | x265 **slow** (*slower* capped: ~2.5× time for ~2–3 %) |
| Hardware (VideoToolbox) | +51 % (live) to +157 % (synthetic) larger at equal VMAF | *Fastest* priority only, never automatic |
| VP9 | ≈ x264 on camera footage, slower than SVT-AV1 | Advanced setting only |
| SVT-AV1 preset | p4 −23 %, p6 −17 %, p8 −10 % | p4 for Maximum/High and for size targets; p5 for Balanced and below; faster for videos over 20 min / 60 min |
| 10-bit vs 8-bit (AV1, 8-bit camera sources) | crowd −12.4 % vs −11.6 %, park −11.6 % vs −11.6 %. **No gain**, ~35 % slower | 10-bit only for >8-bit/HDR sources, synthetic imagery, smooth gradients and dark scenes (banding risk) |
| SVT-AV1 `tune` | `tune=1` (PSNR) needed ~6 % fewer bits than `tune=0` (VQ) for the same VMAF | `tune=1`. Quality targets are VMAF-based and verified; the compare view is there for visual checks |
| Film-grain synthesis | crowd_run: −12.4 % vs −11.6 % without, even by VMAF (which penalises synthetic grain) | On for grainy camera footage (noise σ ≥ 2.2) |
| Screen-content tools (`scm=1`) | screen recording **−27.9 %** at equal VMAF; cartoon animation: no change (bit-identical). The default content-adaptive mode did not trigger on the screen clip | Forced on for the *Screen Recording* profile only |
| Keyframe interval | Static content benefits from long GOPs; seeking stays fast with modern players | 10 s, with scene-cut keyframes |
| Default format on Macs without AV1 decode | Finder's Quick Look, QuickTime and Photos use AVFoundation, which plays AV1 only with a hardware decoder (M3+). `VTIsHardwareDecodeSupported(kCMVideoCodecType_AV1)` is false on this M1 Max | Format control defaults to "HEVC · Previews in Finder" there (HEVC + AAC); "AV1 · Smallest" is one click away, with its size shown |

## 4. Content-dependent quality settings

The constant-quality value that reaches each VMAF target differs by about 20 CRF between camera footage
and synthetic imagery. A single table would therefore be badly wrong for one of them:

| VMAF target | 97 | 95 | 93 | 90 | 85 |
|---|---:|---:|---:|---:|---:|
| SVT-AV1 CRF, camera | 36 | 37 | 39 | 42 | 46 |
| SVT-AV1 CRF, synthetic | 55 | 58 | 60 | 61 | 63 |
| x265 CRF, camera | 23 | 25 | 26 | 28 | 30 |
| x264 CRF, camera | 22 | 23 | 24 | 25 | 27 |

These are medians. Per-video variation is large, which is the case for **measuring** (Smart mode)
rather than predicting. Quick mode uses these tables, one level more conservative for synthetic
content. Smart mode starts its search from them.

## 4b. Ratios used for size estimates

The settings panel shows an estimated size under every option. One light sample search is run on the
video (8 s of samples, ≤ 3 probes); every other choice is scaled from it with these medians from
`results/m1max_1080p.jsonl` (bitrate interpolated at VMAF 85–97 per clip):

| Bitrate vs Balanced (VMAF 93) | 97 | 95 | 93 | 90 | 85 |
|---|---:|---:|---:|---:|---:|
| camera footage (5 clips) | 1.50 | 1.22 | 1 | 0.75 | 0.56 |
| synthetic (3 clips) | 1.40 | 1.13 | 1 | 0.85 | ≈ 0.70 |

| Size vs SVT-AV1 p4 at equal VMAF | x265 slow | x264 slow | VT HEVC | VT H.264 |
|---|---:|---:|---:|---:|
| camera footage | 1.07 | 1.28 | 1.79 | ≈ 2.1 |
| synthetic | 2.23 | 4.6 | 4.3 | 6.6 |

(These medians at fixed VMAF points differ from the BD-rates in §1–2, which average over the whole curve:
for synthetic content, HEVC vs AV1 is 2.2× here and 2.9× by BD-rate.) Resolution changes scale bitrate by
(pixel ratio)^0.75, a common rule of thumb not measured here, so those estimates are the roughest.
Encode-time estimates use the measured speed of the sample trial and `results/speed.json`.

## 5. Rate control and size targets

`Benchmarks/ratecontrol.py`: each clip is encoded at a CRF, then re-encoded in bitrate mode targeting
exactly the bitrate the CRF encode produced. This shows how accurately each encoder hits a size, and
what bitrate-targeted encoding costs in quality (4 clips × 2 operating points):

| encoder | passes | size error vs request (median, range) | VMAF vs CRF at same size |
|---|---|---|---|
| SVT-AV1 p4 | 2 | −6.1 % (−27.2 … −2.1) | −0.19 |
| SVT-AV1 p6 | 2 | −8.6 % (−19.1 … −1.0) | −0.06 |
| x265 slow | 2 | −0.7 % (−2.4 … **+7.5**) | −0.04 |
| x264 slow | 2 | +1.7 % (−1.2 … **+11.1**) | −0.07 |
| VideoToolbox HEVC | 1 | +4.4 % (+1.1 … **+27.7**) | −0.20 |

Conclusions:
* Two-pass encoding costs essentially no quality against constant quality at the same size (≤ 0.2 VMAF
  median), so it is the right tool for size targets.
* **No encoder can be trusted to stay under a size target on its own.** x264/x265 overshoot short or
  static clips, and VideoToolbox overshoots badly. Hence: exact audio size first, per-encoder margins
  (SVT-AV1 1.00, x265/x264 0.96, VideoToolbox 0.88), then **verify the file and re-run pass 2 at a
  corrected bitrate if it is over** (reusing the pass-1 statistics).
* SVT-AV1 undershoots on easy content because it has nothing useful to spend bits on. The app then
  reports that the video reached its quality with less space.

Integration results: every size target in `Tests/integration/REPORT.md` was met.

SVT-AV1 quirk found during testing: overlay frames (`enable-overlays`) are rejected in multi-pass mode,
so they are only enabled for constant-quality encodes.

FFmpeg 9 quirk found during testing: `-color_primaries` and `-color_trc` given as output options are
ignored by all three software encoders. Colour signalling is therefore set on the frames with
`setparams`, which also keeps HDR10 (PQ/BT.2020) intact.

## 6. Quality measurement pitfalls handled

* **Frame pairing**: VMAF pairs frames by index (`setpts=N`), not by timestamp. MKV stores
  millisecond-rounded timestamps, and timestamp pairing silently matched neighbouring frames
  (a 98 VMAF encode measured 63).
* Trial encodes score ≤ ~240 sub-sampled frames. Final verification scores ≤ ~2400 frames.
* VMAF under-weights text sharpness, so screen recordings get a +1 target. It also penalises grain
  synthesis. The compare view (split/flip/zoom, weakest moments) exists so people can judge for themselves.

## 7. Text legibility guard

Inputs: `Benchmarks/make_text_clips.py` renders a 60 s lecture (titles, bullets, a dense table, 18 px footnotes,
coloured callouts, a laser pointer, transitions) and an 18 s camera clip with burnt-in captions (44 px) and a
20 px credit line. Text is found with Vision (`VNRecognizeTextRequest`, accurate, no language correction) on
5–12 frames; legibility is the share of characters (case-folded, whitespace removed) that OCR reads identically
in the encode and in the source frame at the output size (1 − character error rate), at the 4 moments with the
smallest text.

Balanced, 1080p, default effort:

| clip | format | guard off | guard on | size cost |
|---|---|---|---|---:|
| lecture | HEVC | 654 KB, 100 % legible | 715 KB, 100 % | +9 % (one-point higher VMAF target) |
| lecture | AV1 | 276 KB, 100 % | 246 KB, 100 % | −11 % (screen-content tools) |
| captions | HEVC | 228 KB, **88 %** | 332 KB, 98 % | +46 % |
| captions | AV1 | 99 KB, **82 %** | 158 KB, 100 % | +60 % |

Findings that shaped the implementation:
* Clean slides at 1080p survive Balanced untouched; the guard costs little there. Text over camera noise
  (captions) is where VMAF's average hides damage to text, and where the guard earns its cost.
* The first version checked 2-second clips and read the middle frame. It passed (97.8 %) but the full file
  measured 92 %: a frame shortly after a keyframe is cleaner than a typical frame. The check now reads a frame
  ~5 s after the clip's keyframe, and agrees with the full-file check.
* Quality is raised in steps of ≈ 2.5 VMAF-equivalents (3 CRF on SVT-AV1, 2 on x265), at most 3 times.
* Line height below ~15 px (Vision's box: ascender to descender) is treated as unreadable regardless of
  bitrate, so the guard never scales below that automatically.
