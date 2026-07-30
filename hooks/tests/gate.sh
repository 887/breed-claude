#!/usr/bin/env bash
# ============================================================================
# Test harness for hooks/gate.py — the single dispatcher
# ============================================================================
# The per-gate suites already prove each RULE. This proves the DISPATCH: that
# every gate is actually reached through the one entry point, that a clean command
# survives all four, and — the case that matters most — that a BROKEN gate blocks
# loudly instead of quietly not running.
#
# That last one is why this file exists. Consolidating four hook registrations
# into one means a single import error could silently disable every gate at once
# while still exiting 0, which looks identical to "all clear".
#
# Run: bash tests/gate.sh

set -uo pipefail

HOOKS="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GATE="$HOOKS/gate.py"
[ -f "$GATE" ] || { echo "cannot find dispatcher at $GATE" >&2; exit 1; }

pass=0
fail=0

payload() {   # payload <command>
  python3 - "$1" <<'PY'
import json, sys
print(json.dumps({"tool_name": "Bash", "tool_input": {"command": sys.argv[1]}}))
PY
}

run() {   # run <expected-exit> <label> <command> [gate-path]
  local want="$1" label="$2" cmd="$3" gate="${4:-$GATE}" got
  got="$(payload "$cmd" | python3 "$gate" >/dev/null 2>&1; echo $?)"
  if [ "$got" = "$want" ]; then
    pass=$((pass + 1)); printf '  ok    (exit %s) %s\n' "$got" "$label"
  else
    fail=$((fail + 1)); printf '  FAIL  (exit %s, want %s) %s\n' "$got" "$want" "$label"
  fi
}

says() {   # says <substring> <label> <command>
  local want="$1" label="$2" cmd="$3" out
  out="$(payload "$cmd" | python3 "$GATE" 2>&1 >/dev/null)"
  if printf '%s' "$out" | grep -q "$want"; then
    pass=$((pass + 1)); printf '  ok    (says %s) %s\n' "$want" "$label"
  else
    fail=$((fail + 1)); printf '  FAIL  (missing "%s") %s\n' "$want" "$label"
  fi
}

echo "== every gate is REACHED through the one entry point =="
run 2 "rg gate"                        'rg -rn pat .'
run 2 "jj interactive gate"            'jj describe'
run 2 "git interactive gate"           'git commit'
run 2 "update-stale gate"              'jj workspace update-stale'

echo
echo "== and each reports its OWN message, not a generic one =="
says "RG FLAG GATE BLOCKED"     "rg message"          'rg -rn pat .'
says "JJ INTERACTIVE BLOCKED"   "jj message"          'jj describe'
says "GIT INTERACTIVE BLOCKED"  "git message"         'git commit'
says "JJ UPDATE-STALE BLOCKED"  "update-stale message" 'jj workspace update-stale'

echo
echo "== clean commands survive ALL four =="
run 0 "plain ls"                       'ls -la'
run 0 "a correct rg"                   'rg -n pattern src/'
run 0 "a correct jj"                   'jj describe -m "msg"'
run 0 "a correct git"                  'git commit -m "msg"'
run 0 "several safe ones chained"      'jj st && git status && rg -n x . && ls'
run 0 "empty command"                  ''
run 0 "mentions everything, runs none" 'echo "git commit, jj describe, rg -rn, jj workspace update-stale"'

echo
echo "== overrides still reach the gate that owns them =="
run 0 "jj interactive override"         'JJ_GATE_ALLOW_INTERACTIVE=1 jj describe'
run 0 "git interactive override"        'GIT_GATE_ALLOW_INTERACTIVE=1 git commit'
run 0 "update-stale override"           'JJ_ALLOW_UNSAFE_UPDATE_STALE=1 jj workspace update-stale'

echo
echo "== the dispatcher's own escape hatch =="
got="$(payload 'git commit' | CLAUDE_GATE_SKIP=1 python3 "$GATE" >/dev/null 2>&1; echo $?)"
if [ "$got" = "0" ]; then
  pass=$((pass + 1)); printf '  ok    (exit 0) CLAUDE_GATE_SKIP=1 bypasses everything\n'
else
  fail=$((fail + 1)); printf '  FAIL  (exit %s, want 0) CLAUDE_GATE_SKIP=1 bypass\n' "$got"
fi

echo
echo "== a BROKEN gate blocks LOUDLY (never silently skipped) =="
# Real copy of the hooks dir with one gate deliberately corrupted. If the
# dispatcher swallowed the error, the git command below would sail through at
# exit 0 and nothing would say a gate had stopped running.
SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT
cp "$HOOKS"/*.py "$SANDBOX/"
printf 'def check(command):\n    this is not python\n' > "$SANDBOX/git-no-interactive.py"

run 2 "broken gate blocks its own domain"  'git commit -m "fine normally"' "$SANDBOX/gate.py"
run 2 "broken gate blocks an unrelated cmd" 'ls -la' "$SANDBOX/gate.py"

out="$(payload 'ls -la' | python3 "$SANDBOX/gate.py" 2>&1 >/dev/null)"
for want in "GATE BROKEN" "git-no-interactive" "CLAUDE_GATE_SKIP"; do
  if printf '%s' "$out" | grep -q "$want"; then
    pass=$((pass + 1)); printf '  ok    broken-gate message names "%s"\n' "$want"
  else
    fail=$((fail + 1)); printf '  FAIL  broken-gate message omits "%s"\n' "$want"
  fi
done

# A gate that imports fine but EXPLODES at call time must fail the same way.
cp "$HOOKS"/*.py "$SANDBOX/"
printf 'def check(command):\n    raise RuntimeError("boom")\n' > "$SANDBOX/rg-flag-gate.py"
run 2 "a gate raising at call time"    'ls -la' "$SANDBOX/gate.py"

echo "== the ADVERTISED escape must actually work — including on a broken gate =="
# The broken-gate message tells you to re-run with `CLAUDE_GATE_SKIP=1 <command>`.
# That is an INLINE assignment: it is part of the command string the tool is about to
# run, so it never reaches the hook process's environment — which was the only place
# the dispatcher looked. The escape was unreachable from a tool call, and unreachable
# at precisely the moment it is needed, because a broken gate blocks every command
# including the one that would fix it. Measured the hard way: the author of the
# consolidation locked himself out and had to edit the file through a non-Bash tool.
run 0 "inline escape past a broken gate"   'CLAUDE_GATE_SKIP=1 ls -la' "$SANDBOX/gate.py"
run 0 "inline escape, real gates, blocked cmd" 'CLAUDE_GATE_SKIP=1 git commit'
run 0 "escape after an operator"           'cd /tmp; CLAUDE_GATE_SKIP=1 git commit'
run 0 "stacked assignments"                'CLAUDE_GATE_SKIP=1 FOO=2 git commit'
# ...and it must NOT be triggerable by merely NAMING it, or documenting the escape
# in a commit message would silently disable every gate.
run 2 "merely quoted in an echo"           'echo "CLAUDE_GATE_SKIP=1" && git commit'
run 2 "named inside a commit message"      'jj describe -m "use CLAUDE_GATE_SKIP=1 to bypass" && git commit'
run 2 "as an argument to rg"               'rg -n CLAUDE_GATE_SKIP=1 docs/ && git commit'

echo
printf 'passed=%d failed=%d\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1
