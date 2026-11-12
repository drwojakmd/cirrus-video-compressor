# Architecture

Cirrus Video Compressor is a native SwiftUI app on top of a UI-independent
engine (`CirrusCore`). The engine drives FFmpeg/FFprobe as separate processes.
The UI never builds an FFmpeg command line.

```
┌──────────────────────── CirrusApp (SwiftUI, macOS 14+) ────────────────────────┐
│ AppModel (queue, prefs) · Sidebar · Detail (source, settings, plan summary)   │
│ Progress / Result cards · CompareView (split / side-by-side / flip, zoom)     │
└──────────────────────────────────┬────────────────────────────────────────────┘
                                   │ async/await, progress callbacks
┌──────────────────────────────────▼──────────── CirrusCore ─────────────────────┐
│ CompressionEngine (façade)                                                    │
│   inspect ──► MediaProbe (ffprobe JSON, VFR check)                            │
│           ├─► ContentAnalyzer (frame bursts → statistics → ContentClassifier) │
│           └─► AudioAnalyzer (dual-mono detection)                             │
│   plan ────► EncodePlanner (pure: settings + facts → EncodePlan)              │
│   decide ──► Optimizer (SampleBuilder, trial encodes, QualityMeter/VMAF,      │
│              quality search, target-size & Best-Possible comparisons)         │
│   execute ─► audio first → video (1- or 2-pass) → size verification loop      │
│              → full-video VMAF → atomic rename                                │
│ Encoders: SVTAV1Encoder · X265Encoder · X264Encoder · VideoToolboxEncoder ·   │
│           VP9Encoder   (each only maps parameters → FFmpeg arguments)         │
│ Support: ProcessRunner (cancellable, registry), ToolLocator, TempWorkspace,   │
│          Log (os_log + ~/Library/Logs/Cirrus Video Compressor/engine.log)      │
└──────────────────────────────────┬────────────────────────────────────────────┘
                                   │ Process (SIGTERM → SIGKILL on cancel)
                    Contents/Helpers/ffmpeg, ffprobe  (+ Contents/Frameworks/*.dylib)
```

`cirrus` is a command-line front end to the same engine. The integration tests and
the YouTube comparison script use it, and it's handy for batch scripting.

## Key decisions

| Decision | Choice | Why |
|---|---|---|
| UI | SwiftUI, Observation (`@Observable`), macOS 14+ | Native look and behaviour. No web view. |
| Media engine | FFmpeg as a **separate process** | Gives access to SVT-AV1, x265, x264, libvpx, VideoToolbox and libvmaf behind one interface. A crash in a codec can't take the app down. Licensing stays clean, because the app is not linked against GPL code. |
| AVFoundation | Used for playability checks; thumbnails and compare frames come from FFmpeg | AVFoundation can't decode AV1 on M1/M2, MKV/WebM, or many legacy codecs. FFmpeg decodes everything the same way. |
| Primary encoder | SVT-AV1 (see Docs/ENCODING.md) | Measured best quality per byte on this Mac across all content types, and faster than x265 *slow* at a better result. |
| Hardware encoding | VideoToolbox HEVC/H.264 only for "Fastest" | Measured 2.5–3× larger files at equal VMAF. Excellent speed, poor efficiency. |
| Quality target | VMAF (Netflix), measured, never estimated | The only widely validated open perceptual metric. Libvmaf's built-in models mean no model files to ship. |
| Target size | Exact audio first, then two-pass video, then verify and correct | Two-pass rate control is accurate to ~1–2%. The verification loop guarantees "≤ target". |
| Optimisation | Trial encodes on ~20 s of lossless samples | Costs a fraction of one full encode, instead of repeated full encodes. |
| Concurrency | One job at a time, encoder uses all cores | SVT-AV1/x265 already saturate the M1's cores. Running two jobs at once only adds memory pressure. |

## Pipeline of one job

1. **Inspect**: ffprobe facts. 4–16 bursts of 10 frames, analysed at 960 px for spatial/temporal
   complexity, flat/two-tone/texture blocks, noise, frozen pixels and dark/gradient areas. These give
   the content kind and the synthetic/grain/banding flags. Dual-mono audio detection.
2. **Plan** (pure function): output geometry (bounding box, orientation, never upscale, even sizes),
   filters (deinterlace, scale, fps cap), encoder from the priority, bit depth, film grain,
   keyframe interval, effort, audio plan, rate strategy, notes and warnings. This is shown live in the UI.
3. **Decide** (Optimizer, cached per video and settings for the session):
   - *Quality mode*: binary/secant search for the most compressed value whose sample VMAF ≥ the level's
     target. It is also capped so the output never exceeds 85% of an already-compressed source's bitrate.
   - *Target size*: two-pass trial at the budget bitrate gives a measured quality prediction. If that is
     already transparent (≥ 97), it finds the constant-quality setting that needs less space. If it is
     tight, a lower resolution is tried and must win by ≥ 1 VMAF to be chosen.
   - *Best Possible*: the same, across encoders (SVT-AV1 vs x265) and resolutions.
4. **Execute**: audio is encoded first, so its exact size is known. The video budget is recomputed. Then a
   one- or two-pass encode muxes MP4 with `+faststart`, metadata and chapters. Output goes to a hidden
   `.…cirrus-partial…` file next to the destination.
5. **Verify**: if the file is over the target, pass 2 is re-run at a corrected bitrate, reusing the pass-1
   statistics (at most twice). It is never silently delivered over the target.
6. **Measure**: full-video VMAF/PSNR/SSIM, sub-sampled to ≤ ~2400 frames. The worst moments are kept
   for the compare view.
7. **Finish**: atomic rename to `Name (compressed).mp4`. It never overwrites, and is never the source path.

## Safety

* Sources are only ever opened for reading. Output paths are checked against the source and made unique.
* Every child process is registered. Quitting the app terminates all of them (SIGTERM, then SIGKILL).
* Temporary data lives in `$TMPDIR/CirrusVideoCompressor/job-*`. It is deleted on completion or failure,
  and stale folders are swept at launch.
* Disk space is checked before starting.

## Extending

* **New encoder**: implement `VideoEncoder` (arguments only), add it to `EncoderID`/`EncoderRegistry`,
  and add tuning rows to `EngineTuning`.
* **New optimisation strategy**: compose `Optimizer.trial(...)` calls inside `CompressionEngine.decide`.
* **Retuning**: `EngineTuning` holds every benchmark-derived constant. Re-run `Benchmarks/` and update it.

## Added in 1.1

* `Analysis/TextAnalyzer.swift`: Vision text detection at inspection (`TextAnalysis`), OCR comparison
  (`TextLegibilityChecker`), thresholds (`TextLegibility`).
* `EncodePlan.textGuard` (`TextGuardPlan`): active/automatic, reason, minimum readable short side, moments to check,
  suggested resolution. `CompressionEngine.guardText` raises quality after the VMAF search until text reads
  correctly; the finished file is checked again.
* `FFmpegCapabilities.systemDecodesAV1` (VideoToolbox) drives the Format control's default: the app's
  `FormatChoice` maps AV1 / HEVC / H.264 / Hardware onto the engine's priority and
  `CompressionSettings.previewableOnThisMac`; results report `CompressionResult.previewableOnThisMac`.
* Versions: a `QueueItem` (one video) holds `versions: [OutputVersion]`, each with its own settings and job;
  `QueueItem.settings` is the selected version's. The runner takes queued versions in list order;
  `compress(…, versionLabel:)` names outputs "<name> (<label>).mp4" when a video has several. Quick adds, "same
  output" detection, pointless-version warnings and totals are in `App/Versions.swift`; Preview Studio options link
  to versions (`Option.linked`). `Preset.versions` stores a set of versions. `OriginalReplacer.restore` undoes a replacement; `CompressionResult.trashedOriginal` records where it went.
* Preview Studio speed: sample scenes and the near-lossless text reference are cached per video
  (`DecisionCache`), and `predictedDecision` gives a frame within seconds before the measured decision.
* `CompressionSettings.minimumSavings` → `CirrusError.notWorthIt`, checked on the sample prediction and on the
  finished file; the app shows these as "Left as it is".
* `Pipeline/VideoScanner.swift` (recursive folder expansion, skip rules) and `Pipeline/Replace.swift`
  (`CirrusMarker` extended attribute on every output; `OriginalReplacer`: verify → Trash → rename → dates/tags).
* `Pipeline/Studio.swift`: light decisions (`evaluate`), frames encoded with the exact final settings
  (`encodedFrame`), and `SizeEstimator` ratios for the settings panel.
* App: presets and the saved queue (`Preferences.swift`), batch record and CSV (`AppModel.swift`), Preview Studio,
  batch report, About window, and the brand components (`StreaksView`, `ConvergenceProgress`) in `Components.swift`.
