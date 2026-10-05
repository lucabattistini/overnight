#!/bin/sh

set -eu

LABEL="dev.lucabattistini.watchtest.lid"
SAFETY_LABEL="dev.lucabattistini.watchtest.safety"
PLIST="/Library/LaunchDaemons/$LABEL.plist"
SAFETY_PLIST="/Library/LaunchDaemons/$SAFETY_LABEL.plist"
BASE="/Library/Application Support/OvernightWatchTest"
TRIGGER_DIR="$BASE/trigger"
RUNNER="$BASE/runner.sh"
SAFETY_RUNNER="$BASE/safety.sh"
ROOT_LOG="$BASE/fired.log"

fail() { echo "watchtest: $1" >&2; exit 1; }

[ "$(id -u)" = "0" ] || fail "run me with sudo"

REAL_USER="${SUDO_USER:-}"
[ -n "$REAL_USER" ] || fail "could not tell which user invoked sudo; run as 'sudo sh $0'"
REAL_HOME=$(eval echo "~$REAL_USER")
USER_BASE="$REAL_HOME/Library/Application Support/OvernightWatchTest"
USER_LOG="$USER_BASE/touched.log"
TOUCHER="$USER_BASE/toucher.sh"

[ -f "/Library/Application Support/Overnight/state.conf" ] && fail "Overnight has a session active; turn it off first"

CURRENT=$(/usr/bin/pmset -g | awk '$1 == "SleepDisabled" { print $2; exit }')
case "$CURRENT" in
    1) fail "SleepDisabled is already 1; something else set it. Clear it with 'sudo pmset -a disablesleep 0' first" ;;
esac

HELD=$(/usr/bin/pmset -g assertions | grep -cE '^[[:space:]]+(PreventUserIdleSystemSleep|PreventSystemSleep)[[:space:]]+1' || true)
[ "$HELD" = "0" ] || echo "WARNING: something already holds a sleep assertion. Run 'pmset -g assertions' and close it, or the result is confounded."

ON_BATTERY=$(/usr/bin/pmset -g batt | grep -c "Battery Power" || true)
[ "$ON_BATTERY" = "1" ] || echo "WARNING: you look plugged in. Unplug the adapter AND the dock, or the test proves nothing."

echo "== WatchPaths lid-closed test =="
echo
echo "What this does:"
echo "  - sets 'pmset -a disablesleep 1' so the Mac stays awake with the lid shut"
echo "  - installs two temporary LaunchDaemons under the watchtest labels"
echo "  - a background process running as $REAL_USER creates a sentinel 3 minutes from now"
echo "  - a safety job puts everything back 25 minutes from now, even if you walk away"
echo

/bin/launchctl bootout "system/$LABEL" 2>/dev/null || true
/bin/launchctl bootout "system/$SAFETY_LABEL" 2>/dev/null || true
rm -f "$PLIST" "$SAFETY_PLIST"
rm -rf "$BASE"
rm -rf "$USER_BASE"

install -d -o root -g wheel -m 0755 "$BASE"
install -d -o root -g wheel -m 1733 "$TRIGGER_DIR"
install -d -o "$REAL_USER" -m 0755 "$USER_BASE"

cat > "$RUNNER" <<'RUNNER_EOF'
#!/bin/sh
BASE="/Library/Application Support/OvernightWatchTest"
COUNT=$(ls -1 "$BASE/trigger" 2>/dev/null | wc -l | tr -d ' ')
FLAG=$(/usr/bin/pmset -g | awk '$1 == "SleepDisabled" { print $2; exit }')
printf '%s ran as uid=%s files-in-trigger=%s SleepDisabled=%s\n' \
    "$(date '+%H:%M:%S')" "$(id -u)" "$COUNT" "$FLAG" >> "$BASE/fired.log"
RUNNER_EOF
chown root:wheel "$RUNNER"
chmod 0755 "$RUNNER"

cat > "$SAFETY_RUNNER" <<SAFETY_EOF
#!/bin/sh
/usr/bin/pmset -a disablesleep 0
/bin/launchctl bootout "system/$LABEL" 2>/dev/null || true
/bin/launchctl bootout "system/$SAFETY_LABEL" 2>/dev/null || true
rm -f "$PLIST" "$SAFETY_PLIST"
printf '%s safety job restored sleep and unloaded both daemons\n' "\$(date '+%H:%M:%S')" >> "$ROOT_LOG"
SAFETY_EOF
chown root:wheel "$SAFETY_RUNNER"
chmod 0755 "$SAFETY_RUNNER"

cat > "$TOUCHER" <<TOUCHER_EOF
#!/bin/sh
sleep 180
printf '%s about to create the sentinel as uid=%s\n' "\$(date '+%H:%M:%S')" "\$(id -u)" >> "$USER_LOG"
if : > "$TRIGGER_DIR/stop" 2>>"$USER_LOG"; then
    printf '%s sentinel created\n' "\$(date '+%H:%M:%S')" >> "$USER_LOG"
else
    printf '%s COULD NOT WRITE the sentinel\n' "\$(date '+%H:%M:%S')" >> "$USER_LOG"
fi
TOUCHER_EOF
chown "$REAL_USER" "$TOUCHER"
chmod 0755 "$TOUCHER"

plist_time() {
    _e="$1"
    printf '\t\t<key>Month</key>\n\t\t<integer>%s</integer>\n' "$(date -r "$_e" +%m | sed 's/^0//')"
    printf '\t\t<key>Day</key>\n\t\t<integer>%s</integer>\n' "$(date -r "$_e" +%d | sed 's/^0//')"
    printf '\t\t<key>Hour</key>\n\t\t<integer>%s</integer>\n' "$(date -r "$_e" +%H | sed 's/^0*//;s/^$/0/')"
    printf '\t\t<key>Minute</key>\n\t\t<integer>%s</integer>\n' "$(date -r "$_e" +%M | sed 's/^0*//;s/^$/0/')"
}

NOW=$(date +%s)
CAL_EPOCH=$(( NOW + 540 ))
SAFETY_EPOCH=$(( NOW + 1500 ))

{
    echo '<?xml version="1.0" encoding="UTF-8"?>'
    echo '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">'
    echo '<plist version="1.0">'
    echo '<dict>'
    printf '\t<key>Label</key>\n\t<string>%s</string>\n' "$LABEL"
    printf '\t<key>ProgramArguments</key>\n\t<array>\n\t\t<string>/bin/sh</string>\n\t\t<string>%s</string>\n\t</array>\n' "$RUNNER"
    printf '\t<key>RunAtLoad</key>\n\t<false/>\n'
    printf '\t<key>WatchPaths</key>\n\t<array>\n\t\t<string>%s</string>\n\t</array>\n' "$TRIGGER_DIR"
    printf '\t<key>StartCalendarInterval</key>\n\t<dict>\n'
    plist_time "$CAL_EPOCH"
    printf '\t</dict>\n'
    echo '</dict>'
    echo '</plist>'
} > "$PLIST"

{
    echo '<?xml version="1.0" encoding="UTF-8"?>'
    echo '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">'
    echo '<plist version="1.0">'
    echo '<dict>'
    printf '\t<key>Label</key>\n\t<string>%s</string>\n' "$SAFETY_LABEL"
    printf '\t<key>ProgramArguments</key>\n\t<array>\n\t\t<string>/bin/sh</string>\n\t\t<string>%s</string>\n\t</array>\n' "$SAFETY_RUNNER"
    printf '\t<key>RunAtLoad</key>\n\t<false/>\n'
    printf '\t<key>StartCalendarInterval</key>\n\t<dict>\n'
    plist_time "$SAFETY_EPOCH"
    printf '\t</dict>\n'
    echo '</dict>'
    echo '</plist>'
} > "$SAFETY_PLIST"

chown root:wheel "$PLIST" "$SAFETY_PLIST"
chmod 0644 "$PLIST" "$SAFETY_PLIST"

/bin/launchctl bootstrap system "$PLIST" || fail "could not load the watch daemon"
/bin/launchctl bootstrap system "$SAFETY_PLIST" || fail "could not load the safety daemon"

/usr/bin/pmset -a disablesleep 1

/usr/bin/sudo -u "$REAL_USER" /usr/bin/nohup /bin/sh "$TOUCHER" >/dev/null 2>&1 &

echo "armed at $(date '+%H:%M:%S')"
echo "  sentinel will be created at  $(date -r "$(( NOW + 180 ))" '+%H:%M:%S')"
echo "  calendar trigger fires at    $(date -r "$CAL_EPOCH" '+%H:%M:%S')"
echo "  safety job restores sleep at $(date -r "$SAFETY_EPOCH" '+%H:%M:%S')"
echo
echo "Expect THREE lines in the root log, not two:"
echo "  1. one at $(date -r "$NOW" '+%H:%M:%S') - launchd fires a WatchPaths job once at load."
echo "     Seen twice on Darwin 25.6, undocumented by Apple. files-in-trigger=0, so it is noise."
echo "  2. one near $(date -r "$(( NOW + 180 ))" '+%H:%M:%S') with files-in-trigger=1 - THIS IS THE TEST."
echo "     Present means WatchPaths fires with the lid closed on battery."
echo "  3. one near $(date -r "$CAL_EPOCH" '+%H:%M:%S') - the calendar trigger, which already works today."
echo
echo "Line 2 missing, or timestamped when you reopen the lid, means the sentinel design is dead."
echo
echo "NOW: unplug the adapter and the dock, close the lid, and leave it for 11 minutes."
echo "Then open the lid and run read.sh."
