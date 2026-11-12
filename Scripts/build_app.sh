#!/bin/bash
# Build "Cirrus Video Compressor.app" — a self-contained, double-clickable app.
#
#   Scripts/build_app.sh            → build/Cirrus Video Compressor.app
#   Scripts/build_app.sh --dmg      → also build/CirrusVideoCompressor-<version>.dmg
#
# Requires: Command Line Tools (or Xcode), and an FFmpeg with libsvtav1,
# libx265, libx264, libopus and libvmaf (Homebrew's `ffmpeg` formula has all
# of them). Set FFMPEG_DIR to use a specific FFmpeg build.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT=$(pwd)
VERSION=$(cat VERSION)
BUILD="$ROOT/build"
APP="$BUILD/Cirrus Video Compressor.app"
C="$APP/Contents"

# SwiftPM's build database misbehaves inside iCloud-synced folders (~/Documents),
# so intermediate build products live in the temporary directory.
SCRATCH="${CIRRUS_SCRATCH:-${TMPDIR:-/tmp}/cirrus-video-compressor-build}"
echo "▸ Compiling (release, arm64)…"
swift build -c release --arch arm64 --product CirrusApp --scratch-path "$SCRATCH" 2>&1 | grep -vE '^\[[0-9]+/[0-9]+\]' || true
swift build -c release --arch arm64 --product cirrus --scratch-path "$SCRATCH" 2>&1 | grep -E 'error' || true
BINDIR=$(swift build -c release --arch arm64 --scratch-path "$SCRATCH" --show-bin-path)
BIN=$BINDIR/CirrusApp
[ -x "$BIN" ] || { echo "build failed"; exit 1; }

echo "▸ Assembling bundle…"
rm -rf "$APP"
mkdir -p "$C/MacOS" "$C/Resources" "$C/Helpers" "$C/Frameworks"
cp "$BIN" "$C/MacOS/Cirrus Video Compressor"
cp Resources/AppIcon.icns "$C/Resources/AppIcon.icns"
cp "$BINDIR/cirrus" "$C/Helpers/cirrus"      # command-line engine, finds the bundled FFmpeg beside it

echo "▸ Bundling FFmpeg…"
python3 Scripts/bundle_ffmpeg.py "$C" ${FFMPEG_DIR:+--tools-dir "$FFMPEG_DIR"}
cp LICENSE "$C/Resources/Licenses/LICENSE.txt" 2>/dev/null || true

# Minimum macOS = the newest requirement among app + bundled binaries.
MINOS=14.0
for f in "$C/MacOS/"* "$C/Helpers/"* "$C/Frameworks/"*; do
  v=$(vtool -show-build "$f" 2>/dev/null | awk '/minos/{print $2; exit}')
  [ -n "$v" ] && MINOS=$(printf '%s\n%s\n' "$MINOS" "$v" | sort -V | tail -1)
done

cat > "$C/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Cirrus Video Compressor</string>
  <key>CFBundleDisplayName</key><string>Cirrus Video Compressor</string>
  <key>CFBundleIdentifier</key><string>app.cirrusvideo.compressor</string>
  <key>CFBundleExecutable</key><string>Cirrus Video Compressor</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>$MINOS</string>
  <key>LSArchitecturePriority</key><array><string>arm64</string></array>
  <key>LSApplicationCategoryType</key><string>public.app-category.video</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSSupportsAutomaticGraphicsSwitching</key><true/>
  <key>NSHumanReadableCopyright</key><string>© 2026 Cirrus</string>
  <key>CFBundleDocumentTypes</key><array><dict>
    <key>CFBundleTypeName</key><string>Video</string>
    <key>CFBundleTypeRole</key><string>Viewer</string>
    <key>LSHandlerRank</key><string>Alternate</string>
    <key>LSItemContentTypes</key><array>
      <string>public.movie</string><string>public.video</string><string>public.mpeg-4</string>
      <string>com.apple.quicktime-movie</string><string>org.matroska.mkv</string><string>org.webmproject.webm</string>
    </array>
  </dict></array>
</dict></plist>
PLIST

echo "▸ Signing (ad-hoc)…"
for f in "$C/Frameworks/"*.dylib "$C/Helpers/"*; do codesign --force --sign - --timestamp=none "$f" 2>/dev/null; done
codesign --force --sign - --timestamp=none "$APP" 2>/dev/null
codesign --verify --deep --strict "$APP"

echo "▸ Verifying bundled engine…"
# env -i: prove it runs with no Homebrew paths in the environment
ENCODERS=$(env -i "$C/Helpers/ffmpeg" -hide_banner -encoders 2>/dev/null || true)
FILTERS=$(env -i "$C/Helpers/ffmpeg" -hide_banner -filters 2>/dev/null || true)
grep -q libsvtav1 <<<"$ENCODERS" || { echo "bundled ffmpeg failed to run"; exit 1; }
grep -q libvmaf <<<"$FILTERS" || echo "warning: bundled ffmpeg has no libvmaf"
du -sh "$APP" | awk '{print "  bundle size: "$1}'
echo "  minimum macOS: $MINOS"

if [[ "${1:-}" == "--dmg" ]]; then
  echo "▸ Creating disk image…"
  STAGE="$BUILD/dmg"; rm -rf "$STAGE"; mkdir -p "$STAGE"
  cp -R "$APP" "$STAGE/"; ln -s /Applications "$STAGE/Applications"
  DMG="$BUILD/CirrusVideoCompressor-$VERSION.dmg"; rm -f "$DMG"
  hdiutil create -volname "Cirrus Video Compressor" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
  rm -rf "$STAGE"
  echo "  $DMG"
fi
echo "✓ $APP"
