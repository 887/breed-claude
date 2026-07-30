#!/usr/bin/env bash
# ============================================================================
# Test harness for hooks/jj-no-interactive.py
# ============================================================================
# Invokes the REAL hook with synthetic PreToolUse payloads. No jj repo is needed:
# the decision is made entirely from the command string, which is the point — a
# command that would hang must be refused BEFORE it runs, not diagnosed after.
#
# Both directions are asserted, and the pass direction carries more cases than the
# block direction on purpose. A gate that over-blocks gets routed around via its
# override, which disables it wholesale — so a false positive is not cosmetic, it
# is how the protection gets switched off. Three separate false positives across
# these hooks came from matching command TEXT instead of command POSITIONS; the
# mention cases below are the regression guard for that.
#
# Run: bash tests/jj-no-interactive.sh

set -uo pipefail

HOOK="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/jj-no-interactive.py"
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

echo "== must BLOCK: would open an editor and hang =="
run 2 "explicit -i on squash"          'jj squash -i'
run 2 "explicit --interactive"         'jj restore --interactive'
run 2 "split is always a diff editor"  'jj split'
run 2 "split with a revset"            'jj split -r @-'
run 2 "diffedit is always interactive" 'jj diffedit -r @'
run 2 "describe with no message"       'jj describe'
run 2 "describe -r with no message"    'jj describe -r @-'
run 2 "commit with no message"         'jj commit'
run 2 "--editor forces one open"       'jj describe --editor -m "msg"'
run 2 "resolve opens a merge editor"   'jj resolve'
run 2 "--tool implies interactive"     'jj restore --tool meld'
run 2 "--tool= form"                   'jj restore --tool=meld'
run 2 "after a pipe"                   'echo x | jj describe'
run 2 "through bash -c"                "bash -c 'jj split'"
run 2 "with a global flag first"       'jj -R /some/repo describe'
run 2 "chained after a safe command"   'jj st && jj describe'
# MEASURED: with a description on BOTH source and destination, `jj squash` opens an
# editor to combine them and hangs. Which shape you are in depends on repo state
# the hook cannot see, so an explicit -m or -u is required. Two cases below used to
# be asserted as PASS on the assumption that naming paths or a destination avoided
# the prompt — that was never measured, and it is wrong.
run 2 "squash with no message"         'jj squash'
run 2 "squash by path still prompts"   'jj squash src/lib.rs'
run 2 "squash --into still prompts"    'jj squash --into @-'
run 2 "squash --editor beats -m"       'jj squash -m "msg" --editor'

echo "== must PASS: non-interactive forms, the whole point of the gate =="
run 0 "describe with -m"               'jj describe -m "a message"'
run 0 "describe with -m= form"         'jj describe -m="a message"'
run 0 "describe with --message"        'jj describe --message "a message"'
run 0 "describe from a file"           'jj describe -m "$(cat msg.txt)"'
run 0 "describe --stdin"               'cat msg.txt | jj describe --stdin'
run 0 "commit with -m"                 'jj commit -m "a message"'
run 0 "squash with -m"                 'jj squash -m "combined"'
run 0 "squash -m plus a path"          'jj squash -m "combined" src/lib.rs'
run 0 "squash -u keeps dest message"   'jj squash -u'
run 0 "squash --use-destination-msg"   'jj squash --use-destination-message --into @-'
run 0 "squash --help is not a squash"  'jj squash --help'
run 0 "restore by path"               'jj restore --from @- src/lib.rs'
run 0 "resolve --list is read-only"    'jj resolve --list'
run 0 "resolve -l short form"          'jj resolve -l'
run 0 "resolve with :ours builtin"     'jj resolve --tool :ours'
run 0 "resolve with :theirs builtin"   'jj resolve --tool :theirs'
run 0 "plain status"                   'jj st'
run 0 "log is not interactive"         'jj log -r @'
run 0 "new is not interactive"         'jj new main'
run 0 "rebase is not interactive"      'jj rebase -r @ -d main'
run 0 "bookmark set"                   'jj bookmark set main -r @'
run 0 "git push"                       'jj git push --bookmark main'
run 0 "the documented override"        'JJ_GATE_ALLOW_INTERACTIVE=1 jj describe'

echo "== must PASS: MENTIONING an interactive command is not running it =="
# Phrases assembled from pieces so this file cannot trip a text-matching gate.
SPLIT="jj ""split"
DIFFEDIT="jj ""diffedit"
run 0 "grep for it in docs"            "rg -n '$SPLIT' docs/"
run 0 "explaining it in an echo"       "echo \"never run $DIFFEDIT here\""
run 0 "naming it in a commit message"  "jj describe -m \"docs: explain why $SPLIT hangs\""
run 0 "in a heredoc brief"             "cat > brief.txt <<EOF
do not run $DIFFEDIT in the workspace
EOF"
run 0 "inside a python string"         "python3 -c \"print('$SPLIT')\""
run 0 "a path merely ending in jj"     './tools/notjj describe'
run 0 "no jj anywhere"                 'git status'

echo
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
