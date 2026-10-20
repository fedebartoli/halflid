# Changelog

## 0.1.0

The first release. Developed and tested on macOS 26.5.2, Apple Silicon. The app is signed ad hoc and is not notarized; see
"Install" in the README for the first launch.

### What it does

- Keeps the Mac awake with the lid closed while a watched coding agent is working, or on request (30 minutes, 1, 2 or 4 hours,
  or until stopped), through an IOKit call that needs no administrator rights.
- Re-applies the setting four times a second and at once when macOS's power daemon clears it (it does, for example, when an
  external monitor is unplugged), and has a separate guard process that puts everything back if the app dies.
- Locks the screen and turns the display off when the lid closes; restores the brightness when it opens.
- Stops by itself when the work ends (after a wait of two minutes), when the battery is low or hot, when macOS reports heat, or
  after a time limit. Every limit can be changed in Settings and is kept inside a safe range.
- Watches Cursor (by reading the status of its chats, never their text) and, experimentally, Claude Code, Codex, opencode,
  GitHub Copilot CLI and Goose (by process, install path and recent file activity).
- A menu bar icon, a quick panel, a Settings window, a `halflid` command (`status`, `start`, `stop`, `repair`), notifications,
  Open at login, twelve languages.

### Checked

- With the lid really closed, by hand, on this Mac: on power and on battery, in closures of 15 to 52 seconds and one of 29
  minutes; and, with the external monitor unplugged while Half Lid was holding, in four closures, one of them of 3 minutes 34
  seconds. The screen was locked and dark, and the Mac went back to sleeping by itself once Half Lid let go. Details, and the
  failed run that led to the four-times-a-second fix, are in `docs/FINDINGS.md`.
- More than 5,000 automated checks, run with simulated clock, battery, heat, lid override and screen.

### Not checked

- The same closures with Half Lid not holding (the control run), and a clear that arrives after the lid has closed.
- Closures of hours, a really empty or really hot battery, a forced power-off while armed, a Mac that sleeps and wakes during a
  hold.
- Claude Code, Codex, opencode, GitHub Copilot CLI and Goose on real installs. Their recognition is written from how each one is
  installed (`docs/AGENTS.md`); the Agents pane says "Not tested on a real install yet" under each.
- Gemini CLI and other agents written as Node.js scripts are not recognised: macOS reports them as `node`.
- Notifications from permission prompt to banner, Open at login.
- macOS 14 and 15, Intel Macs (the download contains an Intel half that was built and never run).
