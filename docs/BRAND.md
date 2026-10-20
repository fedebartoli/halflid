# Half Lid: brand

Short on purpose. It says what to call the thing, how it should sound, what the mark is and how to use it, and which claims
are allowed.

## Name

- **Half Lid**, two words, in the interface, the README and any prose.
- `halflid` for the command, the repository and anything a machine reads. `HalfLid.app` is only the file name of the app.
- The bundle ids are `io.github.fedebartoli.halflid.menubar` (the app that lives in the menu bar) and
  `io.github.fedebartoli.halflid.settings` (the Settings window). The first one is the identity macOS knows: notifications and
  the login item belong to it, so it should not change after a release.
- The name is the idea: the lid is not fully open and not fully closed. Say so once and move on.

## Voice

- Light, a little self-ironic, in one place per page at most (the laptop propped open at forty-five degrees is the joke).
  Everything about system behaviour is plain and exact: what changes, when, how it is undone.
- Say what happens, not what it feels like. "The Mac stays awake with the lid closed", not "peace of mind".
- No hype words (secure, military-grade, bulletproof, guaranteed, AI-powered). No promise about the future.
- Never describe a limit as a feature. If something has not been tested, the text says so.
- No emojis in the interface or the docs. Icons are drawn, or SF Symbols.

## The mark

A MacBook seen from the side, with the lid at one of three angles. The picture is the state.

| State | Lid | Meaning |
| --- | --- | --- |
| Idle | Closed, a flat bar | Half Lid is waiting; nothing is held awake |
| Active | Half open | The Mac is being kept awake |
| Warning | Half open, an amber dot beyond the tip | Close to a safety limit, or a limit stopped it |

The three pictures are the maintainer's own drawings (`docs/brand/source`: `chiuso.jpeg`, `aperto.jpeg`,
`aperto con pallino.jpeg`). They are traced to vector outlines, not redrawn: nothing is simplified, rebuilt or replaced by a
stock symbol, and every place that shows the mark (menu bar, app icon, panel, Settings) uses these outlines and no others.
`docs/brand/trace-marks.py` fits each drawing with cubic curves (within 0.8 px of the 1024 px drawing, 99.3 to 99.6 % overlap)
and writes `Sources/HalfLidCore/Identity/LidMarks.swift`. The only change made to a drawing is its placement: each is scaled so
that the base of the laptop is the same length in all three, at the same spot, because the drawings differ a little in size.
Change a drawing, run the script again, and a test checks that the app still draws what the drawing shows.

The menu bar image is 24 by 16 points, a template image (the system tints it for light and dark bars). All three states have
the same size, so the item does not change width when the state does. There is no simplified version for small sizes: at 16 px
the app icon is a few pixels of off-white on graphite, which is what the drawing is at that size.

### Files

| File | Use |
| --- | --- |
| `docs/brand/source/*.jpeg` | The maintainer's three drawings, the only source of the mark |
| `docs/brand/svg/halflid-{idle,active,warning}.svg` | The traced mark as a single-colour vector (`currentColor`), with ports and feet |
| `docs/brand/png/app-icon-*.png` | The app icon at 1024 px, the graphite tile on the macOS icon grid (824 px of 1024) |
| `docs/brand/png/menubar-*@4x.png` | The menu bar image at four times (96 by 64 px), for documents |

The app bundle's icon is the active state. Where the drawings come from and under which terms they are released is in `NOTICE`.

### Rules

- Do not rotate, stretch, outline or add a shadow, a glow or a gradient. Do not put the mark on a busy photograph.
- Keep clear space around it equal to the height of the base of the laptop.
- The tile is flat. The mark is off-white on graphite, or a single colour on any plain background.
- The amber dot is the only colour in the mark and appears only in the warning state.

## Colour

| Name | Value | Where |
| --- | --- | --- |
| Graphite | `#25272A` | The app icon tile |
| Off-white | `#F0EDE6` | The mark on the tile |
| Amber | `#EDAB3D` | The warning dot |

The interface uses the system's semantic colours and the user's accent colour, so it follows light and dark and the
accessibility settings. It has no brand colour of its own beyond the amber warning, and no gradient, glow or purple.

## What the text may claim

Only what was measured or checked, with the date, the machine and the method, and in the words of `docs/FINDINGS.md`.

- Allowed, with the figures of the README table: memory at rest, CPU at rest, app size, no network connections, no account.
- Allowed, stated as one Mac on one macOS version: the Mac stays awake with the lid closed, on power and on battery in short
  runs; the screen locks and goes dark.
- Not allowed until it is verified: that it works on other macOS versions or on Intel; that a given agent is detected (only Cursor
  has been checked on a real install); that it survives hours, a flat battery, a forced power-off or a reboot; that
  notifications and Open at login work; that the app is notarized, "safe", or approved by Apple.
- About other tools: say what they document, never what they do badly.

## Naming the agents

Cursor, Claude Code, Codex, opencode, GitHub Copilot CLI and Goose are named and shown with their logos only to say which agent a
row is about. Say "watches" or "works with", never "official", "for" or "powered by". Where each logo comes from, under which licence,
and what to do if an owner objects is in `NOTICE`. The names and logos belong to their owners.
