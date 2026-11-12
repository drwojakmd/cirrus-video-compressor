#!/usr/bin/env python3
"""
Text-legibility test clips (for the text guard).

  lecture   - 60 s of lecture slides: titles, bullet points, a dense table, small
              footnotes (14-18 px), coloured text on coloured panels, a moving
              pointer and slide transitions. Clean synthetic imagery.
  captions  - real camera footage (camera_person.mov) with burnt-in captions and a
              small on-screen source credit. Camera noise + text.

Usage: make_text_clips.py CLIPDIR   (CLIPDIR must contain camera_person.mov for `captions`)
"""
import math, subprocess, sys
from pathlib import Path
from PIL import Image, ImageDraw, ImageFont

UI = "/System/Library/Fonts/SFNS.ttf"
MONO = "/System/Library/Fonts/SFNSMono.ttf"
W, H, FPS = 1920, 1080, 30


def sink(path, w=W, h=H, fps=FPS):
    return subprocess.Popen(["ffmpeg", "-v", "error", "-y", "-f", "rawvideo", "-pix_fmt", "rgb24", "-s", f"{w}x{h}", "-r", str(fps),
                             "-i", "-", "-c:v", "prores_ks", "-profile:v", "3", "-pix_fmt", "yuv422p10le",
                             "-color_primaries", "bt709", "-color_trc", "bt709", "-colorspace", "bt709", str(path)], stdin=subprocess.PIPE)


def font(size, mono=False):
    return ImageFont.truetype(MONO if mono else UI, size)


SLIDES = [
    ("Information theory: entropy", [
        "Entropy measures the average surprise of a source",
        "H(X) = − Σ p(x) · log₂ p(x), measured in bits",
        "A fair coin has 1 bit of entropy per toss",
        "Skewed sources compress better: p = 0.9 gives 0.469 bits",
    ], "Shannon, C. E. (1948). A Mathematical Theory of Communication. Bell System Technical Journal 27, 379–423."),
    ("Prefix codes and Kraft's inequality", [
        "No codeword is a prefix of another codeword",
        "Kraft: Σ 2^(−ℓᵢ) ≤ 1 for any prefix code",
        "Huffman coding is optimal among symbol codes",
        "Average length L satisfies H(X) ≤ L < H(X) + 1",
    ], "See Cover & Thomas, Elements of Information Theory, 2nd ed., chapter 5, pages 103–118."),
    ("Rate–distortion at a glance", None,
     "Values are illustrative. Distortion D in mean squared error; rate R in bits per sample."),
    ("Transform coding in video codecs", [
        "Residual blocks are transformed (DCT / DST)",
        "Coefficients are quantised: this is where loss happens",
        "Entropy coding (CABAC) removes remaining redundancy",
        "AV1 adds palette mode and intra block copy for screen content",
    ], "Block sizes from 4×4 up to 64×64 (HEVC) and 128×128 (AV1). Quantiser index range 0–255 in AV1."),
    ("Summary", [
        "Entropy bounds lossless compression",
        "Rate–distortion theory bounds lossy compression",
        "Modern codecs approach these bounds on natural video",
        "Questions? Office hours: Thursday 14:00–15:30, room 4.12",
    ], "Slides and problem set 3 are on the course page. Problem set due Friday 23:59."),
]


def draw_slide(i, t, local):
    title, bullets, foot = SLIDES[i]
    img = Image.new("RGB", (W, H), (250, 250, 247))
    d = ImageDraw.Draw(img)
    d.rectangle([0, 0, W, 132], fill=(28, 52, 92))
    d.text((80, 36), title, font=font(60), fill=(255, 255, 255))
    d.text((W - 260, 52), f"Lecture 4 · {i + 1}/5", font=font(26), fill=(190, 205, 230))
    if bullets:
        y = 210
        for k, b in enumerate(bullets):
            if local > 0.6 + k * 0.9:  # bullets appear one by one
                d.ellipse([92, y + 16, 106, y + 30], fill=(28, 52, 92))
                d.text((130, y), b, font=font(40), fill=(25, 25, 30))
            y += 92
        # coloured callout box with small text
        d.rounded_rectangle([1240, 640, 1840, 860], radius=18, fill=(255, 226, 170))
        d.text((1270, 664), "Exam tip", font=font(30), fill=(120, 60, 0))
        d.text((1270, 712), "Know how to derive the bound,", font=font(24), fill=(90, 50, 10))
        d.text((1270, 746), "not just state it. Worked example", font=font(24), fill=(90, 50, 10))
        d.text((1270, 780), "on page 112 (problem 5.3).", font=font(24), fill=(90, 50, 10))
    else:
        # dense table, 22 px
        cols = ["Rate (bits)", "Distortion D", "PSNR (dB)", "Codec", "Notes"]
        rows = [["0.25", "0.0412", "13.85", "JPEG q10", "blocking"], ["0.50", "0.0175", "17.57", "JPEG q30", "ringing"],
                ["1.00", "0.0061", "22.15", "JPEG q60", "mild"], ["0.25", "0.0198", "17.03", "AV1 crf 45", "soft"],
                ["0.50", "0.0083", "20.81", "AV1 crf 35", "clean"], ["1.00", "0.0027", "25.69", "AV1 crf 25", "transparent"]]
        x0, y0, cw, rh = 120, 220, 330, 62
        for c, name in enumerate(cols):
            d.rectangle([x0 + c * cw, y0, x0 + (c + 1) * cw - 4, y0 + rh - 4], fill=(222, 230, 242))
            d.text((x0 + c * cw + 16, y0 + 16), name, font=font(26), fill=(20, 30, 50))
        for r, row in enumerate(rows):
            for c, v in enumerate(row):
                d.text((x0 + c * cw + 16, y0 + (r + 1) * rh + 18), v, font=font(24, mono=c < 3), fill=(30, 30, 35))
    d.line([80, H - 96, W - 80, H - 96], fill=(200, 200, 205), width=2)
    d.text((80, H - 78), foot, font=font(18), fill=(95, 95, 105))
    # laser pointer
    px = 700 + 500 * math.sin(t * 0.7 + i)
    py = 520 + 220 * math.sin(t * 1.1 + i * 2)
    d.ellipse([px - 9, py - 9, px + 9, py + 9], fill=(230, 30, 40))
    return img


def lecture(out):
    p = sink(out)
    n = 60 * FPS
    for f in range(n):
        t = f / FPS
        i, local = int(t // 12), t % 12
        img = draw_slide(i, t, local)
        if local < 0.4 and i > 0:  # cross-fade from previous slide
            img = Image.blend(draw_slide(i - 1, t, 12), img, local / 0.4)
        p.stdin.write(img.tobytes())
    p.stdin.close(); p.wait()


CAPTIONS = ["So the first thing we measured was the bitrate", "needed to reach the same perceived quality,",
            "and AV1 came out about a fifth smaller", "than the older H.264 encoder on camera footage.",
            "On animation the gap was much, much bigger.", "We'll go through the numbers in a minute."]


def captions(clipdir, out, seconds=18):
    src = Path(clipdir) / "camera_person.mov"
    probe = subprocess.run(["ffprobe", "-v", "error", "-select_streams", "v:0", "-show_entries", "stream=width,height",
                            "-of", "csv=p=0", str(src)], capture_output=True, text=True).stdout.strip().split(",")
    w, h = 1920, 1080
    dec = subprocess.Popen(["ffmpeg", "-v", "error", "-i", str(src), "-t", str(seconds), "-vf", f"scale={w}:{h}:force_original_aspect_ratio=increase,crop={w}:{h},fps={FPS}",
                            "-f", "rawvideo", "-pix_fmt", "rgb24", "-"], stdout=subprocess.PIPE)
    p = sink(out, w, h)
    f = 0
    cap_font, small = font(44), font(20)
    while True:
        raw = dec.stdout.read(w * h * 3)
        if len(raw) < w * h * 3:
            break
        img = Image.frombytes("RGB", (w, h), raw)
        d = ImageDraw.Draw(img)
        line = CAPTIONS[(f // (3 * FPS)) % len(CAPTIONS)]
        tw = d.textlength(line, font=cap_font)
        x, y = (w - tw) / 2, h - 150
        d.rounded_rectangle([x - 24, y - 14, x + tw + 24, y + 64], radius=10, fill=(0, 0, 0))
        d.text((x, y), line, font=cap_font, fill=(255, 255, 255))
        d.text((40, 36), "Source: internal benchmark, M1 Max, SVT-AV1 4.3 preset 4 vs x264 slow", font=small, fill=(255, 255, 255))
        p.stdin.write(img.tobytes())
        f += 1
    p.stdin.close(); p.wait(); dec.wait()


if __name__ == "__main__":
    d = Path(sys.argv[1])
    lecture(d / "lecture.mov")
    captions(d, d / "captions.mov")
    print("wrote", d / "lecture.mov", d / "captions.mov")
