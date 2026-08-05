#!/usr/bin/env bash
# Tests for the sccache-health gate.
#
# A gate nobody has verified is a gate nobody has verified — this proves it
# both CATCHES the offending shape and ACCEPTS the correct one, which is the
# half that actually matters: a gate with false positives trains people to
# route around it.
set -u

HOOK="$HOME/.claude/hooks/sccache-health.py"
pass=0
fail=0

# Run the gate over a command string. Echoes "BLOCK" or "ALLOW".
run() {
  local out
  out=$(printf '{"tool_input":{"command":%s}}' "$(python3 -c '
import json,sys; print(json.dumps(sys.argv[1]))' "$1")" | python3 "$HOOK" 2>/dev/null; echo "rc=$?")
  case "$out" in
    *rc=2*) echo BLOCK ;;
    *)      echo ALLOW ;;
  esac
}

expect() {
  local want="$1" cmd="$2" label="$3" got
  got=$(run "$cmd")
  if [ "$got" = "$want" ]; then
    pass=$((pass + 1))
    printf '  ok   %s\n' "$label"
  else
    fail=$((fail + 1))
    printf '  FAIL %s — wanted %s, got %s\n' "$label" "$want" "$got"
  fi
}

echo "sccache-health gate"

# --- BLOCKS: the hard-kill shapes that create the re-spawn loop -------------
expect BLOCK 'pkill sccache'                  'pkill sccache'
expect BLOCK 'killall sccache'                'killall sccache'
expect BLOCK 'kill -9 $(pgrep sccache)'       'kill -9 of an sccache pid'
expect BLOCK 'kill -KILL $(pgrep -f sccache)' 'kill -KILL of an sccache pid'

# --- ALLOWS: the sanctioned stop, and unrelated kills ----------------------
# The whole point of the block message is to route people here, so if this
# were also blocked the gate would be a dead end.
expect ALLOW 'sccache --stop-server'          'the sanctioned stop'
expect ALLOW 'sccache --start-server'         'explicit start'
expect ALLOW 'kill -9 12345'                  'kill -9 of an unrelated pid'
expect ALLOW 'pkill -f some-other-daemon'     'pkill of an unrelated process'

# --- ALLOWS: builds. These may repair the server, but must never block. ----
expect ALLOW 'cargo build -p foo'             'cargo build'
expect ALLOW 'cargo nextest run --profile ci' 'cargo nextest'
expect ALLOW 'cd /tmp && cargo check'         'cargo behind a cd'

# --- ALLOWS: everything else, without paying the probe ---------------------
expect ALLOW 'ls -la'                         'unrelated command'
expect ALLOW 'echo "cargo is great"'          'cargo only inside a string'
expect ALLOW 'git status'                     'git'

# --- The documented-trap case: prose about the gate must not trip it -------
expect ALLOW 'echo "never pkill sccache"'     'prose naming pkill sccache'

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
