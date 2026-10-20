# Security

## Reporting a vulnerability

Please do not open a public issue for a vulnerability. Use GitHub's private reporting instead: open the **Security** tab of
this repository and choose **Report a vulnerability**. Only the maintainer sees what you send.

Half Lid is maintained by one person in spare time. There is no service level: expect a first answer within about a week, and a
fix once the problem is understood. If you want to be named in the release notes, say so in the report.

## What counts

Half Lid runs as your user. It needs no administrator rights, has no network code and installs no helper daemon, so the
interesting problems are about what another program on the Mac, or a file on the disk, can make it do:

- **The control channel and the guard.** Anything that makes Half Lid keep the Mac awake when it should not, or stops it (or its
  separate guard process) from putting the lid behaviour and the screen back. Note that any program running as your user can
  already send the control requests (`halflid start` and `halflid stop` use the same channel, and Settings can switch them
  off); that is the same trust boundary as the user's own account, so it is not a vulnerability by itself.
- **Files in `~/Library/Application Support/HalfLid`** (preferences, status, last session, saved brightness): anything that lets
  another user or program turn them into code execution, or makes Half Lid read or write somewhere else.
- **Reading what it should not.** Half Lid reads process names and paths, CPU use, modification times of an agent's session
  folder and, for Cursor, status fields of its chat database, read-only. A way to make it read or reveal message text, file
  contents or command-line arguments would be a vulnerability.
- **A download that does not match the source.** Anything in a release file or in the build scripts that is not in the
  repository.

## What does not count

These are known and written down in the [README](README.md): the app is signed ad hoc and not notarized; the call that makes
macOS ignore the closed lid is not documented by Apple and can change in any release; a Mac kept awake with the lid closed gets
warm and can run its battery down inside the limits you set; the agents' recognition has not been tested on real installs
([docs/AGENTS.md](docs/AGENTS.md)).

## Supported versions

Only the latest release.
