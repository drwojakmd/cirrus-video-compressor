#!/usr/bin/env python3
"""
Copy ffmpeg + ffprobe and every non-system dylib they need into an .app
bundle, rewriting install names so the app runs on Macs without Homebrew.

  Contents/Helpers/ffmpeg, ffprobe        (executables)
  Contents/Frameworks/*.dylib             (their libraries)

References are rewritten to @loader_path-relative paths; everything is
ad-hoc re-signed afterwards by build_app.sh (install_name_tool invalidates
signatures). Also writes a third-party notice file listing every bundled
library with its licence, taken from Homebrew's formula metadata.

Usage: bundle_ffmpeg.py APP_CONTENTS_DIR [--tools-dir DIR]
"""
import argparse, json, os, re, shutil, subprocess, sys
from pathlib import Path

SYSTEM_PREFIXES = ("/usr/lib/", "/System/")


def sh(*a):
    return subprocess.run(a, check=True, capture_output=True, text=True).stdout


def deps(path):
    out = sh("otool", "-L", str(path)).splitlines()[1:]
    res = []
    for line in out:
        m = re.match(r"\s+(.+?) \(compatibility", line)
        if m:
            res.append(m.group(1))
    return res


def rpaths(path):
    out = sh("otool", "-l", str(path)).splitlines()
    rp = []
    for i, line in enumerate(out):
        if "cmd LC_RPATH" in line:
            for j in range(i, min(i + 4, len(out))):
                m = re.search(r"path (.+?) \(offset", out[j])
                if m:
                    rp.append(m.group(1))
    return rp


def resolve(ref, owner):
    """Absolute path of a dependency reference, or None for system libraries."""
    if ref.startswith(SYSTEM_PREFIXES):
        return None
    if ref.startswith("@rpath/"):
        for rp in rpaths(owner):
            rp = rp.replace("@loader_path", str(Path(owner).parent)).replace("@executable_path", str(Path(owner).parent))
            cand = Path(rp) / ref[len("@rpath/"):]
            if cand.exists():
                return str(cand.resolve())
        raise SystemExit(f"cannot resolve {ref} for {owner}")
    if ref.startswith("@loader_path/"):
        return str((Path(owner).parent / ref[len("@loader_path/"):]).resolve())
    return str(Path(ref).resolve())


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("contents")
    ap.add_argument("--tools-dir", default=None)
    a = ap.parse_args()
    contents = Path(a.contents)
    helpers, fw = contents / "Helpers", contents / "Frameworks"
    helpers.mkdir(parents=True, exist_ok=True); fw.mkdir(parents=True, exist_ok=True)

    tools_dir = a.tools_dir or os.path.dirname(shutil.which("ffmpeg") or "")
    if not tools_dir:
        raise SystemExit("ffmpeg not found (set --tools-dir)")
    exes = [Path(tools_dir) / "ffmpeg", Path(tools_dir) / "ffprobe"]

    # breadth-first walk of the dependency graph
    queue = [str(e.resolve()) for e in exes]
    seen = {}
    while queue:
        cur = queue.pop()
        for ref in deps(cur):
            r = resolve(ref, cur)
            if r and r not in seen and r != cur:
                seen[r] = Path(r).name
                queue.append(r)
    names = list(seen.values())
    if len(names) != len(set(names)):
        raise SystemExit("two different libraries share a file name; cannot flatten")

    # copy
    copied = []
    for e in exes:
        dst = helpers / e.name
        shutil.copy2(e.resolve(), dst); os.chmod(dst, 0o755); copied.append(dst)
    for src, name in seen.items():
        dst = fw / name
        shutil.copy2(src, dst); os.chmod(dst, 0o644); copied.append(dst)

    # rewrite install names
    for f in copied:
        is_exe = f.parent == helpers
        prefix = "@loader_path/../Frameworks/" if is_exe else "@loader_path/"
        args = []
        if not is_exe:
            args += ["-id", f"@rpath/{f.name}"]
        src_owner = next((s for s, n in seen.items() if n == f.name), None) or str((Path(tools_dir) / f.name).resolve())
        for ref in deps(f):
            r = resolve(ref, src_owner) if not ref.startswith(SYSTEM_PREFIXES) else None
            if r and r in seen:
                args += ["-change", ref, prefix + seen[r]]
        for rp in rpaths(f):
            args += ["-delete_rpath", rp]
        if args:
            subprocess.run(["install_name_tool", *args, str(f)], check=True, capture_output=True)

    # sanity: nothing may still point at the build machine
    bad = []
    for f in copied:
        for ref in deps(f):
            if ref.startswith(("/opt/", "/usr/local/")):
                bad.append(f"{f.name} -> {ref}")
    if bad:
        raise SystemExit("unrewritten references:\n" + "\n".join(bad))

    # licence notices from Homebrew metadata
    conf = sh(str(exes[0]), "-hide_banner", "-version")
    gpl = "version 3 or later" if "--enable-version3" in conf else "version 2 or later"
    notices = ["Cirrus Video Compressor bundles the following third-party software, unmodified, as separate",
               "programs (ffmpeg, ffprobe) and the libraries they load. Each remains under its own licence.",
               "", f"This FFmpeg build is configured with --enable-gpl (it includes x264 and x265), so it is",
               f"distributed under the GNU General Public License, {gpl}. The app itself only runs it as a",
               "separate program.", "", "Build configuration:", *[l for l in conf.splitlines() if l.startswith("configuration:")],
               "Corresponding source code: https://ffmpeg.org/download.html and the project pages listed below;",
               "the exact versions are recorded here. A copy can also be requested from the distributor.", ""]
    formulae = {}
    for src in seen:
        m = re.match(r".*/Cellar/([^/]+)/([^/]+)/", src)
        if m:
            formulae.setdefault(m.group(1), m.group(2))
    m = re.match(r".*/Cellar/([^/]+)/([^/]+)/", str(exes[0].resolve()))
    if m:
        formulae.setdefault(m.group(1), m.group(2))
    try:
        info = json.loads(sh("brew", "info", "--json=v2", *sorted(formulae)))["formulae"]
        for f in info:
            notices.append(f"{f['name']} {formulae.get(f['name'], '')} — licence: {f.get('license') or 'see project'} — {f.get('homepage', '')}")
    except Exception as e:  # brew missing: list names only
        for n, v in sorted(formulae.items()):
            notices.append(f"{n} {v}")
    lic = contents / "Resources" / "Licenses"
    lic.mkdir(parents=True, exist_ok=True)
    (lic / "THIRD_PARTY_NOTICES.txt").write_text("\n".join(notices) + "\n")
    print(f"bundled {len(exes)} tools + {len(seen)} libraries "
          f"({sum(p.stat().st_size for p in copied) / 1e6:.1f} MB)")


if __name__ == "__main__":
    main()
