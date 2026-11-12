#!/usr/bin/env python3
"""
Generate deterministic, representative benchmark clips.

Each generator renders RGB frames with Pillow and pipes them to FFmpeg, which
stores them as near-lossless 10-bit ProRes 422 HQ mezzanine files. Clean
masters matter: benchmarking against an already-compressed source rewards
encoders for reproducing someone else's artefacts.

Clips:
  talking_head  - animated character, static gradient room, lip-sync, captions
  screen        - code editor / UI capture: crisp text, typing, scrolling, chart
  animation     - fast flat-colour cartoon, parallax pan, many moving objects

Live-action material is cut from a real camera source separately (see
run_bench.sh) because it cannot be synthesised honestly.

Usage: make_clips.py OUTDIR [--seconds 20] [--w 1920 --h 1080 --fps 30]
"""
import argparse, math, random, subprocess, sys
from PIL import Image, ImageDraw, ImageFont, ImageFilter

FONT_UI = "/System/Library/Fonts/SFNS.ttf"
FONT_MONO = "/System/Library/Fonts/SFNSMono.ttf"


def ffmpeg_sink(path, w, h, fps):
    cmd = ["ffmpeg", "-v", "error", "-y", "-f", "rawvideo", "-pix_fmt", "rgb24",
           "-s", f"{w}x{h}", "-r", str(fps), "-i", "-",
           "-c:v", "prores_ks", "-profile:v", "3", "-pix_fmt", "yuv422p10le",
           "-color_primaries", "bt709", "-color_trc", "bt709", "-colorspace", "bt709",
           path]
    return subprocess.Popen(cmd, stdin=subprocess.PIPE)


def lerp(a, b, t):
    return tuple(int(a[i] + (b[i] - a[i]) * t) for i in range(3))


def gradient(w, h, top, bottom):
    """Smooth vertical gradient (a classic banding stress test)."""
    col = Image.new("RGB", (1, h))
    for y in range(h):
        col.putpixel((0, y), lerp(top, bottom, y / (h - 1)))
    return col.resize((w, h))


# --------------------------------------------------------------------------
def talking_head(out, w, h, fps, secs):
    rnd = random.Random(1)
    bg = gradient(w, h, (38, 52, 92), (196, 142, 120))
    d = ImageDraw.Draw(bg)
    s = h / 1080
    # static room: window, shelf, plant
    d.rounded_rectangle([w*0.06, h*0.12, w*0.30, h*0.55], radius=int(18*s), fill=(150, 190, 230), outline=(240, 230, 210), width=int(10*s))
    d.line([w*0.18, h*0.12, w*0.18, h*0.55], fill=(240, 230, 210), width=int(8*s))
    d.rectangle([w*0.70, h*0.30, w*0.95, h*0.32], fill=(110, 70, 50))
    for i in range(5):
        x = w*0.71 + i*w*0.045
        d.rectangle([x, h*0.20, x + w*0.03, h*0.30], fill=[(200, 80, 70), (70, 120, 180), (230, 190, 90), (90, 160, 110), (160, 100, 170)][i])
    d.polygon([(w*0.80, h*0.95), (w*0.86, h*0.95), (w*0.88, h*0.78), (w*0.78, h*0.78)], fill=(170, 90, 60))
    for i in range(9):
        a = -math.pi/2 + (i-4)*0.33
        d.ellipse([w*0.83 + math.cos(a)*w*0.06 - 40*s, h*0.70 + math.sin(a)*h*0.12 - 20*s,
                   w*0.83 + math.cos(a)*w*0.06 + 40*s, h*0.70 + math.sin(a)*h*0.12 + 20*s], fill=(60, 140, 70))
    bg = bg.filter(ImageFilter.GaussianBlur(1.2))  # soft, slightly defocused background
    font = ImageFont.truetype(FONT_UI, int(44*s))
    captions = ["So today we're looking at video compression.",
                "Why do some files look great at a fraction of the size?",
                "It comes down to spending bits where your eyes look.",
                "Static backgrounds cost almost nothing to send.",
                "Lips, eyes and text are what you actually notice.",
                "Let's see how each encoder handles it."]
    sink = ffmpeg_sink(out, w, h, fps)
    cx, cy = w*0.5, h*0.55
    for f in range(int(fps*secs)):
        t = f / fps
        img = bg.copy()
        d = ImageDraw.Draw(img)
        bob = math.sin(t*2.1)*6*s
        sway = math.sin(t*0.7)*10*s
        # body
        d.rounded_rectangle([cx-230*s+sway, cy+120*s+bob, cx+230*s+sway, h+40], radius=int(120*s), fill=(52, 98, 160))
        # gesture arm every ~5s
        g = max(0.0, math.sin((t-1.5)*1.25))**3
        ax, ay = cx+200*s+sway, cy+230*s+bob
        d.line([ax, ay, ax+140*s, ay-220*s*g-40*s], fill=(52, 98, 160), width=int(70*s))
        d.ellipse([ax+105*s, ay-220*s*g-75*s, ax+175*s, ay-220*s*g-5*s], fill=(240, 200, 170))
        # head
        hx, hy = cx+sway, cy-80*s+bob
        d.ellipse([hx-160*s, hy-190*s, hx+160*s, hy+170*s], fill=(240, 200, 170), outline=(90, 60, 40), width=int(5*s))
        d.chord([hx-170*s, hy-215*s, hx+170*s, hy+40*s], 180, 360, fill=(70, 45, 30))
        # eyes w/ blink
        blink = (t % 3.3) < 0.12
        for ex in (-60, 60):
            if blink:
                d.line([hx+ex*s-28*s, hy-20*s, hx+ex*s+28*s, hy-20*s], fill=(40, 30, 30), width=int(6*s))
            else:
                d.ellipse([hx+ex*s-28*s, hy-48*s, hx+ex*s+28*s, hy+8*s], fill=(255, 255, 255), outline=(40, 30, 30), width=int(4*s))
                px = math.sin(t*0.9)*8*s
                d.ellipse([hx+ex*s-12*s+px, hy-32*s, hx+ex*s+12*s+px, hy-8*s], fill=(40, 30, 30))
        # mouth (pseudo phonemes)
        open_ = abs(math.sin(t*11.0) * math.sin(t*3.7)) if (t % 6) < 5.2 else 0.0
        mw = (50 + 25*math.sin(t*5.3))*s
        d.ellipse([hx-mw, hy+75*s-8*s-open_*38*s, hx+mw, hy+75*s+8*s+open_*38*s], fill=(150, 50, 60), outline=(90, 30, 30), width=int(4*s))
        # lower-third caption
        cap = captions[int(t // 4) % len(captions)]
        tw = d.textlength(cap, font=font)
        d.rounded_rectangle([w/2-tw/2-30*s, h*0.86, w/2+tw/2+30*s, h*0.86+70*s], radius=int(14*s), fill=(15, 15, 20))
        d.text((w/2-tw/2, h*0.86+10*s), cap, font=font, fill=(255, 255, 255))
        sink.stdin.write(img.tobytes())
    sink.stdin.close(); sink.wait()


# --------------------------------------------------------------------------
CODE = """import AVFoundation
import Foundation

/// Plans an encode that maximises perceptual quality under a size budget.
struct EncodePlanner {
    let probe: MediaProbe
    let target: SizeTarget

    func videoBitrate(duration: Double, audioKbps: Int) -> Int {
        let totalBits = Double(target.bytes) * 8 * 0.985   // container margin
        let audioBits = Double(audioKbps * 1000) * duration
        return Int((totalBits - audioBits) / duration)
    }

    func chooseCodec(for analysis: ContentAnalysis) -> Codec {
        switch analysis.kind {
        case .screen:     return .av1(tune: .screenContent)
        case .animation:  return .av1(tune: .flatColour)
        case .liveAction: return analysis.grain > 0.4 ? .av1(filmGrain: 8) : .av1()
        default:          return .hevc
        }
    }
}
""".splitlines()


def screen(out, w, h, fps, secs):
    s = h / 1080
    mono = ImageFont.truetype(FONT_MONO, int(22*s))
    ui = ImageFont.truetype(FONT_UI, int(20*s))
    lh = int(32*s)
    kw = {"import": (252, 95, 163), "struct": (252, 95, 163), "let": (252, 95, 163), "func": (252, 95, 163),
          "return": (252, 95, 163), "switch": (252, 95, 163), "case": (252, 95, 163), "default": (252, 95, 163)}
    lines = CODE * 6
    sink = ffmpeg_sink(out, w, h, fps)
    total_chars = 0
    for f in range(int(fps*secs)):
        t = f / fps
        img = Image.new("RGB", (w, h), (30, 30, 36))
        d = ImageDraw.Draw(img)
        # menu bar + sidebar
        d.rectangle([0, 0, w, 34*s], fill=(236, 236, 240))
        d.text((20*s, 6*s), "  Xcode   File   Edit   View   Find   Navigate   Editor   Product", font=ui, fill=(20, 20, 20))
        d.text((w-200*s, 6*s), "Wed 11 Nov  10:42", font=ui, fill=(20, 20, 20))
        d.rectangle([0, 34*s, 300*s, h], fill=(40, 40, 46))
        for i, name in enumerate(["CirrusCompressor", "  App", "  Engine", "    MediaProbe.swift", "    EncodePlanner.swift",
                                  "    RateControl.swift", "    VMAF.swift", "  UI", "    DropZone.swift", "    QueueView.swift"]):
            sel = i == 4
            if sel:
                d.rectangle([8*s, 50*s+i*30*s, 292*s, 78*s+i*30*s], fill=(40, 90, 200))
            d.text((20*s, 52*s+i*30*s), name, font=ui, fill=(230, 230, 235))
        # editor: scrolls one line every 1.5 s, and a char is typed each frame
        scroll = int(t / 1.5)
        typed = int(t * 18)
        x0, y0 = 360*s, 60*s
        visible = int((h - 300*s) // lh)
        for i in range(visible):
            ln = scroll + i
            txt = lines[ln % len(lines)]
            if i == visible - 1:
                txt = txt[: typed % (len(txt) + 1)]
            d.text((x0 - 50*s, y0 + i*lh), f"{ln+1:>3}", font=mono, fill=(110, 110, 120))
            x = x0
            for tok in txt.replace("(", " ( ").split(" "):
                col = kw.get(tok, (110, 190, 255) if tok[:1].isupper() else (225, 225, 230))
                if tok.startswith("//"):
                    col = (110, 160, 110)
                d.text((x, y0 + i*lh), tok, font=mono, fill=col)
                x += d.textlength(tok + " ", font=mono)
            if i == visible - 1 and (f // 15) % 2 == 0:
                d.rectangle([x, y0 + i*lh, x + 2*s, y0 + i*lh + lh - 6*s], fill=(255, 255, 255))
        # bottom panel: live-updating bar chart (a "dashboard")
        py = h - 220*s
        d.rectangle([300*s, py, w, h], fill=(24, 24, 28))
        d.text((330*s, py + 12*s), "Encoder throughput (fps)", font=ui, fill=(200, 200, 205))
        for i in range(24):
            v = 0.5 + 0.45*math.sin(i*0.6 + t*1.7)
            bx = 330*s + i*48*s
            d.rectangle([bx, h - 20*s - v*140*s, bx + 34*s, h - 20*s], fill=(80 + i*6, 160, 230 - i*5))
        # a small window being dragged across the screen, seconds 8-12
        if 8 <= t <= 12:
            k = (t - 8) / 4
            wx, wy = 600*s + k*800*s, 200*s + math.sin(k*math.pi)*120*s
            d.rounded_rectangle([wx, wy, wx + 420*s, wy + 260*s], radius=int(12*s), fill=(250, 250, 252), outline=(160, 160, 170))
            d.text((wx + 20*s, wy + 16*s), "Export Complete", font=ui, fill=(10, 10, 10))
            d.text((wx + 20*s, wy + 60*s), "Cirrus.mp4  •  148 MB  •  AV1", font=ui, fill=(60, 60, 60))
        sink.stdin.write(img.tobytes())
    sink.stdin.close(); sink.wait()


# --------------------------------------------------------------------------
def animation(out, w, h, fps, secs):
    rnd = random.Random(7)
    s = h / 1080
    W = w * 3
    # wide parallax layers rendered once
    far = gradient(W, h, (255, 170, 90), (120, 60, 140))
    d = ImageDraw.Draw(far)
    for i in range(40):
        x = rnd.randint(0, W); r = rnd.randint(60, 200)*s
        d.polygon([(x - r*2, h*0.75), (x, h*0.75 - r*2), (x + r*2, h*0.75)], fill=(90, 50, 110))
    mid = Image.new("RGBA", (W, h), (0, 0, 0, 0))
    d = ImageDraw.Draw(mid)
    for i in range(80):
        x = rnd.randint(0, W)
        d.rectangle([x, h*0.55 + rnd.randint(-40, 40)*s, x + rnd.randint(40, 120)*s, h], fill=(40 + rnd.randint(0, 40), 30, 70, 255))
    d.rectangle([0, h*0.88, W, h], fill=(60, 140, 80, 255))
    sprites = [dict(x=rnd.uniform(0, w), y=rnd.uniform(h*0.2, h*0.8), vx=rnd.uniform(-600, 600)*s, vy=rnd.uniform(-400, 400)*s,
                    r=rnd.uniform(20, 70)*s, c=tuple(rnd.randint(60, 255) for _ in range(3))) for _ in range(18)]
    sink = ffmpeg_sink(out, w, h, fps)
    for f in range(int(fps*secs)):
        t = f / fps
        cam = (math.sin(t*0.35)*0.5 + 0.5)
        img = far.crop((int(cam*W*0.2), 0, int(cam*W*0.2) + w, h))
        img.paste(mid.crop((int(cam*W*0.55), 0, int(cam*W*0.55) + w, h)), (0, 0), mid.crop((int(cam*W*0.55), 0, int(cam*W*0.55) + w, h)))
        d = ImageDraw.Draw(img)
        for sp in sprites:
            sp["x"] += sp["vx"]/fps; sp["y"] += sp["vy"]/fps
            if not (sp["r"] < sp["x"] < w - sp["r"]): sp["vx"] *= -1
            if not (sp["r"] < sp["y"] < h*0.88 - sp["r"]): sp["vy"] *= -1
            x, y, r = sp["x"], sp["y"], sp["r"]
            d.ellipse([x-r, y-r, x+r, y+r], fill=sp["c"], outline=(20, 20, 30), width=int(5*s))
            d.ellipse([x-r*0.3, y-r*0.45, x+r*0.05, y-r*0.1], fill=(255, 255, 255))
        # a running character: squash & stretch
        rx = (t * 500*s) % (w + 400*s) - 200*s
        sq = 1 + 0.25*math.sin(t*18)
        d.ellipse([rx-60*s/sq, h*0.88-180*s*sq, rx+60*s/sq, h*0.88], fill=(250, 220, 60), outline=(30, 30, 30), width=int(6*s))
        d.ellipse([rx+10*s, h*0.88-150*s*sq, rx+40*s, h*0.88-120*s*sq], fill=(30, 30, 30))
        sink.stdin.write(img.tobytes())
    sink.stdin.close(); sink.wait()


GENERATORS = {"talking_head": talking_head, "screen": screen, "animation": animation}

if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("outdir")
    ap.add_argument("--seconds", type=float, default=20)
    ap.add_argument("--w", type=int, default=1920)
    ap.add_argument("--h", type=int, default=1080)
    ap.add_argument("--fps", type=int, default=30)
    ap.add_argument("--only", nargs="*")
    a = ap.parse_args()
    for name, fn in GENERATORS.items():
        if a.only and name not in a.only:
            continue
        out = f"{a.outdir}/{name}.mov"
        print(f"rendering {out}", file=sys.stderr)
        fn(out, a.w, a.h, a.fps, a.seconds)
