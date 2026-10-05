# Runbook — does a `WatchPaths` trigger fire with the lid closed on battery?

This answers one question, and a feature does not get built until it is answered: **can an
unprivileged watcher tell a root `launchd` job to stop an Overnight session, with no password,
while the Mac sits awake with the lid shut and nothing plugged in?**

If yes, Overnight can restore power settings the moment a build finishes instead of burning
battery until the wake hour. If no, that feature is not worth building and the wake hour stays
the only stop — which is what ships today.

Everything else about the design was settled in a `ce-pov` pass. This is the last open fact.

## State of play

**Decided.** Keep `pmset -a disablesleep 1` behind the administrator prompt. The unprivileged
IOKit clamshell call was graded **Hold**: its bit is reportedly lost when the power source
changes on Apple Silicon (FB9101664), and lid-closed-on-battery is exactly that transition.

**Decided.** If this test passes, the shape is **two separate LaunchDaemons**, not one job with
two triggers:

- the calendar job stays byte-for-byte what `payload/overnight-enable.sh` writes today
- a second job watches a sentinel directory and starts with `no file in the directory → exit 0`

**Not decided.** Whether the trigger fires at all with the lid closed. Apple documents the
sleep behaviour of `StartCalendarInterval` and says nothing about `WatchPaths`. No credible
source fills the gap in either direction.

## What is already known, and its expiry date

Run on **Darwin 25.6**, 2026-09-16, with `basic.sh`:

| Question | Answer |
|---|---|
| New file in the watched directory starts the job | yes, within 6s |
| Plain `touch`, mtime only, no content change | yes — Apple documents neither way |
| Removing the file | yes |
| `WatchPaths` and `StartCalendarInterval` in one job | yes, both fire |

And one finding that would have broken the naive design:

> **A `WatchPaths` job fires once the moment it is loaded.** With `RunAtLoad` false, an empty
> watched directory, and nobody touching anything. Reproduced twice, isolated the second time.
> Apple documents this nowhere.

`overnight-enable.sh` writes `state.conf` at step 3 and loads the daemon at step 5. A single
job carrying both triggers would therefore run the restore immediately on arming: replay the
capture, delete the state file, remove its own plist. **Turning Overnight on would switch it
straight back off.** The two-daemon split above exists to absorb that: at arming the sentinel
directory is empty, so the watch job exits without doing anything.

⚠️ **This machine has since moved to Darwin 27.0.** None of the table above has been re-checked
on it. Re-run `basic.sh` first — it needs no password, touches only your home directory, cleans
up after itself, and takes about three minutes.

## Before you start

**Run these from Terminal, not from inside Claude Code or any agent session.** The same warning
already sits on M6 in `docs/MANUAL-CHECKS.md`, for the same reason: a tool holding its own power
assertion silently invalidates the result.

1. **Overnight must be off.** `arm.sh` refuses if `/Library/Application Support/Overnight/state.conf`
   exists, and refuses if `SleepDisabled` is already `1`.
2. **Nothing else may hold a sleep assertion.** `arm.sh` warns; check it yourself with
   `pmset -g assertions` and expect no `PreventUserIdleSystemSleep` or `PreventSystemSleep` holder.
3. **Unplug the adapter and the docking station.** A USB-C dock often charges even with no
   adapter attached, and an external display plus power puts macOS into desktop mode, which
   keeps the Mac awake with the lid closed *on its own*. The test would go green for the wrong
   reason.
4. **Confirm you are on battery.** `pmset -g batt` must say `Battery Power`.
5. Leave Wi-Fi on. It is part of the scenario this feature targets.

## Steps

```sh
cd /Users/lucabattistini/Coding/Personal/overnight/docs/spikes/2026-10-05-watchpaths

sh basic.sh                 # no password, ~3 min, re-establishes the table above on Darwin 27

pmset -g batt               # must say Battery Power
pmset -g assertions         # must show no sleep holder

sudo sh arm.sh              # prints the three timestamps to expect
```

Then **unplug everything, close the lid, and leave it for 11 minutes.** Open the lid and run:

```sh
sudo sh read.sh
```

You have three minutes of slack after arming before the moment that matters. No need to rush
the lid shut.

## Reading the result

`read.sh` prints the root daemon's log. Expect three lines; the middle one is the whole test.

| Root log | Meaning | Consequence |
|---|---|---|
| line at arm time, line at **+3 min** with `files-in-trigger=1`, line at +9 min | the trigger fires with the lid closed | **the feature is unblocked** |
| arm-time and +9 min lines only | `WatchPaths` does not fire with the lid closed | **the sentinel design is dead** |
| a line timestamped when you reopened the lid | fires only on wake | **dead** — the deadline job already does that |
| `COULD NOT WRITE the sentinel` in the user log | mode `1733` on a root-owned directory does not let an unprivileged process create a file there | the directory shape needs rethinking before anything else |

⚠️ **A green result is narrower than it looks.** It says the trigger fired once, on this Mac,
on this macOS. An Apple DTS engineer's June 2025 forum thread has `WatchPaths` working on some
Macs and silently failing on others with no root cause identified by Apple, and Apple's own
`man launchd.plist` calls the key "highly discouraged… it is entirely possible for modifications
to be missed".

That is survivable here, and it is worth being precise about why: a missed trigger means the
session runs to the wake hour, which is today's behaviour. **A lost event costs battery, not
correctness.** The wake hour stays the backstop by design, not as a consolation.

## If something goes wrong

The risk is a Mac left unable to sleep. Three layers cover it:

1. `read.sh` clears the flag and unloads both daemons.
2. A safety LaunchDaemon clears the flag and removes both jobs **25 minutes after arming**,
   whether or not you come back.
3. By hand:

```sh
sudo pmset -a disablesleep 0
sudo launchctl bootout system/dev.lucabattistini.watchtest.lid
sudo launchctl bootout system/dev.lucabattistini.watchtest.safety
sudo rm -f /Library/LaunchDaemons/dev.lucabattistini.watchtest.*.plist
sudo rm -rf "/Library/Application Support/OvernightWatchTest"
pmset -g | grep SleepDisabled      # must read 0
```

Check that last line before you walk away, whichever route you took.

## While you have the hardware set up

**M6 in `docs/MANUAL-CHECKS.md` is still outstanding** and wants the identical physical setup:
unplugged, dock off, lid shut, on battery. It is a separate lid close, not a combined one —
M6 needs Overnight *on*, and this test refuses to run alongside a live session precisely so the
safety job cannot clear a flag Overnight believes it owns.

Same sitting, two lid closes, two answers.

## Resuming

Paste the output of `read.sh` back into the session. Next step after a pass is writing the plan
for the opt-in unplugged mode; that plan does not exist yet in any file.

Four conditions were attached to the design and none of them are satisfied by this test alone:

1. watch a **directory**, never a file — a watched file must exist when the job loads or the
   watch never arms, and a job that deletes its own watched file has the watch silently dropped
2. root must **never open the sentinel path** — not read it, not write it, not follow it. The
   trigger carries no information beyond "something changed"; the restore keeps reading only the
   root-owned `state.conf`. This is what takes symlink and TOCTOU attacks off the table
3. close **#6 and #8 first** — this feature makes the restore path run unattended far more
   often, and #6 is that a silently ignored restore reports success, which nobody is awake to read
4. **three shipped documents become wrong** and have to be rewritten rather than quietly
   contradicted: `README.md:200` and `docs/plans/2026-09-09-overnight-menu-bar-app.md:102-104`
   list "PID or process watchers" as out of scope, and `SECURITY.md:16` claims no standing
   privilege of any kind

On that last one there is a real loss to declare, not just wording to fix: **today, ending a
session early requires the administrator password. After this change, writing a file is enough.**
Anything running as you can stop Overnight without a prompt. That is not privilege escalation —
no arbitrary code runs and the replayed values stay the ones Overnight recorded — but the threat
model changes and `SECURITY.md` has to say so.

The `ce-pov` verdict behind all of this lives only in the session transcript. Nothing in the
repo records the `pmset`-versus-IOKit comparison either.
