# Half Lid: findings

What was learned about macOS while building this, and how each thing was found. The choices that follow from them are in
[DECISIONS.md](DECISIONS.md).

All of it was observed on one Mac: macOS 26.5.2, Apple Silicon, Command Line Tools only. Nothing here is claimed for other
versions. Tags: **[OK]** observed here, **[NOT VERIFIED]** read from documentation or inferred, **[OPEN]** a question left on
purpose.

## 1. Closing the lid

The system power log (`pmset -g log`) is the ground truth, not a heartbeat from the test program: after a lid close macOS
opens a "DarkWake" window of up to 180 seconds in which processes keep running, so a short heartbeat cannot tell "slept"
from "kept awake". The first version of the test used the heartbeat and misread its own control run.

| Run, lid closed | What the log showed | Reading |
| --- | --- | --- |
| Nothing changed (22 s) | `Entering Sleep state due to 'Clamshell Sleep'` | Slept, as expected |
| IOKit `kPMSetClamshellSleepState` (selector 12), no privileges, on power (28 s and 30 s) | No power event at all, not even display off | **Lid ignored** [OK] |
| Same, on battery (15 s, one run by the user) | The user heard the test tool's beeps with the lid closed; no power event | **Lid ignored** [OK] |
| `caffeinate -s` (42 s) | `Entering DarkWake state due to 'Clamshell Sleep'`, display off | Partly awake only |
| `pmset disablesleep` | Not run | [NOT VERIFIED] |

- Every control run after an override slept normally, including one after a run stopped with Ctrl+C: the override does not
  stay behind.
- Releasing the override with the lid closed: the Mac slept by itself 7 seconds later (clamshell sleep, not the idle timer)
  and stayed asleep for 134 seconds until the lid was opened. [OK]
- Lock and display: with the override on and the lid closed for 52 seconds, the session was locked (read from the session
  dictionary) and the display was asleep at the first sample, 0.1 s after the close. The brightness-to-zero call was accepted
  and the original value came back, but its effect cannot be read while the display sleeps. [OK] / [NOT VERIFIED] for the
  brightness itself.
- `sysadminctl -screenLock status` reported the screen lock as **off** on this Mac, so putting the display to sleep alone
  would leave an unlocked session awake in a closed Mac. Hence the explicit lock.
- `AppleClamshellCausesSleep` in `ioreg -rn IOPMrootDomain` reads `No` while the override is applied, but it also read `No`
  after a control run that slept, so it cannot tell whether the override is on. It is not used. `pmset -g` `SleepDisabled`
  stays `0` with this route.
- The lock and the brightness use private functions (`SACLockScreenImmediate` in login.framework, `DisplayServices`), looked up with
  `dlsym` so a missing one degrades instead of crashing. The resident app discards the log lines of a missing function, so
  Settings, Diagnostics shows whether both exist. Both exist on this Mac. [OK]
- [OPEN] Hours with the lid closed (one closure of 29 minutes on 2026-10-19 kept the Mac awake); that the override resets at boot
  (the kernel mask is global per the xnu sources). Whether macOS clears it by itself was answered the hard way, see 1b: it does.

### 1b. A hold that failed in the user's own run, and why (2026-10-19)

The user ran `scripts/lid-check.sh` with Half Lid armed (a timed hold, on power, an external monitor connected) and closed the lid
three times in 90 seconds (6 s, 2 s and 54 s). The report said the Mac went to sleep with the lid closed while Half Lid said it was
holding. The same morning, single closures had worked, among them one of 29 minutes (03:25:02 to 03:54:17, `disabled 0/2` at the
close and no `Clamshell Sleep` until the lid was opened and closed again at 03:55).

**How it was explained.** The unified log is readable without sudo: `/usr/bin/log show --start "YYYY-MM-DD HH:MM:SS" --end ...
--info --debug --style compact --predicate '...'` (in zsh `log` is a builtin, so the full path matters; the first attempts printed
nothing because of that). It holds the kernel's own power-management lines (`PMRD: ...`) and powerd's, with millisecond times, back to
about 02:28 that day. The kernel line is logged by the thread that makes the call, and powerd's own lines carry the same thread
ids, which tells the two writers apart. [OK]

| Time (17:50) | Who | Log line | Reading |
| --- | --- | --- | --- |
| 47.090 | kernel | `(RTBuddy) ... Time Elapsed between Hotplugs` | The display controller sees a link event |
| 47.172 | WindowServer | `Display 3 hot plug 0`, `Inserting hotplug event for state "out"` | The external monitor went away |
| 47.199 | powerd | `DesktopMode set 0 with battery 0`, `EvaluateClamshellSleepState on DesktopMode update` | powerd re-evaluates |
| 47.535 | powerd, kernel | `EvaluateClamshell. Disable :  0 because {DesktopMode with AC: 0, assertions 0`; `setClamShellSleepDisable(2->0)` | **powerd clears the flag** (same thread id on both lines) |
| 48.222 | kernel | `Clamshell closed`; `clamshell closed 1, disabled 0/0, desktopMode 0, ac 1`; `sleep reason Clamshell Sleep` | The lid closes 0.687 s later, the flag is 0, the Mac sleeps |
| 48.233 | powerd | `setClamShellSleepDisable(0->2)` | powerd sets it as the Mac goes to sleep |

- The same pair came back twice. The lid opened at 17:50:53.313 and powerd cleared the flag at 53.398 (85 ms later); again at 57.424
  and 57.465 (41 ms) and at 17:52:02.598 and 02.646 (48 ms). Every closure therefore found the flag off. Half Lid's own write
  (a different thread, 2405) came at 17:52:10.765, 8 s after the last closure: its re-application was once a minute. [OK]
- Before this, the flag read 2 since 12:23:42, and that write came from a powerd thread (`EvaluateClamshell. Disable : 1 because
  {... assertions 1`), not from Half Lid: Half Lid's once-a-minute writes between 17:40 and 17:50 are all `(2->2)`, no change. So until
  17:50:47 the Mac would have survived a closure thanks to powerd's flag, not Half Lid's. That is why single closures had worked: powerd
  had no reason to write. [OK] for the log lines. [NOT VERIFIED] why powerd's answer was 1 at 12:23:42 beyond what its line says
  (an assertion).
- The two writers share one bit: the public xnu source routes selector 12 to `setClamShellSleepDisable(..., kClamshellSleepDisablePowerd)`,
  the bit powerd uses, and the logged values (0 and 2) match. powerd writes only when its own answer changes between zero and not zero,
  and recomputes on user activity, some assertions, a monitor coming or going (desktop mode), a power-source change, and after a wake.
  Read from source, consistent with the log. [NOT VERIFIED] beyond that.
- In the kernel, clearing the last bit while the lid is closed puts the Mac to sleep inside the same call; setting a bit never does. So
  a clear before the close can be undone in time, a clear after it cannot.
- `AppleClamshellCausesSleep` in the registry stays stale (it did before), which is why the log is the only witness. [OK]
- This section corrects an earlier claim in these notes and in DECISIONS that the override was re-applied "after every wake": only a
  60-second timer existed; a wake only triggered a loop iteration. Fixed in the code and the text.

**What changed.** `OverrideKeeper` applies the override four times a second while armed, and again at once and over the next 1.6
seconds on every power-registry message, wake, screen wake or sleep and display change (DECISIONS 1, last subsection). It is checked
by tests and by a real process against the file stand-in. [NOT VERIFIED] with the lid closed after the change. If powerd also clears
the flag after the lid has closed, the keeper cannot help; `scripts/lid-check.sh` reports that case by name.

**First closure with the keeper (2026-10-20, 14:48).** Same Mac, same monitor (VG270U P, connected and online), on power, Half Lid
armed by a timed hold, new build. Three closures in 28 seconds (3.3, 1.7 and 0.7 s by the kernel's clock); the second and third came
2.0 and 1.2 s after the lid was opened. The Mac stayed awake and the network answered 2 of 2 probes. [OK] for these facts:

- The keeper was running: 253 override calls in 30 seconds, about 4 a second with bursts of 19 to 26 a second around lid and display
  events, and every one of them `(2->2)`, so the flag was ON at all three closures (`disabled 0/2`). Nothing cleared it. [OK]
- The failed run's trigger did not happen: no powerd clear and no display going away before the close (WindowServer logged only the
  display coming back 150 to 185 ms after each open). So the part of the keeper that puts the flag back **was not exercised**. [OK]
- powerd's own line `ClamshellState. Closed : 1. ClamshellSleepState: isSleepDisabled : N` read 16 at all six lid events here; in the
  failed run it read 0 at the closure and 256 at the opens. powerd also logged `DesktopMode set 1` 48 to 64 ms after each close (the
  monitor stays, the Mac is on power); in the failed run it had logged `DesktopMode set 0` just before the clear, and its
  `EvaluateClamshell` line named `DesktopMode with AC: 0` as the reason. [OK] for the values. What the number 16 means is not
  documented; it fits powerd holding the flag itself because of the monitor on power, which would explain why nothing was cleared
  here. [NOT VERIFIED] that reading, and [NOT VERIFIED] whether the Mac would have stayed awake without Half Lid in this state:
  the control run (Half Lid not holding, same closures) was not done.
- Conclusion of that run: the new build is active and showed no regression; **it did not show that the failure of 2026-10-19 is
  fixed**. The next run was set up to show it.

**Second run (2026-10-20, 14:57 to 15:02): the trigger reproduced, and the hold held.** The monitor was disconnected with Half Lid
armed (by the Cursor chat that was working) and the lid open, and `scripts/lid-check.sh` was started about 35 seconds later. The
log holds the same sequence as 17:50:47 on 2026-10-19 [OK]:

| Time (14:57) | Who | Log line | Reading |
| --- | --- | --- | --- |
| 42.776 | WindowServer | `Inserting hotplug event for state "out", display id: 3` | The monitor went away (`system_profiler` lists only the built-in display afterwards) |
| 42.803 | powerd | `DesktopMode set 0 with battery 0`, `EvaluateClamshellSleepState on DesktopMode update` | powerd re-evaluates |
| 42.896118 | powerd, kernel | `EvaluateClamshell. Disable :  0 because {DesktopMode with AC: 0, assertions 0`; `setClamShellSleepDisable(2->0)` | **powerd clears the flag** (thread 17a8f5 on both lines) |
| 42.896410 | kernel | `setClamShellSleepDisable(0->2)` | **Put back 292 microseconds later**, by the thread that makes the keeper's regular `(2->2)` calls (17aa61) |

With the old build the flag would have stayed 0 until its next once-a-minute write (on 2026-10-19 that came 83 seconds after the
clear). The check that followed (14:58:18 to 15:02:10) closed the
lid four times: 0.9, 0.7 and 0.7 s, then 3 min 34 s. For all four [OK]:

- The kernel's closure line read `disabled 0/2, desktopMode 0, ac 1`, and powerd's own line `isSleepDisabled : 0` with desktop mode
  off: powerd was holding nothing itself, so the override bit was the only thing standing between the Mac and sleep (in xnu, the lid
  puts the Mac to sleep unless `clamshellDisabled`, desktop mode on power, or the mask is set; read from source).
- No change of the override during the check, no powerd write, no `Entering Sleep`, no DarkWake, no `sleep reason Clamshell Sleep`.
  890 keeper calls during the long closure, about 4 a second, all `(2->2)`. The network answered 42 of 42 probes, 5 seconds apart.
- The report of that run, as pasted, did not list the clear and the put-back, because the script then read only from 2 seconds
  before its first heartbeat. It now reads 2.5 minutes before and marks where the check starts (DECISIONS 10, "Seeing a
  closed-lid run from the outside", last paragraph).

**What this shows, and what it does not.** The keeper put the flag back within a millisecond of powerd clearing it, in the exact
situation that failed on 2026-10-19, and the closures that followed passed with nothing else holding the Mac. [NOT VERIFIED]:
the control in this setup (the same closures with Half Lid not holding; the only idle closure on record is 2026-10-19 02:40,
`disabled 0/0` then a lid sleep); a clear that arrives **after** the lid has closed, which nothing can undo and which neither run
has shown (powerd cleared 0.1 to 0.4 s after the display event both times, so a monitor that drops within about 0.4 s of the
close would be the dangerous case); closures of hours; battery power; a Mac that has slept and woken during the hold.

## 2. Knowing that an agent is working

- **Cursor has no process to watch.** Over 7 minutes (5 s samples) the CPU of its process tree was 17 to 120 % whether an agent
  was working or a chat sat waiting on a question; session-file times were stale; one or two sleep assertions were held in
  both states. A process-based detector would keep the Mac awake all day for chats that wait for the user.
- **Cursor's own chat state can tell them apart.** It lives in `~/Library/Application Support/Cursor/User/globalStorage/state.vscdb`
  (SQLite, 23 GB on this Mac). It is opened read-only, by exact key, and only status fields are selected (status, tool name and
  status, timestamps), so message text and chat names never enter Half Lid. A full read takes about 0.4 s. On this Mac the
  running chat was "working", four chats with an open question were "waiting", two finished chats were "idle", and a chat
  changed to "waiting" two minutes after it posted a question. [OK]
- [NOT VERIFIED] It is an internal format and can change in any Cursor version. When it does, the reader returns an error,
  the app says so, and the manual keep-awake still works.
- **Command-line agents** are recognised by process names and install paths, and counted as working when the process tree is
  busy (15 % of one core or more) or a session file was written in the last 30 seconds. This was calibrated with a simulated
  agent, not with the real ones. [NOT VERIFIED] with real Claude Code, Codex, opencode, GitHub Copilot CLI and Goose:
  none of them was installed on this Mac, and installing software to test was not asked for. The two last ones were added on
  2026-10-20 from their public documentation only. On the same day the matching rules were checked against how each agent is
  installed (package manifests, Homebrew definitions, public bug reports) and one real mismatch was found and fixed: the native
  installer of Claude Code runs a file named after its version, so macOS calls the process `2.1.168` and not `claude`, and a
  match by name alone would never have seen it (a program started through a symlink is reported under the name of the real
  file; checked on this Mac with a small test program). Gemini CLI was taken out of the catalog because its usual installs
  (npm, Homebrew) are Node.js scripts, which macOS reports as `node`. All in `docs/AGENTS.md`.
- Cost: with the Cursor reader on, the resident app grows from 13 MB to between 16 and 20 MB (each read pulls whole chat records of
  0.1 to 3.5 MB through SQLite and macOS keeps the freed pages resident). Not fixable with a smaller query: any function over
  a stored value loads all of it.

## 3. Things macOS does that cost days

- **A menu bar icon can be hidden for a bundle id.** Twice the icon was created and immediately hidden: the system log
  (`/usr/bin/log show`, process `ControlCenter`, category `appStatusItems`) said "Moving host to blocked list". It happened
  when the bundled app was started from a terminal inside Cursor, which makes Cursor the "responsible" app; the block is
  kept per bundle id across launches and restarts of Control Center, is in no readable preference file, and was not cleared
  by the toggles in System Settings, Menu Bar. Rule for development: start the bundled app only with `open` or Finder; run the
  bare `build/bin` executables for anything else. A user starting the app from Finder is not affected. [OK]
- **A background app cannot bring a window to the front.** Since macOS 14 activation is cooperative: a program started by a
  background app that is not frontmost is not allowed to take the front from the app in use. With a real click on the panel's
  gear (CGEvent, Accessibility granted to the terminal), a Settings process started directly by the menu bar app opened
  behind Cursor. Things that did not help: activating the menu bar app first; handing the process over by re-launching the
  same bundle (an `LSUIElement` bundle is not activated by LaunchServices either). What worked: Settings as a small regular
  application of its own, nested in the main app and started with `NSWorkspace.openApplication`, as any app the user opens is.
  Clicking the gear again with Settings behind another window brings it back. [OK]
- **Two identities, so the system-level things move to the menu bar app.** The login item (`SMAppService.mainApp`) and the
  notification permission belong to the app that asks. Settings, being another app, asks the menu bar app to change them
  through a distributed notification and reads the answer from the status file.
- **`open` forwards the shell's environment** to the app it launches, and the shell of a tool session keeps its variables
  between commands. A test variable (`HALFLID_FAKE_OVERRIDE`, a preferences file) left set once made the "real" app run as a
  test. Use an inline assignment (`VAR=x open ...`) or unset it afterwards.
- **A menu bar app can show the notification permission prompt.** A throwaway accessory (`LSUIElement`) app, never
  activated, asked `UNUserNotificationCenter` for permission and the system showed "Notifications from ..." under the other
  banners; it went away when the process ended. [OK] The same program placed in `/tmp` got an immediate `UNErrorDomain` 1
  ("Notifications are not allowed for this application") and no prompt, twice. Placed in a project folder it prompted. The
  location was the only difference; why is [OPEN].
- **`SMAppService.mainApp.status` says "not found" for an app that was never registered**, ad-hoc signed, in `/tmp`, in a
  project folder and in `/Applications` alike. Half Lid treats it as "off" and lets the switch try; whether registering then
  works is [NOT VERIFIED], because registering changes the user's Login Items.
- **Gatekeeper rejects the ad-hoc signed app** (`spctl --assess`: rejected), as expected without notarization. The signature
  itself is valid (`codesign --verify --deep --strict`), also after zipping with `ditto` and unzipping. A downloaded copy gets
  the quarantine flag and needs Open Anyway in System Settings, Privacy & Security. [NOT VERIFIED] on a quarantined copy: the
  builds made here carry no flag.
- **SwiftPM does not work on this Mac.** `swift build` fails to link the manifest of any package, even one made by
  `swift package init`: the `libPackageDescription` in these Command Line Tools does not match its interface (a stale
  `.private.swiftinterface` from 2024 sits next to a newer one). Hence `swiftc` scripts. Other installs may be fine.
- **Screenshots from a tool session.** `screencapture -l` fails here; `-R x,y,w,h` works. The first capture raises a Screen
  Recording prompt attributed to the app that started the tool (Cursor). Half Lid itself never asks for that permission:
  `HalfLidPanel --render` draws the panel to a file without a window.

## 4. What an interface costs in memory

Release builds, `footprint`, the figure Activity Monitor calls Memory (`experiments/ui-memory`).

| Variant | Footprint |
| --- | --- |
| AppKit status item with a native menu | 10 MB |
| SwiftUI `MenuBarExtra` | 14 MB |
| AppKit plus a window with 12 switches (open / after closing) | 24 MB / 21 MB |
| AppKit plus a SwiftUI window with 12 toggles (open / after closing) | 29 MB / 27 MB |

A window costs 11 to 19 MB and does not give it back after closing, with either toolkit. An in-process popover left about
8 MB behind after its first opening. So the panel and the Settings window are separate programs that exist only while they
are open. Starting the panel process to having it on screen took 233 to 299 ms (five runs); the resident app stayed at the
same size while the panel was open and after it closed.

The resident app now: 11 to 13 MB with every agent switched off, 16 to 20 MB while watching Cursor, 0.17 to 0.18 % and 0.75 %
of one core (README, "Measured"; the Cursor rows are from 2026-10-16, the others were repeated on 2026-10-17 with the final
mark). Opening Settings once did not change it at the resolution of `footprint` (18 MB before, 18 MB after).

## 5. Not done, on purpose or for lack of a Mac

- Hours with the lid closed, a flat or hot battery, a forced power-off while armed, a reboot while armed.
- Real installs of four of the five agents; macOS 14 and 15; Intel; VoiceOver speech (only the accessibility tree of the
  panel was read: every control in it has a label).
- Notifications from prompt to banner, and Open at login, which both need an answer from the person at the keyboard.
- Energy impact in Activity Monitor, memory over many hours, network traffic over time (only open sockets were checked, and
  the source contains no network API).
