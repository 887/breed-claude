#!/usr/bin/env bash
# ============================================================================
# Test harness for hooks/jj-no-forget-default-workspace.py
# ============================================================================
# Decides from the command string alone, so no jj repo is needed — same as the
# other harnesses. The PASS direction carries most of the cases on purpose: this
# gate's whole design claim is that it blocks ONE name and leaves ordinary
# workspace cleanup alone, so the accept side is what actually needs proving.
#
# Run: bash tests/jj-no-forget-default-workspace.sh

set -uo pipefail

HOOK="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/jj-no-forget-default-workspace.py"
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
run 2 "the bare command"                 'jj workspace forget default'
run 2 "default LAST in a long list"      'jj workspace forget a b c default'
run 2 "default FIRST in a list"          'jj workspace forget default a b'
run 2 "default in the MIDDLE"            'jj workspace forget a default b'
run 2 "with a cd in front"               'cd /repo && jj workspace forget default'
run 2 "after another command"            'jj workspace list; jj workspace forget default'
run 2 "chained with &&"                  'jj st && jj workspace forget default'
run 2 "through bash -c"                  "bash -c 'jj workspace forget default'"
run 2 "-R before the subcommand"         'jj -R /some/repo workspace forget default'
run 2 "--repository= form"               'jj --repository=/some/repo workspace forget default'
run 2 "--at-op consumes its value"       'jj --at-op @- workspace forget default'
run 2 "an absolute jj path"              '/usr/bin/jj workspace forget default'
run 2 "piped into something"             'jj workspace forget default | tee log'
run 2 "unrelated env prefix"             'FOO=1 jj workspace forget default'

echo
echo "== must PASS: forgetting ANY other workspace is ordinary hygiene =="
run 0 "one named workspace"              'jj workspace forget proj-cc-x'
run 0 "a long bulk cleanup"              'jj workspace forget a b c d e f g h'
run 0 "a name CONTAINING default"        'jj workspace forget my-default-probe'
run 0 "a name prefixed with default"     'jj workspace forget defaults'
run 0 "the rest of workspace"            'jj workspace list'
run 0 "workspace add"                    'jj workspace add ../proj-cc-x'
run 0 "workspace root"                   'jj workspace root'
run 0 "forget on a DIFFERENT subcommand" 'jj forget default'
run 0 "plain status"                     'jj st'
run 0 "not jj at all"                    'git worktree remove default'
run 0 "no jj anywhere"                   'ls -la && echo done'
run 0 "a path merely ending in jj"       './tools/notjj workspace forget default'

echo
echo "== must PASS: mentions are not invocations =="
run 0 "grepping for it"                  "rg 'jj workspace forget default' docs/"
run 0 "documenting it"                   'echo "never run jj workspace forget default"'

echo
echo "== must PASS: the override, and only in command position =="
run 0 "override prefixes the command"    'JJ_ALLOW_FORGET_DEFAULT_WORKSPACE=1 jj workspace forget default'
run 0 "override through bash -c"         "JJ_ALLOW_FORGET_DEFAULT_WORKSPACE=1 bash -c 'jj workspace forget default'"
run 2 "override on a DIFFERENT command"  'JJ_ALLOW_FORGET_DEFAULT_WORKSPACE=1 ls; jj workspace forget default'
run 2 "override merely echoed"           'echo "JJ_ALLOW_FORGET_DEFAULT_WORKSPACE=1"; jj workspace forget default'

echo
printf 'passed %d, failed %d\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
