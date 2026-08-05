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

# --- The orphan reaper: unit-level, because the shapes it must NOT act on -
# --- cannot be staged as real processes without risking a live build. -------
echo
echo "orphan reaper"

unit() {
  local label="$1" script="$2" want="$3" got
  got=$(python3 - "$HOOK" <<PYEOF
import importlib.util, sys
spec = importlib.util.spec_from_file_location("m", sys.argv[1])
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
$script
PYEOF
)
  if [ "$got" = "$want" ]; then
    pass=$((pass + 1)); printf '  ok   %s\n' "$label"
  else
    fail=$((fail + 1)); printf '  FAIL %s — wanted %s, got %s\n' "$label" "$want" "$got"
  fi
}

# A lone server is the overwhelmingly common state: nothing to reap, and the
# expensive lsof must never be reached.
unit 'lone server is left alone' '
m._sccache_pids = lambda: [111]
m._build_in_flight = lambda: False
m._listening_pid = lambda: (_ for _ in ()).throw(AssertionError("lsof reached"))
print(m._reap_orphan_clients())' '0'

# Nothing running at all.
unit 'no sccache at all' '
m._sccache_pids = lambda: []
print(m._reap_orphan_clients())' '0'

# THE SAFETY INTERLOCK. Many clients + a live build = a healthy compile. Killing
# these would be the catastrophic false positive.
unit 'live build clients are NOT reaped' '
m._sccache_pids = lambda: [111, 222, 333, 444]
m._build_in_flight = lambda: True
m._listening_pid = lambda: 111
import os
os.kill = lambda *a: (_ for _ in ()).throw(AssertionError("killed a live client"))
print(m._reap_orphan_clients())' '0'

# Cannot identify the server -> do nothing. Killing the listener by mistake is
# what re-triggers the lazy-respawn wedge this whole file prevents.
unit 'unknown listener reaps nothing' '
m._sccache_pids = lambda: [111, 222]
m._build_in_flight = lambda: False
m._listening_pid = lambda: None
import os
os.kill = lambda *a: (_ for _ in ()).throw(AssertionError("killed without knowing the server"))
print(m._reap_orphan_clients())' '0'

# The real defect: orphans with no build in flight. Reap all but the listener.
unit 'orphans reaped, server spared' '
killed = []
m._sccache_pids = lambda: [41731, 62677, 87358]
m._build_in_flight = lambda: False
m._listening_pid = lambda: 41731
import os
os.kill = lambda pid, sig: killed.append(pid)
n = m._reap_orphan_clients()
print(n if killed == [62677, 87358] else f"wrong victims {killed}")' '2'

# A process that exits between the scan and the kill is not an error.
unit 'already-gone orphan is tolerated' '
m._sccache_pids = lambda: [1, 2]
m._build_in_flight = lambda: False
m._listening_pid = lambda: 1
import os
def boom(pid, sig): raise OSError("no such process")
os.kill = boom
print(m._reap_orphan_clients())' '0'

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
