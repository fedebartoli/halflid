# Agents

Which coding agents Half Lid recognises, how it recognises them, what each rule rests on, which agents were looked at and
left out, and how to test or add one. Written on 2026-10-20. Status tags as in the other notes: **[OK]** checked on this Mac
(macOS 26.5.2, Apple Silicon), **[NOT VERIFIED]** written from public information only.

## How Half Lid decides that an agent is working

Half Lid never reads what an agent says or does. For a command-line agent it looks at four things, all of them from macOS
itself:

1. **The process.** Every running process has a name and the path of its executable. An agent is "running" when a process
   matches its entry in `Resources/agents.json` by exact name (`processNames`) or by a piece of the executable path
   (`pathContains`). Everything started by a matching process (its children) counts as part of the agent. Command-line
   arguments are never read: they can hold secrets.
2. **How busy it is.** CPU used by that process tree since the previous sample (every 5 seconds while Half Lid is holding the
   Mac, every 10 otherwise), as a share of one core.
3. **When its session files were last touched.** Only the modification time of the files under the agent's own session folder
   (`sessionPaths`). Never their contents.
4. Nothing else. No hooks are installed in any agent, no agent configuration is changed.

A running agent counts as **working** when the tree uses 15 % of one core or more, or a file in its session folder was written
in the last 30 seconds. Running but neither of these: **idle**. No matching process: **not running**. The numbers are in
`Sources/HalfLidCore/Loop/WorkDetector.swift` (`ProcessAgentRule`) and were calibrated with a simulated agent, not with the
real ones [NOT VERIFIED].

The session folders are walked only while a matching process exists, which is what keeps Half Lid at about 13 MB and nearly
no CPU when nothing is running.

**Cursor is the exception.** Its processes are busy both while a chat works and while it waits for your answer, so the process
table cannot tell them apart. Half Lid reads the status fields of Cursor's own chat database instead (read-only, never message
text). This was measured and checked on a real install [OK]; the details are in [FINDINGS.md](FINDINGS.md), section 2.

## The agents in the catalog

`verified` in `agents.json` is `true` only when the entry has been checked against the real agent on a real machine. The
Agents pane of Settings says "Not tested on a real install yet" under every agent whose entry is not verified.

| Agent | Recognised by | Session folder (times only) | What the rule rests on | Real install |
| --- | --- | --- | --- | --- |
| Cursor | the app (`/Cursor.app/`) and its command-line agent (`/cursor-agent/versions/`), plus the chat database | `~/.cursor/projects` | measured here | yes |
| Claude Code | `claude`, `claude.exe`; paths with `/@anthropic-ai/claude-code` or `/claude/versions/` | `~/.claude/projects` | install layouts, below | one partial report |
| Codex | `codex`; path with `/@openai/codex/` | `~/.codex/sessions` | install layouts, below | no |
| opencode | `opencode`, `opencode.exe` | `~/.local/share/opencode` | install layouts, below | no |
| GitHub Copilot CLI | `copilot` | `~/.copilot/session-state` | install layouts, below | no |
| Goose | `goose` | `~/.local/share/goose/sessions` and `~/Library/Application Support/Block/goose/sessions` | install layouts, below | no |

The session folders are the ones the agents document; none of them was looked at on this Mac.

### How each agent is installed, and what macOS then calls its process

macOS reports a process under the name of the **real file** it runs, after following symlinks (checked on this Mac with a
small test program: started as `bin/hlfake`, a link to `versions/9.9.9`, the process is `9.9.9` and its path is the real one;
`ps` shows the name it was started with, which is why `ps` and Half Lid can disagree). So the rules were written from how each
agent is packaged, as of 2026-10-20:

- **Claude Code.** The native installer (the recommended one) puts every release in `~/.local/share/claude/versions/<version>`
  and links `~/.local/bin/claude` to it ([setup guide](https://code.claude.com/docs/en/setup)). The process is therefore named
  after the version, for example `2.1.168`, never `claude` (see the bug reports
  [#12433](https://github.com/anthropics/claude-code/issues/12433) and
  [#49982](https://github.com/anthropics/claude-code/issues/49982)). That is why the entry also matches the path piece
  `/claude/versions/`. One real install agrees about the name (`2.1.304`, see "Reports received" below); the path piece has not
  been seen on a real Mac yet. The npm package runs `bin/claude.exe` (named in its `package.json`; the process is `claude.exe`), which
  its postinstall step links to the binary of a platform package (`@anthropic-ai/claude-code-darwin-arm64`); either way the
  path contains `/@anthropic-ai/claude-code`. The Homebrew cask installs a file called `claude`. The Claude desktop app is a
  different program and is not matched.
- **Codex.** The npm package starts, through a small Node.js shim (`bin/codex.js`), the native program
  `vendor/<target>/codex/codex` of its platform package (read in the shim's source); the Homebrew cask installs `bin/codex`.
  Both are called `codex`.
- **opencode.** The npm package `opencode-ai` runs `bin/opencode.exe`; the installer and the Homebrew formula give a file called
  `opencode`.
- **GitHub Copilot CLI.** The npm package `@github/copilot` starts the native `copilot` of its platform package; the Homebrew
  cask `copilot-cli` installs the same program. Older versions of the npm package were plain JavaScript and would run as
  `node` (see below).
- **Goose.** The `goose-cli` crate builds a program called `goose`.

All of this is written from package manifests, Homebrew definitions and public bug reports, not from running the agents.
`Tests/HalfLidCoreTests/AgentTests.swift` has one check per install shape, so a change to the catalog that breaks one of them
fails the tests; that proves the rules do what this page says, not that the agents are packaged the way this page says.

## Limits to know about

- **Programs written in JavaScript are not recognised.** An npm package that is a plain Node.js script runs as `node`, whatever
  script it is given, and Half Lid has no way to tell it from any other Node program without reading command lines, which it
  does not do. This is the reason Gemini CLI is not in the catalog (below). Where an agent ships a native program behind its
  Node shim (Claude Code, Codex, opencode, Copilot CLI), the native program is what Half Lid sees.
- **Goose has a namesake.** A database migration tool is also called `goose` (the Homebrew formula `goose`; the agent's formula
  is `block-goose-cli`). Half Lid matches by name, so while the Goose agent is switched on in Half Lid, a migration that uses
  15 % of a core or more would be taken for the agent working.
- **A fresh session file is a hint, not proof.** Whatever else writes into a session folder counts as activity for 30 seconds.
- **Another way to install an agent may look different.** A copy built from source, a company-managed install or a wrapper
  script can run under another name. The test report below is how those get found.

## Looked at and left out

| Agent | Why it is not in the catalog (2026-10-20) |
| --- | --- |
| Gemini CLI | Was in the catalog until this check. Its npm package and the Homebrew formula (which depends on `node`) are a Node.js script: the process is `node` ([a macOS check by another project](https://github.com/codeaholicguy/ai-devkit/pull/70) says the same). Nothing to match without reading command lines. |
| Qwen Code, Cline CLI | Node.js programs, same reason. |
| Aider | A Python program (the process is `Python`), and it keeps its history files inside each project folder, so there is no folder to watch. |
| Amp | Current versions keep their threads on the server; nothing is written locally to watch. |
| Droid (Factory) | A native program with a documented session folder, so it fits. Left out only because no logo under a free license was found; the first candidate to add. |
| Kiro CLI | A native program, but its documentation and the tools that read its data disagree about where sessions are stored. Waiting for someone with an install. |
| Crush | Keeps its sessions in a `.crush` folder inside each project, so there is no fixed folder to watch. |

A recognition mode for Node.js agents would have to be built on the session folder alone (no process to anchor it). That means
walking the folder all the time instead of only while a matching process exists, which costs the idle resources Half Lid is
careful about, and it has not been designed or tested. It is open to anyone who wants to try.

## Testing an agent on a real install

The catalog is only as good as the number of real installs it has met. A test takes about 15 minutes, needs no closed lid and
changes nothing on the Mac. Use a build of Half Lid 0.1.0 or later and fill in the "Agent test report" issue form (or send the
same answers any other way).

1. Install Half Lid. Open Settings, Agents: your agent should be listed with its switch on.
2. In the terminal tab where you will run the agent, run `tty` first. It prints something like `/dev/ttys004`. Write it down.
3. Start the agent in that tab and send it nothing. Wait ten seconds, click the Half Lid icon: the agent's row should say
   **Idle**. If it says **Not running**, Half Lid does not recognise this install: go to step 7, that is the useful result.
4. Give the agent a task that takes at least a minute (for example "read every file in this folder and write a short summary
   of each"). Within about 20 seconds the row should say **Working** and the menu bar icon should show that Half Lid is keeping
   the Mac awake. Write down how long it took.
5. When the agent has finished and waits for your next message, the row should go back to **Idle** within about a minute, and
   about two minutes later Half Lid should let go (the icon returns to its resting look).
6. Quit the agent. The row should say **Not running**.
7. Collect, in a second terminal tab, while the agent was running (step 3 or 4):

   ```sh
   ps -t ttys004 -o pid=,ppid=,ucomm=,comm=      # use the tty from step 2, without /dev/
   ```

   This prints, for the processes of that tab only, the process number, the parent, the name macOS gives each one and the path
   of what it runs. It does not print command lines. Your user name appears in some paths; replace it if you like. Also copy
   Settings, Diagnostics, Copy report (it has no paths and no chat text), the agent's version (`<agent> --version`) and how you
   installed it (native installer, npm, Homebrew, other).
8. Report each step as it happened (matched what is written above, or what you saw instead).

A passing report is what flips `verified` to `true` for that agent in `agents.json`, in a pull request that links the report.
A failing one is just as useful: the `ps` lines say what to match.

### Reports received

- **Claude Code 2.1.304, native installer (`curl -fsSL https://claude.ai/install.sh | bash`), macOS, 2026-10-20: partial.**
  The reporter wrote that the panel said "Fermo" (Idle in the Italian interface) with the agent started and sent nothing, which
  is what step 3 expects. `ps -t` for that tab showed the login shell, then the agent with the name `2.1.304` and the command
  name `claude`, and under the agent a child process `caffeinate`. So macOS did name the process after the version, as the
  section above says, and the agent starts a `caffeinate` of its own (Half Lid does not depend on it). Steps 4 to 6 (Working,
  back to Idle, Not running) have not been reported, and the exact path of the program was not in the output, so `verified`
  stays `false`.

## Adding an agent

1. Add an entry to `Resources/agents.json`: `id`, `processNames` and/or `pathContains` (the name macOS reports for the real
   file, see above), `sessionPaths`, `verified: false`, `mark`.
2. Add a monochrome mark, `Resources/agent-marks/<mark>.svg`: a `viewBox`, one or more plain `<path>` elements, nothing else.
   Use a logo under a license that allows it and say where it came from in the first lines of the file and in `NOTICE`.
3. Add `agent.<id>` (the display name) to all twelve files in `Resources/i18n`. The tests fail if one is missing.
4. Add the install shapes you know to `runProcessShapeTests` in `Tests/HalfLidCoreTests/AgentTests.swift`, and run
   `scripts/test.sh`.
5. Say in the pull request what the entry rests on. Without a test report it stays `verified: false`.
