#!/usr/bin/env python3
"""
Cirrus Video Compressor — encoder benchmark harness.

Encodes each source clip with every configured encoder at several quality
points, then measures:
  * wall-clock encode speed (fps, single encode at a time, nothing else running)
  * output size / bitrate
  * VMAF (v0.6.1 model, plus NEG "no enhancement gain" model), PSNR-Y, SSIM-Y

Results are appended to results/<run>.jsonl so a long run can be resumed.
`report.py` turns the JSONL into rate–quality curves and BD-rate tables.

VMAF is computed with Netflix's `vmaf` CLI fed by FFmpeg through named pipes
(Y4M), so no large intermediates are written and it works with any FFmpeg
build, with or without --enable-libvmaf.
"""
import argparse, json, os, shutil, subprocess, sys, tempfile, time
from pathlib import Path

VMAF_MODEL_DIR = Path(os.environ.get("VMAF_MODEL_DIR", "/opt/homebrew/opt/libvmaf/share/libvmaf/model"))

# ---------------------------------------------------------------------------
# Encoder definitions. Each returns ffmpeg video args for a quality knob `q`.
# Everything is 10-bit where the encoder supports it, since 10-bit improves
# coding efficiency (finer quantiser precision, less banding) at no size cost.
# ---------------------------------------------------------------------------
def svt(preset, extra=""):
    def f(q):
        p = f"tune=0:enable-overlays=1:scd=1{(':' + extra) if extra else ''}"
        return ["-c:v", "libsvtav1", "-preset", str(preset), "-crf", str(q), "-g", "300",
                "-pix_fmt", "yuv420p10le", "-svtav1-params", p]
    return f

def x265(preset, extra=""):
    def f(q):
        p = f"log-level=error{(':' + extra) if extra else ''}"
        return ["-c:v", "libx265", "-preset", preset, "-crf", str(q), "-pix_fmt", "yuv420p10le",
                "-x265-params", p, "-tag:v", "hvc1"]
    return f

def x264(preset):
    def f(q):
        return ["-c:v", "libx264", "-preset", preset, "-crf", str(q), "-pix_fmt", "yuv420p"]
    return f

def vt_hevc(q):
    # constant-quality mode (Apple Silicon only): -q:v 1..100
    return ["-c:v", "hevc_videotoolbox", "-q:v", str(q), "-pix_fmt", "p010le", "-tag:v", "hvc1",
            "-profile:v", "main10"]

def vt_hevc_br(kbps):
    return ["-c:v", "hevc_videotoolbox", "-b:v", f"{kbps}k", "-pix_fmt", "p010le", "-tag:v", "hvc1",
            "-profile:v", "main10"]

def vt_h264(q):
    return ["-c:v", "h264_videotoolbox", "-q:v", str(q), "-pix_fmt", "nv12"]

def vp9(cpu):
    def f(q):
        return ["-c:v", "libvpx-vp9", "-crf", str(q), "-b:v", "0", "-cpu-used", str(cpu), "-row-mt", "1",
                "-tile-columns", "2", "-frame-parallel", "0", "-auto-alt-ref", "1", "-lag-in-frames", "25",
                "-pix_fmt", "yuv420p10le", "-profile:v", "2"]
    return f

ENCODERS = {
    "svtav1_p4":   (svt(4),   [24, 32, 40, 48, 56, 63], "mkv"),
    "svtav1_p6":   (svt(6),   [24, 32, 40, 48, 56, 63], "mkv"),
    "svtav1_p8":   (svt(8),   [24, 32, 40, 48, 56, 63], "mkv"),
    "svtav1_p10":  (svt(10),  [24, 32, 40, 48, 56, 63], "mkv"),
    "x265_medium": (x265("medium"), [16, 22, 28, 34, 40], "mp4"),
    "x265_slow":   (x265("slow"),   [16, 22, 28, 34, 40], "mp4"),
    "x264_slow":   (x264("slow"),   [16, 22, 28, 34, 40], "mp4"),
    "vt_hevc":     (vt_hevc,  [30, 42, 54, 66, 78], "mp4"),
    "vt_h264":     (vt_h264,  [35, 50, 65, 80], "mp4"),
    "vp9_cpu2":    (vp9(2),   [20, 32, 44, 56], "webm"),
    # psychovisual / content-specific variants (run on the clips they target)
    "svtav1_p6_scm":   (svt(6, "scm=1"), [24, 32, 40, 48, 56, 63], "mkv"),   # screen-content tools (palette, IntraBC)
    "svtav1_p6_grain": (svt(6, "film-grain=8:film-grain-denoise=1"), [24, 32, 40, 48, 56], "mkv"),
    "svtav1_p6_vbq":   (svt(6, "enable-variance-boost=1"), [24, 32, 40, 48, 56, 63], "mkv"),
    # leaner sweeps for the (much slower to encode) real camera footage
    "L_svtav1_p4":  (svt(4),  [28, 36, 44, 52], "mkv"),
    "L_svtav1_p6":  (svt(6),  [28, 36, 44, 52], "mkv"),
    "L_svtav1_p8":  (svt(8),  [28, 36, 44, 52], "mkv"),
    "L_svtav1_p10": (svt(10), [28, 36, 44, 52], "mkv"),
    "L_x265_slow":  (x265("slow"),   [20, 25, 30, 35], "mp4"),
    "L_x265_medium":(x265("medium"), [20, 25, 30, 35], "mp4"),
    "L_x264_slow":  (x264("slow"),   [20, 25, 30, 35], "mp4"),
    "L_vt_hevc":    (vt_hevc, [45, 58, 70, 82], "mp4"),
    "L_vp9_cpu2":   (vp9(2),  [28, 38, 48], "webm"),
    "L_svtav1_p6_grain": (svt(6, "film-grain=8:film-grain-denoise=1"), [28, 36, 44, 52], "mkv"),
    "L_svtav1_p6_8bit":  (lambda q: [a if a != "yuv420p10le" else "yuv420p" for a in svt(6)(q)], [28, 36, 44, 52], "mkv"),
    "L_svtav1_p6_tune1": (lambda q: [a.replace("tune=0", "tune=1") for a in svt(6)(q)], [28, 36, 44, 52], "mkv"),
}


def probe(path):
    out = subprocess.run(["ffprobe", "-v", "error", "-show_entries", "format=duration,size:stream=width,height,r_frame_rate,nb_frames",
                          "-select_streams", "v:0", "-of", "json", str(path)], capture_output=True, text=True, check=True)
    j = json.loads(out.stdout)
    st = j["streams"][0]; num, den = map(int, st["r_frame_rate"].split("/"))
    return dict(w=st["width"], h=st["height"], fps=num/den, duration=float(j["format"]["duration"]),
                size=int(j["format"]["size"]))


def encode(src, dst, vargs, threads=None):
    cmd = ["ffmpeg", "-v", "error", "-y", "-i", str(src), "-an", *vargs, str(dst)]
    t0 = time.perf_counter()
    r = subprocess.run(cmd, capture_output=True, text=True)
    dt = time.perf_counter() - t0
    if r.returncode != 0:
        raise RuntimeError(r.stderr[-2000:])
    return dt


def vmaf(ref, dist, w, h, subsample=1, threads=os.cpu_count()):
    """Return dict(vmaf, vmaf_neg, psnr_y, ssim_y, vmaf_p5) using the vmaf CLI via FIFOs."""
    tmp = Path(tempfile.mkdtemp(prefix="cirrus_vmaf_"))
    try:
        rf, df, js = tmp / "ref.y4m", tmp / "dist.y4m", tmp / "out.json"
        os.mkfifo(rf); os.mkfifo(df)
        # both decoded to the same 10-bit 4:2:0 at reference resolution; distorted scaled
        # back with bicubic if it was encoded at a lower resolution (standard VMAF practice)
        common = ["-f", "yuv4mpegpipe", "-pix_fmt", "yuv420p10le", "-strict", "-1"]
        pr = subprocess.Popen(["ffmpeg", "-v", "error", "-y", "-i", str(ref), "-vf", f"scale={w}:{h}:flags=bicubic", *common, str(rf)])
        pd = subprocess.Popen(["ffmpeg", "-v", "error", "-y", "-i", str(dist), "-vf", f"scale={w}:{h}:flags=bicubic", *common, str(df)])
        models = ["--model", f"path={VMAF_MODEL_DIR/'vmaf_v0.6.1.json'}:name=vmaf",
                  "--model", f"path={VMAF_MODEL_DIR/'vmaf_v0.6.1neg.json'}:name=vmaf_neg"]
        r = subprocess.run(["vmaf", "-r", str(rf), "-d", str(df), *models, "--feature", "psnr", "--feature", "float_ssim",
                            "--threads", str(threads), "--subsample", str(subsample), "--json", "-o", str(js), "-q"],
                           capture_output=True, text=True)
        pr.wait(); pd.wait()
        if r.returncode != 0:
            raise RuntimeError(r.stderr[-2000:])
        j = json.loads(js.read_text())
        pooled = j["pooled_metrics"]
        frames = sorted(fr["metrics"]["vmaf"] for fr in j["frames"])
        return dict(vmaf=pooled["vmaf"]["mean"], vmaf_neg=pooled["vmaf_neg"]["mean"],
                    vmaf_min=pooled["vmaf"]["min"], vmaf_p5=frames[max(0, int(len(frames)*0.05) - 1)],
                    psnr_y=pooled["psnr_y"]["mean"], ssim_y=pooled["float_ssim"]["mean"])
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("clips", nargs="+")
    ap.add_argument("--encoders", nargs="*", default=list(ENCODERS))
    ap.add_argument("--out", default="results/bench.jsonl")
    ap.add_argument("--work", default=None, help="dir for encoded files (default: temp)")
    ap.add_argument("--scale", default=None, help="WxH output resolution (e.g. 1280x720)")
    a = ap.parse_args()

    done = set()
    outp = Path(a.out); outp.parent.mkdir(parents=True, exist_ok=True)
    if outp.exists():
        for line in outp.read_text().splitlines():
            r = json.loads(line); done.add((r["clip"], r["encoder"], r["q"], r.get("scale")))
    work = Path(a.work or tempfile.mkdtemp(prefix="cirrus_bench_")); work.mkdir(parents=True, exist_ok=True)

    for clip in a.clips:
        info = probe(clip); name = Path(clip).stem
        for enc in a.encoders:
            fn, qs, ext = ENCODERS[enc]
            for q in qs:
                if (name, enc, q, a.scale) in done:
                    continue
                dst = work / f"{name}.{enc}.q{q}.{ext}"
                vargs = fn(q)
                if a.scale:
                    sw, sh = a.scale.split("x")
                    vargs = ["-vf", f"scale={sw}:{sh}:flags=lanczos", *vargs]
                try:
                    dt = encode(clip, dst, vargs)
                except RuntimeError as e:
                    print(f"[{name}] {enc} q={q} FAILED: {e}", file=sys.stderr); continue
                size = dst.stat().st_size
                m = vmaf(clip, dst, info["w"], info["h"])
                rec = dict(clip=name, encoder=enc, q=q, scale=a.scale, secs=dt, fps=info["duration"]*info["fps"]/dt,
                           bytes=size, kbps=size*8/info["duration"]/1000, **m)
                print(f"[{name}] {enc:16s} q={q:<3} {rec['kbps']:8.0f} kb/s  VMAF {m['vmaf']:6.2f} (neg {m['vmaf_neg']:6.2f}, p5 {m['vmaf_p5']:6.2f})  {rec['fps']:6.1f} fps", flush=True)
                with outp.open("a") as fh:
                    fh.write(json.dumps(rec) + "\n")
                dst.unlink(missing_ok=True)


if __name__ == "__main__":
    main()
