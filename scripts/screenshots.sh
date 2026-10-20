#!/bin/bash
# Makes the pictures of the README (docs/screenshots) from the real programs, with sample data instead of anything of this Mac.
#
#   scripts/screenshots.sh [OUTPUT_DIR]
#
# The menu bar panel is drawn by its own preview mode (`HalfLidPanel --render`): no window, nothing on screen. It uses a flat
# background where the real panel is translucent.
#
# The settings window is the real one. It is started against sample files, stays on screen for a few seconds, and is photographed
# with `screencapture -l`, which takes that one window and nothing else of the screen. This needs Screen Recording to be allowed
# for the app that runs the script; the script checks first and never triggers the system prompt.
#
# A window only looks as it does when you use it (coloured switches and selection, lit traffic lights) while it is the active
# one, and macOS does not let a program started from a terminal take the focus from another app. So the Settings program is put
# in a small bundle of its own in a scratch folder, with another identifier than the installed app, and started with `open`, which
# does bring an app to the front. A picture is kept only if the window was still the active one when it was taken and is as large
# as asked (macOS makes a window shorter when it does not fit the usable part of the screen); otherwise it is thrown away and
# taken again, up to five times.
#
# The window is put on the screen with the most pixels to the point (HALFLID_WINDOW_SCREEN=sharpest), so the pictures are as sharp
# as a Retina screen shows them when this Mac has one; the script says so when it does not.
#
# A picture takes the keyboard focus for a few seconds, so the script starts one only when the keyboard and the mouse have been
# left alone for 10 seconds, and waits for that (up to ten minutes) if they have not.
#
# The sample runs send nothing to a running Half Lid (HALFLID_NO_CONTROL) and use a lock file of their own. They refuse to start
# while a Settings window of Half Lid is open.
set -euo pipefail
cd "$(dirname "$0")/.."

OUT="${1:-docs/screenshots}"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/halflid-shots.XXXXXX")"
SETTINGS_PID=""

# A window remembers its size and position, and the sizes of its panes, in the preferences of the user under the identifier of its
# bundle, and would open at that size the next time whatever size is asked for. So every try uses a bundle with an identifier of
# its own, which has nothing remembered, and the entries of all of them are removed at the end. None of them is the identifier
# of the installed app.
DOMAIN="io.github.fedebartoli.halflid.settings.pictures"
TRIES=0

cleanup() {
  if [ -n "$SETTINGS_PID" ]; then
    kill "$SETTINGS_PID" 2>/dev/null || true
    sleep 0.5 # let the program exit before its preferences are removed, or it could write them back
  fi
  local number
  for number in $(seq 1 "$TRIES"); do
    defaults delete "$DOMAIN.$number" >/dev/null 2>&1 || true
    rm -f "$HOME/Library/Preferences/$DOMAIN.$number.plist"
  done
  rm -rf "$WORK"
}
trap cleanup EXIT

if pgrep -x HalfLidSettings >/dev/null; then
  echo "A Settings window of Half Lid is open. Close it and run this again." >&2
  exit 1
fi

scripts/build.sh >/dev/null
swiftc -O scripts/window-id.swift -o "$WORK/window-id" 2>/dev/null
if ! "$WORK/window-id" --preflight; then
  echo "Screen Recording is not allowed for this app (System Settings, Privacy & Security). Nothing was captured." >&2
  exit 1
fi

# The real Settings program in a bundle of its own, so that `open` can start it (see the top of this file). Prints its path.
make_bundle() { # identifier
  local bundle="$WORK/Half Lid Settings ($1).app"
  mkdir -p "$bundle/Contents/MacOS"
  cp build/bin/HalfLidSettings "$bundle/Contents/MacOS/HalfLidSettings"
  cat > "$bundle/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>HalfLidSettings</string>
  <key>CFBundleIdentifier</key><string>$1</string>
  <key>CFBundleName</key><string>Half Lid Settings</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSPrincipalClass</key><string>NSApplication</string>
</dict></plist>
PLIST
  codesign --force --sign - "$bundle" >/dev/null 2>&1
  echo "$bundle"
}

front_pid() { # the process id of the app that has the focus
  lsappinfo info -only pid "$(lsappinfo front)" 2>/dev/null | sed -n 's/.*"pid"=\([0-9]*\).*/\1/p'
}
front_name() { # its name, for the messages
  lsappinfo info -only name "$(lsappinfo front)" 2>/dev/null | sed -n 's/.*"LSDisplayName"="\(.*\)".*/\1/p'
}

idle_seconds() { # since the last key or mouse event (0 when the Mac cannot say, which is the cautious answer)
  local nanoseconds
  nanoseconds="$(ioreg -c IOHIDSystem 2>/dev/null | sed -n 's/.*"HIDIdleTime" = \([0-9]*\).*/\1/p' | head -1)"
  echo $(( ${nanoseconds:-0} / 1000000000 ))
}

size_matches() { # width height requested(WIDTHxHEIGHT, or empty when no size was asked for): within two points
  [ -n "$3" ] || return 0
  local wider=$(( $1 - ${3%x*} )) taller=$(( $2 - ${3#*x} ))
  [ "${wider#-}" -le 2 ] && [ "${taller#-}" -le 2 ]
}

WAITED=0
wait_for_quiet() { # a picture takes the keyboard focus for a few seconds: not while someone is typing
  while [ "$(idle_seconds)" -lt 10 ]; do
    [ "$WAITED" = 0 ] && echo "Waiting until the keyboard and the mouse have been left alone for 10 seconds..." >&2
    WAITED=$((WAITED + 1))
    [ "$WAITED" -le 600 ] || { echo "The Mac stayed in use for ten minutes. Run this again when it is not." >&2; exit 1; }
    sleep 1
  done
}

# Sample data. The status names this script as the running menu bar app, so the window sees "a Half Lid that is keeping the Mac
# awake for Cursor and Claude Code".
echo '{"language": "en"}' > "$WORK/preferences.json"
cat > "$WORK/status.json" <<JSON
{"pid": $$, "armed": true, "indicator": "active", "title": "Keeping the Mac awake", "detail": "Claude Code and Cursor are working",
 "holdUntilStopped": false, "workingAgents": ["cursor", "claude-code"], "openAtLogin": "enabled", "notificationAccess": "allowed"}
JSON
VERSION="$(sed -n 's/^VERSION="${VERSION:-\(.*\)}"$/\1/p' scripts/make-app.sh)"
SAMPLE=(
  HALFLID_VERSION="$VERSION" # a build that is not installed has no version of its own to show
  HALFLID_RESOURCES="$PWD/Resources"
  HALFLID_PREFERENCES="$WORK/preferences.json"
  HALFLID_STATUS="$WORK/status.json"
  HALFLID_LAST_SESSION="$WORK/last-session.json"
  HALFLID_NO_CONTROL=1
  HALFLID_SETTINGS_LOCK="$WORK/settings.lock"
)

mkdir -p "$OUT"

panel() { # state appearance(light|dark)
  local flag=()
  [ "$2" = "dark" ] && flag=(--dark)
  env "${SAMPLE[@]}" build/bin/HalfLidPanel --render "$OUT/panel-$1-$2.png" --state "$1" ${flag[@]+"${flag[@]}"}
  echo "panel-$1-$2.png"
}

# One try at the picture of a Settings pane. Returns 0 only when the picture is clean; otherwise nothing of it is kept.
try_settings() { # pane appearance(light|dark) size(WIDTHxHEIGHT, optional)
  wait_for_quiet
  TRIES=$((TRIES + 1))
  local bundle
  bundle="$(make_bundle "$DOMAIN.$TRIES")"
  local variables=()
  for entry in "${SAMPLE[@]}" HALFLID_WINDOW_SCREEN=sharpest ${3:+HALFLID_WINDOW_SIZE="$3"}; do variables+=(--env "$entry"); done
  open -n "${variables[@]}" "$bundle" --args --section "$1" --appearance "$2"
  SETTINGS_PID=""
  for _ in $(seq 1 100); do
    SETTINGS_PID="$(pgrep -x HalfLidSettings | head -1 || true)"
    [ -n "$SETTINGS_PID" ] && break
    sleep 0.1
  done
  [ -n "$SETTINGS_PID" ] || { echo "the Settings program did not start" >&2; exit 1; }
  "$WORK/window-id" "$SETTINGS_PID" >/dev/null || { echo "the Settings window did not appear" >&2; exit 1; }
  for _ in $(seq 1 50); do
    [ "$(front_pid)" = "$SETTINGS_PID" ] && break
    sleep 0.1
  done

  local info id width height inside scale problem=""
  if [ "$(front_pid)" != "$SETTINGS_PID" ]; then
    problem="the window could not be brought to the front ($(front_name) has the focus)"
  else
    sleep 1.5 # the window opens with an animation, and the list fills in a moment later
    if info="$("$WORK/window-id" "$SETTINGS_PID")"; then
      read -r id width height inside scale <<< "$info"
      rm -f "$WORK/picture.png"
      /usr/sbin/screencapture -x -l "$id" "$WORK/picture.png"
      if [ "$(front_pid)" != "$SETTINGS_PID" ]; then
        problem="$(front_name) took the focus, so the window was greyed out"
      elif ! size_matches "$width" "$height" "${3:-}"; then
        problem="the window is $width by $height points, not the ${3:-} asked for"
      elif [ "$inside" != 1 ]; then
        problem="the window reaches beyond the usable part of the screen"
      fi
    else
      problem="the window was gone after a moment (a change of Space?)"
    fi
  fi

  kill "$SETTINGS_PID" 2>/dev/null || true
  while kill -0 "$SETTINGS_PID" 2>/dev/null; do sleep 0.1; done
  SETTINGS_PID=""
  if [ -n "$problem" ]; then
    echo "  not kept: $problem" >&2
    return 1
  fi
  mv "$WORK/picture.png" "$OUT/settings-$1-$2.png"
  [ "$scale" -ge 2 ] || echo "  note: no Retina screen found, this picture has one pixel to the point and is not as sharp" >&2
}

settings() {
  local attempt
  for attempt in 1 2 3 4 5; do
    if try_settings "$@"; then
      echo "settings-$1-$2.png"
      return 0
    fi
    sleep 2
  done
  echo "No clean picture of the $1 pane ($2) after five tries; the old one, if any, was left as it was." >&2
  echo "Something keeps taking the focus (a notification, or a change of Space). Run this again when the Mac is quiet." >&2
  exit 1
}

# Which pictures: the panel states and the settings panes, each in the light and the dark look. SHOTS_APPEARANCES narrows it.
for appearance in ${SHOTS_APPEARANCES:-light dark}; do
  for state in ${SHOTS_PANEL_STATES:-active hold stopped}; do panel "$state" "$appearance"; done
  for pane in ${SHOTS_SETTINGS_PANES:-agents safety}; do
    case "$pane" in
      agents) settings "$pane" "$appearance" 780x610 ;; # every agent with its two lines of text, shown whole
      safety) settings "$pane" "$appearance" 780x860 ;; # the longest pane, shown whole
      *) settings "$pane" "$appearance" ;;
    esac
  done
done
