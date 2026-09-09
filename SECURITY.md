# Security

Overnight changes system power settings, which needs root. This is what it does with that, and what it deliberately does not do.

## What runs as root, and for how long

Two shell scripts, each for the few seconds it takes to run, each behind its own administrator prompt:

- `payload/overnight-enable.sh` — captures settings, arms the deadline job, applies the profile.
- `payload/overnight-restore.sh` — replays the capture and tears the job down.

Privilege is obtained through AppleScript's `do shell script … with administrator privileges`. When the script exits, no elevated process remains.

## What is not installed

No privileged daemon. No XPC helper. No `SMJobBless` tool. No sudoers rule. No login item. No standing privilege of any kind.

The one persistent artifact is a `launchd` job that fires once at your chosen wake time and deletes itself. It is not a service — it holds no process between the moment it is armed and the moment it fires.

## Root-owned artifacts

| Path | Owner | Mode | Purpose |
|---|---|---|---|
| `/Library/Application Support/Overnight/` | `root:wheel` | `0755` | Container |
| `/Library/Application Support/Overnight/state.conf` | `root:wheel` | `0644` | The captured settings |
| `/Library/Application Support/Overnight/overnight-restore.sh` | `root:wheel` | `0755` | The copy `launchd` executes |
| `/Library/LaunchDaemons/dev.lucabattistini.overnight.restore.plist` | `root:wheel` | `0644` | The one-shot deadline job |

### Why the restore script is copied

`Overnight.app` lives in `/Applications`, which an admin user can write without authenticating. A `launchd` job pointed at a script inside the app bundle would therefore be a **user-writable executable that runs as root** — a local privilege escalation.

So `enable` installs the restore script to a root-owned directory with `install -o root -g wheel -m 0755`, and the job runs that copy. The copy inside the bundle is never executed by `launchd`.

### Why the directory is verified, not repaired

If `/Library/Application Support/Overnight` already exists, `enable` requires it to be a real directory (not a symlink), owned `0:0`, mode `0755`, and **aborts** otherwise. It does not chown or chmod it into shape.

A directory that already exists with the wrong ownership is a substitution attempt, not a mistake to fix. Repairing it would mean writing a root-executed script through a path an attacker chose. The check holds regardless of how the parent directory happens to be permissioned.

## Untrusted input

Two things are treated as hostile, and both are validated on both sides of the privilege boundary.

**Arguments.** The app validates every value through `SafeArgument` before it can reach a command: numbers must be a bare run of ASCII digits within a length bound, paths must be absolute and free of control characters. The shell script re-validates all five arguments itself. An injection would have to defeat both layers.

Values cross two independent escaping layers on the way out — `SafeArgument.appleScriptLiteral` for the AppleScript source string, then AppleScript's own `quoted form of` for the shell beneath it. Both are needed: the app bundle path is user-controlled, because anyone can rename the app.

**The saved state file.** `restore` parses it as untrusted input even though it sits in a root-owned directory. Every key must be one of a fixed set, every value must be digits only within a length bound, and the version must match. An unknown key, a malformed line, or an out-of-range value aborts the restore rather than reaching `pmset`. This is why the file is a digits-only line format rather than JSON: the privileged side has no quoting problem to get wrong.

There is no shell string built anywhere in the Swift code. `pmset` is invoked with an explicit absolute path and an argument array.

## Blast radius

Overnight writes four AC-profile timers and one global flag. It never writes the battery profile, and it never writes a setting it did not first record.

The exception is inherent to the tool, not to Overnight: `disablesleep` has no per-power-source form, so while Overnight is on the machine will not sleep on battery either. See the README for how this is mitigated and where the mitigation stops.

`pmset restoredefaults` is never used, anywhere. It resets power management as a group and would discard unrelated settings.

## Known residue

Toggling `powernap` causes macOS to add `SleepServices 1` to the AC profile, and `pmset` offers no way to remove a key. Everything Overnight recorded is restored exactly; that one implicit key cannot be removed by any tool.

## Threats this does not address

- An attacker who can already run commands as root.
- An attacker who can modify `/Applications/Overnight.app` **and** persuade you to approve an administrator prompt afterwards. That is the same trust you extend to any installer.
- Physical access to an unlocked machine.

## Reporting

Open an issue at https://github.com/lucabattistini/overnight/issues. If you would rather not report publicly, say so in a minimal issue and a private channel will be arranged.
