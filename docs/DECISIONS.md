# Half Lid: implementation decisions

Status tags: **[OK]** verified on this Mac (macOS 26.5.2, arm64), **[NOT VERIFIED]** designed or read from docs only, **[PENDING TEST]** needs the closed-lid test.

Written as the work went on, so an older section can be out of date: where it disagrees with section 10 or with
[FINDINGS.md](FINDINGS.md), the newer text wins. Last updated 2026-10-20.

Scope rule: Half Lid does one thing. When a coding agent is working and the lid is closed, the Mac stays awake with the screen dark and locked. Everything else is out (how other tools differ is in the README, "Alternatives").

## 1. Keeping the Mac awake with the lid closed

**Evidence (first closed-lid run, AC power, macOS 26.5.2).** Ground truth is the system power log (`pmset -g log`), not a heartbeat: after a lid close macOS opens a DarkWake window of up to 180 s in which processes keep running, so a short heartbeat test cannot tell "slept" from "kept awake". The first version of the experiment used the heartbeat and misread its own control run.

| Run (lid closed) | Power log | Reading |
| --- | --- | --- |
| Control, nothing changed (22 s) | `Entering Sleep state due to 'Clamshell Sleep'` | Slept, as expected |
| IOKit selector 12, unprivileged (28 s) | No power event at all, not even display off | **Lid ignored** |
| `caffeinate -s` (42 s) | `Entering DarkWake state due to 'Clamshell Sleep'`, display off | Partial: no full sleep |
| `pmset disablesleep` | Not run (the sudo password prompt did not accept input) | Not tested |

The IOKit window is inferred: runs are sequential and the only gap with no event (103 s) is the one that contains it.

Second AC run, with the power-log verdict printed by the tool itself: IOKit selector 12, lid closed 30 s, 0 power events, `LID IGNORED`. A control run right after (including after a run interrupted with Ctrl+C) slept normally (`SLEPT`), so the override is cleared after restore or interruption. On battery (user, 15 s, one run): the test tool's beeps were heard with the lid closed and the power log showed no event, so the lid was ignored there too.

`AppleClamshellCausesSleep` is not a reliable indicator: it flipped to false after the control run (which slept), stayed false after an explicit restore, and was true at other times. Do not use it in the product. The `caffeinate` run after the IOKit restore logged a normal clamshell event, which shows the restore did clear the override. A short control run (`quick-control`) before each test confirms the Mac is back to normal.

**Choice.** IOKit `kPMSetClamshellSleepState` (selector 12), unprivileged: no admin prompt, no sudoers, no helper, no password, ever. This contradicts Adrafinil's note for macOS 26.3 ("returns success, Mac still sleeps"); on macOS 26.5.2 here it worked, on AC (two runs) and on battery (one run). It is not an interface Apple documents, so another macOS version may behave differently. What is still open:

- [OK] done: a second run on AC (30 s) and one on battery (15 s) both ignored the lid. [PENDING TEST] runs of 120 s and longer.
- [PENDING TEST] long duration: whether macOS clears the mask on sleep/wake or power-source change over hours.
- [NOT VERIFIED] the mask survives the process (kernel-global per the xnu source) and resets at boot. Assume it survives and keep a guard.
- With the lid ignored, the internal display stays on. The sequence in section 5 (lock, display off) is therefore mandatory, not cosmetic.

**Fallback.** `pmset -a disablesleep 1|0` through a narrow sudoers rule installed once (allows exactly those two commands, validated with `visudo -cf`, existing file backed up; not shipped). Used only if the IOKit route fails on battery or over time. Everything below about a root boot daemon applies only to this fallback.

**Common rules.**

- Armed while an agent is working, even with the lid open. The override must exist before the lid closes, otherwise the Mac sleeps at once. Armed with the lid open is harmless.
- Re-applied several times a second while armed by the keeper (below), because the flag is shared with macOS's power daemon, which
  clears it on its own events. The first version re-applied it every 60 s, and this line also promised "after every wake", which was
  never implemented. That gap is what failed in the maintainer's run of 2026-10-19.

**Rejected.**

| Option | Why not |
| --- | --- |
| Privileged helper through `SMAppService` | Needs a Developer ID signature (`SMAuthorizedClients` with `anchor apple generic`). Costs money. |
| `caffeinate -s` (PreventSystemSleep) | Only partial (DarkWake, display off), documented as AC only, and Apple's header calls the type unsupported. Keep as a backup idea only. |
| Apple clamshell mode | Needs an external display. |

### The override flag is shared with powerd, so the hold is re-applied four times a second (2026-10-19)

**What failed.** The maintainer ran `scripts/lid-check.sh` with Half Lid armed (a timed hold, on power, external monitor connected) and
closed the lid three times in 90 seconds. Each time the Mac went to sleep (DarkWake and Sleep, `Clamshell Sleep`), while Half Lid
said it was holding. Earlier the same day single closures had worked, and so had one of 29 minutes (03:25 to 03:54).

**Why (FINDINGS 1b has the log lines).** The flag behind selector 12 is one bit of a kernel mask, and `powerd` writes the same bit
(`kClamshellSleepDisablePowerd` in the public xnu source; the logged values 0 and 2 match). powerd recomputes it on its own events
(a monitor coming or going, user activity, a wake) and writes only when its own answer changes. So the flag was not Half Lid's alone:
before the failure it read 2 since 12:23:42 because a powerd thread had set it, and Half Lid's once-a-minute writes were no-ops (2 to 2).
At 17:50:47.535 powerd cleared it after the external monitor went away, 0.687 s before the kernel heard "lid closed". After each
wake powerd cleared it again within 40 to 85 ms, and Half Lid's next write came 8 s after the last closure.

**Choice: `OverrideKeeper`** (`Safety/OverrideKeeper.swift`). While armed, a timer on its own queue applies the override every 0.25 s
(about 60 microseconds per call, measured as one open and close of the connection). The same call is made at once, and again after
0.05, 0.1, 0.2, 0.4, 0.8 and 1.6 s, whenever something that can make powerd write has just happened: a message from the power
registry (`RootDomainWatcher`, the lid among them), a wake, the screens waking or sleeping, a change of display configuration. The
loop on the main thread is not involved, so a long Cursor read on the main thread cannot delay it. `ProcessInfo.beginActivity` with
`.userInitiatedAllowingIdleSystemSleep` and `.latencyCritical` keeps App Nap from stretching the timer; it does not hold the Mac
awake (checked: `pmset -g assertions` shows nothing from a process running only the keeper).

**It can only ever set the override, so two rules keep it from making a release fail.**

- `stop()` is synchronous: when it returns, no call is in flight and none can start. `ActionExecutor` calls it before releasing, so
  the release is always the last write. 40 rapid arm and release cycles with a 1 ms keeper never left the override set.
- The keeper applies only while the loop keeps saying it is alive (once per iteration, at most 5 s apart when armed). After 30 seconds
  of awake time without that, it stops applying, well before the guard's 120 s heartbeat timeout releases the Mac, so it cannot undo
  the guard. If the app is killed the keeper dies with it and the guard releases as before (tested: SIGKILL of `halflid run`, the
  stand-in file reads `normal` at once and is not written again).

**Not done, on purpose.** A `PreventSystemSleep` assertion held by Half Lid would keep powerd's own answer non-zero and so stop it
clearing the bit, but only on power (documented for `caffeinate -s`, which here gave a DarkWake, not a full stay-awake, in the first
closed-lid run) and it cannot be tested without a lid. Not added; revisit if the log shows powerd clearing the flag after the lid
has closed, which is the one case the keeper cannot catch.

**What it does not cover [OPEN].** The kernel puts the Mac to sleep inside the same call that clears the last bit when the lid is
already closed. If powerd clears the flag after the lid closed, nothing can put it back in time. `scripts/lid-check.sh` now reads the
system log for exactly this and says so ("turned off by powerd ... AFTER the lid closed"). Whether that happens on this Mac, for
example when the monitor's link drops after the close, has not been observed. [NOT VERIFIED] with a real closure after the change:
the keeper is checked by tests with a fake override and by a real `halflid run` against the file stand-in (the file is rewritten about
four times a second while armed and reads `normal` after the run), not with the lid. The next real run is the user's.

## 2. Recovery: never leave the Mac awake

Layers, in order of how soon they act:

1. Normal release when work ends, a limit fires, or the user stops.
2. Signal handlers (SIGTERM, SIGINT, SIGHUP) restore at once. [OK] tested with a fake `pmset`.
3. Separate guard process (`halflid guard --parent <pid> --heartbeat <file>`) restores as soon as the app is gone, even after `kill -9`, and on its own SIGTERM/SIGINT. [OK] automated tests with the real process and a file stand-in for the override: restored within seconds. The earlier fake-`pmset` watchdog (restore about 30 s after `kill -9`) is superseded.
4. Heartbeat: the guard also restores if the app's heartbeat file is older than 120 s (app hung). [OK] automated test with the file stand-in. Fail-safe by construction: a missing heartbeat file also releases.
5. Boot-time reset. With the IOKit route the kernel mask resets at boot by itself [NOT VERIFIED]; no daemon needed. Only the `pmset` fallback needs a root LaunchDaemon with `RunAtLoad` running `pmset -a disablesleep 0`, installed in the same single admin step.
6. On app start: read the lid state and clear the override if we did not set it this session. With IOKit the guard needs no sudo: any user process can clear it.

Uninstall with the IOKit route: clear the override and delete the app; nothing else exists on the system. With the `pmset` fallback: one command removes the sudoers rule and the daemon and sets `disablesleep 0`.

### Ending work with the lid closed

Releasing the override must make the Mac sleep by itself.

- [OK] Measured with `halflid sleep-test` (maintainer, 2026-10-16, macOS 26.5.2, on the real IOKit route): lid closed, override released 3 s later, and the Mac went to sleep **by itself 7 s after the release** (clamshell sleep, not the idle timer), then stayed asleep 134 s until the lid was opened. Our fallback (15 s in the test) did not have to act. Not recorded: which sleep assertions were held at the time (Cursor was probably running).
- The fallback stays as a safety net for other settings or machines: if the lid is still closed and the Mac is awake 90 s after release, run `pmset sleepnow` (no root needed). Only when the lid is closed, never with the lid open. [NOT VERIFIED] on hardware, because on this Mac it was never needed.

## 3. Detecting that an agent is working

**Choice.** Layered signals, no changes to any agent configuration by default. Only process names and paths, CPU of the process tree, modification times of session files, and sleep assertions held by agent processes. Never contents, never command-line arguments.

- For command-line agents (process visible): working if any strong signal is present: a fresh session-file write, a sleep assertion held by the agent, or CPU of the tree above its own learned idle level.
- Idle only after about 2 minutes without any signal (grace), to ride out long network waits.
- Cursor has no process of its own to watch. Measured (7 minutes, 5 s samples): tree CPU is 17 to 120 % (average 50 to 65 %) both while an agent works and while the chat sits waiting on a question card; session-file mtime is stale (the chat transcript file is rewritten only now and then, not live); one sleep assertion (sometimes two) is held in both states. So the process table cannot separate "working" from "waiting for me". Many chats waiting on a question is the normal state of the user, so a process-based detector would keep the Mac awake until the duration cap for nothing.
- **Cursor choice: read Cursor's own chat state, read-only** (`Agents/CursorChatState.swift`). Prior art: Cursor Pocket (`docs/FINDINGS.md` sections 2, 8, 9) found where the state lives; the fields were re-checked live here. No hooks, no change to any Cursor configuration.
  - Source: `~/Library/Application Support/Cursor/User/globalStorage/state.vscdb` (SQLite, several GB). Opened read-only, short queries by exact key, closed after each read. About 0.4 s for a full read of the recent chats.
  - Only state fields are selected (status, tool name and status, timestamps). Message text and chat names are never selected, so they never enter our process. Chat ids are shortened to 8 characters in anything we print. [OK] automated test with a canary text.
  - Per chat, in this order: waiting for the user if the last step is an unanswered `ask_question` or a tool awaiting approval (also in the step before); idle if `composerData.status` is `completed` with nothing queued; otherwise working only with a sign of life in the last 5 minutes (the header checkpoint is refreshed every 30 to 60 s during a run) and one of: run flag set, a tool still `loading`, a step written in the last 2 minutes, or an answer just submitted (the run flag is not written in that phase).
  - [OK] Live check on this Mac: a chat that was running is "working"; four chats with an open question and one with an aborted status plus an open question are "waiting"; two finished chats are "idle". A second chat that was running changed to "waiting" two minutes later when it posted a question, and its last step confirmed it. The checkpoint age of the running chats stayed under 60 s over 80 s of sampling.
  - Limits. [NOT VERIFIED] across Cursor versions: this is an internal format and can change without notice; the reader then returns an error, the app says so and the manual hold still works. [NOT VERIFIED] a very long command with no checkpoint refresh; a Cursor that quit mid-run leaves a stale run flag (bounded by the 5-minute sign-of-life rule, and the app also requires a Cursor process). Stopped by hand: up to 5 minutes counted as working when the last step was a just-answered question.
- Hooks (Claude Code, Codex) remain an optional later step for other agents, with a backup of the config before any change. Not needed for Cursor.
- Adaptive idle level per agent (Keepresso's approach) over a fixed threshold (Adrafinil uses 3 % for 90 s): a TUI that animates while waiting would break a fixed number.

## 4. Safety limits

| Limit | Default | Source |
| --- | --- | --- |
| Battery | warn at 30 %, stop at 20 %, no automatic resume | public IOPS API [OK] |
| Duration | 4 h on battery, 12 h on AC | timer |
| Thermal state | stop at serious or worse | `ProcessInfo.thermalState` [OK] |
| Battery temperature | warn at 42 C, stop at 45 C sustained 60 s | `AppleSmartBattery`, read without root [OK], unit assumed centi-degrees [NOT VERIFIED] |

- A fired limit latches until the hazard recedes, to avoid acquire/cutoff oscillation. Idea from Adrafinil. Recovery rules as implemented in `Safety/Controller.swift`:
  - battery: charger connected, or level back to stop + 5 points;
  - battery temperature: back to stop - 5 C (40 C);
  - thermal: below the stop level and at least 60 s after the stop (cool-down);
  - maximum duration: the lid opening starts a new session; the latch also clears when no work is wanted any more;
  - override failure: retry after 60 s.
- Limits apply to manual holds as well (a hold until stopped still ends at the 12 h cap).
- With the lid closed, a stop releases the override and asks for sleep after 90 s if the Mac has not slept by itself.
- Verified only against virtual time (`halflid simulate <scenario>` and the automated tests), never with a real hot or empty battery. [NOT VERIFIED] on hardware.
- CPU die temperature is skipped: no public API on Apple Silicon, and the private routes add risk for little gain over thermal state plus battery temperature.

## 5. Lid-close sequence

On a lid-closed change (root-domain notification, [OK] available) while armed:

1. Lock the screen explicitly with `SACLockScreenImmediate` (login.framework). [OK] symbol present. Fallback: sleep the display and show a hint.
2. Sleep the display (`pmset displaysleepnow`), re-issued while the lid stays closed.
3. Brightness to 0 through `DisplayServices` as a second layer, restoring the original value on open. [OK] symbols present, prior art in `cp-brightness`.

Implemented in `Screen/SystemScreenControl.swift` (all private symbols are looked up with `dlsym`; a missing one is logged and skipped). Brightness is set first, then the display is put to sleep. The original brightness is saved to `~/Library/Application Support/HalfLid/brightness.saved`; the guard process restores it after releasing the override, so a crash cannot leave a black screen, and `halflid repair` does the same by hand. After a release with the lid closed, `pmset sleepnow` runs after 90 s only if the lid is still closed and the override was not re-applied. This fallback is a safety net: it was first assumed to be essential because Cursor holds a sleep assertion even when idle, but the real test (section 2) showed macOS sleeping by itself 7 s after the release. Verification tool: `halflid screen-test` (reads lock state from the session dictionary and display sleep from CoreGraphics). [OK] automated tests with fakes, dry run without closing the lid. Everything below is [PENDING TEST] with the lid closed, except what the first real run showed.

Why an explicit lock: on this Mac `sysadminctl -screenLock status` reports **screenLock is off**, so display sleep alone would leave an unlocked session awake in a closed lid. `CGSession` is gone on this macOS and is not an option.

**First real closed-lid run** (`halflid screen-test`, user, 2026-10-16, macOS 26.5.2, lid closed 52 s, override active, on the real IOKit route):
- [OK] The session was locked while the lid was closed (`session_locked=yes`, read from the session dictionary).
- [OK] The display was asleep at the first sample after the close (0.1 s). Not separated: whether our display-off or the lid itself did it; either way the result is the wanted one.
- [OK] The brightness-to-0 call was accepted (no failure logged) and the original value (0.62) was back after the release. [NOT VERIFIED] that brightness actually reached 0: it cannot be read while the display sleeps (`brightness_lowest_while_closed=unknown`). Its job is the case where something wakes the panel with the lid closed (a notification), so it stays as a second layer.
- [OK] The test process kept running and sampling for the whole time, so the Mac stayed awake with the lid closed.
- [OK] Release with the lid closed followed by sleep: see section 2 (`halflid sleep-test`, slept by itself after 7 s).
- [NOT VERIFIED] The 90 s `pmset sleepnow` fallback on hardware (never needed here), runs of hours.

## 6. Interface

Measured on this Mac (macOS 26.5.2, arm64, release builds from `experiments/ui-memory/`, `footprint`: the figure Activity Monitor calls Memory). [OK]

| Variant | Footprint |
| --- | --- |
| AppKit status item with a native menu | 10 MB |
| SwiftUI `MenuBarExtra` (`.menu` style) | 14 MB |
| AppKit, plus a window with 12 switches (open / after closing) | 24 MB / 21 MB |
| AppKit, plus a SwiftUI window with 12 toggles (open / after closing) | 29 MB / 27 MB |

A window costs 11 to 19 MB and the memory does not come back after closing, with either toolkit. So the toolkit is not the lever; keeping a window process alive is.

- **Three kinds of process** (this replaces the first plan of two modes of one executable):
  - *Resident* `HalfLidApp`, always running, AppKit only, `LSUIElement`: status item, the classic `NSMenu` on right-click, the agent loop, the login item and the notifications (both belong to its bundle id). 13 MB with every agent off.
  - *Panel* `HalfLidPanel`, started by a left click: a borderless `NSPanel`, JSON lines over standard input and output, exits when dismissed (build step 4 below).
  - *Settings* `Half Lid Settings.app`, SwiftUI: a regular application nested in `Contents/Helpers`, started through LaunchServices by the gear, exits when its window closes (section 10).
  - The command-line tool `halflid`, which is also the guard process, sits next to the resident executable.
  - Preferences are one small JSON file in Application Support; the resident reloads it on a Darwin notification. Settings and the command line talk to the resident through distributed notifications and read its answers from `status.json` (section 10).
- Targets, to be published only if measured and met: at most 20 MB with the default modules, idle CPU about 0 %, no network connections. [OK] met (section 8).
- Menu content: one status line, keep awake until stopped, timer entries, limits summary, settings, quit. Only entries of enabled modules appear; nothing greyed out.
- Icon: a laptop in profile, template image, three states: idle (closed), active (half open), warning (half open plus a dot). They are the maintainer's three drawings, traced to vectors and used as they are for the menu bar mark, the app icon, the panel and Settings (first built as my own reconstruction, replaced on 2026-10-17: see "The mark" in section 10); sources in `docs/brand`, rules in `docs/BRAND.md`. [OK]
- No emojis, no gradients, no glow.

## 7. Text, languages, build, distribution

- All texts in flat JSON catalogs, English fallback, `{placeholder}` replacement, no plural forms. 12 languages: en, it, es, fr, de, pt, ja, zh-Hans, zh-Hant, ko, ru, tr. A parity test fails if any key is missing.
- Build with `swiftc` scripts: SwiftPM is broken by a Command Line Tools version mismatch on this Mac. [OK]
- Ad-hoc signed, universal (arm64 and x86_64) zip from `scripts/package.sh`, with a SHA-256 checksum. [OK] it builds, `codesign --verify --deep --strict` passes, `spctl --assess` rejects it (not notarized). [OK] The first launch of a quarantined download was seen once (2026-10-20, 0.1.1, macOS 26.5.2): a dialog with only Move to Trash and Done, see FINDINGS. [NOT VERIFIED] on Intel, on macOS 14 and 15. The route this project recommends to people who can build is from source: no quarantine flag, no ritual.
- Homebrew: a cask draft is in `packaging/homebrew/halflid.rb`, never run. The official `homebrew/cask` repository requires casks to pass Gatekeeper (signed and notarized) and is disabling those that do not (September 2026), so it could only live in a personal tap. Checked against Homebrew's own announcements on 2026-10-16.
- Notarization ($99 per year) is the one purchase that would change install friction and trust. Revisit only if the project gains traction.
- No network access, no telemetry, no auto-update in version 1.

## 8. Claims we can measure for the brand

Publish only numbers we measured: idle CPU, resident memory, app size, no network connections, number of settings. Do not claim anything about competitors beyond their own documentation.

Measured 2026-10-16 on macOS 26.5.2, Apple Silicon, release build, ad-hoc signed bundle, with the stand-in for the lid override and no screen actions (so nothing on the machine was changed). Memory is `phys_footprint` from `footprint`; CPU is process CPU time over 60 s.

| Measure | Result |
| --- | --- |
| App bundle size | 4.4 MB (arm64 only), 8.4 MB with both architectures; the zip is 2.6 MB |
| Memory, every agent off | 13 MB (peak 13 MB) |
| Memory, Cursor module on, Cursor working | 16 to 20 MB |
| CPU, every agent off (poll every 10 s) | 0.18 % of one core (0.11 s per minute) |
| CPU, Cursor module on, holding awake (poll every 5 s) | 0.75 % of one core (0.45 s per minute) |
| Threads, open files | 3 threads, 29 open files (every agent off) |
| Internet sockets | 0 at the moment of sampling, in the resident app, the panel, Settings and the guard (no network code exists) |

- The first measurement of this table (before the panel and Settings existed, an app of 1.5 MB) gave 11 MB, 0.17 % and 4 threads. The rows above were re-measured on 2026-10-16 with the packaged, universal bundle (13 MB against 11 MB with everything off). Opening Settings once changed nothing (18 MB before and after, Cursor module on).
- The Cursor module costs about 5 to 7 MB now (about 10 MB in the first measurement) because each read pulls whole chat records of 0.1 to 3.5 MB through SQLite; macOS keeps the freed blocks resident (live heap after a read is 0.4 MB; `malloc_zone_pressure_relief` and `sqlite3_release_memory` both release nothing). Not fixable with a smaller query: any function over a stored value loads all of it. Possible later: do the read in a short-lived helper process (memory freed on exit, at the cost of more CPU per poll).
- Before the fix of the session-folder scan (about 90 ms per poll for Cursor's folders, never needed for Cursor) the same loop used 2.9 % CPU. Session folders are now walked only for watched command-line agents that are running.
- Not measured: energy impact in Activity Monitor, memory over many hours, network traffic over time (only open sockets were checked).

## 9. Modules, resource rules and build order

Scope: everything in the "core" and "later" tables of the feature inventory. The "left out on purpose" list stays out (unrelated to agents, or needs private APIs or more privilege); the module layout lets any of it be added later without costing memory for people who do not use it.

**Rule: a module that is off costs nothing.** No timers, no threads, no observers, no menu entries, no settings noise. Modules are created when enabled and destroyed when disabled. Anything with a window runs in the on-demand window process (section 6).

| Module | Default | Notes |
| --- | --- | --- |
| Engine: lid override, guard, recovery, safety limits | always on | Limits have defaults and can be tuned in settings. |
| Cursor (reads Cursor's chat state) | on if Cursor is installed | Polls only while a Cursor process exists. |
| Command-line agents: Claude Code, Codex, opencode, GitHub Copilot CLI, Goose | each on if its process is found | One switch per agent. Signals calibrated on a simulated agent: [NOT VERIFIED] on the real ones. |
| Manual hold and timers | on | Menu entries. |
| Screen: lock on close, display off, brightness 0 | on | Lock and display off [OK] with the lid closed (section 5); brightness effect and sleep fallback [NOT VERIFIED]. |
| Lid-open summary | on | One line in the menu; needs a tiny local log. |
| Notifications (finished, limit fired) | off | Asks for permission only when enabled, from the resident (its bundle id). The prompt appeared for a probe app of the same kind; [NOT VERIFIED] from prompt to banner. |
| Command line `halflid status/start/stop/repair` | on | Start and stop go to the resident through a distributed notification and can be switched off in General; status and repair work without it. |
| Launch at login | off | User's choice, asked of the resident (`SMAppService.mainApp`). Reads "not found" before the first registration and is shown as off. [NOT VERIFIED] that registering works for an ad-hoc signed app. |
| Why is my Mac awake | on demand | Settings, Diagnostics pane; lists who holds sleep assertions. |
| Hooks for exact detection | off | Opt-in, backup of the agent config first. Not needed for Cursor. |
| MCP server, Shortcuts, URL scheme | later | Each a separate on-demand mode, nothing resident. |
| Automatic updates | not in version 1 | Needs signing; no network in version 1. |

**Interface rules.** Menu: status line, one primary action, then only what active modules add. Settings: a list of modules, each with a one-line description and a switch; details appear only when it is on. No wizard on first run. System font, native controls, SF Symbols only, light and dark automatically, one accent colour and one warning colour. No emojis, no gradients, no glow.

**Build order.**
1. Agent loop in a headless mode (`halflid run`): Controller + Cursor reader + process signals + preferences, with a simulated screen. Tests.
2. Real screen control: lock, display off, brightness, sleep fallback. Needs the user's closed-lid tests.
3. Agent app: status item, menu, icon, catalogs, manual hold and timer, summary, notifications; assemble the `.app` (Info.plist, ad-hoc signature, icon).
4. Window process: settings with modules and limits, why-is-my-Mac-awake.
5. CLI control, login item.
6. The ten remaining translations (12 languages in total).
7. Package: zip, Homebrew tap, README, LICENSE; measure memory, CPU and network and publish only measured claims.
8. Long runs by the maintainer: 30 to 60 minutes lid closed under load, `kill -9`, forced power-off and reboot, battery. (Release-then-sleep is done: section 2.)

Status: steps 1 to 7 are built (section 10 for 4 to 7). Step 8 is the maintainer's and is open.

### Build step 1 status: the headless agent loop (`halflid run`)

Implemented in `Loop/` (`Preferences.swift`, `WorkDetector.swift`, `AgentLoop.swift`) and `main.swift`.

- **Tick order.** Controller step, then lock and display-off filtered by preferences, then heartbeat touched and guard started, and only then the override applied. When the override cannot be applied, the guard is stopped, the indicator turns to warning and the controller retries after 60 s. A tick runs on every lid-state change and on a timer; each state change prints one `key=value` line.
- **Work rule.** Work wanted = manual hold, or Cursor has at least one chat in the working state (read only when the Cursor module is on and a Cursor process exists), or a command-line agent process shows CPU of 15 % or more, or a session file written in the last 30 s. A process seen for the first time has no CPU baseline and reads as 0 until the second sample. A Cursor read error is reported as a problem and never counted as work.
- **Preferences.** One small JSON file (`~/Library/Application Support/HalfLid/preferences.json`, overridable with `HALFLID_PREFERENCES`). Decoded on top of defaults; any problem means defaults. Limits are clamped to safe ranges (battery stop 5 to 50 %, warning at least stop + 5, hours 0.25 to 24 on battery and 0.25 to 72 on AC, battery temperature stop 38 to 50 C) so a bad value cannot disable a safety net.
- **Guard supervision.** The loop starts one guard process while armed and stops it when disarmed. The guard is given the full environment explicitly: leaving the property unset did not hand the parent's variables to the child, so a guard started by `run` used the real IOKit override instead of the test stand-in. Found by the `kill -9` test, fixed, covered by it. A guard that finds its app dead also deletes the app's heartbeat file; with a stale heartbeat it keeps the file, because the app may still be alive.
- [OK] Automated: 349 checks, 0 failures at the time of writing (the suite has grown to more than 5,000 since: `scripts/test.sh`), including the real `halflid run` process (arm and release with the file stand-in, `kill -9` of the app and recovery by the guard, clean exit on SIGTERM) and a simulated CLI agent (a CPU burner) detected and released.
- [OK] Live on this Mac with the real Cursor state: armed while a Cursor chat was running, released on SIGTERM, no leftover process or file.
- [NOT VERIFIED] On hardware with the lid closed (section 5) and over several hours; real command-line agents; hold behaviour if macOS clears the kernel mask on its own.

### Build step 3 status: the menu bar agent

Sources in `Sources/HalfLidApp/`: `HalfLidApp.swift` (status item, signal handling, `--print-menu` check mode), `AgentService.swift` (loop, preferences, last session, polling), `MenuController.swift` (native menu built each time it opens). Testable parts live in the core: `Presentation/StatusPresenter.swift` (texts of the state) and `Session/SessionTracker.swift` (last-session summary). `scripts/make-app.sh` assembles `build/HalfLid.app`.

- **No windows, no SwiftUI.** Native `NSMenu`: a status header, one detail line, the last session line (only while not holding), "Keep awake" (until stopped, 30 minutes, 1, 2 or 4 hours) or "Stop keeping awake" while holding, "Watch" (Cursor and each command-line agent, checked when on), "When the lid closes" (lock, display off), Quit. Refreshes its readings when opened. Icon: the existing three states of the mark, redrawn only when the state changes; accessibility label and tooltip set.
- **Polling.** 5 s while holding, 10 s otherwise, 20 % tolerance, plus an immediate tick on lid change and on wake. Nothing else runs.
- **Single controller.** An advisory file lock (`controller.lock`) shared by the app and `halflid run`: two controllers would clear each other's override. The kernel drops the lock when the holder dies. Not taken with the stand-in override (tests).
- **Guard first.** The loop never applies the override unless the guard process is running (the CLI executable sits next to the app executable in the bundle). If it cannot start, the Mac is not held, the indicator turns to warning and the user is told. [OK] automated test, found while assembling the bundle.
- **Last session** (start, end, why it ended; no names or content) is saved in `last-session.json` and shown in the menu. It replaces a separate lid-open summary for now.
- [OK] Automated: 568 checks, 0 failures, including the real `HalfLidApp --print-menu` (idle, watched agents, holding, Italian), presentation texts for every state and stop reason in both languages, the session tracker and the instance lock.
- [OK] The bundle runs: arms on real Cursor activity (with the stand-in override), starts the guard, exits cleanly on SIGTERM, restores the override, leaves no process, saves the last session.
- First real launch (maintainer, `open build/HalfLid.app`): nothing seemed to appear. First guess (partly wrong, see below): the closed-lid (idle) mark was two thin bars sitting low in the button, easy to miss among many icons. Fixed by centring it vertically (`Glyph.draw`); the three states were re-rendered and checked on a dark bar. New items are added to the left of all the others, so on a crowded bar the icon is at the far left of the status area, not next to the clock.
- Second real launch: still nothing, and the diagnosis above was incomplete (the centring is still a fix, but not the cause). The 34 pt status window had been seen only for the bare `build/bin/HalfLidApp`; the bundled app created none. Cause, from the system log (`/usr/bin/log show`, process `ControlCenter`, category `appStatusItems`; note that `log` alone is a zsh builtin): for the bundle id `io.github.fedebartoli.halflid` macOS 26 logged "Starting to track blocked host" on every launch, so the item was created and immediately hidden. A bare executable is tracked as `.adhocBinary` and is allowed. When a bundled app is started from a terminal inside Cursor, macOS attributes its item to the responsible application ("Adding menu item at .bundle(X) to tracked application at .bundle(Cursor)") and then logs "Moving host to blocked list"; the state is kept per bundle id across launches and across a restart of Control Center, it is not in any readable preference file, and flipping the toggles in System Settings > Menu Bar (already on) did not change it. The old id was most likely blocked by an earlier test started from Cursor's terminal. Fix: the bundle id is now `io.github.fedebartoli.halflid.app` (nothing was published, nothing else used the old id). Verified: a build with the new id started with `open` from the same shell creates the status windows on both screens (2 windows on screen) and the log says "Starting to track host".
- Developer rule: start the bundled app only with `open` or from Finder, never by running `HalfLid.app/Contents/MacOS/HalfLidApp` from a terminal inside Cursor (that blocks the id on this Mac). Automated tests use `--print-menu`, which exits before creating a status item. A normal user starting the app from Finder is its own responsible app, so this does not affect users. Setting `autosaveName` / `isVisible` made no difference and was reverted.
- [OK] Third launch (maintainer, `open build/HalfLid.app`, id `io.github.fedebartoli.halflid.app`): the icon is seen in the real menu bar and the menu opens when clicked.
- Repeat of the block: while the panel was being checked, `build/HalfLid.app/Contents/MacOS/HalfLidApp` was started from the terminal, against the rule above. The log showed "Moving host to blocked list" for `io.github.fedebartoli.halflid.app` at once, and also for the copy the maintainer already had running (so its icon was hidden). Bundle id changed again, to `io.github.fedebartoli.halflid.menubar`. For any check that needs the real process, run the bare `build/bin/HalfLidApp` (tracked as an ad hoc binary, never blocked); the panel executable is found next to it, in `build/bin`. Never run anything inside `HalfLid.app` from a terminal.
- [NOT VERIFIED] The icon's look in light/dark bars; accessibility with VoiceOver; the order of the menu entries.
- [SINCE BUILT] Notifications, launch at login, the settings window, the icon redesign, the ten other translations and the CLI `start/stop/status`: section 10.

### Build step 4 status: the quick-actions panel (on-demand process)

A click on the icon opens a custom panel under it: status header with the mark, keep awake for 30 min / 1 h / 2 h / 4 h / until stopped (or "Stop keeping awake" while holding), one row per agent with its icon, state and a switch, a gear (Settings) and a power button (Quit). Right-click or Control-click still opens the classic native menu (keyboard and assistive technology fallback). Agent icons were first read from the installed applications through `NSWorkspace`, with a neutral terminal symbol for agents that are not installed; they were later replaced by vector marks that ship with the app (section 10).

- **Why a separate process.** An in-process popover left about 8 MB resident after the first open (phys_footprint 6.5 MB before, 14.5 MB after, flat over five more opens; AppKit, no SwiftUI). A panel that exists only while it is open costs nothing at rest. `HalfLidApp` starts `HalfLidPanel` (next to it in `Contents/MacOS`, or in `build/bin`), sends the content as JSON lines on its standard input and reads requests (hold, stop, watch, settings, quit) from its standard output. No sockets, no XPC. The panel exits when dismissed (click elsewhere, Esc, loss of focus) or when its input closes, so it cannot outlive the app. Core of the protocol: `Presentation/PanelSession.swift` (tested with stand-in child processes).
- **Measured** (release build, this Mac, `footprint`): resident app 12 to 13 MB at rest and unchanged while the panel is open or after it closed. Panel process while open: 18 to 23 MB steady; a reading about one second after opening showed 120 MB, which `footprint` attributes to graphics surfaces shared with the window server (reclaimable) and which is gone with the process. Time from starting the process to the window being on screen: 233, 245, 266, 274, 299 ms (5 runs, `CGWindowList`, release). Instrumented once and removed: about 90 ms before the content is processed (process start and AppKit), 50 to 60 ms building the views (app icons are not the cost: the same without them), 35 ms putting the window on screen, then a 0.12 s fade-in (none with Reduce Motion).
- **Click races.** The panel dismisses itself on a click elsewhere, so the click on the icon that would close it arrives when it is already gone: the app ignores an icon click within 0.3 s of the panel's exit. A request sent just before the panel exits (Settings, Quit) is delivered before the exit is reported (found by review, test added).
- **SwiftUI** is no longer linked into the always-running executables (a link loads the framework at launch). Measured A/B, two runs each: the resident app is 12 MB with and without, so no gain is claimed; it stays out because nothing there uses it.
- [OK] Automated: 664 checks, 0 failures, including `HalfLidPanel --print` (content on standard input, views as text: idle, watched agents, holding, Italian), the wire format, partial lines, an over-long line, requests followed by an immediate exit, `close`, a missing executable.
- [OK] Offscreen renderings (`HalfLidPanel --render PATH [--dark] [--state ...]`, no window, no Screen Recording permission) in light and dark for the active, idle, holding, warning and stopped states.
- [OK] The real flow with the bare `build/bin` executables: the app starts the panel, the panel puts a 320 x 343 window at the menu level, closing it leaves the app running with no panel process, quitting the app leaves no panel process.
- [OK] The real app (`open build/HalfLid.app`, bundle id `io.github.fedebartoli.halflid.menubar`, tracked by ControlCenter, not blocked) driven with synthetic mouse and key events from a terminal that has Accessibility access (helpers in /tmp, not part of the repo): a left click on the icon opens the panel centred under it (window 320 pt wide, menu level, top edge under the menu bar) and it stays open; a second click on the icon closes it and does not reopen it; a third opens it again; Esc closes it; a click on an empty part of the menu bar closes it; a click on "30 min" makes the panel switch to "Stop keeping awake" and shrink with its top edge fixed; a click on that button brings the duration chooser back; a right click opens the classic menu (and not the panel) and Esc closes it. The resident app stayed at 16 MB (real preferences, Cursor module on) before, while and after the panel was open; the panel process measured 24 MB steady and is gone when closed. The accessibility tree of the open panel names every control (switches "Watch X", gear "Settings…", power "Quit Half Lid", durations, stop) and the icon's label is "Half Lid: <state>".
- [NOT VERIFIED] The look of the real window (no arrow, material over the real wallpaper, light and dark): no screenshot was taken because that needs Screen Recording access, which Half Lid does not ask for; Tab order and the Command-comma shortcut inside the panel; VoiceOver speech (only the accessibility tree was read); the agent bundle ids of Claude and Codex (guesses, the fallback symbol is used if they are not installed); the Settings window (not built at that point; built in step 5, section 10).

## 10. Settings, system access, command line, languages, package (build steps 4 to 7)

Status as of 2026-10-16, same tags as above.

### The Settings window

- A SwiftUI application of its own, `Half Lid Settings.app`, nested in `HalfLid.app/Contents/Helpers`: regular (no
  `LSUIElement`), the same icon, bundle id `io.github.fedebartoli.halflid.settings`. The gear starts it through
  `NSWorkspace.openApplication`; it is a single instance (a second click brings it to the front) and it exits when its window
  closes. Seven panes: General, Agents, Lid and screen, Safety limits, Notifications, Diagnostics, About. Diagnostics shows
  the state of the resident app, who holds sleep assertions, whether the two private macOS functions behind the screen steps
  (lock, brightness) exist on this Mac, a shortcut to the Menu Bar settings, Repair and a plain-text report for bug reports
  (English, no paths, no chat text). The screen functions row exists because the app drops the log lines of a missing
  function: without `SACLockScreenImmediate` the Mac would stay unlocked behind a dark screen and nothing else would say so.
  It reports that the symbols can be looked up, not that they work; a future macOS could keep a symbol and change what it does.
- **Why a nested application and not a process of the resident one.** Since macOS 14 activation is cooperative, and a
  process started by a background app that is not frontmost cannot take the front: Settings opened behind Cursor. A regular
  app started through LaunchServices is activated like any app the user opens. [OK] with a real click on the gear
  (FINDINGS, section 3).
- [OK] Resident memory is unchanged by opening and closing Settings, and Settings holds no sockets.
- [NOT VERIFIED] The last third of the Diagnostics pane when scrolled, VoiceOver speech, and every pane in Dark Mode beyond
  the renderings that were looked at.

### Who owns what

The login item (`SMAppService.mainApp`) and the notification permission belong to the app that asks, so they belong to the
resident app. Settings, being another app, asks the resident through `ControlCommand`s on a distributed notification
(`io.github.fedebartoli.halflid.control`: set open at login, request notification access, send a test notification, refresh,
start, stop) and reads the answers from `status.json` (`openAtLogin`, `openAtLoginError`, `notificationAccess`). The resident
looks these up only when asked, so asking costs nothing at rest. Settings polls the file once a second while open and asks for a
refresh when it appears and when it becomes active again; when no resident runs, the window says so instead of pretending.

- Preferences: `preferences.json` plus a Darwin notification. `status.json` is removed on shutdown and validated against the
  process id, so a stale file is not believed. `settings.lock` and a distributed notification keep Settings single when it is
  started directly (development).
- [OK] Automated: every command and payload, the status file with and without the new fields, the bundle layout.
- [NOT VERIFIED] Notification permission prompt through banner; the first registration of the login item.

### Command line

`halflid status [--json]`, `start [30 | 30m | 2h | --minutes N | --hours N]`, `stop`, `repair`, `version`. Exit codes: 0 done,
3 Half Lid not running, 4 command-line control turned off, 5 no answer, 64 wrong use. `start` and `stop` follow the "command-line
control" switch in General (default on); `status` and `repair` do not. The texts follow the system language. [OK] automated.
The tool lives in `Contents/MacOS` of the app; the Settings app finds it from inside its own nested bundle.

### Languages

Twelve flat catalogs, `Resources/i18n/<code>.json`: en, it, es, fr, de, pt (Brazil), ja, zh-Hans, zh-Hant, ko, ru, tr. A test
fails when a key or a placeholder differs from English. [OK] The panel was rendered offscreen in all twelve languages and six
states (welcome, active, hold, stopped, warning, idle) and nothing is cut off or overlaps. All the translations are machine-written;
none was reviewed by a native speaker. [NOT VERIFIED] wording, and the Settings window in each language.
Turkish "Working" was changed from "Çalışıyor" to "Aktif" because it differed by one letter from "Çalışmıyor" (not running).

### Agent logos

The marks of Cursor, Claude Code, Codex, opencode, GitHub Copilot CLI and Goose ship as small SVG files in
`Resources/agent-marks`, drawn on uniform tiles by `AgentMark`. Where each comes from and under which license is in `NOTICE`,
which also says that the logos belong to their owners and that Half Lid is not affiliated with any of them. The trademark
exposure is real and is the maintainer's call: the logos are used to say which agent a row is about, and removing them is one
file per agent. In `agents.json` only Cursor is `verified: true`; the other five are `false` for detection (section 9) and the
Agents pane says so in each of their rows. Which agents are in the catalog, and which were looked at and left out (Gemini CLI
among them), is in `docs/AGENTS.md`.

### The mark (reworked 2026-10-17)

The first version of the mark was a reconstruction of the three drawings: a parametric laptop, a simplified variant for
small sizes, and the system symbol `laptopcomputer` in the Settings sidebar. Laid over the drawings it overlapped 88 to 94 %,
its lid opened wider than the drawing's, and it was not the maintainer's artwork. The maintainer asked for his three drawings
and nothing else (closed, open, open with a dot), so it was replaced:

- `docs/brand/trace-marks.py` (Python with numpy, scipy, scikit-image and Pillow, needed only to run the script) traces each
  JPEG: the outline at the half-grey level, corners kept, curves fitted with cubic Beziers within 0.45 px, the two ports as
  holes, the dot as a path of its own. It writes `Sources/HalfLidCore/Identity/LidMarks.swift` in the coordinates of the drawing.
- `LidGlyph` only places the outlines. The one change made to a drawing is scaling it so the base is 1000 units long and putting
  the base at the same spot, because the bases of the three drawings differ a little in length.
- They are used for the menu bar template image, the app icon at every size, the panel header, the About pane and the Lid entry
  of the Settings sidebar. There is no simplified variant: at 16 px the icon is a few pixels of off-white on graphite.
- Fidelity [OK]: each outline lies within 0.8 px (mean 0.3 px) of its 1024 px drawing and overlaps it 99.35, 99.37 and 99.56 %
  (idle, active, warning). A test draws the shipped outlines over the JPEGs in `docs/brand/source` and fails under 99 %; shifted by
  2 px they drop to 97.3 to 98.4 % sideways and 85 to 89 % vertically, so the test can fail.
- The drawings are not identical in proportion: the open lid of the warning drawing rises to 245 units above the base and that of
  the active drawing to 220, so the lid rises a little when the dot appears. That is in the drawings and was left alone.
- Not changed: the other Settings sidebar icons (gear, terminal, shield, bell, stethoscope, info) are system symbols for generic
  ideas, as on any Mac settings window. They are not laptop marks.
- Seen [OK]: the three app icons on a contact sheet and the warning one at 1024 px in detail (hinge, ports and feet, tip and
  dot at 3x), the About pane, the sidebar entry (selected and not), the panel header in the three states (dark), the menu bar
  marks as pixels at 2x on light and dark.
  [NOT VERIFIED] the real menu bar with the new icon: the copy of Half Lid that was already running was not touched and keeps the
  old icon until it is quit and opened again.

### Isolating a test run (found 2026-10-17)

A second copy of the resident app can be started for a measurement only with the file stand-in for the override
(`HALFLID_FAKE_OVERRIDE`), which also skips the instance lock. `HOME=/tmp/something` does **not** isolate it: the app expands `~`
from the account's real home, so a run started that way read the real `preferences.json` and Cursor state and, when it was
stopped, wrote a 28-second `last-session.json` into the real Application Support folder (deleted; it did not exist before).
Those numbers were thrown away. To isolate a run set `HALFLID_PREFERENCES`, `HALFLID_LAST_SESSION` and `HALFLID_STATUS` to
files of its own, with `cursorEnabled` false and an empty `cliAgents` in the preferences file, and compare the real folder
before and after (`diff` of `ls -la`). Never send `halflid start` or `stop` during such a run: the running copy would obey it too.

### A timed hold that never ended on screen (found 2026-10-18 in the maintainer's own run, fixed)

The maintainer kept the Mac awake for 30 minutes, closed the lid and found the lock screen on opening. That is the design, not a sleep:
"Lock the screen" is on by default (step 1 of section 5), `sysadminctl -screenLock status` says the system's own lock is off so the
lock came from Half Lid, and the power log shows two short closures (1 s and 3 s) with display off and on and no sleep.
Looking at what the app had published afterwards showed a real bug: `status.json` still said "held until 16:18" more than an hour
after the hold had ended at 16:18:08, while `last-session.json` had the session right (15:48:08 to 16:18:09, finished).
`AgentLoop` kept `hold = .until(date)` after the date had passed. The Mac was released on time (`Controller.isActive` compares the
date), but everything that reads the hold stayed wrong: by the code, the panel offered "stop keeping awake" and the menu left out
the durations (`PanelPresenter`, `MenuController`; not looked at on screen). Fix: `AgentLoop.tick()` clears a timed hold once its
end has passed. `LoopTests` has five checks for it (shown, still shown just before the end, cleared after it, released after the grace
period, a new hold can start); with the fix removed the main one fails, which was tried. The copy of Half Lid running at the time keeps the old
behaviour until it is quit and opened again.

### Seeing a closed-lid run from the outside (`scripts/lid-check.sh`, 2026-10-18)

`halflid screen-test` and `sleep-test` run inside Half Lid's own code. The script is separate and only watches: it changes no
setting and sends nothing to Half Lid. It uses three witnesses because one alone can be fooled (FINDINGS section 1: macOS keeps a
Mac running for a short DarkWake window after a lid close):

- a heartbeat once a second with the lid state (`ioreg`, `AppleClamshellState`). A Mac that sleeps freezes it, so a gap above 5 s is
  a candidate for a sleep (epochs have whole seconds, so gaps of 2 s are normal);
- the power log (`pmset -g log`) for the same window, the ground truth FINDINGS settled on. A `Clamshell Sleep` line decides
  "slept", even when the heartbeat never saw the lid closed because the Mac slept within a second of the close;
- every 5 s, Half Lid's published state (armed, idle, not running), so a sleep with Half Lid idle ("expected") is told apart from one
  with Half Lid armed ("the hold failed"), and a request to captive.apple.com, the address macOS itself uses, to see that the network
  answers while the lid is closed. `--no-network` skips the request.

A heartbeat gap alone is called a sleep only when macOS logged a sleep or wake in the same window; a gap with nothing in the log is
reported as "not conclusive", because a very busy Mac can miss a few ticks and a false "the hold failed" is worse than "run it
again". It ends by itself 10 s after the lid opens again. It cannot show that one particular agent finished its job, and says so.

Added 2026-10-19, after the hold failed (above): the report also has an "Override" section read from macOS's unified log for the
same minutes (`/usr/bin/log show` with a predicate for powerd, the kernel's `PMRD:` lines and WindowServer's display hot-plug lines;
no sudo, about two seconds for a minute and a half). It lists each closure with the state of the override when the lid closed, who
changed it last (powerd or another process, told apart by the thread id, which the kernel line and powerd's own lines share) and the
changes in order. The verdict says whether powerd turned the override off before the closure, after it, or whether it was off all
along. Repeated "Clamshell closed" lines that macOS logs at every DarkWake of a closed Mac count as one closure. It was run on
the real recording and log of the failed run (it names powerd, 687 ms, the display that went away at 17:50:47.172), on the real 29-minute
closure of 03:25 ("override ON when the lid closed, and no sleep followed"), and on hand-written logs for "turned off and put back
in time" and "turned off after the close" (`LID_CHECK_FAKE_LOG` stands in for the system log).
Tested with synthetic recordings for every verdict (never closed, awake, slept while armed and while idle, slept right after the
close and found only through the real power log of 2026-10-17 15:24:11, a gap with only other sleep lines, a gap with nothing in
the log, a gap with the lid open, network failing, no lid sensor, empty file), with a real run and the real network probe while
the lid stayed open, and with a fake lid file (`LID_CHECK_FAKE_LID`) closed for 6 s and reopened: it stopped 10 s later and
reported the closure with 2 of 2 probes answered. [NOT VERIFIED] a real closure by hand with it; that needs the lid.

Added 2026-10-20, after two real runs with the keeper. The first (three quick closures, monitor connected) passed, but the log
showed it could not tell whether Half Lid's hold was what kept the Mac awake: all 253 override writes were `(2->2)`, powerd logged
`isSleepDisabled : 16` at every lid event (it had logged 0 at the closure of the failed run) and `DesktopMode set 1` right after each
close. So the Override section now prints, for each closure, powerd's own state and desktop mode around the close, and the verdict
separates four cases: powerd busy (non-zero state or desktop mode on: "this run does not show that Half Lid alone kept the Mac
awake", with the control run to do); powerd holding nothing (state 0 and desktop mode off at every closure: the override Half Lid
keeps applying is what kept the Mac awake); armed with no powerd reading (the control reminder); Half Lid idle and the Mac awake
anyway (something else held it, the closure tests nothing). What `isSleepDisabled` means is not documented: the script prints the
number and only compares it with zero. The second run was set up to reproduce the failure (monitor disconnected while armed, then
closures); its report did not list the clear and the put-back because they happened 35 s before the script's first heartbeat. The
script therefore now reads the system log from 2.5 minutes before the first heartbeat, ignores closures before the check, and puts a
line in the history where the check starts. Checked on the real recording and log of that run (the clear at 14:57:42.896118 and the
put-back 292 microseconds later now show above the marker; four closures, powerd state 0, verdict "held nothing itself"), and on
edited copies of that log for powerd busy, Half Lid idle, and the failure (flag off at the first closure, a lid sleep, powerd named).

### Package

`scripts/package.sh` builds the universal app, checks that every executable has every slice, and makes
`build/dist/HalfLid-<version>.zip` with `ditto` and its checksum. [OK] Built; the signature verifies; Gatekeeper rejects it, as
expected without notarization. Nothing is uploaded by any script.

### Not verified in steps 4 to 7

Notifications end to end, the login item toggle, any agent other than Cursor on a real install, hours with the lid closed, a
really low or hot battery, a forced power-off while armed, the Intel half, macOS 14 and 15, a quarantined download through
Gatekeeper, and VoiceOver speech. They are listed again in the README and FINDINGS so nobody has to read this far to find them.
(Since then, 2026-10-20: the first launch of a quarantined download was seen once, see FINDINGS.)
