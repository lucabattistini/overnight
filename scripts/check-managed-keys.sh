#!/bin/sh
#
# Guards the one contract shared by the Swift and shell layers: the set of pmset settings
# Overnight is allowed to touch.
#
# ManagedSetting in Sources/OvernightCore/PowerCapture.swift and MANAGED_KEYS in
# payload/overnight-enable.sh describe the same thing in two languages. Nothing at runtime
# forces them to agree, so this check does.

set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
EXPECTED="disksleep displaysleep powernap sleep tcpkeepalive"

swift_keys=$(sed -n '/^public enum ManagedSetting/,/^}/p' "$ROOT/Sources/OvernightCore/PowerCapture.swift" \
    | sed -n 's/^    case \([a-z]*\)$/\1/p' | sort | tr '\n' ' ' | sed 's/ $//')

shell_keys=$(sed -n 's/^MANAGED_KEYS="\(.*\)"$/\1/p' "$ROOT/payload/overnight-enable.sh" \
    | tr ' ' '\n' | sort | tr '\n' ' ' | sed 's/ $//')

status=0
if [ "$swift_keys" != "$EXPECTED" ]; then
    echo "ManagedSetting drifted: expected '$EXPECTED', found '$swift_keys'" >&2
    status=1
fi
if [ "$shell_keys" != "$EXPECTED" ]; then
    echo "MANAGED_KEYS drifted: expected '$EXPECTED', found '$shell_keys'" >&2
    status=1
fi

# The restore script must know every key the enable script can write into the state file,
# otherwise a valid capture would be rejected as an unknown key at restore time.
for key in $EXPECTED; do
    for profile in ac battery; do
        if ! grep -q "${profile}_${key}" "$ROOT/payload/overnight-restore.sh"; then
            echo "overnight-restore.sh does not handle the state key '${profile}_${key}'" >&2
            status=1
        fi
    done
done

[ "$status" -eq 0 ] && echo "managed keys agree across Swift and shell: $EXPECTED"
exit "$status"
