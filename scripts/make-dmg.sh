#!/bin/sh
#
# Packages dist/Overnight.app as an unsigned DMG.
#
# Unsigned is deliberate: Developer ID signing and notarization are out of scope. The README
# covers the Gatekeeper approval this costs the person installing it.

set -eu

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
DIST="$ROOT/dist"
APP="$DIST/Overnight.app"
DMG="$DIST/Overnight.dmg"
STAGE="$DIST/dmg-stage"

if [ "$(uname -s)" != "Darwin" ]; then
    echo "make-dmg.sh needs macOS: hdiutil is not available elsewhere." >&2
    exit 1
fi

[ -d "$APP" ] || sh "$ROOT/scripts/build-app.sh"

rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

hdiutil create \
    -volname "Overnight" \
    -srcfolder "$STAGE" \
    -ov \
    -format UDZO \
    "$DMG" >/dev/null

rm -rf "$STAGE"
echo "Built $DMG"
