#!/bin/sh
#
# Payload harness.
#
# The privileged scripts are the highest-risk code in this repository and they run as root, so
# leaving them without automated coverage was not acceptable. They hardcode absolute paths to
# /usr/bin/pmset and /bin/launchctl on purpose — a root-run script must not take its binary
# paths from the environment — so this harness rewrites those paths into a throwaway copy and
# runs that, rather than the scripts consulting PATH.
#
# Runs on Linux and on macOS. It proves the scripts' control flow, validation, and argument
# construction. It proves nothing about how macOS actually responds to pmset; that is what
# docs/MANUAL-CHECKS.md is for.

set -eu

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd)
STUBS="$ROOT/tests/payload/stubs"
PASS=0
FAIL=0

setup() {
    WORK=$(mktemp -d)
    export OVERNIGHT_TEST_LOG="$WORK/calls.log"
    : > "$OVERNIGHT_TEST_LOG"
    mkdir -p "$WORK/daemons"
    export OVERNIGHT_STUB_CUSTOM="$WORK/custom.txt"
    export OVERNIGHT_STUB_LIVE="$WORK/live.txt"
    unset OVERNIGHT_STUB_STAT OVERNIGHT_STUB_UID OVERNIGHT_STUB_LAUNCHCTL_FAIL 2>/dev/null || true

    cat > "$OVERNIGHT_STUB_CUSTOM" <<'EOF'
Battery Power:
 lidwake              1
 hibernatemode        3
 hibernatefile        /var/vm/sleepimage
 powernap             0
 displaysleep         5
 sleep                1
 tcpkeepalive         1
 disksleep            10
AC Power:
 lidwake              1
 hibernatemode        3
 hibernatefile        /var/vm/sleepimage
 powernap             1
 displaysleep         10
 sleep                30
 tcpkeepalive         1
 disksleep            10
EOF

    cat > "$OVERNIGHT_STUB_LIVE" <<'EOF'
System-wide power settings:
 SleepDisabled		0
Currently in use:
 standby              1
 displaysleep         10
EOF

    # Rewrite the hardcoded absolute paths into the sandbox.
    for script in overnight-enable overnight-restore; do
        sed \
            -e "s#/usr/bin/pmset#$STUBS/pmset#g" \
            -e "s#/bin/launchctl#$STUBS/launchctl#g" \
            -e "s#/Library/Application Support/Overnight#$WORK/support#g" \
            -e "s#/Library/LaunchDaemons#$WORK/daemons#g" \
            "$ROOT/payload/$script.sh" > "$WORK/$script.sh"
        chmod +x "$WORK/$script.sh"
    done
    PATH="$STUBS:$PATH"
    export PATH
}

teardown() { rm -rf "$WORK"; }

ok()  { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; }

check() {
    if [ "$2" = "$3" ]; then ok "$1"; else
        bad "$1"
        printf '       expected: %s\n       actual:   %s\n' "$3" "$2"
    fi
}

assert_contains() {
    if printf '%s' "$2" | grep -q -- "$3"; then ok "$1"; else
        bad "$1"
        printf '       expected to contain: %s\n       in: %s\n' "$3" "$2"
    fi
}

assert_absent() {
    if printf '%s' "$2" | grep -q -- "$3"; then
        bad "$1"
        printf '       expected NOT to contain: %s\n       in: %s\n' "$3" "$2"
    else ok "$1"; fi
}

run_enable() { sh "$WORK/overnight-enable.sh" "$@"; }
run_restore() { sh "$WORK/overnight-restore.sh"; }

echo "payload harness"

# --- enable: argument validation ----------------------------------------------------------
echo "enable / argument validation"

setup
if run_enable 9 10 25 30 1788000000 >/dev/null 2>&1; then bad "rejects hour 25"; else ok "rejects hour 25"; fi
assert_absent "no pmset write after a rejected hour" "$(cat "$OVERNIGHT_TEST_LOG")" "pmset -c"
teardown

setup
if run_enable 9 10 "7; touch /tmp/pwned" 30 1788000000 >/dev/null 2>&1; then
    bad "rejects a shell metacharacter in hour"
else ok "rejects a shell metacharacter in hour"; fi
teardown

setup
if run_enable 9 10 7 60 1788000000 >/dev/null 2>&1; then bad "rejects minute 60"; else ok "rejects minute 60"; fi
teardown

setup
if run_enable 13 10 7 30 1788000000 >/dev/null 2>&1; then bad "rejects month 13"; else ok "rejects month 13"; fi
teardown

setup
if run_enable 9 10 7 30 >/dev/null 2>&1; then bad "rejects a missing epoch argument"; else ok "rejects a missing epoch argument"; fi
teardown

setup
export OVERNIGHT_STUB_UID=501
if run_enable 9 10 7 30 1788000000 >/dev/null 2>&1; then bad "refuses to run as non-root"; else ok "refuses to run as non-root"; fi
teardown

# --- enable: directory precondition -------------------------------------------------------
echo "enable / directory precondition"

setup
mkdir -p "$WORK/support"
export OVERNIGHT_STUB_STAT="501 20 777"
if run_enable 9 10 7 30 1788000000 >/dev/null 2>&1; then
    bad "aborts when the support directory is not root-owned"
else ok "aborts when the support directory is not root-owned"; fi
assert_absent "no pmset write after a failed directory check" "$(cat "$OVERNIGHT_TEST_LOG")" "pmset -c"
teardown

setup
mkdir -p "$WORK/elsewhere"
ln -s "$WORK/elsewhere" "$WORK/support"
if run_enable 9 10 7 30 1788000000 >/dev/null 2>&1; then
    bad "refuses a symlinked support directory"
else ok "refuses a symlinked support directory"; fi
teardown

# --- enable: the happy path ---------------------------------------------------------------
echo "enable / happy path"

setup
run_enable 9 10 7 30 1788000000 >/dev/null 2>&1 || bad "enable succeeded"
LOG=$(cat "$OVERNIGHT_TEST_LOG")
STATE=$(cat "$WORK/support/state.conf")

assert_contains "captures the AC sleep value"          "$STATE" "ac_sleep 30"
assert_contains "captures the AC displaysleep value"   "$STATE" "ac_displaysleep 10"
assert_contains "captures the battery profile too"     "$STATE" "battery_sleep 1"
assert_contains "records the prior SleepDisabled flag" "$STATE" "prior_sleep_disabled 0"
assert_contains "records the deadline"                 "$STATE" "deadline_epoch 1788000000"
assert_absent   "ignores unmanaged keys"               "$STATE" "hibernatemode"
assert_absent   "ignores non-numeric unmanaged keys"   "$STATE" "hibernatefile"

assert_contains "applies the AC timers with -c"        "$LOG" "pmset -c sleep 0 disksleep 0 displaysleep 2 powernap 0"
assert_contains "applies disablesleep globally"        "$LOG" "pmset -a disablesleep 1"
assert_absent   "never writes the battery profile"     "$LOG" "pmset -b"
assert_absent   "never writes tcpkeepalive"            "$LOG" "pmset -c sleep 0 disksleep 0 displaysleep 2 powernap 0 tcpkeepalive"
assert_contains "installs the restore payload root-owned" "$LOG" "install -o root -g wheel -m 0755"
assert_contains "loads the deadline job"               "$LOG" "launchctl bootstrap system"

check "writes the launchd plist" "$([ -f "$WORK/daemons/dev.lucabattistini.overnight.restore.plist" ] && echo yes || echo no)" "yes"
PLIST=$(cat "$WORK/daemons/dev.lucabattistini.overnight.restore.plist")
assert_contains "plist pins the month"  "$PLIST" "<integer>9</integer>"
assert_contains "plist pins the day"    "$PLIST" "<integer>10</integer>"
assert_contains "plist pins the hour"   "$PLIST" "<integer>7</integer>"
assert_contains "plist pins the minute" "$PLIST" "<integer>30</integer>"
assert_contains "plist does not run at load" "$PLIST" "<key>RunAtLoad</key>"
assert_contains "plist runs the installed copy, not the bundle copy" "$PLIST" "support/overnight-restore.sh"

# state must be written before the profile is applied
STATE_LINE=$(grep -n "install -o root" "$OVERNIGHT_TEST_LOG" | head -1 | cut -d: -f1)
APPLY_LINE=$(grep -n "pmset -c sleep 0" "$OVERNIGHT_TEST_LOG" | head -1 | cut -d: -f1)
if [ "$STATE_LINE" -lt "$APPLY_LINE" ]; then
    ok "arms the restore before touching the machine"
else
    bad "arms the restore before touching the machine"
fi
teardown

# --- enable: changing the deadline must not recapture --------------------------------------
echo "enable / deadline change"

setup
run_enable 9 10 7 30 1788000000 >/dev/null 2>&1
ORIGINAL=$(cat "$WORK/support/state.conf")

# Simulate the machine now reporting the overnight profile, which is what pmset would say
# once the first enable has been applied.
cat > "$OVERNIGHT_STUB_CUSTOM" <<'STUBEOF'
Battery Power:
 powernap             0
 displaysleep         5
 sleep                1
 disksleep            10
AC Power:
 powernap             0
 displaysleep         2
 sleep                0
 disksleep            0
STUBEOF
printf 'System-wide power settings:\n SleepDisabled\t\t1\n' > "$OVERNIGHT_STUB_LIVE"

: > "$OVERNIGHT_TEST_LOG"
run_enable 9 10 9 0 1788010000 >/dev/null 2>&1 || bad "second enable succeeded"
UPDATED=$(cat "$WORK/support/state.conf")

assert_contains "keeps the original AC sleep value"    "$UPDATED" "ac_sleep 30"
assert_contains "keeps the original AC powernap value" "$UPDATED" "ac_powernap 1"
assert_contains "keeps the original global flag"       "$UPDATED" "prior_sleep_disabled 0"
assert_absent   "does not recapture the applied profile" "$UPDATED" "ac_sleep 0"
assert_contains "moves the deadline"                   "$UPDATED" "deadline_epoch 1788010000"
assert_absent   "drops the old deadline"               "$UPDATED" "deadline_epoch 1788000000"

# The deadline line is the only thing allowed to change.
printf '%s\n' "$ORIGINAL" | grep -v '^deadline_epoch ' > "$WORK/before.txt"
printf '%s\n' "$UPDATED"  | grep -v '^deadline_epoch ' > "$WORK/after.txt"
if diff -q "$WORK/before.txt" "$WORK/after.txt" >/dev/null; then
    ok "changes nothing but the deadline"
else
    bad "changes nothing but the deadline"
    diff "$WORK/before.txt" "$WORK/after.txt" || true
fi

# The whole point: restore must still put the real settings back.
: > "$OVERNIGHT_TEST_LOG"
run_restore >/dev/null 2>&1 || bad "restore after a deadline change succeeded"
assert_contains "restores the pre-Overnight values after a deadline change" \
    "$(cat "$OVERNIGHT_TEST_LOG")" "pmset -c disksleep 10 displaysleep 10 powernap 1 sleep 30"
teardown

setup
mkdir -p "$WORK/support"
printf 'garbage\n' > "$WORK/support/state.conf"
if run_enable 9 10 7 30 1788000000 >/dev/null 2>&1; then
    bad "refuses to build on an unreadable existing capture"
else ok "refuses to build on an unreadable existing capture"; fi
teardown

# --- enable: an unusable capture must abort ------------------------------------------------
echo "enable / unusable capture"

setup
# A managed key with a value pmset should never emit. The capture must fail loudly rather than
# quietly omitting the key, because an omitted key is a key that never gets restored.
printf 'AC Power:\n sleep                banana\n powernap             1\n' > "$OVERNIGHT_STUB_CUSTOM"
if run_enable 9 10 7 30 1788000000 >/dev/null 2>&1; then
    bad "aborts on an unusable value rather than dropping the key"
else ok "aborts on an unusable value rather than dropping the key"; fi
assert_absent "no pmset write after an unusable capture" "$(cat "$OVERNIGHT_TEST_LOG")" "pmset -c sleep 0"
check "writes no state file after an unusable capture" \
    "$([ -f "$WORK/support/state.conf" ] && echo yes || echo no)" "no"
teardown

setup
printf 'AC Power:\n sleep                999999\n' > "$OVERNIGHT_STUB_CUSTOM"
if run_enable 9 10 7 30 1788000000 >/dev/null 2>&1; then
    bad "aborts on an overlong captured value"
else ok "aborts on an overlong captured value"; fi
teardown

# --- enable: a failure to arm must not leave the machine changed --------------------------
echo "enable / failure to arm"

setup
export OVERNIGHT_STUB_LAUNCHCTL_FAIL=1
if run_enable 9 10 7 30 1788000000 >/dev/null 2>&1; then
    bad "aborts when the deadline job cannot be loaded"
else ok "aborts when the deadline job cannot be loaded"; fi
assert_absent "leaves the machine untouched when arming fails" "$(cat "$OVERNIGHT_TEST_LOG")" "pmset -c sleep 0"
teardown

# --- restore ------------------------------------------------------------------------------
echo "restore"

setup
if run_restore >/dev/null 2>&1; then ok "exits 0 when there is nothing to restore"; else bad "exits 0 when there is nothing to restore"; fi
assert_absent "issues no pmset write when there is nothing to restore" "$(cat "$OVERNIGHT_TEST_LOG")" "pmset -c"
teardown

setup
run_enable 9 10 7 30 1788000000 >/dev/null 2>&1
: > "$OVERNIGHT_TEST_LOG"
run_restore >/dev/null 2>&1 || bad "restore succeeded"
LOG=$(cat "$OVERNIGHT_TEST_LOG")
assert_contains "replays the captured AC values" "$LOG" "pmset -c disksleep 10 displaysleep 10 powernap 1 sleep 30"
assert_contains "replays the prior global flag"  "$LOG" "pmset -a disablesleep 0"
assert_absent   "never replays the battery profile" "$LOG" "pmset -b"
assert_absent   "never replays tcpkeepalive"     "$LOG" "tcpkeepalive"
assert_contains "unloads the deadline job"       "$LOG" "launchctl bootout"
check "removes the plist" "$([ -f "$WORK/daemons/dev.lucabattistini.overnight.restore.plist" ] && echo yes || echo no)" "no"
check "removes the saved state" "$([ -f "$WORK/support/state.conf" ] && echo yes || echo no)" "no"
teardown

setup
mkdir -p "$WORK/support"
printf 'version 1\nac_sleep 0; touch /tmp/pwned\n' > "$WORK/support/state.conf"
if run_restore >/dev/null 2>&1; then bad "rejects an injected value in saved state"; else ok "rejects an injected value in saved state"; fi
assert_absent "issues no write after rejecting saved state" "$(cat "$OVERNIGHT_TEST_LOG")" "pmset -c"
teardown

setup
mkdir -p "$WORK/support"
printf 'version 1\nac_hibernatemode 3\n' > "$WORK/support/state.conf"
if run_restore >/dev/null 2>&1; then bad "rejects an unknown key in saved state"; else ok "rejects an unknown key in saved state"; fi
teardown

setup
mkdir -p "$WORK/support"
printf 'ac_sleep 30\n' > "$WORK/support/state.conf"
if run_restore >/dev/null 2>&1; then bad "rejects saved state with no version line"; else ok "rejects saved state with no version line"; fi
teardown

setup
mkdir -p "$WORK/support"
printf 'version 9\nac_sleep 30\n' > "$WORK/support/state.conf"
if run_restore >/dev/null 2>&1; then bad "rejects an unsupported state version"; else ok "rejects an unsupported state version"; fi
teardown

setup
mkdir -p "$WORK/support"
printf 'version 1\nac_sleep 123456\n' > "$WORK/support/state.conf"
if run_restore >/dev/null 2>&1; then bad "rejects an overlong value"; else ok "rejects an overlong value"; fi
teardown

setup
mkdir -p "$WORK/support"
# A capture from a machine that never reported SleepDisabled still clears the flag.
printf 'version 1\nac_sleep 30\n' > "$WORK/support/state.conf"
run_restore >/dev/null 2>&1 || bad "restores without a captured flag"
assert_contains "clears disablesleep when the flag was never captured" "$(cat "$OVERNIGHT_TEST_LOG")" "pmset -a disablesleep 0"
teardown

setup
mkdir -p "$WORK/support"
printf 'version 1\nac_sleep 30\nprior_sleep_disabled 1\n' > "$WORK/support/state.conf"
run_restore >/dev/null 2>&1 || bad "honours a prior flag of 1"
assert_contains "replays a prior SleepDisabled of 1 rather than assuming 0" \
    "$(cat "$OVERNIGHT_TEST_LOG")" "pmset -a disablesleep 1"
teardown

setup
mkdir -p "$WORK/support"
printf 'version 1\nac_sleep 30\n' > "$WORK/support/state.conf"
run_restore >/dev/null 2>&1
: > "$OVERNIGHT_TEST_LOG"
if run_restore >/dev/null 2>&1; then ok "restore is idempotent"; else bad "restore is idempotent"; fi
assert_absent "a second restore issues no write" "$(cat "$OVERNIGHT_TEST_LOG")" "pmset -c"
teardown

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
