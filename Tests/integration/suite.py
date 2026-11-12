#!/usr/bin/env python3
"""
End-to-end test suite: runs the real engine (via the `cirrus` CLI) on realistic
inputs and checks the promises the app makes:

  * the original file is never modified
  * size targets are met (output ≤ target) and not wildly undershot
  * output resolution / orientation / aspect are right; never upscaled
  * duration, audio presence and channel layout are preserved
  * HDR signalling survives; VFR timing survives
  * quality levels reach their measured VMAF floors
  * the output decodes cleanly from start to end
  * impossible requests fail with a clear message, not a bad file
  * "Preview in Finder" outputs play in Apple's own player (AVFoundation)
  * the text guard keeps captions readable (on-device OCR on the result)
  * videos that would save too little are skipped, original untouched
  * folder batches in "replace originals" mode: originals replaced only when
    verified, other files untouched, names/dates kept, outputs never re-added

Usage: suite.py [--cirrus PATH] [--only NAME...] [--report Tests/integration/REPORT.md]
"""
import argparse, hashlib, json, os, platform, re, shutil, subprocess, sys, tempfile, time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
INPUTS = ROOT / "Tests/integration/inputs"

# name, input, cirrus args, expectations
MAC_DECODES_AV1 = not re.search(r"Apple M[12]\b", subprocess.run(["sysctl", "-n", "machdep.cpu.brand_string"], capture_output=True, text=True).stdout)

# name, input, cirrus args, expectations
# (--min-savings 0 is added unless a case sets it: these cases test encoding, not skipping)
CASES = [
    ("anim-balanced",      "th_animation_1080p.mp4", ["--quality", "balanced", "--smallest"],           dict(res=(1920, 1080), vmaf_min=91, codec="av1")),
    ("anim-720p-5MB",      "th_animation_1080p.mp4", ["--res", "720", "--target", "5MB", "--smallest"], dict(res=(1280, 720), target=5e6, codec="av1")),
    ("anim-apple-high",    "th_animation_1080p.mp4", ["--priority", "apple", "--quality", "high"],      dict(codec="hevc", vmaf_min=93)),
    ("finder-default",     "th_animation_1080p.mp4", ["--quality", "balanced"],                         dict(codec="av1" if MAC_DECODES_AV1 else "hevc", quicklook=True)),
    ("av1-no-quicklook",   "th_animation_1080p.mp4", ["--quality", "balanced", "--smallest", "--depth", "quick"], dict(codec="av1", quicklook=MAC_DECODES_AV1)),
    ("screen-balanced",    "screen_1080p.mp4",       ["--quality", "balanced"],                         dict(res=(1920, 1080), vmaf_min=91)),
    ("screen-3MB",         "screen_1080p.mp4",       ["--target", "3MB"],                               dict(target=3e6)),
    ("captions-guard",     "captions.mp4",           ["--quality", "aggressive"],                       dict(text_min=0.97)),
    ("captions-no-guard",  "captions.mp4",           ["--quality", "aggressive", "--text-guard", "off"], dict(text_report=True)),
    ("live-1080p-15MB",    "live_crowd_5.1.mp4",     ["--res", "1080", "--target", "15MB"],             dict(target=15e6, channels=6)),
    ("live-quick-high",    "live_crowd_5.1.mp4",     ["--quality", "high", "--depth", "quick"],         dict(channels=6)),
    ("live-h264-20MB",     "live_crowd_5.1.mp4",     ["--priority", "everywhere", "--target", "20MB"],  dict(target=20e6, codec="h264")),
    ("4k-to-1080-4MB",     "landscape_4k.mp4",       ["--res", "1080", "--target", "4MB"],              dict(res=(1920, 1080), target=4e6)),
    ("4k-best-3MB",        "landscape_4k.mp4",       ["--res", "1080", "--target", "3MB", "--depth", "best", "--smallest"], dict(target=3e6)),
    ("portrait-720",       "portrait_phone.mov",     ["--res", "720", "--quality", "balanced"],         dict(res=(720, 1280))),
    ("vfr-fastest",        "vfr_noaudio.mp4",        ["--priority", "fastest", "--quality", "balanced"], dict(codec="hevc", audio=False)),
    ("hdr-everywhere",     "hdr10.mp4",              ["--priority", "everywhere", "--quality", "balanced"], dict(codec="hevc", hdr=True)),
    ("short-odd-max",      "short_odd.mkv",          ["--quality", "max"],                              dict(vmaf_min=94)),
    ("skip-small-saving",  "screen_1080p.mp4",       ["--quality", "max", "--min-savings", "99"],       dict(expect_skip=True)),
    ("impossible-target",  "live_crowd_5.1.mp4",     ["--target", "100KB"],                             dict(expect_fail=True)),
    ("folder-replace",     None,                     ["--quality", "aggressive", "--depth", "quick"],   dict(folder=True)),
]


def sh(*a, **k):
    return subprocess.run(a, capture_output=True, text=True, **k)


def probe(p):
    j = json.loads(sh("ffprobe", "-v", "error", "-show_format", "-show_streams", "-of", "json", str(p)).stdout)
    v = next(s for s in j["streams"] if s["codec_type"] == "video")
    a = [s for s in j["streams"] if s["codec_type"] == "audio"]
    rot = 0
    for sd in v.get("side_data_list", []):
        rot = int(sd.get("rotation", 0)) or rot
    w, h = v["width"], v["height"]
    if abs(rot) % 180 == 90:
        w, h = h, w
    return dict(w=w, h=h, codec=v["codec_name"], pix=v.get("pix_fmt"), trc=v.get("color_transfer"),
                duration=float(j["format"]["duration"]), size=int(j["format"]["size"]),
                audio=len(a) > 0, channels=a[0]["channels"] if a else 0)


def digest(p):
    h = hashlib.sha256()
    with open(p, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


AVPLAYABLE = None


def quicklook_plays(path):
    """Apple's own decoder (AVFoundation) can decode a frame: what Finder's preview uses."""
    return sh(AVPLAYABLE, str(path)).returncode == 0


def run_folder_case(cirrus, name, args, workdir):
    """A folder tree with videos at several depths, non-video files and an existing Cirrus
    output. Compress it in replace mode and check every promise of that mode."""
    checks, ok = [], True

    def check(cond, msg):
        nonlocal ok
        checks.append(("✓" if cond else "✗") + " " + msg)
        ok = ok and cond

    tree, trash = workdir / "Course", workdir / "Trash"
    (tree / "Week 1" / "Lecture").mkdir(parents=True); (tree / "Week 2").mkdir(); trash.mkdir()
    shutil.copy(INPUTS / "short_odd.mkv", tree / "Intro.mkv")
    shutil.copy(INPUTS / "vfr_noaudio.mp4", tree / "Week 1" / "Lecture" / "Demo.mp4")
    shutil.copy(INPUTS / "captions.mp4", tree / "Week 2" / "Talk.mp4")
    shutil.copy(INPUTS / "short_odd.mkv", tree / "Week 2" / "Old (compressed).mp4")       # looks like an earlier output
    (tree / "Week 1" / "notes.txt").write_text("keep me\n")
    (tree / "Week 2" / "slides.pdf").write_bytes(b"%PDF-1.4 test\n")
    others = {p: digest(p) for p in [tree / "Week 1" / "notes.txt", tree / "Week 2" / "slides.pdf", tree / "Week 2" / "Old (compressed).mp4"]}
    old_mtime = 1_600_000_000
    for v in [tree / "Intro.mkv", tree / "Week 1" / "Lecture" / "Demo.mp4", tree / "Week 2" / "Talk.mp4"]:
        os.utime(v, (old_mtime, old_mtime))
    sizes = {v.relative_to(tree): v.stat().st_size for v in tree.rglob("*") if v.is_file()}
    durations = {p: probe(tree / p)["duration"] for p in [Path("Intro.mkv"), Path("Week 1/Lecture/Demo.mp4"), Path("Week 2/Talk.mp4")]}

    t0 = time.time()
    r = sh(cirrus, "compress", str(tree), "--replace", "--min-savings", "0", *args, env={**os.environ, "CIRRUS_TEST_TRASH": str(trash)})
    secs = time.time() - t0
    check(r.returncode == 0, "batch exit 0" + ("" if r.returncode == 0 else ": " + r.stderr.strip()[-300:]))
    check("3 videos to compress, 1 skipped" in r.stdout, "finds 3 videos in subfolders, skips the existing output")
    for p, h in others.items():
        check(p.exists() and digest(p) == h, f"untouched: {p.relative_to(tree)}")
    for orig, final in [("Intro.mkv", "Intro.mp4"), ("Week 1/Lecture/Demo.mp4", "Week 1/Lecture/Demo.mp4"), ("Week 2/Talk.mp4", "Week 2/Talk.mp4")]:
        f = tree / final
        if not f.exists():
            check(False, f"{final} in place"); continue
        o = probe(f)
        check(f.stat().st_size < sizes[Path(orig)], f"{final}: smaller ({sizes[Path(orig)]/1e6:.2f} → {o['size']/1e6:.2f} MB)")
        check(abs(o["duration"] - durations[Path(orig)]) < 0.3, f"{final}: same duration")
        check(abs(f.stat().st_mtime - old_mtime) < 2, f"{final}: original modification date kept")
        check("app.cirrusvideo.compressed" in sh("xattr", str(f)).stdout, f"{final}: marked as a Cirrus output")
    check(not (tree / "Intro.mkv").exists(), "Intro.mkv replaced by Intro.mp4")
    check(len(list(trash.iterdir())) == 3, "3 originals moved to the (test) Trash")
    check(not list(tree.rglob(".*cirrus-partial*")) and not list(tree.rglob("* (compressed).mp4"))[1:], "no partial or duplicate files left")
    again = sh(cirrus, "compress", str(tree), "--replace", *args, env={**os.environ, "CIRRUS_TEST_TRASH": str(trash)})
    check("0 videos to compress" in again.stdout, "re-running on the folder skips everything")
    return dict(name=name, ok=ok, checks=checks, secs=secs)


def run_case(cirrus, name, inp, args, exp, outdir):
    if exp.get("folder"):
        return run_folder_case(cirrus, name, args, outdir)
    src = INPUTS / inp
    if "--min-savings" not in args:
        args = args + ["--min-savings", "0"]
    before = (digest(src), src.stat().st_mtime)
    t0 = time.time()
    r = sh(cirrus, "compress", str(src), *args, "--out", str(outdir), "--json")
    secs = time.time() - t0
    checks, ok = [], True

    def check(cond, msg):
        nonlocal ok
        checks.append(("✓" if cond else "✗") + " " + msg)
        ok = ok and cond

    check((digest(src), src.stat().st_mtime) == before, "original untouched")
    if exp.get("expect_fail"):
        check(r.returncode != 0, "fails cleanly")
        msg = (r.stderr.strip().splitlines() or [""])[-1]
        check("too small" in msg or "Try at least" in msg, f"explains why: “{msg[:110]}”")
        check(not any(outdir.glob(f"{src.stem}*")), "no output file written")
        return dict(name=name, ok=ok, checks=checks, secs=secs)
    if exp.get("expect_skip"):
        check(r.returncode == 0 and "skip" in r.stdout, "skipped: " + (r.stdout.strip().splitlines() or [""])[-1][:120])
        check(not any(outdir.glob("*")), "no output file kept")
        return dict(name=name, ok=ok, checks=checks, secs=secs)
    if r.returncode != 0:
        check(False, "exit 0: " + r.stderr.strip()[-300:])
        return dict(name=name, ok=ok, checks=checks, secs=secs)
    res = json.loads(r.stdout)
    from urllib.parse import urlparse, unquote
    u = res["outputURL"]
    out = Path(unquote(urlparse(u).path)) if u.startswith("file:") else Path(u)
    s, o = probe(src), probe(out)
    check(not list(outdir.glob(".*cirrus-partial*")), "no partial files left behind")
    if "target" in exp:
        check(o["size"] <= exp["target"], f"size {o['size']/1e6:.2f} MB ≤ target {exp['target']/1e6:.2f} MB")
        note = " ".join(res.get("notes", []))
        if "under the target" not in note:
            check(o["size"] >= exp["target"] * 0.85, f"uses the budget (≥ 85 %: {o['size']/exp['target']*100:.0f} %)")
    if "res" in exp:
        check((o["w"], o["h"]) == exp["res"], f"resolution {o['w']}×{o['h']} == {exp['res'][0]}×{exp['res'][1]}")
    check(o["w"] * o["h"] <= s["w"] * s["h"], "not upscaled")
    check(abs(o["w"] / o["h"] - s["w"] / s["h"]) < 0.02, "aspect ratio preserved")
    check(abs(o["duration"] - s["duration"]) < max(0.25, s["duration"] * 0.01), f"duration {o['duration']:.2f}s ≈ {s['duration']:.2f}s")
    check(o["audio"] == exp.get("audio", s["audio"]), f"audio present: {o['audio']}")
    if "channels" in exp:
        check(o["channels"] == exp["channels"], f"{o['channels']} audio channels")
    if "codec" in exp:
        check(o["codec"] == exp["codec"], f"codec {o['codec']}")
    if exp.get("hdr"):
        check(o["trc"] == "smpte2084" and "10" in (o["pix"] or ""), f"HDR kept ({o['trc']}, {o['pix']})")
    q = res.get("quality")
    if "vmaf_min" in exp:
        check(q is not None and q["vmaf"] >= exp["vmaf_min"],
              f"VMAF {q['vmaf']:.2f} ≥ {exp['vmaf_min']}" if q else "VMAF measured")
    dec = sh("ffmpeg", "-v", "error", "-i", str(out), "-f", "null", "-")
    check(dec.returncode == 0 and not dec.stderr.strip(), "decodes cleanly")
    if "quicklook" in exp:
        plays = quicklook_plays(out)
        check(plays == exp["quicklook"], f"Apple's player {'decodes' if plays else 'cannot decode'} it (Quick Look {'works' if plays else 'unavailable'})")
        check(res.get("previewableOnThisMac") == plays, "app reports Quick Look support correctly")
    t = res.get("textCheck")
    if "text_min" in exp:
        check(t is not None and t["accuracy"] >= exp["text_min"], f"text reads {t['accuracy']*100:.0f}% identically" if t else "text checked")
    if exp.get("text_report") and t:
        checks.append(f"· text reads {t['accuracy']*100:.0f}% identically without the guard")
    return dict(name=name, ok=ok, checks=checks, secs=secs, size=o["size"], src_size=s["size"], codec=o["codec"],
                text=t["accuracy"] if t else None,
                res=f"{o['w']}×{o['h']}", vmaf=q["vmaf"] if q else None, summary=res.get("settingsSummary"))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--cirrus", default=str(ROOT / ".build/release/cirrus"))
    ap.add_argument("--only", nargs="*")
    ap.add_argument("--report", default=str(ROOT / "Tests/integration/REPORT.md"))
    a = ap.parse_args()
    global AVPLAYABLE
    AVPLAYABLE = str(Path(tempfile.gettempdir()) / "cirrus-avplayable")
    subprocess.run(["swiftc", "-O", str(ROOT / "Tests/integration/avplayable.swift"), "-o", AVPLAYABLE], check=True)
    if not INPUTS.exists():
        subprocess.run([str(ROOT / "Tests/integration/make_inputs.sh")], check=True)
    outdir = Path(tempfile.mkdtemp(prefix="cirrus_suite_"))
    results = []
    for name, inp, args, exp in CASES:
        if a.only and name not in a.only:
            continue
        print(f"▸ {name} …", flush=True)
        case_dir = outdir / name; case_dir.mkdir()
        r = run_case(a.cirrus, name, inp, args, exp, case_dir)
        results.append(r)
        for c in r["checks"]:
            print("   " + c)
        print(f"   {'PASS' if r['ok'] else 'FAIL'} in {r['secs']:.0f}s", flush=True)
    shutil.rmtree(outdir, ignore_errors=True)

    lines = ["# Integration test report", "", f"{sum(r['ok'] for r in results)}/{len(results)} passed", "",
             "| case | result | output | codec | res | VMAF | text | time | settings |", "|---|---|---:|---|---|---:|---:|---:|---|"]
    for r in results:
        size = f"{r['size']/1e6:.2f} MB" if r.get("size") else "—"
        vm = f"{r['vmaf']:.1f}" if r.get("vmaf") is not None else "—"
        tx = f"{r['text']*100:.0f}%" if r.get("text") is not None else "—"
        lines.append(f"| {r['name']} | {'✅' if r['ok'] else '❌'} | {size} | {r.get('codec', '—')} | {r.get('res', '—')} | "
                     f"{vm} | {tx} | {r['secs']:.0f}s | {r.get('summary') or ''} |")
    lines += ["", "## Checks", ""]
    for r in results:
        lines.append(f"**{r['name']}** — " + "; ".join(r["checks"]))
        lines.append("")
    Path(a.report).write_text("\n".join(lines))
    print(f"\n{sum(r['ok'] for r in results)}/{len(results)} passed → {a.report}")
    sys.exit(0 if all(r["ok"] for r in results) else 1)


if __name__ == "__main__":
    main()
