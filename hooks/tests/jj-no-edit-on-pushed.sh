#!/usr/bin/env bash
# ============================================================================
# Hermetic tests for jj-no-edit-on-pushed.py
# ============================================================================
# The gate ASKS THE REPO whether `@` is on pushed history, so a decision-only
# harness would prove nothing about the part that can be wrong. Every case runs
# the REAL hook against a throwaway jj repo built into the shape under test,
# with a real bare git remote and a real `jj git push` where "pushed" matters.
#
# The PASS cases are the ones that make this gate usable, and they outnumber
# the blocks deliberately. This hook fires on EVERY file edit; a false positive
# does not merely annoy, it teaches the operator to keep the override in hand,
# and an override held by reflex is not a safeguard.
#
# Two fixtures exist because an earlier draft of this gate passed every "must
# pass" case for the wrong reason, and only these distinguish working from
# silent:
#
#   PUSHED       pushes a FEATURE bookmark. Pushing trunk is NOT equivalent —
#                jj moves `@` off a pushed trunk commit and marks it immutable,
#                so a trunk-only fixture is never in the state under test and a
#                dead gate looks healthy against it.
#   PUSHED_TRUNK asserts that same jj behaviour, so the gate stays silent where
#                jj already protects rather than duplicating it.
#
# COLOCATED is the false-positive guard: in a colocated repo every bookmark also
# has a `<name>@git` counterpart, so a gate that counts the git remote fires on
# ordinary local work.

set -uo pipefail

HOOK="${JJ_EDIT_HOOK:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/jj-no-edit-on-pushed.py}"
[ -f "$HOOK" ] || { echo "cannot find hook at $HOOK" >&2; exit 1; }

pass=0; fail=0
TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT
# JJ_USER/JJ_EMAIL are REQUIRED alongside an empty config: without an author jj
# refuses to push at all, which would silently gut every "pushed" fixture here.
export JJ_CONFIG=/dev/null JJ_USER=t JJ_EMAIL=t@e

# run <expected-exit> <file> <label> [tool]
run() {
  local want="$1" file="$2" label="$3" tool="${4:-Edit}" got
  got="$(
    python3 - "$file" "$tool" <<'PY' | python3 "$HOOK" >/dev/null 2>&1; echo $?
import json, sys
print(json.dumps({"tool_name": sys.argv[2],
                  "tool_input": {"file_path": sys.argv[1]}}))
PY
  )"
  if [ "$got" = "$want" ]; then
    pass=$((pass + 1)); printf '  ok    (exit %s) %s\n' "$got" "$label"
  else
    fail=$((fail + 1)); printf '  FAIL  (exit %s, want %s) %s\n' "$got" "$want" "$label"
  fi
}

command -v jj >/dev/null 2>&1 || { echo "jj not installed — these tests need it"; exit 1; }

# ---- shapes ---------------------------------------------------------------

# PUSHED: a pushed FEATURE bookmark. This is the shape that actually bites:
# pushing trunk makes jj move `@` off and mark the commit immutable, but pushing
# a feature bookmark leaves `@` sitting on it, mutable, with no warning at all.
PUSHED="$TMPROOT/pushed"
REMOTE="$TMPROOT/remote.git"
git init -q --bare "$REMOTE" 2>/dev/null
mkdir -p "$PUSHED"
( cd "$PUSHED"
  jj git init . >/dev/null 2>&1
  echo base > base.txt
  jj describe -m base >/dev/null 2>&1
  jj bookmark set main -r @ >/dev/null 2>&1
  jj git remote add origin "$REMOTE" >/dev/null 2>&1
  jj git push --bookmark main >/dev/null 2>&1
  echo real > real.txt
  jj describe -m "feat: real work" >/dev/null 2>&1
  jj bookmark set mybranch -r @ >/dev/null 2>&1
  jj git push --bookmark mybranch >/dev/null 2>&1 )

# PUSHED_TRUNK: trunk pushed and nothing else. jj ALREADY protects this by
# moving `@` off, so the gate must stay silent rather than duplicate jj.
PUSHED_TRUNK="$TMPROOT/pushed-trunk"
REMOTE3="$TMPROOT/remote3.git"
git init -q --bare "$REMOTE3" 2>/dev/null
mkdir -p "$PUSHED_TRUNK"
( cd "$PUSHED_TRUNK"
  jj git init . >/dev/null 2>&1
  echo real > real.txt
  jj describe -m "feat: real work" >/dev/null 2>&1
  jj bookmark set main -r @ >/dev/null 2>&1
  jj git remote add origin "$REMOTE3" >/dev/null 2>&1
  jj git push --bookmark main >/dev/null 2>&1 )

# AFTER_NEW: same repo, one `jj new` later. This is the FIX the message names,
# so it must pass — if it did not, following the advice would not clear the gate.
AFTER_NEW="$TMPROOT/after-new"
REMOTE2="$TMPROOT/remote2.git"
git init -q --bare "$REMOTE2" 2>/dev/null
mkdir -p "$AFTER_NEW"
( cd "$AFTER_NEW"
  jj git init . >/dev/null 2>&1
  echo real > real.txt
  jj describe -m "feat: real work" >/dev/null 2>&1
  jj bookmark set mybranch -r @ >/dev/null 2>&1
  jj git remote add origin "$REMOTE2" >/dev/null 2>&1
  jj git push --bookmark mybranch >/dev/null 2>&1
  jj new >/dev/null 2>&1 )

# COLOCATED: bookmarked local work, NO real remote. Every bookmark here has a
# `@git` counterpart from the colocation alone. This is the false-positive case.
COLOCATED="$TMPROOT/colocated"
mkdir -p "$COLOCATED"
( cd "$COLOCATED"
  jj git init --colocate . >/dev/null 2>&1
  echo local > local.txt
  jj describe -m "wip: local only" >/dev/null 2>&1
  jj bookmark set feature -r @ >/dev/null 2>&1 )

# PLAIN: an ordinary jj repo, no remote at all.
PLAIN="$TMPROOT/plain"
mkdir -p "$PLAIN"
( cd "$PLAIN"
  jj git init . >/dev/null 2>&1
  echo x > x.txt
  jj describe -m "wip" >/dev/null 2>&1 )

# NOTJJ: not a repo of any kind.
NOTJJ="$TMPROOT/notjj"
mkdir -p "$NOTJJ"
echo hello > "$NOTJJ/file.txt"

echo "== editing while @ is a PUSHED commit must BLOCK =="
run 2 "$PUSHED/real.txt"        "edit an existing tracked file"
run 2 "$PUSHED/brand-new.txt"   "create a new file in the same repo"
run 2 "$PUSHED/sub/deep/n.txt"  "path whose directories do not exist yet"
run 2 "$PUSHED/real.txt"        "Write, not just Edit"        Write
run 2 "$PUSHED/nb.ipynb"        "NotebookEdit"                NotebookEdit

echo
echo "== the fix the message names must CLEAR the gate =="
run 0 "$AFTER_NEW/real.txt"     "after jj new, editing is fine"
run 0 "$AFTER_NEW/fresh.txt"    "after jj new, a new file is fine"

echo
echo "== shapes that only LOOK pushed must PASS =="
run 0 "$COLOCATED/local.txt"    "colocated repo: @git is not a real remote"
run 0 "$PLAIN/x.txt"            "jj repo with no remote at all"
run 0 "$PUSHED_TRUNK/real.txt"  "trunk pushed: jj already moved @ off"

echo
echo "== outside jj, and outside scope, must PASS =="
run 0 "$NOTJJ/file.txt"         "not a jj workspace"
run 0 "/nonexistent/zz/f.txt"   "path that resolves nowhere"
run 0 ""                        "empty file_path"
run 0 "$PUSHED/real.txt"        "a tool this gate does not guard"   Bash

echo
echo "== the override must work, and only when set to 1 =="
CLAUDE_ALLOW_EDIT_ON_PUSHED=1 run 0 "$PUSHED/real.txt" "override=1 allows"
CLAUDE_ALLOW_EDIT_ON_PUSHED=yes run 2 "$PUSHED/real.txt" "override=yes still blocks"

echo
echo "== the message must name the fix, not just the problem =="
msg="$(python3 - "$PUSHED/real.txt" <<'PY' | python3 "$HOOK" 2>&1 >/dev/null
import json, sys
print(json.dumps({"tool_name": "Edit", "tool_input": {"file_path": sys.argv[1]}}))
PY
)"
for want in "jj new" "CLAUDE_ALLOW_EDIT_ON_PUSHED" "already pushed to a remote"; do
  if printf '%s' "$msg" | grep -qF "$want"; then
    pass=$((pass + 1)); printf '  ok    message names %s\n' "$want"
  else
    fail=$((fail + 1)); printf '  FAIL  message omits %s\n' "$want"
  fi
done

echo
printf 'passed %d, failed %d\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
