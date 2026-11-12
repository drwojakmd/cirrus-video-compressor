#!/usr/bin/env python3
"""
Compare Cirrus Video Compressor against YouTube's own processing of the same video.

YouTube's pipeline is proprietary; what we *can* do is measure its public output.
See Docs/YOUTUBE_BENCHMARK.md for the full procedure. In short:

  1. Upload ORIGINAL to YouTube (unlisted). Wait until the HD/AV1 renditions exist
     (can take hours for AV1).
  2. Download YouTube's video-only and audio-only streams for the resolution you
     care about, e.g. with yt-dlp:
         yt-dlp -F URL                       # list formats
         yt-dlp -f 399 -o yt_video.mp4 URL   # 1080p AV1  (or 248 VP9, 137 H.264)
         yt-dlp -f 251 -o yt_audio.webm URL  # Opus ~130 kbps (or 140 AAC 128 kbps)
  3. Run:
         youtube_compare.py ORIGINAL --yt-video yt_video.mp4 [--yt-audio yt_audio.webm] \
             [--cirrus path/to/cirrus] [--out results/youtube]

It then:
  * measures YouTube's video bitrate and VMAF/PSNR against the original (scaled
    to the same resolution with the same Lanczos scaler for every contender),
  * encodes the original with Cirrus twice —
        (a) EQUAL SIZE:    target = YouTube's video+audio size  → compare quality
        (b) EQUAL QUALITY: target VMAF = YouTube's VMAF          → compare size
  * writes a Markdown + JSON report and side-by-side PNGs of the weakest moments.

Audio: there is no trustworthy open-source perceptual audio metric bundled with
FFmpeg, so audio is compared on codec/bitrate only, and 10-second clips of each
are extracted for blind listening.
"""
import argparse, json, subprocess, sys, tempfile
from pathlib import Path
from urllib.parse import urlparse, unquote

HERE = Path(__file__).resolve().parent


def sh(*a, check=True):
    r = subprocess.run(a, capture_output=True, text=True)
    if check and r.returncode != 0:
        raise SystemExit(f"command failed: {' '.join(map(str, a))}\n{r.stderr[-1500:]}")
    return r


def probe(p):
    j = json.loads(sh("ffprobe", "-v", "error", "-show_format", "-show_streams", "-of", "json", str(p)).stdout)
    v = next((s for s in j["streams"] if s["codec_type"] == "video"), None)
    a = next((s for s in j["streams"] if s["codec_type"] == "audio"), None)
    num, den = map(int, v["avg_frame_rate"].split("/")) if v else (0, 1)
    return dict(duration=float(j["format"]["duration"]), size=int(j["format"]["size"]),
                w=v and v["width"], h=v and v["height"], fps=num / den if den else 0, vcodec=v and v["codec_name"],
                acodec=a and a["codec_name"], channels=a and a.get("channels"),
                abitrate=int(a["bit_rate"]) if a and a.get("bit_rate") else None)


def stream_bytes(p, kind):
    """Bytes of one elementary stream (sum of packet sizes) — excludes container overhead and the other stream."""
    r = sh("ffprobe", "-v", "error", "-select_streams", f"{kind}:0", "-show_entries", "packet=size", "-of", "csv=p=0", str(p))
    return sum(int(x) for x in r.stdout.split() if x.strip().isdigit())


def vmaf(reference, distorted, w, h, log):
    # frames paired by index (YouTube keeps the frame count at ≤ 60 fps sources)
    graph = (f"[0:v]settb=1/1000,setpts=N,scale={w}:{h}:flags=bicubic,format=yuv420p10le[d];"
             f"[1:v]settb=1/1000,setpts=N,scale={w}:{h}:flags=lanczos+accurate_rnd,format=yuv420p10le[r];"
             f"[d][r]libvmaf=model='version=vmaf_v0.6.1':feature='name=psnr':n_threads=10:n_subsample=2:"
             f"log_fmt=json:log_path={log}:shortest=1")
    sh("ffmpeg", "-v", "error", "-nostdin", "-i", str(distorted), "-i", str(reference), "-filter_complex", graph, "-f", "null", "-")
    j = json.loads(Path(log).read_text())
    fr = sorted(f["metrics"]["vmaf"] for f in j["frames"])
    worst = sorted(j["frames"], key=lambda f: f["metrics"]["vmaf"])[0]["frameNum"]
    return dict(vmaf=j["pooled_metrics"]["vmaf"]["mean"], p5=fr[max(0, len(fr) // 20 - 1)],
                psnr=j["pooled_metrics"]["psnr_y"]["mean"], worst_frame=worst)


def cirrus(cirrus_bin, src, out, *args):
    r = sh(cirrus_bin, "compress", str(src), "--out", str(out), "--json", *args)
    res = json.loads(r.stdout)
    u = res["outputURL"]
    return Path(unquote(urlparse(u).path)) if u.startswith("file:") else Path(u), res


def frame_pair(ref, dist, t, w, h, out):
    a, b = out.with_suffix(".a.png"), out.with_suffix(".b.png")
    sh("ffmpeg", "-v", "error", "-y", "-ss", f"{t:.3f}", "-i", str(ref), "-frames:v", "1", "-vf", f"scale={w}:{h}:flags=lanczos", str(a))
    sh("ffmpeg", "-v", "error", "-y", "-ss", f"{t:.3f}", "-i", str(dist), "-frames:v", "1", str(b))
    sh("ffmpeg", "-v", "error", "-y", "-i", str(a), "-i", str(b), "-filter_complex", "hstack", str(out))
    a.unlink(); b.unlink()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("original")
    ap.add_argument("--yt-video", required=True)
    ap.add_argument("--yt-audio")
    ap.add_argument("--cirrus", default=str(HERE.parent / "build/Cirrus Video Compressor.app/Contents/Helpers/cirrus"))
    ap.add_argument("--out", default=str(HERE / "results/youtube"))
    ap.add_argument("--priority", default="smallest", help="cirrus --priority for our encodes")
    a = ap.parse_args()
    out = Path(a.out); out.mkdir(parents=True, exist_ok=True)
    tmp = Path(tempfile.mkdtemp(prefix="ytcmp_"))
    orig, ytv = Path(a.original), Path(a.yt_video)
    po, py = probe(orig), probe(ytv)
    w, h = py["w"], py["h"]
    if abs(py["fps"] - po["fps"]) > 0.5:
        print(f"note: YouTube rendition is {py['fps']:.2f} fps vs original {po['fps']:.2f} fps — VMAF alignment assumes equal frame counts.")
    yt_vbytes = stream_bytes(ytv, "v")
    yt_abytes = stream_bytes(Path(a.yt_audio), "a") if a.yt_audio else 0
    pa = probe(a.yt_audio) if a.yt_audio else None
    print(f"YouTube: {py['vcodec']} {w}×{h}, video {yt_vbytes/1e6:.2f} MB ({yt_vbytes*8/po['duration']/1000:.0f} kbps)"
          + (f", audio {pa['acodec']} {yt_abytes*8/po['duration']/1000:.0f} kbps" if pa else ""))
    q_yt = vmaf(orig, ytv, w, h, tmp / "yt.json")
    print(f"YouTube VMAF {q_yt['vmaf']:.2f} (p5 {q_yt['p5']:.2f}), PSNR {q_yt['psnr']:.2f}")

    res_flag = ["--res", f"{w}x{h}"]
    rows = [("YouTube", py["vcodec"], yt_vbytes, yt_abytes, q_yt, None)]
    # (a) equal size
    target = yt_vbytes + yt_abytes
    o1, r1 = cirrus(a.cirrus, orig, tmp, *res_flag, "--priority", a.priority, "--target", f"{target/1e6:.4f}MB", "--no-measure")
    q1 = vmaf(orig, o1, w, h, tmp / "eq_size.json")
    rows.append(("Cirrus — equal size", probe(o1)["vcodec"], stream_bytes(o1, "v"), stream_bytes(o1, "a") if probe(o1)["acodec"] else 0, q1, r1))
    # (b) equal quality
    o2, r2 = cirrus(a.cirrus, orig, tmp, *res_flag, "--priority", a.priority, "--vmaf", f"{q_yt['vmaf']:.2f}", "--no-measure")
    q2 = vmaf(orig, o2, w, h, tmp / "eq_quality.json")
    rows.append(("Cirrus — equal quality", probe(o2)["vcodec"], stream_bytes(o2, "v"), stream_bytes(o2, "a") if probe(o2)["acodec"] else 0, q2, r2))

    d = po["duration"]
    md = [f"# Cirrus vs YouTube — {orig.name}", "",
          f"Resolution compared: **{w}×{h}**, duration {d:.1f} s. VMAF v0.6.1 against the original scaled with Lanczos (same reference for all).", "",
          "| contender | codec | video | video kbps | audio kbps | VMAF | worst 5 % | PSNR |", "|---|---|---:|---:|---:|---:|---:|---:|"]
    for name, codec, vb, ab, q, _ in rows:
        md.append(f"| {name} | {codec} | {vb/1e6:.2f} MB | {vb*8/d/1000:.0f} | {ab*8/d/1000:.0f} | {q['vmaf']:.2f} | {q['p5']:.2f} | {q['psnr']:.2f} |")
    eq_q = rows[2]
    md += ["", f"* **Equal size:** Cirrus VMAF {rows[1][4]['vmaf']:.2f} vs YouTube {q_yt['vmaf']:.2f} "
               f"({rows[1][4]['vmaf'] - q_yt['vmaf']:+.2f}).",
           f"* **Equal quality:** Cirrus video is {(1 - eq_q[2]/yt_vbytes)*100:+.1f}% smaller than YouTube's "
               f"(positive = smaller) at VMAF {eq_q[4]['vmaf']:.2f} vs {q_yt['vmaf']:.2f}.", "",
           "Audio is compared by codec and bitrate only; listen to the extracted clips (same 10 s) blind.", ""]
    # visuals & audio clips
    for name, src in (("youtube", ytv), ("cirrus_equal_size", rows[1][5] and o1)):
        t = q_yt["worst_frame"] / max(1, po["fps"])
        frame_pair(orig, src, t, w, h, out / f"worst_{name}.png")
        md.append(f"![{name}](worst_{name}.png)")
    mid = max(0, d / 2 - 5)
    for name, src in (("original", orig), ("youtube", Path(a.yt_audio) if a.yt_audio else None), ("cirrus", o1)):
        if src:
            sh("ffmpeg", "-v", "error", "-y", "-ss", f"{mid:.2f}", "-t", "10", "-i", str(src), "-vn", "-c:a", "pcm_s16le", str(out / f"audio_{name}.wav"))
    (out / "report.md").write_text("\n".join(md) + "\n")
    (out / "report.json").write_text(json.dumps([dict(name=r[0], codec=r[1], video_bytes=r[2], audio_bytes=r[3], **r[4]) for r in rows], indent=1))
    print("\n".join(md))
    print(f"\n→ {out/'report.md'}")


if __name__ == "__main__":
    main()
