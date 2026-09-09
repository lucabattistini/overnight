#!/bin/sh
#
# Overnight — privileged enable.
#
# Runs once as root, from a single AppleScript "do shell script ... with administrator
# privileges" invocation. It captures the machine's current power settings, arms a one-shot
# restore job for the deadline, and only then applies the overnight profile.
#
# Usage: overnight-enable.sh <month> <day> <hour> <minute> <deadline-epoch>
#
# The month/day/hour/minute quadruple arms launchd's StartCalendarInterval. The epoch is the
# same instant as a plain integer, computed by the app against the user's calendar so this
# script never has to reason about year boundaries or time zones; it is recorded in the saved
# state purely so the menu bar can display the deadline after a relaunch.
#
# Every argument is re-validated here even though the app validated it first. This is the
# second of the two layers: an injection would have to defeat both.

set -eu

SUPPORT_DIR="/Library/Application Support/Overnight"
STATE_FILE="$SUPPORT_DIR/state.conf"
INSTALLED_RESTORE="$SUPPORT_DIR/overnight-restore.sh"
LABEL="dev.lucabattistini.overnight.restore"
PLIST="/Library/LaunchDaemons/$LABEL.plist"
PMSET="/usr/bin/pmset"

# The settings Overnight captures. Kept identical to ManagedSetting in
# Sources/OvernightCore/PowerCapture.swift; CI greps both for drift.
MANAGED_KEYS="sleep disksleep displaysleep powernap tcpkeepalive"

# The settings Overnight writes. tcpkeepalive is captured but deliberately not written:
# its -c scoping is unverified. See PowerCapture.swift for the full reasoning.
APPLY_ARGS="sleep 0 disksleep 0 displaysleep 2 powernap 0"

fail() {
    echo "overnight-enable: $1" >&2
    exit 1
}

# Accepts only a bare run of ASCII digits. Rejects "1; touch /tmp/x", "$(id)", "-1",
# embedded whitespace, and anything with a newline.
require_number() {
    _value="$1"
    _max="$2"
    _label="$3"
    case "$_value" in
        '' | *[!0-9]*) fail "$_label is not a plain number: '$_value'" ;;
    esac
    if [ "${#_value}" -gt "$_max" ]; then
        fail "$_label has too many digits: '$_value'"
    fi
}

[ "$#" -eq 5 ] || fail "expected 5 arguments (month day hour minute epoch), got $#"

MONTH="$1"; DAY="$2"; HOUR="$3"; MINUTE="$4"; DEADLINE_EPOCH="$5"
require_number "$MONTH" 2 "month"
require_number "$DAY" 2 "day"
require_number "$HOUR" 2 "hour"
require_number "$MINUTE" 2 "minute"
require_number "$DEADLINE_EPOCH" 11 "deadline epoch"
[ "$MONTH" -ge 1 ] && [ "$MONTH" -le 12 ] || fail "month out of range: $MONTH"
[ "$DAY" -ge 1 ] && [ "$DAY" -le 31 ] || fail "day out of range: $DAY"
[ "$HOUR" -le 23 ] || fail "hour out of range: $HOUR"
[ "$MINUTE" -le 59 ] || fail "minute out of range: $MINUTE"

[ "$(id -u)" = "0" ] || fail "must run as root"

# The restore script ships beside this one inside the app bundle. Resolving it from $0 means
# no path argument crosses the privilege boundary.
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
RESTORE_SRC="$SCRIPT_DIR/overnight-restore.sh"
[ -f "$RESTORE_SRC" ] || fail "restore script not found next to this script"
[ -L "$RESTORE_SRC" ] && fail "restore script is a symlink; refusing to install it"

# --- 1. The support directory must be root-owned and not a symlink ------------------------
#
# Created if absent; verified if present. It is never repaired in place: a directory that
# already exists with the wrong ownership is a substitution attempt, not a mistake to fix.
if [ -e "$SUPPORT_DIR" ] || [ -L "$SUPPORT_DIR" ]; then
    [ -L "$SUPPORT_DIR" ] && fail "$SUPPORT_DIR is a symlink; refusing to use it"
    [ -d "$SUPPORT_DIR" ] || fail "$SUPPORT_DIR exists but is not a directory"
    OWNERSHIP=$(stat -f '%u %g %Lp' "$SUPPORT_DIR")
    [ "$OWNERSHIP" = "0 0 755" ] || fail "$SUPPORT_DIR must be root:wheel mode 755, found: $OWNERSHIP"
else
    install -d -o root -g wheel -m 0755 "$SUPPORT_DIR"
fi

# --- 2. Capture the current settings ------------------------------------------------------
#
# Reading pmset needs no privilege, but doing the capture here rather than in the app means
# no user-writable file is ever consumed by the privileged side.
capture_profiles() {
    "$PMSET" -g custom | awk -v keys="$MANAGED_KEYS" '
        BEGIN { n = split(keys, k, " "); for (i = 1; i <= n; i++) want[k[i]] = 1 }
        /^Battery Power:/ { section = "battery"; next }
        /^AC Power:/      { section = "ac";      next }
        /^[^ \t]/         { section = "";        next }
        {
            if (section == "" || NF != 2) next
            if (!($1 in want)) next
            if ($2 !~ /^[0-9]+$/ || length($2) > 5) {
                print "unusable value for " $1 ": " $2 > "/dev/stderr"
                exit 1
            }
            printf "%s_%s %s\n", section, $1, $2
        }
    ' | sort
}

# disablesleep is undocumented and never appears in 'pmset -g custom'. It reads back as the
# system-wide SleepDisabled flag.
capture_sleep_disabled() {
    "$PMSET" -g | awk '$1 == "SleepDisabled" && NF == 2 && $2 ~ /^[01]$/ { print $2; exit }'
}

PROFILES=$(capture_profiles) || fail "could not parse 'pmset -g custom'"
[ -n "$PROFILES" ] || fail "'pmset -g custom' reported none of the managed settings"
PRIOR_SLEEP_DISABLED=$(capture_sleep_disabled || true)

# --- 3. Write the captured state atomically -----------------------------------------------
#
# Written to a temporary file in the same directory and renamed into place, so a crash
# mid-write cannot leave a half-parsed capture that restore would act on.
TMP_STATE="$SUPPORT_DIR/.state.conf.$$"
umask 022
{
    echo "version 1"
    echo "deadline_epoch $DEADLINE_EPOCH"
    if [ -n "$PRIOR_SLEEP_DISABLED" ]; then
        echo "prior_sleep_disabled $PRIOR_SLEEP_DISABLED"
    fi
    echo "$PROFILES"
} > "$TMP_STATE"
chown root:wheel "$TMP_STATE"
chmod 0644 "$TMP_STATE"
mv -f "$TMP_STATE" "$STATE_FILE"

# --- 4. Install the restore payload root-owned --------------------------------------------
#
# launchd must never execute the copy inside the app bundle: that lives under a path the user
# can write, which would make it a user-writable privileged executable.
install -o root -g wheel -m 0755 "$RESTORE_SRC" "$INSTALLED_RESTORE"

# --- 5. Arm the one-shot deadline job -----------------------------------------------------
#
# Month and day are pinned as well as hour and minute, so the job is effectively one-shot even
# if the restore never gets to remove it. launchd runs a missed interval at the next wake,
# which is exactly the behaviour wanted for the crash case.
/bin/launchctl bootout "system/$LABEL" 2>/dev/null || true
rm -f "$PLIST"

cat > "$PLIST" <<PLIST_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>$LABEL</string>
	<key>ProgramArguments</key>
	<array>
		<string>/bin/sh</string>
		<string>$INSTALLED_RESTORE</string>
	</array>
	<key>RunAtLoad</key>
	<false/>
	<key>StartCalendarInterval</key>
	<dict>
		<key>Month</key>
		<integer>$MONTH</integer>
		<key>Day</key>
		<integer>$DAY</integer>
		<key>Hour</key>
		<integer>$HOUR</integer>
		<key>Minute</key>
		<integer>$MINUTE</integer>
	</dict>
</dict>
</plist>
PLIST_EOF

chown root:wheel "$PLIST"
chmod 0644 "$PLIST"
/bin/launchctl bootstrap system "$PLIST" || fail "could not load the deadline job"

# --- 6. Apply the overnight profile -------------------------------------------------------
#
# Last, so an abort at any earlier step leaves the machine exactly as it was found.
#
# The timers are scoped to AC with -c. disablesleep is applied with -a because it has no
# per-power-source form: the 2026-09-09 hardware spike confirmed that 'pmset -c disablesleep 1'
# exits 0, warns about nothing, and sets the global flag anyway.
# shellcheck disable=SC2086
"$PMSET" -c $APPLY_ARGS
"$PMSET" -a disablesleep 1

echo "overnight-enable: active until $(printf '%02d-%02d %02d:%02d' "$MONTH" "$DAY" "$HOUR" "$MINUTE")"
