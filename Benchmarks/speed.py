#!/usr/bin/env python3
"""
Clean encoder-speed measurement on an otherwise idle machine: each encoder at a
mid-range quality setting, one at a time, three runs, median fps. No quality
measurement in this run, so nothing competes for the CPU.

Usage: speed.py clips/live_park_joy.mkv clips/talking_head.mov --out results/speed.json
"""
import argparse, json, statistics, subprocess, time
from pathlib import Path
from bench import ENCODERS, probe

MID = {"svtav1_p4": 38, "svtav1_p6": 38, "svtav1_p8": 38, "svtav1_p10": 38, "x265_slow": 26, "x265_medium": 26,
       "x264_slow": 24, "vt_hevc": 58, "vt_h264": 60, "vp9_cpu2": 36}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("clips", nargs="+")
    ap.add_argument("--runs", type=int, default=3)
    ap.add_argument("--out", default="results/speed.json")
    a = ap.parse_args()
    res = {}
    for clip in a.clips:
        info = probe(clip); frames = info["duration"] * info["fps"]
        for enc, q in MID.items():
            fn, _, ext = ENCODERS[enc]
            times = []
            for _ in range(a.runs):
                t0 = time.perf_counter()
                subprocess.run(["ffmpeg", "-v", "error", "-y", "-i", clip, "-an", *fn(q), "-f", "null", "-"], check=True)
                times.append(time.perf_counter() - t0)
            fps = frames / statistics.median(times)
            res.setdefault(Path(clip).stem, {})[enc] = round(fps, 1)
            print(f"{Path(clip).stem:16s} {enc:12s} {fps:7.1f} fps", flush=True)
    Path(a.out).write_text(json.dumps(res, indent=1))


if __name__ == "__main__":
    main()
