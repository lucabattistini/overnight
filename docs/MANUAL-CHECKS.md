# Manual checks

Things no CI runner and no Linux host can answer. Run these on the actual MacBook.

The 2026-09-09 spike on macOS 26.6 (Mac16,7, M4 Pro) already cleared M1–M5. **M6, M7, M8 and M9 are the ones still outstanding before a release.**

Throughout: `pmset -g custom` shows the per-profile timers, `pmset -g | grep SleepDisabled` shows the global flag. Capture both before you start.

```sh
pmset -g custom > /tmp/before-custom.txt
pmset -g | grep SleepDisabled > /tmp/before-flag.txt
```

---

## M6. Closed-lid run without the caffeinate confound — **outstanding**

The 89-second lid test in the spike ran while an unrelated process held `caffeinate -i -t 300`. `caffeinate -i` prevents idle sleep and should *not* prevent clamshell sleep, so that result is provisionally positive rather than settled. This re-test removes the confound and extends the duration.

Run it from Terminal directly, **not** from inside Claude Code, an agent session, or any tool that might hold its own power assertion.

```sh
# 1. Nothing else may be holding an assertion. This must list no PreventUserIdleSystemSleep
#    or PreventSystemSleep holder other than your own shell.
pmset -g assertions

# 2. Turn Overnight on from the menu bar, deadline ~30 minutes out.

# 3. Confirm the flag and the AC profile.
pmset -g | grep SleepDisabled          # expect: SleepDisabled  1
pmset -g custom                        # expect AC: sleep 0, disksleep 0, displaysleep 2, powernap 0

# 4. Start a heartbeat, then close the lid with the external display,
#    keyboard and mouse all powered OFF.
while true; do echo "$(date +%H:%M:%S)" >> /tmp/overnight-heartbeat.log; sleep 2; done
```

Leave it closed for **at least 20 minutes**. Then open the lid and check:

```sh
# Gaps should all be ~2s. A multi-minute gap means the machine slept.
awk 'NR>1 { print }' /tmp/overnight-heartbeat.log | tail -20

# Zero sleep events during the window.
pmset -g log | grep -i "Entering Sleep" | tail -20
```

**Pass:** continuous heartbeat, no sleep events, no assertion held by anything but Overnight's `pmset` settings.

## M7. Actual AC loss while active — **outstanding**

Never tested. This is the path the whole AC-watcher design exists for.

1. Turn Overnight on. Confirm `SleepDisabled 1`.
2. Physically unplug the MagSafe/USB-C power.

**Expect, within a few seconds:** a notification saying power was unplugged, and the administrator prompt appearing to restore.

Then check both branches:

- **Approve the prompt.** Confirm `pmset -g | grep SleepDisabled` reports `0` and `pmset -g custom` matches `/tmp/before-custom.txt` for the AC timers. The menu bar should show Off.
- **Repeat, and dismiss the prompt instead.** Confirm the menu bar shows the "Running on battery" warning and that `SleepDisabled` is still `1` — this is the documented limitation, not a bug. Confirm the deadline job is still armed:
  ```sh
  sudo launchctl print system/dev.lucabattistini.overnight.restore | head -5
  ```

**Pass:** the notification and prompt appear promptly on unplug, approving restores exactly, and dismissing leaves an honest warning plus an intact backstop.

## M8. The icon renders — **outstanding**

No CI runner and no Linux host can say how a menu bar glyph or a Dock icon actually looks. Both .icns files are checked structurally on CI and the band's geometry is unit-tested, but neither of those is a pair of eyes.

**App icon.** With the app in `/Applications`:

```sh
# Finder should show the artwork at every step size, not a generic blank document.
open -R /Applications/Overnight.app
```

Step the Finder icon size slider from 16pt to 512pt and confirm the band stays legible and the rounded rectangle sits at the same size as its neighbours rather than larger or smaller. Check Get Info and Spotlight too, since they read different representations out of the same .icns.

**Menu bar glyph.** With Overnight off, then on:

1. Confirm the on glyph is one continuous S — low and nearly flat on the left, sweeping up through the middle, flat again on the right — and that the off glyph is the same S with the middle removed. They must be tellable apart in peripheral vision, without looking straight at them. If the on state reads as a plain diagonal slash rather than as a curve with a visible reversal in it, the geometry is wrong, not the rendering: `MenuBarBand.armAngleDegrees` and `armReach` in `Sources/OvernightCore/MenuBarBand.swift` are the two numbers that control it.
2. Switch **System Settings → Appearance** between Light and Dark. The glyph must invert with the menu bar rather than staying one colour or disappearing.
3. Click the item. The glyph must invert again against the highlighted background.
4. On a Retina display, look closely for a soft or doubled edge. The band is stroked on demand, so it should be as sharp as the system's own menu bar glyphs.
5. With VoiceOver on, focus the item and confirm it is announced as "Overnight is on" or "Overnight is off" rather than as an unlabelled image.

**Pass:** artwork at every size, the two states distinguishable at a glance, correct inversion in light, dark and highlighted menu bars, no softness at 2x, and a spoken label that names the state.

## M9. The installer window renders — **outstanding**

CI mounts the finished DMG and proves Finder wrote a layout into it. It cannot prove the layout is a *good* one: no runner has a screen. Build one and look at it.

```sh
sh scripts/make-dmg.sh
open dist/Overnight.dmg
```

**The window.**

1. It opens by itself at roughly 600×400 points, with **no toolbar and no status bar and no sidebar**. If any of those are showing, the AppleScript did not fully apply.
2. Overnight sits on the left, an arrow points right from the middle of the window, and the `Applications` alias sits on the right. The arrow's shaft must line up with the horizontal centres of both icons rather than running above or below them. Each icon should sit inside the soft circular plate painted behind it — if either is noticeably high or low on its plate, Finder is anchoring `position` somewhere other than the icon's centre, and `DMG_APP_Y` / `DMG_APPLICATIONS_Y` in `resources/branding/dmg-layout.env` need adjusting by that offset. Re-run `python3 scripts/icons.py build` afterwards so the artwork follows.
3. Resize nothing and drag nothing. Eject, mount again, and confirm the window comes back the same. A layout that only survives the first mount means the `.DS_Store` was not flushed before the image was detached.

**The labels — do this in both appearances.** Switch **System Settings → Appearance** between Light and Dark with the DMG mounted.

Finder takes the icon labels' colour from the system appearance, not from the background behind them, so "Overnight" and "Applications" are drawn in dark text in Light Mode over a deliberately dark background. The plates behind the icons are the local contrast that hedges this.

**If the labels are unreadable in Light Mode**, that is the thing to fix, and the knob is in `render_dmg_background` in `scripts/icons.py`: raise the well plate's amplitude, currently `0.13`, and its rim, currently `0.06`. Rebuild with `python3 scripts/icons.py build` and repackage.

**The volume icon.**

4. The mounted volume must show the Overnight platter — a dark disc with the band of light across it and a spindle in the middle — in the Finder sidebar, on the desktop if you show mounted disks there, and in the DMG window's own title bar. A generic white external-disk icon means the `kHasCustomIcon` flag did not take.
5. Check it at the sidebar's small size specifically. That is 16pt, and it is the size the icon is seen at most.

**Retina.** On a Retina display, look closely at the background's star field and at the edge of the arrow. Both should be crisp. Softness means `tiffutil` did not pair the 1x and 2x backgrounds and the packaging step fell back to the 1x PNG — it prints a warning when it does, so check the build output.

**The install itself.**

6. Drag Overnight to Applications from inside the window and confirm it lands in `/Applications`.

**Pass:** a toolbar-free window at the designed size, both icons seated on their plates with the arrow between them, labels readable in both Light and Dark, the branded volume icon in the sidebar at 16pt, a crisp background at 2x, and a drag that installs.

---

## Already cleared on 2026-09-09 — re-run only after changing the payload

### M1. Baseline capture round-trips

```sh
pmset -g custom; pmset -g | grep SleepDisabled
# Turn Overnight on, then off.
diff <(pmset -g custom) /tmp/before-custom.txt
```

**Pass:** the battery profile is byte-identical and the AC timers match. One expected difference: `SleepServices 1` may appear in the AC profile, added by macOS when `powernap` is toggled. `pmset` cannot remove a key, so this cannot be undone by any tool.

### M2. `pmset -c disablesleep 1` is not profile-scoped

```sh
sudo pmset -c disablesleep 1; echo "exit=$?"
pmset -g | grep SleepDisabled     # confirmed: 1, i.e. global despite -c
sudo pmset -a disablesleep 0
```

**Result:** exits 0, no warning, sets the global flag. This is why Overnight applies `disablesleep` with `-a` and why the AC watcher exists.

### M3. Timer settings do scope with `-c`

```sh
sudo pmset -c displaysleep 2
pmset -g custom     # AC displaysleep 2, battery displaysleep unchanged
```

**Result:** `sleep`, `disksleep`, `displaysleep`, `powernap` all scope correctly. `tcpkeepalive` is still unverified — the machine's baseline was already 1 on both profiles, so a scoped write looked identical to a global one. Overnight does not write it.

### M4. The one-shot deadline job fires as root

```sh
# Turn Overnight on with a deadline ~2 minutes out, then:
sudo launchctl print system/dev.lucabattistini.overnight.restore | head -20
# Wait past the deadline.
pmset -g | grep SleepDisabled        # expect 0
ls /Library/LaunchDaemons/dev.lucabattistini.overnight.restore.plist   # expect: no such file
```

**Result:** fired as uid 0, exit 0, replayed the captured value, booted itself out and removed its plist.

### M5. Unsigned DMG and the admin prompt

Download the release DMG on a Mac that has never seen the app, drag to `/Applications`, and confirm the Gatekeeper block, then the right-click → Open path. Confirm the menu bar item appears with no Dock icon, and that one administrator prompt appears on Turn On.
