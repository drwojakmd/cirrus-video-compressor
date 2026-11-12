# Integration test report

21/21 passed (impossible-target re-run after a CLI fix; see below)

| case | result | output | codec | res | VMAF | text | time | settings |
|---|---|---:|---|---|---:|---:|---:|---|
| anim-balanced | ✅ | 0.65 MB | av1 | 1920×1080 | 94.9 | 100% | 296s | SVT-AV1 preset 5, 10-bit, constant quality 63 |
| anim-720p-5MB | ✅ | 0.75 MB | av1 | 1280×720 | 96.8 | 100% | 225s | SVT-AV1 preset 4, 10-bit, constant quality 54 |
| anim-apple-high | ✅ | 1.55 MB | hevc | 1920×1080 | 96.7 | 100% | 781s | x265 preset slow, 10-bit, constant quality 26 |
| finder-default | ✅ | 1.33 MB | hevc | 1920×1080 | 94.2 | 100% | 350s | x265 preset slow, 10-bit, constant quality 34 |
| av1-no-quicklook | ✅ | 0.75 MB | av1 | 1920×1080 | 96.6 | 100% | 156s | SVT-AV1 preset 5, 10-bit, constant quality 58 |
| screen-balanced | ✅ | 1.72 MB | hevc | 1920×1080 | 96.1 | 83% | 784s | x265 preset slow, 10-bit, constant quality 26 |
| screen-3MB | ✅ | 1.73 MB | hevc | 1920×1080 | 96.8 | 86% | 667s | x265 preset slow, 10-bit, constant quality 23 |
| captions-guard | ✅ | 0.43 MB | hevc | 1920×1080 | 94.3 | 98% | 606s | x265 preset slow, 10-bit, constant quality 30 |
| captions-no-guard | ✅ | 0.33 MB | hevc | 1920×1080 | 90.1 | 59% | 251s | x265 preset slow, 10-bit, constant quality 35 |
| live-1080p-15MB | ✅ | 14.29 MB | hevc | 1920×1080 | 63.9 | 36% | 1417s | x265 preset slow, 10-bit, 4421 kbps two-pass |
| live-quick-high | ✅ | 66.21 MB | hevc | 1920×1080 | 95.7 | 56% | 581s | x265 preset slow, 10-bit, constant quality 25 |
| live-h264-20MB | ✅ | 19.30 MB | h264 | 1920×1080 | 66.4 | 31% | 386s | x264 preset slower, 8-bit, 6021 kbps two-pass |
| 4k-to-1080-4MB | ✅ | 3.81 MB | hevc | 1920×1080 | 93.6 | — | 160s | x265 preset slow, 8-bit, 2438 kbps two-pass |
| 4k-best-3MB | ✅ | 2.95 MB | av1 | 1920×1080 | 93.2 | — | 284s | SVT-AV1 preset 4, 8-bit, 1776 kbps two-pass |
| portrait-720 | ✅ | 9.95 MB | hevc | 720×1280 | 92.1 | — | 253s | x265 preset slow, 8-bit, constant quality 28 |
| vfr-fastest | ✅ | 0.14 MB | hevc | 1280×360 | 93.3 | — | 10s | VideoToolbox HEVC hardware, 10-bit, constant quality 50 |
| hdr-everywhere | ✅ | 36.82 MB | hevc | 1920×1080 | 94.0 | — | 371s | x265 preset slow, 10-bit, constant quality 22 |
| short-odd-max | ✅ | 0.18 MB | hevc | 1918×1078 | 97.8 | — | 58s | x265 preset slow, 10-bit, constant quality 30 |
| skip-small-saving | ✅ | — | — | — | — | — | 498s |  |
| impossible-target | ❌ | — | — | — | — | — | 14s |  |
| folder-replace | ✅ | — | — | — | — | — | 66s |  |

## Checks

**anim-balanced** — ✓ original untouched; ✓ no partial files left behind; ✓ resolution 1920×1080 == 1920×1080; ✓ not upscaled; ✓ aspect ratio preserved; ✓ duration 60.00s ≈ 60.00s; ✓ audio present: True; ✓ codec av1; ✓ VMAF 94.90 ≥ 91; ✓ decodes cleanly

**anim-720p-5MB** — ✓ original untouched; ✓ no partial files left behind; ✓ size 0.75 MB ≤ target 5.00 MB; ✓ resolution 1280×720 == 1280×720; ✓ not upscaled; ✓ aspect ratio preserved; ✓ duration 60.00s ≈ 60.00s; ✓ audio present: True; ✓ codec av1; ✓ decodes cleanly

**anim-apple-high** — ✓ original untouched; ✓ no partial files left behind; ✓ not upscaled; ✓ aspect ratio preserved; ✓ duration 60.01s ≈ 60.00s; ✓ audio present: True; ✓ codec hevc; ✓ VMAF 96.68 ≥ 93; ✓ decodes cleanly

**finder-default** — ✓ original untouched; ✓ no partial files left behind; ✓ not upscaled; ✓ aspect ratio preserved; ✓ duration 60.01s ≈ 60.00s; ✓ audio present: True; ✓ codec hevc; ✓ decodes cleanly; ✓ Apple's player decodes it (Quick Look works); ✓ app reports Quick Look support correctly

**av1-no-quicklook** — ✓ original untouched; ✓ no partial files left behind; ✓ not upscaled; ✓ aspect ratio preserved; ✓ duration 60.00s ≈ 60.00s; ✓ audio present: True; ✓ codec av1; ✓ decodes cleanly; ✓ Apple's player cannot decode it (Quick Look unavailable); ✓ app reports Quick Look support correctly

**screen-balanced** — ✓ original untouched; ✓ no partial files left behind; ✓ resolution 1920×1080 == 1920×1080; ✓ not upscaled; ✓ aspect ratio preserved; ✓ duration 36.00s ≈ 36.00s; ✓ audio present: True; ✓ VMAF 96.10 ≥ 91; ✓ decodes cleanly

**screen-3MB** — ✓ original untouched; ✓ no partial files left behind; ✓ size 1.73 MB ≤ target 3.00 MB; ✓ not upscaled; ✓ aspect ratio preserved; ✓ duration 36.01s ≈ 36.00s; ✓ audio present: True; ✓ decodes cleanly

**captions-guard** — ✓ original untouched; ✓ no partial files left behind; ✓ not upscaled; ✓ aspect ratio preserved; ✓ duration 11.97s ≈ 11.97s; ✓ audio present: True; ✓ decodes cleanly; ✓ text reads 98% identically

**captions-no-guard** — ✓ original untouched; ✓ no partial files left behind; ✓ not upscaled; ✓ aspect ratio preserved; ✓ duration 11.97s ≈ 11.97s; ✓ audio present: True; ✓ decodes cleanly; · text reads 59% identically without the guard

**live-1080p-15MB** — ✓ original untouched; ✓ no partial files left behind; ✓ size 14.29 MB ≤ target 15.00 MB; ✓ uses the budget (≥ 85 %: 95 %); ✓ not upscaled; ✓ aspect ratio preserved; ✓ duration 24.00s ≈ 24.00s; ✓ audio present: True; ✓ 6 audio channels; ✓ decodes cleanly

**live-quick-high** — ✓ original untouched; ✓ no partial files left behind; ✓ not upscaled; ✓ aspect ratio preserved; ✓ duration 24.00s ≈ 24.00s; ✓ audio present: True; ✓ 6 audio channels; ✓ decodes cleanly

**live-h264-20MB** — ✓ original untouched; ✓ no partial files left behind; ✓ size 19.30 MB ≤ target 20.00 MB; ✓ uses the budget (≥ 85 %: 96 %); ✓ not upscaled; ✓ aspect ratio preserved; ✓ duration 24.00s ≈ 24.00s; ✓ audio present: True; ✓ codec h264; ✓ decodes cleanly

**4k-to-1080-4MB** — ✓ original untouched; ✓ no partial files left behind; ✓ size 3.81 MB ≤ target 4.00 MB; ✓ uses the budget (≥ 85 %: 95 %); ✓ resolution 1920×1080 == 1920×1080; ✓ not upscaled; ✓ aspect ratio preserved; ✓ duration 12.01s ≈ 12.00s; ✓ audio present: True; ✓ decodes cleanly

**4k-best-3MB** — ✓ original untouched; ✓ no partial files left behind; ✓ size 2.95 MB ≤ target 3.00 MB; ✓ uses the budget (≥ 85 %: 98 %); ✓ not upscaled; ✓ aspect ratio preserved; ✓ duration 12.00s ≈ 12.00s; ✓ audio present: True; ✓ decodes cleanly

**portrait-720** — ✓ original untouched; ✓ no partial files left behind; ✓ resolution 720×1280 == 720×1280; ✓ not upscaled; ✓ aspect ratio preserved; ✓ duration 8.00s ≈ 8.00s; ✓ audio present: True; ✓ decodes cleanly

**vfr-fastest** — ✓ original untouched; ✓ no partial files left behind; ✓ not upscaled; ✓ aspect ratio preserved; ✓ duration 12.00s ≈ 11.97s; ✓ audio present: False; ✓ codec hevc; ✓ decodes cleanly

**hdr-everywhere** — ✓ original untouched; ✓ no partial files left behind; ✓ not upscaled; ✓ aspect ratio preserved; ✓ duration 6.00s ≈ 6.00s; ✓ audio present: False; ✓ codec hevc; ✓ HDR kept (smpte2084, yuv420p10le); ✓ decodes cleanly

**short-odd-max** — ✓ original untouched; ✓ no partial files left behind; ✓ not upscaled; ✓ aspect ratio preserved; ✓ duration 2.52s ≈ 2.51s; ✓ audio present: True; ✓ VMAF 97.79 ≥ 94; ✓ decodes cleanly

**skip-small-saving** — ✓ original untouched; ✓ skipped: skip  screen_1080p.mp4 — Skipped: this video is already efficiently compressed. Re-encoding would save only about 25% (y; ✓ no output file kept

**impossible-target** — ✓ original untouched; ✓ fails cleanly; ✗ explains why: “”; ✓ no output file written

**folder-replace** — ✓ batch exit 0; ✓ finds 3 videos in subfolders, skips the existing output; ✓ untouched: Week 1/notes.txt; ✓ untouched: Week 2/slides.pdf; ✓ untouched: Week 2/Old (compressed).mp4; ✓ Intro.mp4: smaller (1.18 → 0.11 MB); ✓ Intro.mp4: same duration; ✓ Intro.mp4: original modification date kept; ✓ Intro.mp4: marked as a Cirrus output; ✓ Week 1/Lecture/Demo.mp4: smaller (0.77 → 0.03 MB); ✓ Week 1/Lecture/Demo.mp4: same duration; ✓ Week 1/Lecture/Demo.mp4: original modification date kept; ✓ Week 1/Lecture/Demo.mp4: marked as a Cirrus output; ✓ Week 2/Talk.mp4: smaller (10.06 → 0.31 MB); ✓ Week 2/Talk.mp4: same duration; ✓ Week 2/Talk.mp4: original modification date kept; ✓ Week 2/Talk.mp4: marked as a Cirrus output; ✓ Intro.mkv replaced by Intro.mp4; ✓ 3 originals moved to the (test) Trash; ✓ no partial or duplicate files left; ✓ re-running on the folder skips everything

## Re-run after fixes (text check calibration, CLI error output)

3/3 passed

| case | result | output | codec | res | VMAF | text | time | settings |
|---|---|---:|---|---|---:|---:|---:|---|
| captions-guard | ✅ | 0.43 MB | hevc | 1920×1080 | 94.3 | 99% | 618s | x265 preset slow, 10-bit, constant quality 30 |
| captions-no-guard | ✅ | 0.33 MB | hevc | 1920×1080 | 90.1 | 70% | 294s | x265 preset slow, 10-bit, constant quality 35 |
| impossible-target | ✅ | — | — | — | — | — | 22s |  |

## Checks

**captions-guard** — ✓ original untouched; ✓ no partial files left behind; ✓ not upscaled; ✓ aspect ratio preserved; ✓ duration 11.97s ≈ 11.97s; ✓ audio present: True; ✓ decodes cleanly; ✓ text reads 99% identically

**captions-no-guard** — ✓ original untouched; ✓ no partial files left behind; ✓ not upscaled; ✓ aspect ratio preserved; ✓ duration 11.97s ≈ 11.97s; ✓ audio present: True; ✓ decodes cleanly; · text reads 70% identically without the guard

**impossible-target** — ✓ original untouched; ✓ fails cleanly; ✓ explains why: “error: 100 KB is too small for 0:24 of 1080p video — there would only be 0 kbps for the picture. Try at least ”; ✓ no output file written
