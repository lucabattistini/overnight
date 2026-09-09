#!/bin/sh
#
# Builds dist/Overnight.app.
#
# The bundle is assembled by hand from `swift build` output rather than by an Xcode project.
# A checked-in .xcodeproj is the larger moving part: swift build already produces the universal
# binary, and the bundle is three directories and an Info.plist.

set -eu

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
DIST="$ROOT/dist"
APP="$DIST/Overnight.app"
VERSION="${OVERNIGHT_VERSION:-$(git -C "$ROOT" describe --tags --abbrev=0 2>/dev/null || echo 0.0.0)}"
VERSION="${VERSION#v}"

if [ "$(uname -s)" != "Darwin" ]; then
    echo "build-app.sh needs macOS: it builds a macOS app bundle with the Swift toolchain." >&2
    echo "On Linux, run 'sh tests/payload/run.sh' for the payload tests instead." >&2
    exit 1
fi

echo "Building Overnight $VERSION"
swift build --package-path "$ROOT" -c release --arch arm64 --arch x86_64

BIN=$(swift build --package-path "$ROOT" -c release --arch arm64 --arch x86_64 --show-bin-path)

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN/Overnight" "$APP/Contents/MacOS/Overnight"

# The privileged payload ships inside the bundle. enable installs a root-owned copy of the
# restore script before launchd is ever pointed at it, so the copy that runs as root is never
# the one sitting in this user-writable directory.
cp "$ROOT/payload/overnight-enable.sh" "$APP/Contents/Resources/"
cp "$ROOT/payload/overnight-restore.sh" "$APP/Contents/Resources/"
chmod 0755 "$APP/Contents/Resources/overnight-enable.sh" "$APP/Contents/Resources/overnight-restore.sh"

# The .icns is a checked-in build product, not something generated here: `iconutil` and `sips`
# only exist on macOS, and an icon that is rebuilt during packaging is an icon that can differ
# between machines. scripts/icons.py regenerates it from the branding master, and CI checks the
# committed file still matches. CFBundleIconFile in Info.plist names this file.
if [ ! -f "$ROOT/resources/Overnight.icns" ]; then
    echo "resources/Overnight.icns is missing. Run 'python3 scripts/icons.py build'." >&2
    exit 1
fi
cp "$ROOT/resources/Overnight.icns" "$APP/Contents/Resources/Overnight.icns"

sed "s/__VERSION__/$VERSION/g" "$ROOT/resources/Info.plist" > "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

plutil -lint "$APP/Contents/Info.plist" >/dev/null

echo "Built $APP"
file "$APP/Contents/MacOS/Overnight"
