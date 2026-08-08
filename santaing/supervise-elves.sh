#!/usr/bin/env bash
# Durable supervisor around santaing's watch-elves.sh.
#
# THE PROBLEM IT SOLVES: watch-elves.sh is edge-triggered, which is what keeps it
# from flooding context — but it means "nothing changed" and "the watcher is dead"
# produce the identical observation: silence. A monitor whose death is
# indistinguishable from its healthy quiet state is not a monitor.
#
# Three additions:
#   1. HEARTBEAT every HB_EVERY seconds, so silence longer than that is DIAGNOSTIC
#      rather than ambiguous. If no line arrives within ~2 heartbeats, it is dead.
#   2. A persistent append-only LOG, so events survive the harness task dying and
#      can be read back after the fact instead of being lost with it.
#   3. AUTO-RESTART: if watch-elves.sh exits for any reason, restart it and say so.
#      A restart is itself an event worth seeing.
#
# Usage: supervise-elves.sh <report-dir> <session>...
set -uo pipefail

REPORT_DIR="${1:?usage: supervise-elves.sh <report-dir> <session>...}"
shift
[ $# -gt 0 ] || { echo "usage: supervise-elves.sh <report-dir> <session>..." >&2; exit 2; }

WATCHER="${WATCHER:-$HOME/.claude/skills/santaing/watch-elves.sh}"
LOG="${SUPERVISE_LOG:-$REPORT_DIR/fleet-watch.log}"
HB_EVERY="${HB_EVERY:-600}"          # heartbeat cadence in seconds
SESSIONS=("$@")

[ -x "$WATCHER" ] || { echo "FATAL supervisor: $WATCHER not executable"; exit 2; }

emit() {  # one line -> stdout (an event) and the durable log
  local line="$1"
  printf '%s\n' "$line"
  printf '%s %s\n' "$(date -u +%H:%M:%SZ)" "$line" >> "$LOG"
}

emit "SUPERVISOR-UP watching ${SESSIONS[*]} (heartbeat ${HB_EVERY}s, log $LOG)"

last_hb=$(date +%s)
restarts=0

while true; do
  # Run the real watcher, streaming its lines through. It normally never exits
  # while WATCH_STAY=1, so reaching the end of this pipe means it died.
  WATCH_STAY=1 "$WATCHER" "$REPORT_DIR" "${SESSIONS[@]}" 2>&1 | while IFS= read -r line; do
    emit "$line"
  done

  restarts=$((restarts + 1))
  emit "WATCHER-EXITED restart #$restarts — the fleet watcher stopped on its own; restarting it"
  sleep 5

  now=$(date +%s)
  if [ $((now - last_hb)) -ge "$HB_EVERY" ]; then
    emit "HEARTBEAT supervisor alive, ${restarts} watcher restart(s)"
    last_hb=$now
  fi
done &
SUPERVISED=$!

# Independent heartbeat: fires even while the watcher is healthy and silent, so
# absence of ANY line for >2x HB_EVERY means the supervisor itself is gone.
while kill -0 "$SUPERVISED" 2>/dev/null; do
  sleep "$HB_EVERY"
  alive=0
  for s in "${SESSIONS[@]}"; do
    tmux has-session -t "$s" 2>/dev/null && alive=$((alive + 1))
  done
  emit "HEARTBEAT $alive/${#SESSIONS[@]} sessions alive"
done

emit "SUPERVISOR-DOWN inner loop exited"
