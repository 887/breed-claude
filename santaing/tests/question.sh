#!/usr/bin/env bash
# Behavioural test for the QUESTION signal in watch-elves.sh: a Codex lane with a
# pending question is reported even while a background terminal reads as working;
# a plain working pane is not.
set -u
HERE="$(cd "$(dirname "$0")/.." && pwd)"
WATCH="$HERE/watch-elves.sh"
W="$(mktemp -d)"
trap 'rm -rf "$W"' EXIT
pass=0; fail=0
check() { local name="$1" want="$2"; shift 2
  if eval "$@"; then got=0; else got=1; fi
  if [ "$got" = "$want" ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "  FAIL $name (want=$want got=$got)"; fi; }
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
QUESTION_PANE='• Waiting for background terminal (1h 26m 43s • esc to interrupt) · 2 background terminals running
• Queued follow-up inputs
  ? 1 question
    shift+← to answer
› Ask Codex to do anything'
WORKING_PANE='• Waiting for background terminal (1h 26m 43s • esc to interrupt) · 2 background terminals running
› Ask Codex to do anything'
run_watch() { local name="$1" pane="$2"
  printf '%s\n' "$pane" > "$W/panes/elfA.txt"
  env PATH="$W/bin:$PATH" WATCH_TICK=1 WATCH_STAY=1 WATCH_SHOW_WORKING=1 WATCH_STATE_DIR="$W/state-$name" \
      WATCH_DISK_MIN_G=0 WATCH_FREE_MIN_PCT=0 "$WATCH" "$W" elfA > "$W/$name.out" 2>&1 &
  local pid=$!; sleep 3; kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null; }
run_watch q "$QUESTION_PANE"
check "pending question is reported"           0 'grep -q "QUESTION elfA" "$W/q.out"'
check "question outranks the working terminal" 1 'grep -q "WORKING elfA" "$W/q.out"'
check "question is reported once, not per tick" 0 '[ "$(grep -c "QUESTION elfA" "$W/q.out")" -eq 1 ]'
run_watch w "$WORKING_PANE"
check "plain working pane raises no question"  1 'grep -q "QUESTION" "$W/w.out"'
check "plain working pane still reads WORKING" 0 'grep -q "WORKING elfA" "$W/w.out"'
echo "question: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
