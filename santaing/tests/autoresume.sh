#!/usr/bin/env bash
# Behavioural test for WATCH_AUTORESUME in watch-elves.sh and HB_QUIET in
# supervise-elves.sh. A fake `tmux` serves canned panes and a fake WATCH_TALK
# records what would have been sent, so nothing real is touched.
# Both directions: the capacity stall IS resumed silently; every other stall,
# and the default (mode off), are NOT.
set -u
HERE="$(cd "$(dirname "$0")/.." && pwd)"
WATCH="$HERE/watch-elves.sh"
SUPERVISE="$HERE/supervise-elves.sh"
W="$(mktemp -d)"
trap 'rm -rf "$W"' EXIT
pass=0; fail=0
check() { # name want(0=true) condition...
  local name="$1" want="$2"; shift 2
  if eval "$@"; then got=0; else got=1; fi
  if [ "$got" = "$want" ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "  FAIL $name (want=$want got=$got)"; fi
}

# fake tmux: has-session succeeds; capture-pane prints $W/panes/<session>.txt
mkdir -p "$W/bin" "$W/panes"
cat > "$W/bin/tmux" <<E
#!/bin/sh
case "\$1" in
  has-session) exit 0 ;;
  capture-pane) while [ "\$#" -gt 0 ]; do [ "\$1" = "-pt" ] || [ "\$1" = "-t" ] && { cat "$W/panes/\$2.txt"; exit 0; }; shift; done ;;
esac
exit 0
E
chmod +x "$W/bin/tmux"
cat > "$W/talk" <<E
#!/bin/sh
echo "\$*" >> "$W/talk.calls"
E
chmod +x "$W/talk"

CAPACITY_PANE='• Explored
  └ Read lib.rs
■ Selected model is at capacity. Please try a different model.
  GPT-6.1-Sol low · ~/workspace/x · x   Goal stalled (/goal resume)'
OTHER_PANE='• Explored
  └ Read lib.rs
■ Goal marked blocked pending a decision from the owner.
  GPT-6.1-Sol low · ~/workspace/x · x   Goal stalled (/goal resume)'

# run_watch <name> <pane> <seconds> [ENV=VAL ...]  -> $W/<name>.out, $W/talk.calls
run_watch() {
  local name="$1" pane="$2" secs="$3"; shift 3
  rm -f "$W/talk.calls" "$W/$name.log"
  printf '%s\n' "$pane" > "$W/panes/elfA.txt"
  env PATH="$W/bin:$PATH" WATCH_TALK="$W/talk" WATCH_TICK=1 WATCH_STAY=1 WATCH_IDLE_TICKS=2 \
      WATCH_STATE_DIR="$W/state-$name" WATCH_RESUME_LOG="$W/$name.log" WATCH_DISK_MIN_G=0 WATCH_FREE_MIN_PCT=0 "$@" \
      "$WATCH" "$W" elfA > "$W/$name.out" 2>&1 &
  local pid=$!
  sleep "$secs"
  kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
}
calls() { [ -f "$W/talk.calls" ] && wc -l < "$W/talk.calls" | tr -d ' ' || echo 0; }

# 1. Capacity stall, mode ON: resumed, rate-limited, and the watcher says nothing.
run_watch on "$CAPACITY_PANE" 5 WATCH_AUTORESUME=1 WATCH_RESUME_GAP=3
check "capacity stall is resumed"            0 '[ "$(calls)" -ge 1 ]'
check "resume sends /goal resume to the lane" 0 'grep -q "elfA -m /goal resume" "$W/talk.calls"'
check "resume is rate limited by the gap"    0 '[ "$(calls)" -le 2 ]'
check "resume is logged to the resume log"   0 'grep -q "auto-resumed elfA" "$W/on.log"'
check "resume emits NO event line"           1 'grep -q "resum" "$W/on.out"'
check "a resumed lane is not reported IDLE"  1 'grep -q "IDLE" "$W/on.out"'

# 2. Same pane, mode OFF (the default): nothing is sent.
run_watch off "$CAPACITY_PANE" 4
check "mode off sends nothing"               0 '[ "$(calls)" -eq 0 ]'

# 3. A different stall, mode ON: never resumed, and it still surfaces as IDLE.
run_watch other "$OTHER_PANE" 5 WATCH_AUTORESUME=1 WATCH_RESUME_GAP=1
check "another stall is not resumed"         0 '[ "$(calls)" -eq 0 ]'
check "another stall still raises IDLE"      0 'grep -q "IDLE elfA" "$W/other.out"'

# 4. A lane that never recovers: after RESUME_MAX resumes in a row, ONE STUCK event.
run_watch stuck "$CAPACITY_PANE" 7 WATCH_AUTORESUME=1 WATCH_RESUME_GAP=1 WATCH_RESUME_MAX=2
check "a lane that never recovers raises STUCK" 0 'grep -q "STUCK elfA" "$W/stuck.out"'
check "STUCK is raised once, not every tick"    0 '[ "$(grep -c "STUCK elfA" "$W/stuck.out")" -eq 1 ]'

# 5. HB_QUIET: heartbeats go to the log, not stdout; default prints them.
run_super() { # name quiet
  rm -f "$W/$1.log"
  printf '%s\n' "$CAPACITY_PANE" > "$W/panes/elfA.txt"
  env PATH="$W/bin:$PATH" WATCH_TALK="$W/talk" WATCH_TICK=1 HB_EVERY=1 HB_QUIET="$2" SUPERVISE_LOG="$W/$1.log" \
      WATCH_STATE_DIR="$W/state-$1" WATCH_DISK_MIN_G=0 WATCH_FREE_MIN_PCT=0 \
      "$SUPERVISE" "$W" elfA > "$W/$1.out" 2>&1 &
  local pid=$!
  sleep 4
  pkill -P "$pid" 2>/dev/null; kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
}
run_super quiet 1
check "HB_QUIET keeps heartbeats off stdout"   1 'grep -q HEARTBEAT "$W/quiet.out"'
check "HB_QUIET still logs heartbeats"         0 'grep -q HEARTBEAT "$W/quiet.log"'
run_super loud 0
check "default still prints heartbeats"        0 'grep -q HEARTBEAT "$W/loud.out"'

echo "pass=$pass fail=$fail"
[ "$fail" = 0 ]
