#!/bin/sh
# Builds "Double Shot.app" (universal: Apple Silicon + Intel) and a zip for GitHub Releases.
# Usage: scripts/build-app.sh            ad-hoc signed
#        SIGN_IDENTITY="Developer ID Application: ..." scripts/build-app.sh
set -e
cd "$(dirname "$0")/.."

if ! xcode-select -p | grep -q "Xcode"; then
    echo "Double Shot needs full Xcode for the universal build. Run: sudo xcode-select -s /Applications/Xcode.app"
    exit 1
fi

VERSION=$(cat VERSION)
# Build number from the version (1.2.3 -> 10203), so it never depends on git history
BUILD=$(echo "$VERSION" | awk -F. '{ printf "%d%02d%02d", $1, $2, $3 }')
APP="dist/Double Shot.app"

swift build -c release --arch arm64 --arch x86_64
BIN="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/DoubleShot"

rm -rf dist && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/DoubleShot"
sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD/" Resources/Info.plist > "$APP/Contents/Info.plist"

# App icon: every size macOS asks for, from the 1024 master
ICONSET=$(mktemp -d)/AppIcon.iconset
mkdir -p "$ICONSET"
for size in 16 32 128 256 512; do
    sips -z $size $size Resources/AppIcon.png --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
    sips -z $((size * 2)) $((size * 2)) Resources/AppIcon.png --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

codesign --force --options runtime --timestamp=none --sign "${SIGN_IDENTITY:--}" "$APP"
codesign --verify --strict "$APP"

(cd dist && ditto -c -k --keepParent "Double Shot.app" "DoubleShot-$VERSION.zip")
echo "Built $APP and dist/DoubleShot-$VERSION.zip"
