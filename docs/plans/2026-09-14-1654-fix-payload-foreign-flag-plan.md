---
title: Payload Refuses a Foreign SleepDisabled - Plan
type: fix
date: 2026-09-14
topic: payload-foreign-flag
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
product_contract_source: ce-plan-bootstrap
execution: code
---

# Payload Refuses a Foreign SleepDisabled - Plan

## Goal Capsule

- **Objective:** A Mac whose sleep was disabled by something other than Overnight can still be put back to sleep afterwards. Overnight never adopts a power setting it did not itself set.
- **Means:** The privileged enable refuses its fresh capture when the live `SleepDisabled` flag already reads `1` (KTD1).
- **Authority:** Requirements (R-IDs) win on behavior. KTDs win on mechanism within those requirements.
- **Execution profile:** The host is macOS. `sh tests/payload/run.sh` runs locally and on both CI jobs, and the harness stubs `pmset` entirely, so nothing here needs a real power-management call or root.
- **Stop conditions:** Stop and report if the refusal cannot be placed before the state write, or if refusing on `1` turns out to break the legitimate case where Overnight is already on (that path reuses an existing capture and must not reach the guard at all).
- **Tail ownership:** The caller owns commit, push, and any release tagging.

---

## Product Contract

### Summary

`payload/overnight-enable.sh` refuses to take a fresh capture when the machine's `SleepDisabled` flag is already set and Overnight holds no state file. That closes the path by which a *new* capture can adopt a foreign flag, at the privilege boundary where no mistake in the app can reach past it.

It does not retroactively help a machine whose `state.conf` already holds a foreign `prior_sleep_disabled 1`. That population needs its own change and is named under Scope Boundaries.

### Problem Frame

The restore replays whatever the capture recorded. With no `state.conf` on disk the enable script takes its fresh-capture branch and records the live flag value as Overnight's own baseline — `payload/overnight-enable.sh:140`. When that value is `1` because something else set it, `payload/overnight-restore.sh:99-100` replays `pmset -a disablesleep 1` on every restore afterwards, including the unattended `launchd` deadline job. The machine can then never be put back to sleep by the app.

The obvious justification for refusing is that Overnight writes its state file before it sets the flag, so "flag set, no state file" should never be a state Overnight produces. **That is not true**, and the plan does not rest on it. A machine whose capture already holds a foreign `prior_sleep_disabled 1` reaches exactly that state through an ordinary successful restore: `payload/overnight-restore.sh:99-100` replays the `1`, then `:115` deletes the state file unconditionally.

The guard is still correct, for a narrower reason. In that state `OvernightStatus.derive` returns `.externallyDisabled`, whose `canEnable` is false, so the menu offers no enable path and the payload is never reached. The guard's job is the remaining window: a menu built before something else set the flag, picked after.

The app already refuses this in `OvernightStatus.canEnable`, which is what keeps the menu from offering the affordance. That gate is presentation-layer: it depends on the app's own read of the flag being current, and the menu is a snapshot. The payload's read happens as root, at the moment of the write.

### Key Decisions

- **Fix it in the privileged payload, not only app-side.** (session-settled: user-directed — chosen over relying on the app-side `canEnable` gate alone: when the payload runs as root it reads the real flag, so it is the only place that can be sure.) Governs R1, R2.
- **The app-side `canEnable` gate stays exactly as it is.** (session-settled: user-approved — chosen over replacing it with this check: two independent layers, and the app-side gate is also what decides whether the menu offers the item at all.) Governs R5.
- **Refuse only on exactly `1`.** (session-settled: user-directed — chosen over refusing on any non-zero or unreadable value, which was issue #3: an unreported flag means this macOS never surfaces it, and refusing there would make Overnight permanently unusable on those machines.) Governs R3.

### Requirements

- R1. With no state file present and the live `SleepDisabled` flag reading `1`, the privileged enable refuses and exits non-zero with a message naming what was refused, why, and what the user can do next.
- R2. The refusal happens before any state file or temporary state file is written, and before any `pmset` write.
- R3. A flag the machine does not report is not a refusal. The capture proceeds as it does today and omits `prior_sleep_disabled`.
- R4. A live flag reading `0` with no state file captures and proceeds exactly as today.
- R5. The path where Overnight is already on is untouched: an existing state file reuses its capture and never reaches the new guard.

### Acceptance Examples

- AE1. **Covers R1, R2.** Given no `state.conf` and the stub reporting `SleepDisabled 1`, when the enable script runs, then it exits non-zero, no `state.conf` exists afterwards, and no `pmset -c` write appears in the log.
- AE2. **Covers R4.** Given no `state.conf` and the stub reporting `SleepDisabled 0`, when the enable script runs, then the state records `prior_sleep_disabled 0` and the run succeeds — unchanged from today.
- AE3. **Covers R5.** Given an existing `state.conf` and the stub reporting `SleepDisabled 1`, when the enable script runs, then it succeeds and keeps the original capture — unchanged from today, and already asserted by the harness.

### Scope Boundaries

- `payload/overnight-restore.sh` is untouched. It replays what the capture holds; the fix is to stop a bad capture existing.
- The Swift targets are untouched, including `OvernightStatus.canEnable` and `MenuPresentation`.
- No new state, no config key, no user-facing surface, no change to the state-file format.
- Not in scope: the orphaned-flag recovery path a user reaches by hand (`sudo pmset -a disablesleep 0`), which the README already documents.

#### Deferred to Follow-Up Work

- **Machines whose capture already holds a foreign `prior_sleep_disabled 1`.** This change stops new bad captures; it does nothing for existing ones. Those installs replay the bad value once more through the unmodified restore, then sit in `.externallyDisabled` with no enable path and no in-app way back — so they never even see this guard's message. Fixing it means deciding what `payload/overnight-restore.sh` should do when the value it is about to replay is `1`, which is a change to the unattended privileged path and belongs in its own review. Filed as a follow-up rather than folded in here.

### Sources / Research

- `payload/overnight-enable.sh:132-149` — the branch. `:140` is the capture line; `:155-163` is the state write, which is where the "before any write" requirement gets its answer.
- `payload/overnight-restore.sh:99-100` — the replay that makes a bad capture permanent.
- `tests/payload/run.sh:52-58` — the stub's live output, pinned to `SleepDisabled 0`, which is why this input has never been exercised.
- `tests/payload/run.sh:219` — an existing case already overrides that stub to report `1`, so the mechanism the new case needs is proven.
- `tests/payload/run.sh:136-146` — the shape of a negative case: run, expect non-zero, then assert no `pmset -c` write happened.
- `tests/payload/stubs/pmset` — `"-g ") cat "$OVERNIGHT_STUB_LIVE"` is one unconditional case with no notion of which branch called it, so overriding that file reaches the fresh-capture read as well as the reuse read. Verified, not inferred.
- GitHub issue #4 for the write-up, and issue #3 (closed) for why an unreported flag is not treated as a refusal.

---

## Planning Contract

### Key Technical Decisions

- KTD1. **Place the guard immediately after the capture line, inside the `else` branch only.** The state write starts at `payload/overnight-enable.sh:155`, so a guard at `:140` cannot leave a partial capture and needs no cleanup — the open question from intake, now settled by reading the script. Putting it in the `else` branch is also what keeps R5 true: the reuse branch never evaluates it. Governs R1, R2, R5.
- KTD2. **Use the script's existing `[ cond ] && fail "..."` guard shape.** The script runs under `set -eu` (`:19`), and a failing left side of `&&` does not trip errexit — `:81`, `:88` and `:133` already depend on that. Do not rewrite it as an `if`; matching the surrounding style is the point. Governs R1.
- KTD3. **Test the refusal before writing it.** The script currently adopts the flag, so a case asserting refusal fails until the guard exists. That failure is the evidence the case actually drives the dangerous input rather than passing for an unrelated reason. Governs R1.

### Risks & Dependencies

- **The refusal arrives after the administrator prompt, so it reads as the app failing rather than protecting.** It is reachable only through a stale menu — `canEnable` withholds the affordance otherwise — but a user who has just typed a password and then seen a non-zero exit has no context. The message is the only thing they get, which is why R1 requires it to name a next step and why U2 step 3 cites the advice-giving precedent rather than the silent ones. The README's Recovery section is not a substitute: it is written around uninstalling or undoing a session Overnight actually ran, and its documented sequence starts by reading a `state.conf` that R2 guarantees will not exist here.

---

## Implementation Units

### U1. A harness case that drives the dangerous input

- **Goal:** A test that fails today, for the right reason.
- **Requirements:** R1, R2. Covers AE1.
- **Dependencies:** none.
- **Files:**
  - `tests/payload/run.sh` (modify)
- **Approach:**
  1. Add a case under a heading in the file's existing style, alongside the other enable negative cases.
  2. `setup`, then overwrite `$OVERNIGHT_STUB_LIVE` so the live block reports `SleepDisabled 1` — the same `printf` shape as `tests/payload/run.sh:219`. Do **not** pre-create the support directory: `payload/overnight-enable.sh:93` creates it with `install -d` when absent, and `tests/payload/stubs/install` honours that form with `mkdir -p`.
  3. Run the enable script expecting failure, using the `if run_enable … then bad … else ok …` shape from `:142-144`.
  4. Assert no state file exists, using the `check "…" "$([ -f … ] && echo yes || echo no)" "no"` idiom at `:268-269` — `assert_absent` greps a string for a substring and cannot prove a file's absence.
  5. Assert the command log contains no `pmset -c`, which *is* `assert_absent`'s shape, mirroring `:145`.
  6. `teardown`.
- **Execution note:** Run the harness before touching the payload and confirm this case fails. It must fail because the script *adopts* the flag and succeeds — not because the case is malformed. Read the failure output to be sure which it is.
- **Patterns to follow:** `tests/payload/run.sh:136-146` for a negative case end to end; `:219` for the stub override; `:268-269` for asserting a state file was not written; `assert_absent` at `:93` for asserting a command was not logged.
- **Test scenarios:**
  - Covers AE1. No state file plus a live flag of `1`: the script exits non-zero.
  - No state file is left behind after the refusal.
  - No `pmset -c` appears in the command log after the refusal.
  - The case fails before U2 lands, and the failure is the script succeeding rather than a harness error.
- **Verification:** `sh tests/payload/run.sh` reports this case failing, and the existing 65 still pass.

### U2. Refuse the foreign flag

- **Goal:** The capture is never taken from a flag Overnight did not set.
- **Sequencing:** U1 and U2 land in one commit. U1's case is required to fail until U2 exists, and both CI jobs run `sh tests/payload/run.sh` on every push (`.github/workflows/ci.yml:35` and `:129`), so a push carrying U1 alone would go red on the plan's own primary gate. The red state stays local.
- **Requirements:** R1, R2, R3, R4, R5. Implements KTD1, KTD2.
- **Dependencies:** U1.
- **Files:**
  - `payload/overnight-enable.sh` (modify)
- **Approach:**
  1. In the `else` branch only, immediately after `PRIOR_SLEEP_DISABLED=$(capture_sleep_disabled || true)`, add one guard refusing when the value is exactly `1`.
  2. Compare against the literal `1` so an empty value — a machine that does not report the flag — still proceeds, per R3 and KTD3.
  3. Word the message the way the surrounding guards are worded: what was refused, why, and where to go next. `payload/overnight-enable.sh:134` is the precedent — `fail "existing saved state is unreadable; run overnight-restore.sh first"` gives the user a next step, and this refusal needs one more than that one does, because it arrives after the administrator prompt has already been answered.
- **Patterns to follow:** `payload/overnight-enable.sh:133` for the exact guard shape, and `:80-81` and `:88-91` for message tone.
- **Test scenarios:**
  - Covers AE1. U1's case now passes.
  - Covers AE2. The happy path still records `prior_sleep_disabled 0` and completes.
  - Covers AE3. The reuse-capture case still keeps the original capture with the live flag reading `1`.
  - A live block with no `SleepDisabled` line still captures and omits `prior_sleep_disabled`.
- **Verification:** `sh tests/payload/run.sh` passes in full, `shellcheck payload/overnight-enable.sh` is clean, and `sh -n payload/overnight-enable.sh` parses.

---

## Verification Contract

| Gate | Command | Applies to | Done signal |
|---|---|---|---|
| Payload harness | `sh tests/payload/run.sh` | U1, U2 | All cases pass. Baseline before this work is 65 passed, 0 failed; expect 65 plus the new assertions. |
| Shell lint | `shellcheck payload/overnight-enable.sh tests/payload/run.sh` | U1, U2 | No new findings. |
| Shell syntax | `sh -n payload/overnight-enable.sh tests/payload/run.sh` | U1, U2 | Parses. |
| Managed-key drift | `sh scripts/check-managed-keys.sh` | U2 | Still passes — the guard adds no managed key, and this check exists to catch exactly that kind of drift. |
| Swift suite | `swift test` | none | Unchanged by this work; must stay at 96 passing. |

The harness stubs `pmset`, `launchctl`, `install`, `stat`, `chown` and `id`, so every gate here runs without root and without touching real power settings.

---

## Definition of Done

- R1 through R5 hold, and AE1 is enforced by a case in `tests/payload/run.sh` that was observed failing before the guard existed.
- The guard sits in the `else` branch only, before the state write, and the reuse-capture path is provably untouched.
- An unreported flag still captures successfully — the case issue #3 was closed on.
- `sh tests/payload/run.sh`, `shellcheck`, `sh -n` and `sh scripts/check-managed-keys.sh` all pass; `swift test` still reports 96.
- The diff touches two files and no more.
- No debugging leftovers in the harness — no stray `set -x`, no commented-out cases, no temporary echo.
