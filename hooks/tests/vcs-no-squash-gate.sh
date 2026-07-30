#!/usr/bin/env bash
# ============================================================================
# Hermetic test harness for .claude/hooks/vcs-no-squash-gate.sh
# ============================================================================
# The gate is a PreToolUse(Bash) trust boundary: it decides whether a VCS command
# reaches the shell. Its check B ("no `jj new` stranding of a dirty @") can only
# be exercised against a real jj repo whose @ is genuinely non-empty, because the
# hook asks jj. So this harness builds a throwaway jj repo per case, dirties @,
# and invokes the REAL hook with a synthetic PreToolUse payload whose `.cwd`
# points at that repo. No double of the hook, no mutation of this workspace.
#
# WHY THESE CASES: the hook's own segment-grab cuts the command at the first
# `;&|`, so `jj new 2>&1 | tail -2` reduces to the fragment `2>`. That is not a
# flag and not `@`, so the positional scan read it as a revset target and blocked
# a command that strands nothing. A hook that blocks safe commands gets routed
# around with its override env var, which then also disables the case it exists
# to catch — a false positive is not a cosmetic defect here, it is how the real
# protection gets switched off.
#
# Both directions are asserted. A gate is only trustworthy if it has been
# observed BLOCKING what it must block, not merely passing what it must pass.

set -uo pipefail

HOOK="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/vcs-no-squash-gate.sh"
[ -f "$HOOK" ] || { echo "cannot find hook at $HOOK" >&2; exit 1; }

pass=0
fail=0
TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT

# Build a jj repo. `dirty=1` leaves @ non-empty; otherwise @ is empty.
make_repo() {
  local dir="$TMPROOT/repo-$1" dirty="$2"
  mkdir -p "$dir"
  (
    cd "$dir" || exit 1
    jj git init --quiet . >/dev/null 2>&1 || jj git init . >/dev/null 2>&1
    echo base > base.txt
    jj describe -m "base" >/dev/null 2>&1
    jj new >/dev/null 2>&1
    if [ "$dirty" = "1" ]; then
      echo wip > wip.txt          # @ now has real working-copy content
    fi
  )
  printf '%s' "$dir"
}

# run <expected-exit> <repo-dir> <label> <command>
run() {
  local want="$1" repo="$2" label="$3" cmd="$4" got
  got="$(
    python3 - "$repo" "$cmd" <<'PY' | bash "$HOOK" >/dev/null 2>&1; echo $?
import json, sys
print(json.dumps({"tool_name": "Bash",
                  "cwd": sys.argv[1],
                  "tool_input": {"command": sys.argv[2]}}))
PY
  )"
  if [ "$got" = "$want" ]; then
    pass=$((pass + 1)); printf '  ok    (exit %s) %s\n' "$got" "$label"
  else
    fail=$((fail + 1)); printf '  FAIL  (exit %s, want %s) %s\n' "$got" "$want" "$label"
  fi
}

DIRTY="$(make_repo dirty 1)"
CLEAN="$(make_repo clean 0)"

echo "== check B: bare/child-of-@ forms must PASS even with a dirty @ =="
run 0 "$DIRTY" "bare jj new"                        'jj new'
run 0 "$DIRTY" "bare jj new + stderr dup (the bug)" 'jj new 2>&1 | tail -2'
run 0 "$DIRTY" "bare jj new + file redirect"        'jj new > /tmp/vcsgate-out.txt'
run 0 "$DIRTY" "bare jj new + stderr to file"       'jj new 2>/dev/null'
run 0 "$DIRTY" "explicit child-of-@"                'jj new @'
run 0 "$DIRTY" "child-of-@ with a message"          'jj new -m "wip"'
run 0 "$DIRTY" "cd then bare jj new, piped"         "cd $DIRTY && jj new 2>&1 | tail -1"

echo "== check B: re-parenting with a dirty @ must BLOCK =="
run 2 "$DIRTY" "positional target"                  'jj new main'
run 2 "$DIRTY" "insert-after"                       'jj new -A somechange'
run 2 "$DIRTY" "insert-before"                      'jj new --before somechange'
run 2 "$DIRTY" "target plus redirect"               'jj new main 2>&1 | tail -2'

echo "== check B: an EMPTY @ strands nothing, so never block =="
run 0 "$CLEAN" "positional target, empty @"         'jj new main'
run 0 "$CLEAN" "insert-after, empty @"              'jj new -A somechange'

echo "== check B: the documented override disengages it =="
run 0 "$DIRTY" "override prefix"                    'FOUNDLINGS_ALLOW_JJ_NEW_STRANDING=1 jj new main'

echo "== check A: squash / shared-history rewrite still blocks =="
run 2 "$DIRTY" "jj squash"                          'jj squash'
run 2 "$DIRTY" "gh pr merge --squash"               'gh pr merge 42 --squash'
run 2 "$DIRTY" "API merge_method=squash"            'gh api repos/o/r/pulls/1/merge -f merge_method=squash'
run 2 "$DIRTY" "whole-branch rebase"                'jj rebase -b -d main'
run 0 "$DIRTY" "single-revision rebase is fine"     'jj rebase -r @ -d main'
run 0 "$DIRTY" "merge_method=merge is the right one" 'gh api repos/o/r/pulls/1/merge -f merge_method=merge'
run 0 "$DIRTY" "history-rewrite override"           'FOUNDLINGS_ALLOW_HISTORY_REWRITE=1 jj squash'

echo
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
