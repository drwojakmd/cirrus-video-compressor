#!/usr/bin/env python3
"""
Summarise bench.py JSONL results.

For every clip × encoder:
  * bitrate needed to reach VMAF 90 / 93 / 95  (log-rate interpolation)
  * BD-rate vs. a reference encoder over the overlapping VMAF range
    (piecewise-linear log-rate vs. quality, trapezoidal integration —
     the PCHIP-style variant of Bjøntegaard, robust with few points)
  * median encode speed (fps)

Usage: report.py results/m1max_1080p.jsonl [--ref x265_slow] [--metric vmaf]
"""
import argparse, json, math, statistics
from collections import defaultdict


def curve(points, metric):
    """Sorted (quality, log10 kbps), monotone-cleaned (drop points that don't improve quality)."""
    pts = sorted(((p[metric], math.log10(p["kbps"])) for p in points), key=lambda x: x[1])
    out = []
    for q, lr in pts:
        if not out or q > out[-1][0]:
            out.append((q, lr))
    return out


def interp(c, q):
    if not c or q < c[0][0] or q > c[-1][0]:
        return None
    for (q0, r0), (q1, r1) in zip(c, c[1:]):
        if q0 <= q <= q1:
            return r0 + (r1 - r0) * (q - q0) / (q1 - q0) if q1 > q0 else r0
    return c[-1][1]


def bd_rate(ref, test, steps=200):
    lo = max(ref[0][0], test[0][0]); hi = min(ref[-1][0], test[-1][0])
    if hi - lo < 1.0:
        return None
    acc = 0.0
    for i in range(steps):
        q = lo + (hi - lo) * (i + 0.5) / steps
        acc += interp(test, q) - interp(ref, q)
    return (10 ** (acc / steps) - 1) * 100


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("jsonl")
    ap.add_argument("--ref", default="x265_slow")
    ap.add_argument("--metric", default="vmaf")
    ap.add_argument("--json", help="write machine-readable summary here")
    a = ap.parse_args()

    data = defaultdict(lambda: defaultdict(list))
    for line in open(a.jsonl):
        r = json.loads(line)
        data[r["clip"]][r["encoder"]].append(r)

    summary = {}
    for clip, encs in data.items():
        print(f"\n### {clip}  (BD-rate vs {a.ref} on {a.metric}; negative = smaller files)\n")
        print(f"| encoder | fps | kb/s @90 | kb/s @93 | kb/s @95 | BD-rate | max {a.metric} |")
        print("|---|---:|---:|---:|---:|---:|---:|")
        ref = curve(encs.get(a.ref, []), a.metric)
        rows = []
        for enc, pts in encs.items():
            c = curve(pts, a.metric)
            fps = statistics.median(p["fps"] for p in pts)
            at = {t: (10 ** v if (v := interp(c, t)) is not None else None) for t in (90, 93, 95)}
            bd = bd_rate(ref, c) if ref and enc != a.ref else (0.0 if enc == a.ref else None)
            rows.append((enc, fps, at, bd, max(p[a.metric] for p in pts)))
        rows.sort(key=lambda r: (r[3] is None, r[3] if r[3] is not None else 0))
        fmt = lambda v: f"{v:,.0f}" if v is not None else "—"
        for enc, fps, at, bd, mx in rows:
            print(f"| {enc} | {fps:.1f} | {fmt(at[90])} | {fmt(at[93])} | {fmt(at[95])} | "
                  f"{(f'{bd:+.1f}%' if bd is not None else '—')} | {mx:.2f} |")
        summary[clip] = {enc: dict(fps=fps, kbps_at=at, bd_rate=bd) for enc, fps, at, bd, _ in rows}

    # cross-clip average
    encs = sorted({e for c in summary.values() for e in c})
    print(f"\n### Average across clips\n\n| encoder | median fps | mean BD-rate vs {a.ref} | clips |\n|---|---:|---:|---:|")
    agg = []
    for e in encs:
        bds = [summary[c][e]["bd_rate"] for c in summary if e in summary[c] and summary[c][e]["bd_rate"] is not None]
        fps = [summary[c][e]["fps"] for c in summary if e in summary[c]]
        if bds:
            agg.append((e, statistics.median(fps), statistics.mean(bds), len(bds)))
    for e, f, b, n in sorted(agg, key=lambda x: x[2]):
        print(f"| {e} | {f:.1f} | {b:+.1f}% | {n} |")
    if a.json:
        json.dump(summary, open(a.json, "w"), indent=1)


if __name__ == "__main__":
    main()
