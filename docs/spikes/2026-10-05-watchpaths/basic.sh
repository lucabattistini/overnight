#!/bin/sh

set -eu

LABEL="dev.lucabattistini.watchtest.basic"
BASE="$HOME/Library/Application Support/OvernightWatchTest"
TRIGGER_DIR="$BASE/trigger"
LOG="$BASE/fired.log"
RUNNER="$BASE/runner.sh"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

cleanup() {
    /bin/launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
    rm -f "$PLIST"
}

echo "== WatchPaths basic test =="
echo "No password needed. Nothing outside your home directory is touched."
echo "Takes about 3 minutes."
echo

cleanup
rm -rf "$BASE"
mkdir -p "$TRIGGER_DIR" "$HOME/Library/LaunchAgents"

cat > "$RUNNER" <<'RUNNER_EOF'
#!/bin/sh
BASE="$HOME/Library/Application Support/OvernightWatchTest"
COUNT=$(ls -1 "$BASE/trigger" 2>/dev/null | wc -l | tr -d ' ')
printf '%s fired, files-in-trigger=%s\n' "$(date '+%H:%M:%S')" "$COUNT" >> "$BASE/fired.log"
RUNNER_EOF
chmod 0755 "$RUNNER"

CAL_EPOCH=$(( $(date +%s) + 150 ))
CAL_MONTH=$(date -r "$CAL_EPOCH" +%m | sed 's/^0//')
CAL_DAY=$(date -r "$CAL_EPOCH" +%d | sed 's/^0//')
CAL_HOUR=$(date -r "$CAL_EPOCH" +%H | sed 's/^0*//')
CAL_MIN=$(date -r "$CAL_EPOCH" +%M | sed 's/^0*//')
: "${CAL_HOUR:=0}"
: "${CAL_MIN:=0}"

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
		<string>$RUNNER</string>
	</array>
	<key>RunAtLoad</key>
	<false/>
	<key>WatchPaths</key>
	<array>
		<string>$TRIGGER_DIR</string>
	</array>
	<key>StartCalendarInterval</key>
	<dict>
		<key>Month</key>
		<integer>$CAL_MONTH</integer>
		<key>Day</key>
		<integer>$CAL_DAY</integer>
		<key>Hour</key>
		<integer>$CAL_HOUR</integer>
		<key>Minute</key>
		<integer>$CAL_MIN</integer>
	</dict>
</dict>
</plist>
PLIST_EOF

/bin/launchctl bootstrap "gui/$(id -u)" "$PLIST"
echo "armed at $(date '+%H:%M:%S'); calendar trigger set for $(date -r "$CAL_EPOCH" '+%H:%M')"
echo

sleep 5
echo "[A] right after arming. Nobody has touched anything."
echo "    On Darwin 25.6 this already showed one line: a WatchPaths job fires once at load,"
echo "    even with RunAtLoad false. Expect a line here, with files-in-trigger=0."
cat "$LOG" 2>/dev/null || echo "    (empty - did NOT fire at load on this macOS)"
echo

echo "[B] creating a new file in the watched directory..."
TOUCHED_AT=$(date '+%H:%M:%S')
: > "$TRIGGER_DIR/stop"
sleep 8
echo "    created at $TOUCHED_AT"
cat "$LOG" 2>/dev/null || echo "    NOTHING FIRED"
echo

echo "[C] plain touch of the same existing file, mtime only..."
sleep 12
TOUCHED_AT=$(date '+%H:%M:%S')
touch "$TRIGGER_DIR/stop"
sleep 8
echo "    touched at $TOUCHED_AT"
cat "$LOG" 2>/dev/null || echo "    NOTHING FIRED"
echo

echo "[D] removing the file..."
sleep 12
TOUCHED_AT=$(date '+%H:%M:%S')
rm -f "$TRIGGER_DIR/stop"
sleep 8
echo "    removed at $TOUCHED_AT"
cat "$LOG" 2>/dev/null || echo "    NOTHING FIRED"
echo

WAIT=$(( CAL_EPOCH - $(date +%s) + 20 ))
if [ "$WAIT" -gt 0 ]; then
    echo "[E] waiting ${WAIT}s for the calendar trigger, to prove both keys coexist..."
    sleep "$WAIT"
fi
echo "    calendar time was $(date -r "$CAL_EPOCH" '+%H:%M')"
echo

echo "== full log =="
cat "$LOG" 2>/dev/null || echo "(never fired at all)"
echo

cleanup
rm -rf "$BASE"
echo "== cleaned up =="
