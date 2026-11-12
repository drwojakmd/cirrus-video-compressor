# Cirrus Video Compressor

*Less weight. Same picture.*

A native macOS app that makes videos as small as possible while keeping them looking as good as possible.
Drop in a video (or a whole folder of them), pick a resolution, pick a quality level or a file size, and click **Compress**.

Everything happens on your Mac. Nothing is uploaded, and your original file is never changed.

## Install

**[Download Cirrus Video Compressor](https://github.com/drwojakmd/cirrus-video-compressor/releases/latest/download/Cirrus-Video-Compressor.dmg)** (free, 22 MB) · [Website](https://drwojakmd.github.io/cirrus-video-compressor/) · [All releases](https://github.com/drwojakmd/cirrus-video-compressor/releases)

1. Open the downloaded `Cirrus-Video-Compressor.dmg` and drag **Cirrus Video Compressor** to **Applications**.
2. The first time you open it, macOS may say it "can't be opened" or comes from an "unidentified developer".
   This happens because the app is signed locally rather than notarised by Apple. Either:
   - right-click the app → **Open** → **Open**, or
   - System Settings → Privacy & Security → scroll down → **Open Anyway**.

   You only need to do this once.

Requirements: a Mac with Apple Silicon (M1 or later) running macOS 26 or later.
Everything else, including the encoders, is inside the app. You don't need Homebrew, Xcode or the command line.

## Using it

1. **Drop videos** onto the window, or click **Choose Videos…**. You can drop several videos, or folders: every video
   in every subfolder is added. Cirrus's own outputs, and originals that already have a compressed copy next to them,
   are skipped (a banner says how many, with **Add Anyway**).
   Each video is analysed straight away (size, resolution, duration, frame rate, codecs, what kind of footage it is,
   and whether it contains slides, captions or other text).
2. **Resolution**: Original, 4K, 1440p, 1080p, 720p, 480p or Custom. The aspect ratio is always kept,
   portrait videos stay portrait, and nothing is ever upscaled.
3. **File size**: either
   - **Choose quality**: one of the five levels below, or
   - **Choose file size**: 500 / 250 / 150 / 100 / 50 MB or any custom size. The result will **not** be bigger
     than the size you ask for.
4. **Format**, one choice that names the codec:
   - **AV1 · Smallest**: the most efficient format: about 7 % smaller than HEVC on camera footage and less than
     half the size on animation, slides and screen recordings. Plays in browsers, VLC, IINA, on YouTube and on
     M3-or-later Macs, but not in Finder's spacebar preview, QuickTime or Photos on M1/M2 Macs.
   - **HEVC · Previews in Finder** *(default on Macs without AV1 decoding)*: plays in Finder's preview, QuickTime
     and Photos, and on every modern iPhone, iPad and Apple TV.
   - **H.264 · Plays everywhere**: plays on practically anything, but the files are larger.
   - **Hardware · Fastest**: the Apple Silicon media engine. Very fast, larger files.

   A **"You'll get"** line at the top of the settings always shows the format, size, quality and estimated file size.
5. **Keep text readable** (on automatically when text is detected): see below.
6. Click **Compress**, or open the **Preview Studio** first.

### Several versions of one video

Not sure which settings to use, or need a big archive copy *and* a small one to send? **Add Version** turns a video
into a set of versions, shown as cards (A, B, C…) above the settings. The sidebar shows how many versions each video
has.

* Click a card to see and change that version's settings. Each card leads with what sets it apart from the others
  (e.g. "720p" vs "480p") and shows its estimated size and time.
* **Add Version** copies the current version, or adds a ready-made one: **Fit for email** (18 MB), **Fit for
  Discord** (10 MB), **Fit for WhatsApp** (16 MB), a **web set** (1080p, 720p and 480p) or **one of each format**
  (AV1, HEVC and H.264). Saved sets of versions appear here too.
* Cirrus warns about pointless versions: two that would make the same file, or one that would be bigger than another
  with no better picture.
* Before you start you see the total: "4 to make · about 850 MB · about 1 h 40 min". Then **Compress 4 Versions**.
* Each file is named after its settings, e.g. `Lecture (AV1, Balanced, 720p).mp4`. Optionally, versions go into a
  `Lecture versions` folder ("Put Versions in Their Own Folder" in the save menu).
* Afterwards, a table compares the versions you made (size, saving, quality, text, Quick Look) with **Play** and
  **Show in Finder**; **Move to Trash** drops a version you don't want.
* **Make These Versions for All Videos** (under *Apply to All*), and **Save These Versions as a Set** (in the
  Preset menu), reuse a set across a batch or next time.
* "Replace originals" makes one version per video, since only one file can take the original's place.

Every setting has a one-line explanation; click it for pros, cons and the measured numbers behind them. Under each
option you see the **estimated size for this video**, and an *Estimated result* box shows the size, the saving, the
output dimensions and the time. Estimates come from one quick measurement on sample scenes of the video, scaled by
the differences measured between settings in the benchmark study; they are labelled as estimates.

### Preview Studio

Compare a video's versions side by side before compressing, plus suggestions (a smaller level, AV1 vs HEVC, a
lower resolution) or anything you set on a card. Each option is measured on sample scenes (estimated size, % vs the
original and vs option A, dimensions, VMAF, text legibility, encode time, Quick Look support). The moments with the
smallest text and the most detail and motion are picked automatically, and you can add any other moment. Flip
between the original and the options with ← → or the number keys, at *Fit*, *Actual pixels* or *2×*. Every option shows a
frame within seconds (predicted settings, labelled as such) while its exact measurement runs. The ticked options
*are* the video's versions: tick **Make this version** to add a suggestion, untick to drop one, or **Only This** to
keep just one. Changes show in the main window too, and **Compress N Versions** makes them all.

### Keep text readable

Cirrus finds slides, captions and on-screen text with Apple's on-device text recognition and measures how small
the smallest text is. When the guard is on:
- it reads the text back from test encodes and raises quality until ≥ 97 % of the characters read the same as in
  the original;
- it never lowers the resolution (automatically) below the point where the smallest text stays readable, and warns
  you, with a one-click fix, if your chosen resolution would make it too small;
- it switches off film-grain synthesis, and uses AV1's screen-content tools on slides.

Every finished file with text gets a legibility check either way ("98 % of on-screen text reads identically").
Measured cost: lecture slides at Balanced needed nothing extra (+9 % on HEVC from the one-point higher target, −11 %
on AV1 thanks to the screen-content tools); captions on camera footage went from 88 % to 98 % legible for +46 %
(HEVC) and from 82 % to 100 % for +60 % (AV1). See `Docs/ENCODING.md` §7.

### Folders, batches and replacing originals

- **Apply to All** copies one video's settings to every video in the list. **Presets** save named combinations
  (four are built in: Lecture archive, YouTube upload, Smallest possible, Share with Apple devices).
- **Where results go**: next to the original (default, as `Name (compressed).mp4`), in a chosen folder, or
  **in place of the original**. In replace mode the original goes to the **Trash** only after its compressed copy
  is finished and verified (it decodes, has the same length and sound, and is smaller); the copy takes the
  original's name (as `.mp4`), creation and modification dates and Finder tags. Other files and folders are never
  touched. You confirm before a batch starts.
- **Skip if saving under 10 %** (adjustable, or off): videos that are already efficiently compressed are left as
  they are instead of being re-encoded for a few percent.
- Changed your mind? **Restore Originals** in the batch report (or **Restore Original** on a single result) brings
  the originals back from the Trash and moves the compressed copies there instead.
- Batches keep the Mac awake, show progress on the Dock icon, survive quitting or a crash (Cirrus offers to
  resume), and end with a **batch report** (before/after, saved, VMAF and text legibility per video), exportable
  as CSV. The sidebar keeps a running total of the space Cirrus has saved you.

When it finishes you'll see the original and compressed sizes, the saving, the resolution, the codec, a **measured** quality
rating, the text legibility check, and whether the file plays in Quick Look on this Mac. From there you can **Play** the file, **Show in Finder**, or **Compare with Original**: side-by-side,
a draggable split, or flip, with zoom up to 8× and jump-to-weakest-moment.

### Compression modes

| Mode | What it aims for | Measured target |
|---|---|---|
| **Maximum Quality** | Visually indistinguishable from the original, still much smaller | VMAF ≈ 97 |
| **High Quality** | Excellent. Differences are only visible when you pause and compare | VMAF ≈ 95 |
| **Balanced** *(default)* | Strong compression with very good quality | VMAF ≈ 93 |
| **Aggressive** | Small files. Fine detail softens in busy scenes | VMAF ≈ 90 |
| **Maximum Compression** | Smallest files. Some visible quality loss is likely | VMAF ≈ 85 |

These are **not fixed bitrates**. With the default **Smart** effort, the app trial-encodes short samples of
*your* video and measures them, then picks the setting that just reaches the target. A static talking-head
animation might reach Balanced at 150 kbps, while a crowd scene might need 15 Mbps.

**Effort**:
- **Quick** predicts settings from the content analysis, with no trial encodes.
- **Smart** *(default)* tunes on samples. It adds a few percent to the encode time.
- **Best Possible** also compares encoders (AV1 vs HEVC) and resolutions on samples, then picks whichever
  measures best.

**Target size, honestly**: the app subtracts the audio and container overhead from your target, encodes in two
passes, and then checks the result. If the file came out even slightly over, it re-encodes to fix it. If the
target is more than the video needs, it stops at near-transparent quality and tells you, instead of wasting space.
If the target is unrealistic, it tells you the smallest sensible size. If a lower resolution would measurably
look better at your size, it uses that resolution and says so. You can turn that off in Advanced.

**Content profiles**: detected automatically, or override them under *Content*:
- *Talking Head / Animation*: static backgrounds, flat colours, outlines, lip-sync, captions.
  Long keyframe intervals let static scenes cost almost nothing, and HEVC/H.264 get their animation tuning.
- *Screen Recording*: text and UI. AV1's screen-content tools (palette mode, intra block copy) are switched on,
  and the quality target is raised by 1 point because VMAF under-weights text sharpness.
- *Live Action*: camera footage. On grainy footage, AV1 film-grain synthesis stores the grain as a model
  instead of pixel by pixel.
- *General Purpose*: neutral settings.

**Audio**: Automatic picks Opus with AV1 and AAC (Apple's encoder) with HEVC/H.264. It never spends more
bits than the original had, keeps an already-efficient AAC track untouched, preserves 5.1/7.1, and stores
"stereo" tracks that are really mono as mono. *High / Standard / Smaller File* pick fixed tiers.

**Advanced** (hidden by default): encoder, speed, manual quality value, explicit VMAF target, frame-rate cap,
keyframe interval, 8/10-bit, film grain, audio codec and bitrate, prefer hardware, allow lower resolution,
quality measurement on/off, and raw encoder parameters.

Settings are remembered between launches. Videos are compressed one after another in a queue. You can keep
adding while it works, and cancel at any time (nothing half-written is left behind).

## Command line

The app also contains a command-line version of the engine:

```bash
"/Applications/Cirrus Video Compressor.app/Contents/Helpers/cirrus" compress input.mov --res 1080 --target 150MB
```

Run it with no arguments for the options (`--quality`, `--priority`, `--depth`, `--audio`, `--vmaf`, `--text-guard`,
`--smallest`, `--min-savings`, `--json`, …). Give it a folder to compress every video inside, and `--replace` to
replace the originals (originals to the Trash) as the app does.

## Updating

- **New version of the app**: replace the app in Applications with the new one. Your settings are kept.
- **Building from source**: you need the Command Line Tools (`xcode-select --install`) and Homebrew's FFmpeg
  (`brew install ffmpeg`, which includes SVT-AV1, x265, x264, Opus and libvmaf). Then:

  ```bash
  Scripts/build_app.sh --dmg
  ```

  This produces `build/Cirrus Video Compressor.app` and a `.dmg`. To pick up newer encoders, run
  `brew upgrade ffmpeg` and rebuild. The build script bundles whichever FFmpeg it finds (or `FFMPEG_DIR`).
- **Retuning the engine** after encoder upgrades: run `Benchmarks/run_bench2.sh`, then `Benchmarks/report.py`,
  and update the constants in `Sources/CirrusCore/Planning/EncodePlan.swift` (`EngineTuning`).

## Known limitations

- **Apple Silicon and macOS 26+ only.** The bundled FFmpeg libraries come from Homebrew bottles built for
  this macOS. Supporting older macOS needs FFmpeg built with an older deployment target (the build script
  accepts any FFmpeg via `FFMPEG_DIR`).
- **Not notarised**, so first launch needs right-click → Open (see Install). Notarisation needs a paid Apple
  Developer ID.
- **AV1 playback on M1/M2**: Finder's preview, QuickTime and Photos can't play AV1 on these chips (Apple has no
  software AV1 decoder). That's why *HEVC · Previews in Finder* is the default format there; results that won't preview
  are labelled.
- **VMAF is a model of perception, not perception.** It under-weights text sharpness and penalises film-grain
  synthesis even when the result looks better. That's why text is checked separately with OCR and why the
  Preview Studio and compare view exist. OCR checks the text it can read: decorative or handwritten text that
  Apple's recogniser can't read in the original isn't covered. Quality ratings are always measured, never invented. With measurement switched off,
  the app says "Not measured".
- **AV1 software encoding is CPU-heavy.** On an M1, *Maximum Quality* on long 4K videos can take a long time.
  Long videos automatically use a faster preset. *Fastest* uses the hardware encoder.
- **Single audio track**: only the first audio track is kept. Text subtitles and chapters are kept when the
  container supports them. Bitmap subtitles (DVD/Blu-ray) are dropped.
- **Dolby Vision** metadata is not preserved. The HDR10 base layer and its signalling are.
- **Licensing**: the bundled FFmpeg includes x264 and x265, which makes it GPL software. Giving the app away is
  fine as long as the corresponding FFmpeg source is offered alongside it (a link on the download page is enough).
  See `Contents/Resources/Licenses/THIRD_PARTY_NOTICES.txt`.

## More

- `Docs/ARCHITECTURE.md`: how it's built
- `Docs/ENCODING.md`: benchmark results on this M1 and the encoder decisions they led to
- `Docs/YOUTUBE_BENCHMARK.md`: how to compare against YouTube's processing
- `Tests/integration/REPORT.md`: latest end-to-end test results
