#!/usr/bin/env python3
"""
Rate-control experiment: how accurately does each encoder hit a size target,
and how much quality (if any) does bitrate-targeted encoding give up versus
constant-quality (CRF) encoding at the same final size?

For each clip × encoder:
  1. encode at a CRF / quality value and record the bitrate it produced (B)
  2. encode again in bitrate mode (2-pass where supported) targeting B
  3. compare: size error % and VMAF delta

Usage: ratecontrol.py clips/*.mov --out results/ratecontrol.jsonl
"""
import argparse, json, sys
from pathlib import Path
import tempfile
from bench import probe, encode, vmaf


def two_pass(enc_args, kbps, dst, src, passlog):
    a1 = enc_args(kbps) + ["-pass", "1", "-passlogfile", passlog, "-f", "null"]
    a2 = enc_args(kbps) + ["-pass", "2", "-passlogfile", passlog]
    t = encode(src, "/dev/null", a1)
    return t + encode(src, dst, a2)


CRF = {
    "svtav1_p4": lambda q: ["-c:v", "libsvtav1", "-preset", "4", "-crf", str(q), "-g", "300", "-pix_fmt", "yuv420p10le", "-svtav1-params", "tune=1:enable-overlays=1"],
    "svtav1_p6": lambda q: ["-c:v", "libsvtav1", "-preset", "6", "-crf", str(q), "-g", "300", "-pix_fmt", "yuv420p10le", "-svtav1-params", "tune=1:enable-overlays=1"],
    "x265_slow": lambda q: ["-c:v", "libx265", "-preset", "slow", "-crf", str(q), "-pix_fmt", "yuv420p10le", "-x265-params", "log-level=error"],
    "x264_slow": lambda q: ["-c:v", "libx264", "-preset", "slow", "-crf", str(q), "-pix_fmt", "yuv420p"],
    "vt_hevc":   lambda q: ["-c:v", "hevc_videotoolbox", "-q:v", str(q), "-pix_fmt", "p010le", "-profile:v", "main10"],
}
VBR = {  # (args(kbps), passes)
    "svtav1_p4": (lambda b: ["-c:v", "libsvtav1", "-preset", "4", "-b:v", f"{b}k", "-g", "300", "-pix_fmt", "yuv420p10le", "-svtav1-params", "tune=1"], 2),
    "svtav1_p6": (lambda b: ["-c:v", "libsvtav1", "-preset", "6", "-b:v", f"{b}k", "-g", "300", "-pix_fmt", "yuv420p10le", "-svtav1-params", "tune=1"], 2),
    "x265_slow": (lambda b: ["-c:v", "libx265", "-preset", "slow", "-b:v", f"{b}k", "-pix_fmt", "yuv420p10le", "-x265-params", "log-level=error"], 2),
    "x264_slow": (lambda b: ["-c:v", "libx264", "-preset", "slow", "-b:v", f"{b}k", "-pix_fmt", "yuv420p"], 2),
    "vt_hevc":   (lambda b: ["-c:v", "hevc_videotoolbox", "-b:v", f"{b}k", "-pix_fmt", "p010le", "-profile:v", "main10"], 1),
}
POINTS = {"svtav1_p4": [30, 42], "svtav1_p6": [30, 42], "x265_slow": [22, 30], "x264_slow": [20, 28], "vt_hevc": [50, 66]}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("clips", nargs="+")
    ap.add_argument("--out", default="results/ratecontrol.jsonl")
    ap.add_argument("--encoders", nargs="*", default=list(CRF))
    a = ap.parse_args()
    work = Path(tempfile.mkdtemp(prefix="cirrus_rc_"))
    for clip in a.clips:
        info = probe(clip); name = Path(clip).stem
        for enc in a.encoders:
            for q in POINTS[enc]:
                d1 = work / f"{name}.{enc}.crf.mkv"
                t1 = encode(clip, d1, CRF[enc](q))
                kbps = d1.stat().st_size * 8 / info["duration"] / 1000
                m1 = vmaf(clip, d1, info["w"], info["h"])
                vargs, passes = VBR[enc]
                d2 = work / f"{name}.{enc}.vbr.mkv"
                tgt = max(1, round(kbps))
                if passes == 2:
                    t2 = two_pass(vargs, tgt, d2, clip, str(work / "plog"))
                else:
                    t2 = encode(clip, d2, vargs(tgt))
                kbps2 = d2.stat().st_size * 8 / info["duration"] / 1000
                m2 = vmaf(clip, d2, info["w"], info["h"])
                rec = dict(clip=name, encoder=enc, q=q, crf_kbps=kbps, target_kbps=tgt, vbr_kbps=kbps2,
                           size_err_pct=(kbps2 / tgt - 1) * 100, crf_vmaf=m1["vmaf"], vbr_vmaf=m2["vmaf"],
                           vmaf_delta=m2["vmaf"] - m1["vmaf"], crf_secs=t1, vbr_secs=t2, passes=passes)
                print(f"[{name}] {enc:10s} crf={q:<3} {kbps:7.0f}k VMAF {m1['vmaf']:.2f} | {passes}-pass @{tgt}k -> {kbps2:7.0f}k "
                      f"({rec['size_err_pct']:+.1f}%) VMAF {m2['vmaf']:.2f} ({rec['vmaf_delta']:+.2f})", flush=True)
                with open(a.out, "a") as fh:
                    fh.write(json.dumps(rec) + "\n")
                d1.unlink(missing_ok=True); d2.unlink(missing_ok=True)


if __name__ == "__main__":
    main()
