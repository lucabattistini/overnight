#!/bin/sh
#
# Packages dist/Overnight.app as an unsigned drag-to-install DMG.
#
# What comes out is a compact Finder window with no toolbar and no status bar, Overnight.app on
# the left, an arrow, and an Applications alias on the right, over a background painted from the
# branding master, on a volume carrying its own icon. Nothing here is third party: hdiutil,
# tiffutil, osascript and xattr all ship with macOS, and the window layout is set by telling
# Finder to do it, which is the only supported way to write the icon-view state that a DMG
# carries in its .DS_Store.
#
# Unsigned is deliberate: Developer ID signing and notarization are out of scope. The README
# covers the Gatekeeper approval this costs the person installing it.
#
# Every position, size and name in the layout comes from resources/branding/dmg-layout.env,
# which scripts/icons.py also reads when it paints the background. Change the layout there, run
# `python3 scripts/icons.py build`, and the window and the artwork move together.

set -eu

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
DIST="$ROOT/dist"
APP="$DIST/Overnight.app"
DMG="$DIST/Overnight.dmg"
STAGE="$DIST/dmg-stage"
SCRATCH="$DIST/Overnight-scratch.dmg"

LAYOUT="$ROOT/resources/branding/dmg-layout.env"
BACKGROUND_1X="$ROOT/resources/branding/OvernightDMGBackground.png"
BACKGROUND_2X="$ROOT/resources/branding/OvernightDMGBackground@2x.png"
VOLUME_ICON="$ROOT/resources/VolumeIcon.icns"

# The 32 bytes of Finder info that say "this directory has a custom icon": zero type and
# creator, then the flag word 0x0400 (kHasCustomIcon), then padding. Written to the volume's
# root so macOS goes looking for .VolumeIcon.icns beside it.
FINDER_INFO_CUSTOM_ICON=0000000000000000040000000000000000000000000000000000000000000000

if [ "$(uname -s)" != "Darwin" ]; then
    cat >&2 <<'ELSEWHERE'
make-dmg.sh needs macOS.

It is not a portability gap that could be patched around. Building the installer window means
asking Finder, through osascript, to write the icon-view layout into the volume's .DS_Store,
and the disk image itself is made by hdiutil. Neither exists off macOS, and no third-party
substitute produces a DMG that Finder will open with the layout intact.

On Linux you can still check everything that is not the DMG itself:

    sh tests/payload/run.sh              the privileged payload, against stubbed binaries
    python3 scripts/icons.py verify      the app icon, volume icon and installer background,
                                         re-derived from the branding master and compared
ELSEWHERE
    exit 1
fi

[ -f "$LAYOUT" ] || {
    echo "make-dmg.sh: $LAYOUT is missing; it holds the installer window's geometry." >&2
    exit 1
}
# shellcheck source=../resources/branding/dmg-layout.env
# shellcheck disable=SC1091
. "$LAYOUT"

# Re-stated here with empty defaults so that everything below is definitely assigned whatever
# the layout file did or did not contain, and so `set -u` reports a missing key as this
# script's own error message rather than as an unbound variable a hundred lines later.
DMG_VOLUME_NAME="${DMG_VOLUME_NAME-}"
DMG_WINDOW_WIDTH="${DMG_WINDOW_WIDTH-}"
DMG_WINDOW_HEIGHT="${DMG_WINDOW_HEIGHT-}"
DMG_WINDOW_X="${DMG_WINDOW_X-}"
DMG_WINDOW_Y="${DMG_WINDOW_Y-}"
DMG_ICON_SIZE="${DMG_ICON_SIZE-}"
DMG_TEXT_SIZE="${DMG_TEXT_SIZE-}"
DMG_APP_X="${DMG_APP_X-}"
DMG_APP_Y="${DMG_APP_Y-}"
DMG_APPLICATIONS_X="${DMG_APPLICATIONS_X-}"
DMG_APPLICATIONS_Y="${DMG_APPLICATIONS_Y-}"

require_number() {
    case "$2" in
        '' | *[!0-9]*)
            echo "make-dmg.sh: $1 in dmg-layout.env must be a whole number, got '$2'" >&2
            exit 1
            ;;
    esac
}

require_number DMG_WINDOW_WIDTH "$DMG_WINDOW_WIDTH"
require_number DMG_WINDOW_HEIGHT "$DMG_WINDOW_HEIGHT"
require_number DMG_WINDOW_X "$DMG_WINDOW_X"
require_number DMG_WINDOW_Y "$DMG_WINDOW_Y"
require_number DMG_ICON_SIZE "$DMG_ICON_SIZE"
require_number DMG_TEXT_SIZE "$DMG_TEXT_SIZE"
require_number DMG_APP_X "$DMG_APP_X"
require_number DMG_APP_Y "$DMG_APP_Y"
require_number DMG_APPLICATIONS_X "$DMG_APPLICATIONS_X"
require_number DMG_APPLICATIONS_Y "$DMG_APPLICATIONS_Y"

case "$DMG_VOLUME_NAME" in
    '' | */* | *:*)
        echo "make-dmg.sh: DMG_VOLUME_NAME must be a plain name, got '$DMG_VOLUME_NAME'" >&2
        exit 1
        ;;
esac

MOUNT=""

cleanup() {
    status=$?
    # Order matters: an attached image cannot be deleted, and a half-built DMG must never be
    # left behind for the release job to find and upload.
    if [ -n "$MOUNT" ]; then
        hdiutil detach "$MOUNT" -force >/dev/null 2>&1 || true
    fi
    rm -rf "$STAGE"
    rm -f "$SCRATCH"
    if [ "$status" -ne 0 ]; then
        rm -f "$DMG"
    fi
    exit "$status"
}

trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

[ -d "$APP" ] || sh "$ROOT/scripts/build-app.sh"

for asset in "$BACKGROUND_1X" "$BACKGROUND_2X" "$VOLUME_ICON"; do
    [ -f "$asset" ] || {
        echo "make-dmg.sh: $asset is missing." >&2
        echo "Run 'python3 scripts/icons.py build' to regenerate the branding assets." >&2
        exit 1
    }
done

MOUNTPOINT="/Volumes/$DMG_VOLUME_NAME"
for existing in "$MOUNTPOINT" "$MOUNTPOINT "*; do
    [ -e "$existing" ] || continue
    cat >&2 <<COLLISION
make-dmg.sh: a volume is already mounted at $existing.

The installer window is laid out by name, so a second volume called $DMG_VOLUME_NAME would make
"tell disk \"$DMG_VOLUME_NAME\"" ambiguous and the layout could land on the wrong one. Eject it
and run this again.
COLLISION
    exit 1
done

# --- Stage everything the volume will carry -------------------------------------------------
#
# Including the hidden files, so they are inside the image the moment it is created rather than
# copied in afterwards. One fewer step that can half-succeed.

rm -rf "$STAGE"
rm -f "$SCRATCH" "$DMG"
mkdir -p "$STAGE/.background"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

# Finder reads a background at its natural size in points, so a 1x PNG on a Retina display is a
# soft one. tiffutil pairs the two committed PNGs into a single TIFF with 72dpi and 144dpi
# representations, which is how AppleScript-driven DMGs have always shipped Retina backgrounds.
# If it is unavailable the 1x PNG still works and only looks soft, so that is a warning rather
# than a failure.
BACKGROUND_NAME=background.tiff
if ! tiffutil -cathidpicheck "$BACKGROUND_1X" "$BACKGROUND_2X" \
    -out "$STAGE/.background/background.tiff" >/dev/null 2>&1; then
    echo "make-dmg.sh: tiffutil could not build the Retina background; falling back to 1x." >&2
    rm -f "$STAGE/.background/background.tiff"
    cp "$BACKGROUND_1X" "$STAGE/.background/background.png"
    BACKGROUND_NAME=background.png
fi

# --- Build a writable image, lay it out, then compress it -----------------------------------

STAGE_KB=$(du -sk "$STAGE" | awk '{ print $1 }')
# Slack for the HFS+ catalogue and for the .DS_Store Finder is about to write. The scratch
# image is deleted either way, so the only cost of being generous is a moment of disk.
SIZE_KB=$((STAGE_KB + 40960))

hdiutil create \
    -srcfolder "$STAGE" \
    -volname "$DMG_VOLUME_NAME" \
    -fs HFS+ \
    -format UDRW \
    -size "${SIZE_KB}k" \
    -ov \
    "$SCRATCH" >/dev/null

hdiutil attach "$SCRATCH" \
    -readwrite \
    -noverify \
    -noautoopen \
    -mountpoint "$MOUNTPOINT" >/dev/null
MOUNT="$MOUNTPOINT"

layout_window() {
    # Finder is the only thing that writes a .DS_Store macOS will read back, so the window is
    # built by describing it to Finder rather than by writing the file. The close/open pair at
    # the end is what makes Finder flush what it has just been told.
    osascript <<APPLESCRIPT
tell application "Finder"
    tell disk "$DMG_VOLUME_NAME"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set the bounds of container window to {$DMG_WINDOW_X, $DMG_WINDOW_Y, $((DMG_WINDOW_X + DMG_WINDOW_WIDTH)), $((DMG_WINDOW_Y + DMG_WINDOW_HEIGHT))}
        try
            -- Not every Finder build exposes this, and a window with no sidebar to hide is
            -- not a reason to fail the packaging step.
            set the sidebar width of container window to 0
        end try
        set viewOptions to the icon view options of container window
        set arrangement of viewOptions to not arranged
        set icon size of viewOptions to $DMG_ICON_SIZE
        set text size of viewOptions to $DMG_TEXT_SIZE
        set label position of viewOptions to bottom
        set shows item info of viewOptions to false
        set shows icon preview of viewOptions to false
        set background picture of viewOptions to file ".background:$BACKGROUND_NAME"
        set position of item "Overnight.app" of container window to {$DMG_APP_X, $DMG_APP_Y}
        set position of item "Applications" of container window to {$DMG_APPLICATIONS_X, $DMG_APPLICATIONS_Y}
        close
        open
        update without registering applications
        delay 2
    end tell
end tell
APPLESCRIPT
}

# Finder can take a moment to notice a volume that has only just been attached, and asking it
# about a disk it has not seen yet is an error rather than a wait. One second covers the usual
# case; the retry loop covers a loaded machine.
sleep 1
attempt=1
while :; do
    if OSASCRIPT_ERROR=$(layout_window 2>&1); then
        break
    fi
    if [ "$attempt" -ge 5 ]; then
        echo "make-dmg.sh: Finder would not lay the installer window out." >&2
        echo "$OSASCRIPT_ERROR" >&2
        cat >&2 <<'PERMISSION'

If that mentions "Not authorized to send Apple events to Finder", macOS is blocking the
automation rather than Finder refusing. Allow the terminal or CI agent under
System Settings > Privacy & Security > Automation, then run this again.
PERMISSION
        exit 1
    fi
    attempt=$((attempt + 1))
    sleep 2
done

# osascript exiting 0 is not proof that anything was written. The .DS_Store is where the whole
# layout lives, so its absence here means the DMG would mount as a plain folder listing and is
# worth failing over now rather than after it has shipped.
[ -f "$MOUNT/.DS_Store" ] || {
    echo "make-dmg.sh: Finder accepted the layout but wrote no .DS_Store to $MOUNT." >&2
    exit 1
}

# --- Volume icon, after Finder is done with the volume ---------------------------------------
#
# Finder deletes .VolumeIcon.icns from a volume it has been asked to open: it takes the file as
# the icon and then owns it. Staging the icon into the image and flagging the volume before the
# layout therefore produced a DMG with no icon file left on it, so both happen here instead,
# once Finder has written the layout and has nothing further to do.
cp "$VOLUME_ICON" "$MOUNT/.VolumeIcon.icns"

# The .icns on the volume does nothing until the volume's root is flagged as having a custom
# icon. SetFile is the documented way and ships with the Xcode command line tools, which this
# machine already has because build-app.sh needed a Swift toolchain; xattr is the fallback for
# the case where it does not, writing the same Finder info by hand.
if ! SetFile -a C "$MOUNT" 2>/dev/null; then
    if ! xattr -wx com.apple.FinderInfo "$FINDER_INFO_CUSTOM_ICON" "$MOUNT" 2>/dev/null; then
        echo "make-dmg.sh: could not flag $MOUNT as having a custom icon." >&2
        echo "Neither 'SetFile -a C' nor 'xattr -wx com.apple.FinderInfo' worked." >&2
        exit 1
    fi
fi

[ -f "$MOUNT/.VolumeIcon.icns" ] || {
    echo "make-dmg.sh: the volume icon did not survive on $MOUNT." >&2
    exit 1
}

chmod -Rf go-w "$MOUNT" 2>/dev/null || true
sync

# Finder's write can still be in flight when the layout script returns, and detaching a busy
# volume fails rather than waiting.
if ! hdiutil detach "$MOUNT" >/dev/null 2>&1; then
    sleep 3
    hdiutil detach "$MOUNT" -force >/dev/null
fi
MOUNT=""

hdiutil convert "$SCRATCH" \
    -format UDZO \
    -imagekey zlib-level=9 \
    -o "$DMG" >/dev/null

hdiutil verify "$DMG" >/dev/null

echo "Built $DMG"
