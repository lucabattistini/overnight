#!/bin/sh

set -eu

LABEL="dev.lucabattistini.watchtest.lid"
SAFETY_LABEL="dev.lucabattistini.watchtest.safety"
PLIST="/Library/LaunchDaemons/$LABEL.plist"
SAFETY_PLIST="/Library/LaunchDaemons/$SAFETY_LABEL.plist"
BASE="/Library/Application Support/OvernightWatchTest"
ROOT_LOG="$BASE/fired.log"

fail() { echo "watchtest: $1" >&2; exit 1; }

[ "$(id -u)" = "0" ] || fail "run me with sudo"

REAL_USER="${SUDO_USER:-}"
[ -n "$REAL_USER" ] || fail "run as 'sudo sh $0'"
REAL_HOME=$(eval echo "~$REAL_USER")
USER_LOG="$REAL_HOME/Library/Application Support/OvernightWatchTest/touched.log"

echo "== what the unprivileged watcher did =="
cat "$USER_LOG" 2>/dev/null || echo "(no user log - the background process never ran)"
echo
echo "== what the root daemon did =="
cat "$ROOT_LOG" 2>/dev/null || echo "(no root log - the daemon NEVER RAN)"
echo
echo "== sentinel directory now =="
ls -la "$BASE/trigger" 2>/dev/null || echo "(gone)"
echo
echo "== did the machine sleep during the window =="
/usr/bin/pmset -g log | grep -iE "Entering Sleep|Wake from" | tail -10 || echo "(no entries)"
echo
echo "== launchd's own record =="
/usr/bin/log show --predicate "eventMessage CONTAINS \"watchtest\"" --last 40m --style compact 2>/dev/null | tail -30 || echo "(no log entries)"
echo

echo "== restoring =="
/usr/bin/pmset -a disablesleep 0
/bin/launchctl bootout "system/$LABEL" 2>/dev/null || true
/bin/launchctl bootout "system/$SAFETY_LABEL" 2>/dev/null || true
rm -f "$PLIST" "$SAFETY_PLIST"

FLAG=$(/usr/bin/pmset -g | awk '$1 == "SleepDisabled" { print $2; exit }')
echo "SleepDisabled is now: ${FLAG:-<not reported by this macOS>}"
/bin/launchctl print "system/$LABEL" >/dev/null 2>&1 && echo "WARNING: watch daemon still loaded" || echo "watch daemon unloaded"
/bin/launchctl print "system/$SAFETY_LABEL" >/dev/null 2>&1 && echo "WARNING: safety daemon still loaded" || echo "safety daemon unloaded"
echo
echo "Logs left for inspection:"
echo "  $ROOT_LOG"
echo "  $USER_LOG"
echo "Remove them with:"
echo "  sudo rm -rf '$BASE' '$REAL_HOME/Library/Application Support/OvernightWatchTest'"
