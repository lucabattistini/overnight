#!/bin/sh
#
# Overnight — privileged restore.
#
# The single restore path. It runs from two places: launchd at the deadline, and the app when
# the user turns Overnight off or unplugs from AC. Both entry points are identical, so there
# is one code path to reason about.
#
# Usage: overnight-restore.sh
#
# Exits 0 when there is nothing to do, so running it twice, or running it when Overnight was
# never on, is harmless.

set -eu

SUPPORT_DIR="/Library/Application Support/Overnight"
STATE_FILE="$SUPPORT_DIR/state.conf"
LABEL="dev.lucabattistini.overnight.restore"
PLIST="/Library/LaunchDaemons/$LABEL.plist"
PMSET="/usr/bin/pmset"

fail() {
    echo "overnight-restore: $1" >&2
    exit 1
}

require_number() {
    case "$1" in
        '' | *[!0-9]*) fail "value for '$2' is not a plain number: '$1'" ;;
    esac
    if [ "${#1}" -gt "$3" ]; then
        fail "value for '$2' has too many digits: '$1'"
    fi
}

[ "$(id -u)" = "0" ] || fail "must run as root"

# Nothing to restore. Not an error: the deadline job and a manual turn-off can race, and
# whichever loses should exit quietly.
if [ ! -f "$STATE_FILE" ]; then
    /bin/launchctl bootout "system/$LABEL" 2>/dev/null || true
    rm -f "$PLIST"
    echo "overnight-restore: nothing to restore"
    exit 0
fi

[ -L "$STATE_FILE" ] && fail "$STATE_FILE is a symlink; refusing to read it"

# The state file lives in a root-owned directory, but it is still parsed as untrusted input.
# Every key must be one this script knows and every value must be digits only, so a tampered
# file aborts the restore instead of reaching pmset.
AC_ARGS=""
PRIOR_SLEEP_DISABLED=""
SAW_VERSION=0

while IFS=' ' read -r key value extra; do
    [ -z "$key" ] && continue
    case "$key" in \#*) continue ;; esac
    [ -n "$extra" ] && fail "malformed line in saved state: '$key $value $extra'"
    [ -z "$value" ] && fail "malformed line in saved state: '$key'"

    case "$key" in
        version)
            [ "$value" = "1" ] || fail "unsupported saved-state version: '$value'"
            SAW_VERSION=1
            ;;
        deadline_epoch)
            require_number "$value" "$key" 11
            ;;
        prior_sleep_disabled)
            case "$value" in
                0 | 1) PRIOR_SLEEP_DISABLED="$value" ;;
                *) fail "prior_sleep_disabled must be 0 or 1, found '$value'" ;;
            esac
            ;;
        # The four settings Overnight writes are the only four it replays.
        ac_sleep | ac_disksleep | ac_displaysleep | ac_powernap)
            require_number "$value" "$key" 5
            AC_ARGS="$AC_ARGS ${key#ac_} $value"
            ;;
        # Captured for diagnostics but never written, so never replayed. Replaying an
        # untouched setting would still be a write to something Overnight did not change.
        ac_tcpkeepalive | battery_sleep | battery_disksleep | battery_displaysleep | battery_powernap | battery_tcpkeepalive)
            require_number "$value" "$key" 5
            ;;
        *)
            fail "unknown key in saved state: '$key'"
            ;;
    esac
done < "$STATE_FILE"

[ "$SAW_VERSION" = "1" ] || fail "saved state has no version line"

# Replay. The AC timers first, then the global flag.
if [ -n "$AC_ARGS" ]; then
    # shellcheck disable=SC2086
    "$PMSET" -c $AC_ARGS
fi
if [ -n "$PRIOR_SLEEP_DISABLED" ]; then
    "$PMSET" -a disablesleep "$PRIOR_SLEEP_DISABLED"
else
    # The capture never saw the flag, which means this macOS does not report it. Clearing it
    # is still the right move: Overnight set it, so Overnight turns it off.
    "$PMSET" -a disablesleep 0
fi

# Tear down the run. The plist and the captured state go; this script stays.
#
# It deliberately does not delete itself: sh reads a script lazily, so removing the file that
# is currently executing is not safe. What is left behind is inert — nothing references it
# once the plist is gone, it is root-owned so it cannot be tampered with, and the next enable
# overwrites it. The README's Uninstall section removes it.
/bin/launchctl bootout "system/$LABEL" 2>/dev/null || true
rm -f "$PLIST"
rm -f "$STATE_FILE"

echo "overnight-restore: restored"
