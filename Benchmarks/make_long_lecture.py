#!/usr/bin/env python3
"""
A realistic long lecture recording, for the website's headline example.

60 minutes of slides (60 distinct slides, a minute each, with bullets that build,
tables, code, footnotes and coloured callouts), and a moving laser pointer,
recorded the way screen recorders and video-call
apps store a lecture: H.264 1080p30 (6 Mbit/s cap) with AAC audio
— static slides need far less than the cap, so the file is ~310 MB, close to a Zoom recording.

Usage: make_long_lecture.py OUT.mp4 [--minutes 60]
"""
import argparse, math, random, subprocess
from PIL import Image, ImageDraw, ImageFont

UI, MONO = "/System/Library/Fonts/SFNS.ttf", "/System/Library/Fonts/SFNSMono.ttf"
W, H, FPS = 1920, 1080, 30
F = {s: ImageFont.truetype(UI, s) for s in (18, 22, 24, 26, 30, 40, 60)}
FM = ImageFont.truetype(MONO, 24)
WORDS = ("signal entropy channel capacity noise coding rate distortion quantisation transform block motion vector "
         "prediction residual frame keyframe bitrate sample filter spectrum frequency phase error bound optimal "
         "estimate variance probability source decoder encoder lossless lossy palette texture gradient").split()


def sentence(rng, n):
    s = " ".join(rng.choice(WORDS) for _ in range(n))
    return s[0].upper() + s[1:]


def slide(i):
    rng = random.Random(i)
    img = Image.new("RGB", (W, H), (250, 250, 247))
    d = ImageDraw.Draw(img)
    d.rectangle([0, 0, W, 132], fill=(28, 52, 92))
    d.text((80, 36), f"{i + 1}. {sentence(rng, 4)}", font=F[60], fill=(255, 255, 255))
    d.text((W - 300, 52), f"Lecture 7 · {i + 1}/60", font=F[26], fill=(190, 205, 230))
    kind = i % 4
    layers = []
    if kind in (0, 1):
        for k in range(rng.randint(3, 5)):
            layers.append(("bullet", 210 + k * 88, sentence(rng, rng.randint(5, 9))))
        if kind == 1:
            layers.append(("callout", sentence(rng, 5), sentence(rng, 6), sentence(rng, 5)))
    elif kind == 2:
        layers.append(("table", [[f"{rng.uniform(0, 100):.2f}" for _ in range(5)] for _ in range(7)]))
    else:
        layers.append(("code", [f"{'    ' * (k % 3)}{rng.choice(['let', 'var', 'return', 'if', 'for'])} {sentence(rng, 3).lower().replace(' ', '_')} = {rng.randint(0, 999)}" for k in range(11)]))
    foot = f"Reading: {sentence(rng, 6)}, chapter {rng.randint(1, 12)}, pages {rng.randint(10, 300)}–{rng.randint(301, 400)}."
    return img, layers, foot


def render(base, layers, foot, local):
    img = base.copy()
    d = ImageDraw.Draw(img)
    for n, L in enumerate(layers):
        if L[0] == "bullet":
            if local > 2 + n * 6:  # bullets build every 6 s
                d.ellipse([92, L[1] + 16, 106, L[1] + 30], fill=(28, 52, 92))
                d.text((130, L[1]), L[2], font=F[40], fill=(25, 25, 30))
        elif L[0] == "callout":
            d.rounded_rectangle([1240, 640, 1840, 860], radius=18, fill=(255, 226, 170))
            for k, t in enumerate(L[1:]):
                d.text((1270, 664 + k * 40), t, font=F[30] if k == 0 else F[24], fill=(110, 55, 5))
        elif L[0] == "table":
            for r, row in enumerate(L[1]):
                for c, v in enumerate(row):
                    if r == 0:
                        d.rectangle([120 + c * 330, 210, 116 + (c + 1) * 330, 266], fill=(222, 230, 242))
                    d.text((136 + c * 330, 226 + r * 62), v, font=F[26] if r == 0 else F[24], fill=(30, 30, 35))
        elif L[0] == "code":
            d.rounded_rectangle([100, 190, 1500, 900], radius=16, fill=(30, 34, 44))
            for k, line in enumerate(L[1]):
                d.text((140, 220 + k * 60), f"{k + 1:>2}  {line}", font=FM, fill=(220, 225, 235))
    d.line([80, H - 96, W - 80, H - 96], fill=(200, 200, 205), width=2)
    d.text((80, H - 78), foot, font=F[18], fill=(95, 95, 105))
    return img


def main():
    """Render each slide state once (bullets build every 6 s), then let FFmpeg hold each
    image for its duration and move the laser pointer: identical pixels to drawing every
    frame, in minutes instead of hours."""
    import os, tempfile
    ap = argparse.ArgumentParser()
    ap.add_argument("out"); ap.add_argument("--minutes", type=float, default=60)
    a = ap.parse_args()
    work = tempfile.mkdtemp(prefix="lecture1h_")
    lines, total, n = [], a.minutes * 60, 0
    for i in range(int(math.ceil(a.minutes))):
        base, layers, foot = slide(i % 60)
        bullets = sum(1 for L in layers if L[0] == "bullet")
        cuts = [2 + k * 6 for k in range(bullets)] + [60]
        prev = 0.0
        for c in cuts:
            local = (prev + c) / 2
            path = os.path.join(work, f"s{n:05d}.png"); n += 1
            render(base, layers, foot, local if bullets else 30).save(path)
            lines.append(f"file '{path}'\nduration {c - prev:.3f}")
            prev = c
    lines.append(f"file '{path}'")          # concat demuxer: repeat the last file
    lst = os.path.join(work, "list.txt"); open(lst, "w").write("\n".join(lines) + "\n")
    dot = os.path.join(work, "dot.png")
    d = Image.new("RGBA", (20, 20), (0, 0, 0, 0)); ImageDraw.Draw(d).ellipse([1, 1, 19, 19], fill=(230, 30, 40, 255)); d.save(dot)
    speech = "anoisesrc=c=pink:a=0.2,highpass=f=200,lowpass=f=3800,volume='if(lt(mod(t,1.3),0.9),1,0.05)':eval=frame"
    subprocess.run(["ffmpeg", "-v", "error", "-y", "-f", "concat", "-safe", "0", "-i", lst, "-loop", "1", "-i", dot, "-f", "lavfi", "-i", speech,
                    "-filter_complex", f"[0:v]fps={FPS},format=yuv420p[bg];[bg][1:v]overlay=x='900+520*sin(t*0.37)':y='540+260*sin(t*0.53)':shortest=1[v]",
                    "-map", "[v]", "-map", "2:a", "-t", f"{total:.0f}",
                    "-c:v", "libx264", "-preset", "veryfast", "-b:v", "6000k", "-maxrate", "6000k", "-bufsize", "12000k",
                    "-g", "60", "-pix_fmt", "yuv420p", "-c:a", "aac", "-b:a", "160k", "-ac", "2", a.out], check=True)


if __name__ == "__main__":
    main()
