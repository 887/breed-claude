#!/usr/bin/env bash
# Test harness for hooks/jj-no-undo.py. Decides from the command string alone.
# Run: bash tests/jj-no-undo.sh

set -uo pipefail

HOOK="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/jj-no-undo.py"
[ -f "$HOOK" ] || { echo "cannot find hook at $HOOK" >&2; exit 1; }

pass=0
fail=0

run() {   # run <expected-exit> <label> <command>
  local want="$1" label="$2" cmd="$3" got
  got="$(
    python3 - "$cmd" <<'PY' | python3 "$HOOK" >/dev/null 2>&1; echo $?
import json, sys
print(json.dumps({"tool_name": "Bash", "tool_input": {"command": sys.argv[1]}}))
PY
  )"
  if [ "$got" = "$want" ]; then
    pass=$((pass + 1)); printf '  ok    (exit %s) %s\n' "$got" "$label"
  else
    fail=$((fail + 1)); printf '  FAIL  (exit %s, want %s) %s\n' "$got" "$want" "$label"
  fi
}

echo "== must BLOCK =="
run 2 "bare jj undo"                   'jj undo'
run 2 "jj undo with a cd in front"     'cd ws && jj undo'
run 2 "after another command"          'jj st; jj undo'
run 2 "-R before the subcommand"       'jj -R /repo undo'
run 2 "--at-op consumes its value"     'jj --at-op @- undo'
run 2 "op restore"                     'jj op restore abc123'
run 2 "operation restore"              'jj operation restore abc123'
run 2 "op undo"                        'jj op undo'
run 2 "through bash -c"                "bash -c 'jj undo'"
run 2 "absolute jj path"               '/opt/homebrew/bin/jj undo'
run 2 "override on another command"    'JJ_ALLOW_UNDO=1 ls; jj undo'

echo
echo "== must PASS =="
run 0 "op revert (the safe tool)"      'jj op revert abc123'
run 0 "op log"                         'jj op log'
run 0 "unrelated jj"                   'jj st'
run 0 "restore a file (not op)"        'jj restore --from @- src/lib.rs'
run 0 "mentioned in rg"                "rg 'jj undo' docs/"
run 0 "mentioned in echo"              'echo "never run jj undo"'
run 0 "override prefix"                'JJ_ALLOW_UNDO=1 jj undo'
run 0 "git restore is not jj"          'git restore file'

echo
echo "passed: $pass  failed: $fail"
[ "$fail" -eq 0 ]
