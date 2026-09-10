#!/bin/sh
#
# Guards the contract shared by the installer window's three moving parts.
#
# resources/branding/dmg-layout.env holds the geometry. scripts/make-dmg.sh reads it to tell
# Finder where to put the window and the two icons. scripts/icons.py reads it to paint the
# background those icons sit on. If a key existed in one and not the others, the failure would
# be an arrow pointing at empty space in a released DMG — visible only to whoever downloaded
# it, on a machine none of the CI runners can be.
#
# This runs anywhere, needs nothing but a shell, and does not build a DMG.

set -eu

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
LAYOUT="$ROOT/resources/branding/dmg-layout.env"
PACKAGER="$ROOT/scripts/make-dmg.sh"
PAINTER="$ROOT/scripts/icons.py"

status=0

fail() {
    echo "$1" >&2
    status=1
}

for file in "$LAYOUT" "$PACKAGER" "$PAINTER"; do
    [ -f "$file" ] || { echo "check-dmg-layout.sh: $file is missing" >&2; exit 1; }
done

# --- Every key is known to all three files --------------------------------------------------
#
# The packager reads them as shell variables and the painter as quoted dictionary keys, so
# "mentions DMG_SOMETHING" is a good enough proxy for "knows about it" in both.

declared=$(sed -n 's/^\(DMG_[A-Z0-9_]*\)=.*/\1/p' "$LAYOUT" | sort -u)
packaged=$(grep -o 'DMG_[A-Z0-9_]*' "$PACKAGER" | sort -u)
painted=$(grep -o '"DMG_[A-Z0-9_]*"' "$PAINTER" | tr -d '"' | sort -u)

[ -n "$declared" ] || fail "dmg-layout.env declares no DMG_ keys at all"

if [ "$declared" != "$packaged" ]; then
    fail "dmg-layout.env and make-dmg.sh disagree about the layout keys"
    printf 'dmg-layout.env declares:\n%s\nmake-dmg.sh reads:\n%s\n' \
        "$declared" "$packaged" >&2
fi

if [ "$declared" != "$painted" ]; then
    fail "dmg-layout.env and icons.py disagree about the layout keys"
    printf 'dmg-layout.env declares:\n%s\nicons.py reads:\n%s\n' \
        "$declared" "$painted" >&2
fi

# --- The geometry is actually possible ------------------------------------------------------

# shellcheck source=../resources/branding/dmg-layout.env
# shellcheck disable=SC1091
. "$LAYOUT"

DMG_WINDOW_WIDTH="${DMG_WINDOW_WIDTH-0}"
DMG_WINDOW_HEIGHT="${DMG_WINDOW_HEIGHT-0}"
DMG_ICON_SIZE="${DMG_ICON_SIZE-0}"
DMG_APP_X="${DMG_APP_X-0}"
DMG_APP_Y="${DMG_APP_Y-0}"
DMG_APPLICATIONS_X="${DMG_APPLICATIONS_X-0}"
DMG_APPLICATIONS_Y="${DMG_APPLICATIONS_Y-0}"

half=$((DMG_ICON_SIZE / 2))

check_inside() {
    what=$1
    x=$2
    y=$3
    if [ "$((x - half))" -lt 0 ] || [ "$((x + half))" -gt "$DMG_WINDOW_WIDTH" ]; then
        fail "$what at x=$x hangs off a ${DMG_WINDOW_WIDTH}pt window at ${DMG_ICON_SIZE}pt icons"
    fi
    if [ "$((y - half))" -lt 0 ] || [ "$((y + half))" -gt "$DMG_WINDOW_HEIGHT" ]; then
        fail "$what at y=$y hangs off a ${DMG_WINDOW_HEIGHT}pt window at ${DMG_ICON_SIZE}pt icons"
    fi
}

check_inside "the app icon" "$DMG_APP_X" "$DMG_APP_Y"
check_inside "the Applications alias" "$DMG_APPLICATIONS_X" "$DMG_APPLICATIONS_Y"

# The arrow is painted into the background between the two icons and is 80pt wide, so the gap
# between their edges has to be wider than that with room to breathe on both sides.
gap=$((DMG_APPLICATIONS_X - DMG_APP_X - DMG_ICON_SIZE))
if [ "$gap" -lt 100 ]; then
    fail "only ${gap}pt between the two icons; the arrow painted between them needs 100pt"
fi

# Finder hangs the label below the icon. If the icon sits too low the label is clipped by the
# bottom of the window, which looks like a bug rather than a layout choice.
if [ "$((DMG_APP_Y + half + 28))" -gt "$DMG_WINDOW_HEIGHT" ]; then
    fail "the app icon's label would be clipped by the bottom of the window"
fi

# --- The volume icon will actually be switched on -------------------------------------------
#
# A .VolumeIcon.icns on the volume does nothing unless the volume's root carries the Finder
# flag that says to go looking for it. make-dmg.sh writes those 32 bytes by hand as a fallback,
# and a typo in them is silent: the DMG builds, and mounts with a generic icon.

finder_info=$(sed -n 's/^FINDER_INFO_CUSTOM_ICON=\([0-9a-fA-F]*\)$/\1/p' "$PACKAGER")
if [ "${#finder_info}" -ne 64 ]; then
    fail "FINDER_INFO_CUSTOM_ICON is ${#finder_info} hex digits, expected 64 (32 bytes)"
elif [ "$(printf '%s' "$finder_info" | cut -c17-20)" != "0400" ]; then
    fail "FINDER_INFO_CUSTOM_ICON does not set kHasCustomIcon (0x0400) in the Finder flags"
elif [ "$(printf '%s' "$finder_info" | cut -c1-16)" != "0000000000000000" ]; then
    fail "FINDER_INFO_CUSTOM_ICON sets a file type or creator; a volume root has neither"
fi

[ "$status" -eq 0 ] && echo "installer window layout agrees across dmg-layout.env, make-dmg.sh and icons.py"
exit "$status"
