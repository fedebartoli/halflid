#!/bin/bash
# Checks what a closed lid really does to this Mac: does it keep running, or does it go to sleep?
#
#   scripts/lid-check.sh               records until the lid has been closed and opened again, then reports
#   scripts/lid-check.sh --seconds N   stops after N seconds whatever happens
#   scripts/lid-check.sh --no-network  skips the network probe
#   scripts/lid-check.sh --analyse F   reads a recording again (the file is named at the end of every run)
#
# Start it, close the lid, wait (a minute says more than ten seconds), open the lid, unlock the Mac. The report is waiting in
# the terminal. It ends by itself 10 seconds after the lid opens again; Ctrl+C ends it earlier. It only watches: it changes no
# setting and sends nothing to Half Lid.
#
# Three witnesses, because one alone can be fooled (docs/FINDINGS.md, section 1: after a lid close macOS keeps a Mac running
# for a short DarkWake window, so a heartbeat alone cannot tell "kept awake" from "about to sleep"):
#   - a heartbeat every second with the lid state (ioreg, AppleClamshellState). A Mac that sleeps freezes it: the gap is the sleep.
#   - the system power log (pmset -g log): macOS's own record of Sleep, DarkWake, Wake and display events.
#   - every 5 seconds, Half Lid's published state (armed or not), so a sleep that happened while Half Lid was idle is told
#     apart from one that happened while it was supposed to hold the Mac; and a request to captive.apple.com, the address
#     macOS itself uses to check connectivity, to see that the network answers. --no-network skips that request.
#
# After the closure it also reads macOS's unified log (log show: the kernel's PMRD lines and the power daemon's own lines) for
# the same minutes, to show what the lid-sleep override was when the lid closed and who changed it. That is how the hold that
# failed on 2026-10-19 was explained (docs/FINDINGS.md, section 1b). It needs no sudo; if the log cannot be read the report
# says so and the rest is unchanged.
#
# What it cannot show: that one particular agent finished its job. For that, give the agent a task longer than the closure.
set -u
PATH=/usr/bin:/bin:/usr/sbin:/sbin

GAP=5            # seconds without a heartbeat that mean "the Mac was not running"
SETTLE=10        # seconds after the lid opens again before the report
SAMPLE_EVERY=5   # seconds between Half Lid samples and network probes
PROBE_URL="http://captive.apple.com/hotspot-detect.html"
SCRATCH="${TMPDIR:-/tmp}"
SCRATCH="${SCRATCH%/}"
LOG="$SCRATCH/halflid-lid-check.log"
STATUS="$HOME/Library/Application Support/HalfLid/status.json"

usage() {
  cat <<'EOF'
usage: scripts/lid-check.sh [--seconds N] [--no-network]
       scripts/lid-check.sh --analyse FILE

Records the lid state, Half Lid's state and the network while you close and open the lid, then reports whether the Mac
kept running. See the top of this script for what it measures.
EOF
}

die() { echo "lid-check: $*" >&2; exit 2; }

# closed | open | none (no lid sensor, as on a desktop Mac). LID_CHECK_FAKE_LID names a file holding one of those words: it
# stands in for the sensor so the recording itself can be tested without touching a lid.
lid_state() {
  if [ -n "${LID_CHECK_FAKE_LID:-}" ]; then cat "$LID_CHECK_FAKE_LID" 2>/dev/null || echo none; return; fi
  ioreg -r -k AppleClamshellState -d 4 2>/dev/null | awk '
    /"AppleClamshellState" =/ { print ($NF == "Yes" ? "closed" : "open"); found = 1; exit }
    END { if (!found) print "none" }'
}

# armed | idle | off: what Half Lid published (off when it is not running: no status file, or its process is gone)
halflid_state() {
  local pid armed
  [ -r "$STATUS" ] || { echo off; return; }
  pid=$(plutil -extract pid raw -o - "$STATUS" 2>/dev/null) || { echo off; return; }
  kill -0 "$pid" 2>/dev/null || { echo off; return; }
  armed=$(plutil -extract armed raw -o - "$STATUS" 2>/dev/null)
  if [ "$armed" = true ]; then echo armed; else echo idle; fi
}

halflid_detail() {
  plutil -extract detail raw -o - "$STATUS" 2>/dev/null
}

# While Half Lid holds the Mac, is the running build the one that applies the lid override several times a second (the keeper), or
# an older one that does it once a minute? The kernel logs one line per call, so the last few seconds of the system log tell.
# Prints nothing when the log cannot be read. LID_CHECK_FAKE_LOG stands in for it in tests.
keeper_note() {
  local out n window=6
  if [ -n "${LID_CHECK_FAKE_LOG:-}" ]; then
    out=$(cat "$LID_CHECK_FAKE_LOG" 2>/dev/null) || return 0
  else
    out=$(/usr/bin/log show --last "${window}s" --info --debug --style compact --predicate \
          'process == "kernel" AND eventMessage BEGINSWITH "PMRD: setClamShellSleepDisable"' 2>/dev/null) || return 0
  fi
  n=$(printf '%s\n' "$out" | grep -c 'setClamShellSleepDisable')
  case "$n" in ''|*[!0-9]*) return 0 ;; esac
  if [ "$n" -ge 8 ]; then
    echo "  It applies the lid override about $((n / window)) times a second: this is the build with the keeper."
  else
    echo "  Only $n override calls were logged in the last $window seconds; the build with the keeper makes about 24. This looks like an"
    echo "  older build that applies it once a minute: quit Half Lid and open the new one first, or this run can fail the way the last one did."
  fi
}

probe_once() {
  local t result
  t=$(date +%s)
  if curl -s -m 4 -o /dev/null "$PROBE_URL"; then result=up; else result=down; fi
  echo "N $t $result" >> "$LOG"
}

# What the kernel and the power daemon logged about the lid-sleep override between two local times. Prints report lines: the
# first goes next to the label, the others below it; every line starts with "L ". Lines starting with "@" are facts for the
# verdict. The override is a flag in the kernel (xnu: clamshellSleepDisableMask) that Half Lid sets and that powerd also writes.
flag_analysis() {
  local from="$1" to="$2" runstart="${3:-}" raw err
  raw=$(mktemp "$SCRATCH/halflid-lid-check-log.XXXXXX") || return 0
  err=$(mktemp "$SCRATCH/halflid-lid-check-logerr.XXXXXX") || { rm -f "$raw"; return 0; }
  [ -t 2 ] && [ -z "${LID_CHECK_FAKE_LOG:-}" ] && echo "  reading macOS's system log for that window..." >&2
  # LID_CHECK_FAKE_LOG names a file in the format of log show --style compact: it stands in for the system log, so the reading
  # of it can be tested with lines written by hand.
  if [ -n "${LID_CHECK_FAKE_LOG:-}" ]; then cat "$LID_CHECK_FAKE_LOG" > "$raw" 2> "$err"
  elif ! /usr/bin/log show --start "$from" --end "$to" --info --debug --style compact --predicate \
       'process == "powerd" OR (process == "kernel" AND eventMessage BEGINSWITH "PMRD: ") OR (process == "WindowServer" AND eventMessage CONTAINS "Display:Hotplug")' \
       > "$raw" 2> "$err"; then
    echo "L not readable: macOS refused the request ($(head -n 1 "$err" | cut -c1-70))"
    rm -f "$raw" "$err"
    return 0
  fi
  awk -v runstart="$runstart" '
    function secs(t,   p) { split(t, p, ":"); return p[1] * 3600 + p[2] * 60 + p[3] }
    function tidof(proc) { if (match(proc, /:[0-9a-f]+\]$/)) return substr(proc, RSTART + 1, RLENGTH - 2); return "" }
    function ago(x) { return (x < 1 ? sprintf("%d ms", x * 1000 + 0.5) : sprintf("%.2f s", x)) }
    function owner(tid) { return ((tid in ptid) ? "powerd" : "another process") }
    function add(kind, t, clk, a, b, tid, x) { n++; k[n] = kind; et[n] = t; ec[n] = clk; ea[n] = a; eb[n] = b; etid[n] = tid; ex[n] = x }
    function out(s) { lines++; text[lines] = s }
    # macOS repeats the closed message at every DarkWake of a Mac whose lid stays closed: only a change counts.
    BEGIN { lid = -1 }
    $1 ~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]$/ {
      if (d0 == "") d0 = $1
      t = ($1 == d0 ? 0 : 86400) + secs($2)
      clk = substr($2, 1, 12)
      proc = $4; tid = tidof(proc)
      msg = substr($0, index($0, $4) + length($4) + 1)
      if (proc ~ /^powerd\[/) {
        ptid[tid] = 1; np++
        if (msg ~ /ClamshellState\. Closed : [01]\. ClamshellSleepState: isSleepDisabled : [0-9]+/) {
          x = msg; sub(/^.*isSleepDisabled : /, "", x); add("pstate", t, clk, x + 0, "", tid, "")
        } else if (msg ~ /DesktopMode set [01] with battery/) {
          x = msg; sub(/^.*DesktopMode set /, "", x); sub(/ .*$/, "", x); add("dmode", t, clk, x + 0, "", tid, "")
        }
        next
      }
      if (proc ~ /^kernel\[/) {
        pm++
        if (msg ~ /^PMRD: setClamShellSleepDisable\(/) {
          x = msg; sub(/^PMRD: setClamShellSleepDisable\(/, "", x); sub(/\).*$/, "", x)
          split(x, ab, "->")
          if (ab[1] != ab[2]) add("flag", t, clk, ab[1] + 0, ab[2] + 0, tid, "")
        } else if (msg ~ /^PMRD: Clamshell closed/) { if (lid != 1) add("closed", t, clk, "", "", tid, ""); lid = 1 }
        else if (msg ~ /^PMRD: Clamshell opened/) { if (lid != 0) add("opened", t, clk, "", "", tid, ""); lid = 0 }
        else if (msg ~ /^PMRD: clamshell closed [01], disabled [0-9]+\/[0-9]+, desktopMode [0-9]+, ac [0-9]+/) {
          if (n > 0 && k[n] == "closed" && ex[n] == "") {
            x = msg; sub(/^PMRD: clamshell closed [01], disabled /, "", x)
            split(x, q, /[\/,]/)
            dm = q[3]; sub(/[^0-9]+/, "", dm); ac = q[4]; sub(/[^0-9]+/, "", ac)
            ex[n] = q[2] "," dm "," ac
          }
        } else if (msg ~ /^PMRD: sleep reason Clamshell Sleep/) add("sleep", t, clk, "", "", tid, "")
        next
      }
      if (proc ~ /^WindowServer\[/ && msg ~ /Inserting hotplug event for state/) {
        st = msg; sub(/^.*state "/, "", st); sub(/".*$/, "", st)
        id = msg; sub(/^.*display id: /, "", id); sub(/[^0-9].*$/, "", id)
        add("hotplug", t, clk, st, id, tid, "")
      }
    }
    END {
      if (pm == 0 && np == 0) {
        print "L nothing in the system log for this window (macOS keeps these lines only a few days, or this account cannot read them)"
        exit
      }
      if (pm == 0) {
        print "L no lid or override event was logged in this window"
        printf "@closures=0\n"
        exit
      }
      out("system log, from 2 minutes before the check: ON = lid ignored (what Half Lid sets), OFF = closing it sleeps the Mac")
      mask = -1; lastflag = 0; rs = -1
      if (runstart != "") { split(runstart, rp, " "); rs = (rp[1] == d0 ? 0 : 86400) + secs(rp[2]) }
      for (i = 1; i <= n; i++) {
        if (k[i] == "flag") { mask = eb[i]; lastflag = i; nflag++; continue }
        if (k[i] != "closed") continue
        if (rs >= 0 && et[i] < rs) continue
        closures++
        lmask = mask; dm = "?"; ac = "?"
        if (ex[i] != "") { split(ex[i], q, ","); lmask = q[1] + 0; dm = q[2]; ac = q[3] }
        slept = 0; afterclear = 0
        for (j = i + 1; j <= n && et[j] - et[i] <= 2; j++) {
          if (k[j] == "sleep") slept = 1
          if (k[j] == "flag" && eb[j] == 0 && !afterclear) afterclear = j
        }
        if (slept) nslept++
        ps = ""; dmv = ""
        for (j = i + 1; j <= n && et[j] - et[i] <= 0.2; j++) if (k[j] == "pstate") { ps = ea[j]; break }
        for (j = 1; j <= n; j++) if (k[j] == "dmode" && et[j] >= et[i] - 2 && et[j] <= et[i] + 0.5) dmv = ea[j]
        head = sprintf("closure %d at %s: override %s when the lid closed", closures, substr(ec[i], 1, 8), (lmask < 0 ? "state unknown" : (lmask == 0 ? "OFF" : "ON")))
        if (slept) head = head (lmask > 0 ? ", yet the Mac slept" : ", and the Mac slept")
        else head = head (lmask == 0 ? ", but no sleep followed (desktop mode " dm ", power adapter " ac ")" : ", and no sleep followed")
        extra = ""
        if (ps != "") extra = "own state " ps
        if (dmv != "") extra = extra (extra != "" ? ", " : "") "desktop mode " (dmv == 1 ? "on" : "off") " around the close"
        if ((ps != "" && ps + 0 != 0) || dmv == "1") busy++
        if (ps != "" && ps + 0 == 0 && dmv != "1" && dm != "1") clean++
        out(head)
        if (extra != "") out("  powerd: " extra)
        if (lmask == 0) {
          noff++
          if (lastflag > 0 && lastflag < i && eb[lastflag] == 0) {
            by = owner(etid[lastflag])
            line = sprintf("  turned off by %s at %s, %s before the lid closed", by, ec[lastflag], ago(et[i] - et[lastflag]))
            for (h = lastflag - 1; h >= 1 && et[lastflag] - et[h] <= 4; h--)
              if (k[h] == "hotplug") { line = line sprintf(" (display %s went %s at %s)", eb[h], (ea[h] == "out" ? "away" : "back"), ec[h]); break }
            out(line)
            if (by == "powerd") powerd_before++
          } else if (nflag == 0) out("  nobody changed it in this window, so it was off from the start")
          else out("  it was off after its last change in this window")
        } else if (lmask > 0) {
          if (afterclear) {
            nafter++
            out(sprintf("  turned off by %s at %s, %s AFTER the lid closed: nothing can put it back in time", owner(etid[afterclear]), ec[afterclear], ago(et[afterclear] - et[i])))
          } else {
            # ON at the close: was it turned off shortly before and put back?
            for (h = i - 1; h >= 1 && et[i] - et[h] <= 6; h--) {
              if (k[h] == "flag" && eb[h] > 0 && ea[h] == 0) {
                for (g = h - 1; g >= 1 && et[h] - et[g] <= 6; g--)
                  if (k[g] == "flag" && eb[g] == 0) {
                    restored++
                    out(sprintf("  %s turned it off at %s, %s turned it back on %s later, before the lid closed", owner(etid[g]), ec[g], owner(etid[h]), ago(et[h] - et[g])))
                    break
                  }
                break
              }
            }
          }
        }
      }
      if (closures == 0) out(nflag == 0 ? "no change of the override and no lid closing logged in this window" : "the override changed " nflag " time" (nflag == 1 ? "" : "s") " in this window; the lid closing was not logged")
      if (n > 0) {
        out("history (changes only):")
        shown = 0; lastdm = ""
        marked = 0
        for (i = 1; i <= n; i++) {
          if (k[i] == "flag") m = sprintf("override %s (%d -> %d) by %s", (eb[i] == 0 ? "OFF" : "ON"), ea[i], eb[i], owner(etid[i]))
          else if (k[i] == "closed") m = "lid closed"
          else if (k[i] == "opened") m = "lid opened"
          else if (k[i] == "sleep") m = "macOS starts a lid sleep"
          else if (k[i] == "pstate") continue
          else if (k[i] == "dmode") { if (ea[i] == lastdm) continue; lastdm = ea[i]; m = "desktop mode " (ea[i] == 1 ? "on" : "off") }
          else m = sprintf("display %s went %s", eb[i], (ea[i] == "out" ? "away" : "back"))
          if (rs >= 0 && !marked && et[i] >= rs) { marked = 1; if (shown > 0) out("  ---- the check starts at " substr(runstart, 12) " ----") }
          if (shown < 16) out("  " ec[i] "  " m)
          shown++
        }
        if (rs >= 0 && !marked && shown > 0) out("  ---- the check starts at " substr(runstart, 12) " ----")
        if (shown > 16) out("  ... " (shown - 16) " more")
      }
      for (i = 1; i <= lines; i++) print "L " text[i]
      printf "@closures=%d\n@slept=%d\n@off=%d\n@after=%d\n@powerd_before=%d\n@restored=%d\n@busy=%d\n@clean=%d\n", closures, nslept, noff, nafter, powerd_before, restored, busy, clean
    }' "$raw"
  rm -f "$raw" "$err"
}

# The report. The recording holds three kinds of line:  T <epoch> <closed|open|none>   H <epoch> <armed|idle|off>
# N <epoch> <up|down>  (the time a probe started).
analyse() {
  local log="$1" first last from to power flagfile
  [ -s "$log" ] || die "nothing recorded in $log"
  first=$(awk '$1 == "T" { print $2; exit }' "$log")
  last=$(awk '$1 == "T" { t = $2 } END { print t }' "$log")
  [ -n "$first" ] || die "no heartbeat in $log"
  from=$(date -r $((first - 2)) '+%Y-%m-%d %H:%M:%S')
  to=$(date -r $((last + 2)) '+%Y-%m-%d %H:%M:%S')
  power=$(mktemp "$SCRATCH/halflid-lid-check-power.XXXXXX") || die "cannot create a temporary file"

  # What macOS itself logged in that window: sleep, wake, darkwake and display on or off.
  pmset -g log 2>/dev/null | awk -v from="$from" -v to="$to" '
    $1 ~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]$/ {
      ts = $1 " " $2
      if (ts < from || ts > to) next
      kind = $4
      if (kind == "Sleep" || kind == "DarkWake" || (kind == "Wake" && $5 != "Requests") ||
          (kind == "Notification" && $0 ~ /Display is turned/)) {
        i = index($0, "\t")
        msg = substr($0, i + 1)
        gsub(/[ \t]+$/, "", msg)
        gsub(/[ \t]+/, " ", msg)
        print $2 "  " (length(msg) > 104 ? substr(msg, 1, 101) "..." : msg)
      }
    }' > "$power"

  flagfile=$(mktemp "$SCRATCH/halflid-lid-check-flag.XXXXXX") || die "cannot create a temporary file"
  # Two and a half minutes before the first heartbeat are read too: a monitor unplugged just before the check, and what the
  # override did then, is part of the evidence. Closures before the check are ignored; the history says where it starts.
  ctx_from=$(date -r $((first - 150)) '+%Y-%m-%d %H:%M:%S')
  flag_analysis "$ctx_from" "$to" "$from" > "$flagfile"

  awk -v gap="$GAP" -v every="$SAMPLE_EVERY" -v pf="$power" -v ff="$flagfile" '
    function span(s,   m, h) {
      if (s < 60) return s " s"
      m = int(s / 60); s = s - m * 60
      if (m < 60) return m " min " sprintf("%02d", s) " s"
      h = int(m / 60); m = m - h * 60
      return h " h " sprintf("%02d", m) " min"
    }
    function clock(t,   cmd, out) {
      cmd = "date -r " t " +%H:%M:%S"; out = ""
      cmd | getline out
      close(cmd)
      return out
    }
    function inside(t,   e) {
      for (e = 1; e <= episodes; e++) if (t >= es[e] && t <= ee[e]) return 1
      return 0
    }
    # Half Lid state at the last sample taken at or before t (the first sample if there is none before).
    function stateat(t,   i, st) {
      st = hstate[1]
      for (i = 1; i <= ht; i++) if (htime[i] <= t) st = hstate[i]
      return st
    }
    FNR == NR {
      if ($1 == "T") {
        t = $2 + 0; lid = $3; n++
        if (n == 1) first = t
        if (n > 1) {
          d = t - prev
          if (d > maxgap) maxgap = d
          if (d > gap) {
            gaps++; gs[gaps] = prev; ge[gaps] = t
            if (prevlid == "closed" || lid == "closed") gclosed++; else gopen++
          }
        }
        if (lid == "none") nolid++
        if (lid == "closed") {
          closedticks++
          if (!inclosed) { episodes++; es[episodes] = t; inclosed = 1 }
          ee[episodes] = t
        } else if (inclosed) {
          ee[episodes] = t; inclosed = 0
        }
        prev = t; prevlid = lid; last = t
      } else if ($1 == "N") { nt++; ntime[nt] = $2 + 0; nres[nt] = $3 }
      else if ($1 == "H") { ht++; htime[ht] = $2 + 0; hstate[ht] = $3 }
      next
    }
    FILENAME == pf {
      pw++; pline[pw] = $0
      if ($0 ~ /Clamshell Sleep/) clam++
      if ($0 ~ /Entering Sleep state due to .Clamshell Sleep/) realsleep++
      if ($0 ~ /Entering DarkWake state due to .Clamshell Sleep/) darkclam++
      if ($0 ~ /Entering Sleep|Entering DarkWake|DarkWake from|Wake from/) sleepev++
      next
    }
    FILENAME == ff {
      if ($0 ~ /^@/) { split(substr($0, 2), kv, "="); fact[kv[1]] = kv[2] + 0 }
      else if ($0 ~ /^L /) { fl++; fline[fl] = substr($0, 3) }
      next
    }
    END {
      for (e = 1; e <= episodes; e++) closedspan += ee[e] - es[e]
      for (i = 1; i <= nt; i++) if (inside(ntime[i])) { nc++; if (nres[i] == "up") ncup++ }
      for (i = 1; i <= nt; i++) if (nres[i] == "up") nup++
      for (i = 1; i <= ht; i++) if (inside(htime[i])) { hc++; hcount[hstate[i]]++ }
      hb_all_armed = (hc > 0 && hcount["armed"] == hc)

      printf "\nLid check  %s to %s  (%s)\n\n", clock(first), clock(last), span(last - first)

      if (episodes == 0) printf "  Lid closed     never seen closed by the heartbeat\n"
      else {
        printf "  Lid closed     %s, %d time%s\n", span(closedspan), episodes, (episodes == 1 ? "" : "s")
        for (e = 1; e <= episodes && e <= 5; e++)
          printf "                 %s to %s  (%s)\n", clock(es[e]), clock(ee[e]), span(ee[e] - es[e])
      }

      if (gaps == 0) printf "  Heartbeat      ran every second, longest gap %d s\n", maxgap
      else {
        printf "  Heartbeat      stopped %d time%s (no tick for more than %d s)\n", gaps, (gaps == 1 ? "" : "s"), gap
        for (g = 1; g <= gaps && g <= 5; g++)
          printf "                 %s to %s  (%s)\n", clock(gs[g]), clock(ge[g]), span(ge[g] - gs[g])
      }

      if (hc > 0) {
        if (hcount["armed"] == hc) printf "  Half Lid       armed on %s taken while the lid was closed\n", (hc == 1 ? "the one sample" : "all " hc " samples")
        else printf "  Half Lid       armed on %d of %d samples taken while the lid was closed (idle on %d, not running on %d)\n", hcount["armed"], hc, hcount["idle"], hcount["off"]
      } else if (ht > 0) printf "  Half Lid       %s at the start, %s at the end%s\n", hstate[1], hstate[ht], (episodes > 0 ? " (no sample fell inside a closure)" : "")
      else printf "  Half Lid       not sampled\n"

      if (nt == 0) printf "  Network        not probed\n"
      else if (nc > 0) {
        printf "  Network        %d of %d probes answered while the lid was closed\n", ncup, nc
        shown = 0
        for (i = 1; i <= nt && shown < 3; i++)
          if (inside(ntime[i]) && nres[i] != "up") { printf "                 no answer at %s\n", clock(ntime[i]); shown++ }
      } else if (episodes == 0) printf "  Network        %d of %d probes answered (the lid was never seen closed)\n", nup, nt
      else printf "  Network        %d of %d probes answered in all; none fell inside a closure (closed under %d s)\n", nup, nt, every

      if (pw == 0) printf "  Power log      no sleep, wake or display event logged in this window\n"
      else {
        printf "  Power log      %d event%s logged by macOS:\n", pw, (pw == 1 ? "" : "s")
        for (i = 1; i <= pw && i <= 12; i++) printf "                 %s\n", pline[i]
        if (pw > 12) printf "                 ... %d more\n", pw - 12
      }

      if (fl > 0) {
        printf "  Override       %s\n", fline[1]
        for (i = 2; i <= fl; i++) printf "                 %s\n", fline[i]
      }

      printf "\n"
      # A heartbeat that stops is only called a sleep when macOS logged one too: a very busy Mac can miss a few ticks.
      # The kernel line "sleep reason Clamshell Sleep" (system log section) counts as much as a sleep in the power log.
      slept = (clam > 0 || fact["slept"] > 0 || (gclosed > 0 && sleepev > 0))
      if (n == 0) print "Verdict: nothing was recorded."
      else if (nolid == n) print "Verdict: this Mac reports no lid state (a desktop Mac?), so there is nothing to check."
      else if (slept) {
        print "Verdict: the Mac went to sleep with the lid closed."
        t0 = (gaps > 0 ? gs[1] : (episodes > 0 ? es[1] : last))
        hb = (ht > 0 ? stateat(t0) : "")
        if (hb == "armed")
          print "         Half Lid said it was holding the Mac when it went to sleep, so this is the hold failing. Keep this report."
        else if (hb == "idle")
          print "         Half Lid was running but not holding the Mac then, so sleeping is what macOS is meant to do."
        else if (hb == "off")
          print "         Half Lid was not running then, so sleeping is what macOS is meant to do."
        else
          print "         Half Lid was not sampled, so this cannot tell whether it was supposed to hold the Mac."
        if (hb == "armed" && fact["powerd_before"] > 0)
          printf "         The system log says why: macOS'"'"'s power daemon turned the override off before the lid closed (%d of %d closures).\n", fact["powerd_before"], fact["closures"]
        else if (hb == "armed" && fact["after"] > 0)
          print "         The system log says the override was turned off after the lid had closed, which Half Lid cannot undo in time."
        else if (hb == "armed" && fact["off"] > 0)
          print "         The system log shows the override was already off when the lid closed, and nobody turned it off in this window."
        if (realsleep > 0)
          printf "         macOS logged %d real sleep%s because of the lid (everything frozen)%s.\n", realsleep, (realsleep == 1 ? "" : "s"), (darkclam > 0 ? sprintf(" and %d DarkWake window%s (display off, processes running)", darkclam, (darkclam == 1 ? "" : "s")) : "")
        else if (gaps == 0)
          print "         The heartbeat never stopped, so the Mac was only partly asleep (a DarkWake: display off, processes still running)."
      } else if (gclosed > 0) {
        print "Verdict: not conclusive. The heartbeat stopped around a closure, but macOS logged no sleep or wake in that time."
        print "         The Mac may only have been very busy. Run it again; if it keeps happening, keep this report."
      } else if (closedticks == 0) {
        print "Verdict: nothing to conclude, the lid was never seen closed while this ran. Run it again and close the lid."
        if (gopen > 0) printf "         The heartbeat did stop %d time%s with the lid open, which has nothing to do with the lid.\n", gopen, (gopen == 1 ? "" : "s")
      } else {
        printf "Verdict: the Mac stayed awake with the lid closed for %s: the check ran every second and macOS logged no sleep.\n", span(closedspan)
        if (fact["restored"] > 0)
          printf "         The system log shows macOS'"'"'s power daemon turned the override off before %d closure%s and %s turned it back on in time.\n", fact["restored"], (fact["restored"] == 1 ? "" : "s"), (hc > 0 && hcount["armed"] == hc ? "Half Lid (armed all through)" : "another process")
        if (nc > 0 && ncup == nc) print "         The network answered every probe during the closure."
        else if (nc > 0) printf "         The network failed %d of %d probes during the closure.\n", nc - ncup, nc
        if (gopen > 0) printf "         The heartbeat also stopped %d time%s with the lid open, which has nothing to do with the lid.\n", gopen, (gopen == 1 ? "" : "s")
        if (hb_all_armed && fact["busy"] > 0) {
          printf "         But the power daemon of macOS reported a non-zero own state, or desktop mode on, at %d of %d closures:\n", fact["busy"], fact["closures"]
          print "         this run does not show that Half Lid alone kept the Mac awake. Repeat the same closures with Half Lid"
          print "         not holding: if the Mac then sleeps, this pass was the work of Half Lid."
        } else if (hb_all_armed && fact["closures"] > 0 && fact["clean"] == fact["closures"]) {
          print "         The power daemon held nothing itself at these closures (own state 0, desktop mode off), so what kept the"
          print "         Mac awake was the override that Half Lid keeps applying."
        } else if (hb_all_armed) {
          print "         A pass means something only if the same closures put the Mac to sleep when Half Lid is not holding it:"
          print "         repeat them once like that."
        } else if (hc > 0 && hcount["armed"] == 0) {
          print "         Half Lid was not holding the Mac, yet it stayed awake: something else kept it awake (an external display"
          print "         in use on power does that, and so does another app). A closure does not test Half Lid in this setup."
        }
        if (closedspan < 20) print "         That is a short closure; close it for a minute or more to be sure."
        print "         This shows the Mac and the network kept running, not that a given agent finished: give it a task longer than the closure."
      }
    }' "$log" "$power" "$flagfile"
  rm -f "$power" "$flagfile"
}

interrupted=0
seconds=0
network=1
analyse_file=""
while [ $# -gt 0 ]; do
  case "$1" in
    --seconds) [ $# -ge 2 ] || die "--seconds needs a number"; seconds="$2"; shift 2 ;;
    --no-network) network=0; shift ;;
    --analyse|--analyze) [ $# -ge 2 ] || die "--analyse needs a file"; analyse_file="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
done
case "$seconds" in ''|*[!0-9]*) die "--seconds needs a whole number" ;; esac

if [ -n "$analyse_file" ]; then
  analyse "$analyse_file"
  exit 0
fi

lid=$(lid_state)
if [ "$lid" = none ]; then
  echo "This Mac reports no lid state (a desktop Mac?), so there is nothing to check."
  exit 0
fi

: > "$LOG" || die "cannot write $LOG"
trap 'interrupted=1' INT TERM

echo "Half Lid lid check"
case "$(halflid_state)" in
  armed) detail=$(halflid_detail); echo "  Half Lid is holding the Mac awake${detail:+ ($detail)}."; keeper_note ;;
  idle)  echo "  Half Lid is running but not holding the Mac awake: closing the lid now should put the Mac to sleep." ;;
  *)     echo "  Half Lid is not running: closing the lid now should put the Mac to sleep." ;;
esac
if [ "$network" = 1 ]; then
  echo "  Every $SAMPLE_EVERY seconds a request goes to captive.apple.com, the address macOS itself uses to check the network."
fi
echo "  Close the lid, wait as long as you like, open it and unlock the Mac. The report ends this by itself."
echo

started=$(date +%s)
tick=0
seen_closed=0
reopened_at=0
closed_total=0
while :; do
  now=$(date +%s)
  lid=$(lid_state)
  echo "T $now $lid" >> "$LOG"
  if [ "$lid" = closed ]; then
    seen_closed=1; reopened_at=0; closed_total=$((closed_total + 1))
  elif [ "$seen_closed" = 1 ] && [ "$reopened_at" = 0 ]; then
    reopened_at=$now
  fi
  if [ $((tick % SAMPLE_EVERY)) -eq 0 ]; then
    echo "H $now $(halflid_state)" >> "$LOG"
    if [ "$network" = 1 ]; then probe_once & fi
  fi
  if [ -t 1 ]; then
    printf '\r\033[K  lid %-6s %4d s recorded, %d s closed' "$lid" $((now - started)) "$closed_total"
  fi
  [ "$interrupted" = 1 ] && break
  if [ "$seconds" -gt 0 ] && [ $((now - started)) -ge "$seconds" ]; then break; fi
  if [ "$reopened_at" -gt 0 ] && [ $((now - reopened_at)) -ge "$SETTLE" ]; then break; fi
  sleep 1
  tick=$((tick + 1))
done
[ -t 1 ] && printf '\n'
wait   # a probe still in flight ends within its 4 second limit
trap - INT TERM

analyse "$LOG"
echo
echo "Recording: $LOG  (read it again with: scripts/lid-check.sh --analyse $LOG)"
