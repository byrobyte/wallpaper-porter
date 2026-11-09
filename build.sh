#!/bin/bash
# Builds "Wallpaper Porter.app" into ./build. Needs Xcode or the Command Line Tools (xcode-select --install).
set -euo pipefail
cd "$(dirname "$0")"

if ! command -v swiftc >/dev/null 2>&1; then
  echo "Swift isn't installed. Run:  xcode-select --install   then run this script again."
  exit 1
fi

APP="build/Wallpaper Porter.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" build/obj

echo "→ Compiling (this takes about a minute)…"
ARCHS=(arm64 x86_64)
BINS=()
for ARCH in "${ARCHS[@]}"; do
  OUT="build/obj/WallpaperPorter-$ARCH"
  swiftc -O -swift-version 5 -parse-as-library \
    -target "$ARCH-apple-macos13.0" \
    Sources/*.swift -o "$OUT"
  BINS+=("$OUT")
done
lipo -create "${BINS[@]}" -output "$APP/Contents/MacOS/WallpaperPorter"

cp Info.plist "$APP/Contents/Info.plist"

if [ -f Resources/AppIcon.png ]; then
  echo "→ Making icon…"
  ICONSET="build/obj/AppIcon.iconset"
  rm -rf "$ICONSET"; mkdir -p "$ICONSET"
  for S in 16 32 128 256 512; do
    sips -z $S $S Resources/AppIcon.png --out "$ICONSET/icon_${S}x${S}.png" >/dev/null
    sips -z $((S*2)) $((S*2)) Resources/AppIcon.png --out "$ICONSET/icon_${S}x${S}@2x.png" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
fi

echo "→ Signing (ad-hoc, for this Mac)…"
codesign --force --deep --sign - "$APP"

echo
echo "✅ Built: $(pwd)/$APP"
echo "   Move it to Applications:  mv \"$APP\" /Applications/"
echo "   Then open it from Launchpad or Finder."
