#!/usr/bin/env bash
# ============================================================================
# Test harness for hooks/jj-no-update-stale.py
# ============================================================================
# Decides from the command string alone, so no jj repo is needed — same as the
# other harnesses. Both directions asserted, with the pass direction carrying more
# cases: a gate that fires on a mention gets routed around via its override, and
# the override switches the whole check off.
#
# Run: bash tests/jj-no-update-stale.sh

set -uo pipefail

HOOK="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/jj-no-update-stale.py"
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
run 2 "the bare command"               'jj workspace update-stale'
run 2 "with a cd in front"             'cd ../proj-cc-x && jj workspace update-stale'
run 2 "after another command"          'jj st; jj workspace update-stale'
run 2 "chained with &&"                'jj workspace list && jj workspace update-stale'
run 2 "through bash -c"                "bash -c 'jj workspace update-stale'"
run 2 "-R before the subcommand"       'jj -R /some/repo workspace update-stale'
run 2 "--repository= form"             'jj --repository=/some/repo workspace update-stale'
run 2 "--at-op consumes its value"     'jj --at-op @- workspace update-stale'
run 2 "piped into something"           'jj workspace update-stale | tee log'
run 2 "with a trailing redirect"       'jj workspace update-stale 2>&1'
run 2 "an absolute jj path"            '/usr/bin/jj workspace update-stale'

echo
echo "== must PASS: other jj, including the rest of workspace =="
run 0 "workspace list"                 'jj workspace list'
run 0 "workspace add"                  'jj workspace add ../proj-cc-x'
run 0 "workspace forget"               'jj workspace forget proj-cc-x'
run 0 "workspace root"                 'jj workspace root'
run 0 "plain status"                   'jj st'
run 0 "describe with a message"        'jj describe -m wip'
run 0 "log"                            'jj log -r @'
run 0 "not jj at all"                  'git status'
run 0 "no jj anywhere"                 'ls -la && echo done'
run 0 "a path merely ending in jj"     './tools/notjj workspace update-stale'

echo
echo "== must PASS: MENTIONED, not run =="
STALE="jj workspace ""update-stale"
run 0 "grepping for it"                "rg -n '$STALE' docs/"
run 0 "explaining it in an echo"       "echo \"never run $STALE in a dirty ws\""
run 0 "naming it in a commit message"  "jj describe -m \"docs: why $STALE destroys work\""
run 0 "in a heredoc brief"             "cat > brief.txt <<EOF
do not run $STALE
EOF"
run 0 "inside a python string"         "python3 -c \"print('$STALE')\""
run 0 "in a quoted grep pattern"       "grep -q '$STALE' CLAUDE.md"

echo
echo "== override =="
run 0 "override as an assignment"      'JJ_ALLOW_UNSAFE_UPDATE_STALE=1 jj workspace update-stale'
run 0 "override with a cd first"       'cd ../ws && JJ_ALLOW_UNSAFE_UPDATE_STALE=1 jj workspace update-stale'
run 2 "override merely MENTIONED"      'echo "set JJ_ALLOW_UNSAFE_UPDATE_STALE=1" && jj workspace update-stale'
run 2 "override on a DIFFERENT command" 'JJ_ALLOW_UNSAFE_UPDATE_STALE=1 ls; jj workspace update-stale'
# An env assignment applies only to the command it prefixes, so the gate reads it
# the same way the shell does. A command-wide check was an accidental escape hatch.
run 2 "override on the FIRST of two"   'JJ_ALLOW_UNSAFE_UPDATE_STALE=1 jj st && jj workspace update-stale'
run 0 "override reaches into bash -c"  "JJ_ALLOW_UNSAFE_UPDATE_STALE=1 bash -c 'jj workspace update-stale'"

echo
echo "== a NEWLINE ends a command — line 2+ must be seen (measured: it was not) =="
# `shlex` treats \n as plain whitespace, so `cd /tmp<newline>jj workspace update-stale` lexed as ONE
# segment whose command word is `cd`; the real command became mere arguments and
# no gate saw it. Every hook here was bypassable by this shape.
run 2 "gated command on line 2"        'cd /tmp
jj workspace update-stale'
run 2 "gated command on line 3"        'cd /tmp
echo hi
jj workspace update-stale'
run 2 "after a heredoc block"          'cat <<EOF
body
EOF
jj workspace update-stale'
run 0 "mentioned in a 2-line message"  'jj describe -m "line one
line two: never run jj workspace update-stale"'
run 0 "exported override carries"      'export JJ_ALLOW_UNSAFE_UPDATE_STALE=1
jj workspace update-stale'

echo
printf 'passed=%d failed=%d\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1
