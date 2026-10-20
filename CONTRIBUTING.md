# Contributing

Half Lid is small and is meant to stay small. Bug reports, agent test reports, translation fixes and focused pull requests are
welcome.

## Build and test

You need the Xcode Command Line Tools (`xcode-select --install`), not Xcode. There is no SwiftPM package and no Xcode project:
everything is built with `swiftc` by the scripts.

```sh
scripts/build.sh        # the four programs, in build/bin
scripts/test.sh         # builds a debug copy and runs every check; the exit code is 0 only if none failed
scripts/make-app.sh     # build/HalfLid.app. It replaces that folder: quit a copy of Half Lid that runs from there first.
```

`scripts/test.sh` must end with `0 failures`. Add checks for what you add. The tests use fakes for the clock, the battery, the
lid override and the screen, so running them never touches your lid or your display; what they cannot see is listed in the
README under "Does it work?".

## What a change has to keep

- **No third-party code, no network code, no new process that stays running.** Half Lid costs about 13 MB and almost no CPU
  when nothing is happening, and that is a feature.
- **It never reads what you say to an agent or what it answers**, never command lines, never the contents of an agent's files.
  Session folders are looked at for modification times only.
- **Every sentence the user can see is in all twelve files of `Resources/i18n`**, with the `{placeholders}` left as they are.
  The tests fail when a language lacks a key. No emojis in the interface; the marks and icons are drawn, not typed.
- **The interface follows the Mac:** semantic colours (light and dark), keyboard use, a label for every control for VoiceOver.
- **Say what you checked.** In code comments, notes and pull requests, separate "checked, on this Mac, this macOS" from "written
  from documentation". The notes in `docs/` use the tags **[OK]** (seen on a real Mac), **[NOT VERIFIED]** (read or inferred) and **[OPEN]** or
  **[PENDING TEST]** (still to be settled) for that.

## Things only a real Mac can show

- **The lid.** `scripts/lid-check.sh` watches a closure from outside and says whether the Mac kept running. The README explains
  how to tell whether a closure proves anything (an external monitor can hide it).
- **An agent.** `docs/AGENTS.md` has a 15-minute protocol for trying an agent on your own install and says how to add one. The
  "Agent test report" issue form takes the answers.
- **The pictures in the README.** `scripts/screenshots.sh` makes them from the real programs with sample data. It opens the
  Settings window for a few seconds at a time and takes the keyboard focus, so it starts only when you have left the keyboard and
  the mouse alone for 10 seconds, and it needs Screen Recording to be allowed for your terminal.

## Pull requests

One topic each. Say what you ran and what you did not. A change to how an agent is recognised needs a test report or a link to
the documentation it rests on (see `docs/AGENTS.md`).

A vulnerability is not a pull request or a public issue: see [SECURITY.md](SECURITY.md).
