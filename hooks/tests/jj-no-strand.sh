#!/usr/bin/env bash
# ============================================================================
# Hermetic tests for jj-no-strand.py
# ============================================================================
# Both checks ASK THE REPO — "does `@` hold unnamed work", "is this bookmark
# empty" — so a decision-only harness would prove nothing. Each case runs the
# REAL hook against a throwaway jj repo built into the shape under test.
#
# Both directions are asserted, and the PASS cases outnumber the blocks on
# purpose: this gate replaces one whose over-blocking is documented history. It
# fired on any non-empty `@`, including a described, bookmarked commit that is
# safe to leave behind, which trained the operator to prefix the override by
# reflex — and the override was then already in hand for the case that mattered.
# An empty commit reached `main` anyway. Over-blocking is not a lesser failure
# than under-blocking; it is the mechanism by which under-blocking happens.

set -uo pipefail

HOOK="${JJ_STRAND_HOOK:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/jj-no-strand.py}"
[ -f "$HOOK" ] || { echo "cannot find hook at $HOOK" >&2; exit 1; }

pass=0; fail=0
TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT
# JJ_USER/JJ_EMAIL are REQUIRED alongside an empty config: without an author jj
# refuses to push at all ("no author and/or committer set"), which silently cost
# this suite its entire check-C fixture the first time.
export JJ_CONFIG=/dev/null JJ_USER=t JJ_EMAIL=t@e

# run <expected-exit> <repo> <label> <command>
run() {
  local want="$1" repo="$2" label="$3" cmd="$4" got
  got="$(
    python3 - "$repo" "$cmd" <<'PY' | (cd "$repo" && python3 "$HOOK") >/dev/null 2>&1; echo $?
import json, sys
print(json.dumps({"tool_name": "Bash", "cwd": sys.argv[1],
                  "tool_input": {"command": sys.argv[2]}}))
PY
  )"
  if [ "$got" = "$want" ]; then
    pass=$((pass + 1)); printf '  ok    (exit %s) %s\n' "$got" "$label"
  else
    fail=$((fail + 1)); printf '  FAIL  (exit %s, want %s) %s\n' "$got" "$want" "$label"
  fi
}

new_repo() {                     # new_repo <name>  -> path
  local d="$TMPROOT/$1"
  mkdir -p "$d"
  ( cd "$d"
    jj git init . >/dev/null 2>&1
    echo base > base.txt
    jj describe -m base >/dev/null 2>&1
    jj new -m second >/dev/null 2>&1
    echo two > two.txt
    jj new >/dev/null 2>&1 ) || return 1
  printf '%s' "$d"
}

command -v jj >/dev/null 2>&1 || { echo "jj not installed — these tests need it"; exit 1; }

# ---- shapes ---------------------------------------------------------------
DIRTY_BARE="$(new_repo dirty-bare)"          # @ has edits, no description, no bookmark
echo wip > "$DIRTY_BARE/wip.txt"

DIRTY_NAMED="$(new_repo dirty-named)"        # @ has edits AND a description
echo wip > "$DIRTY_NAMED/wip.txt"
( cd "$DIRTY_NAMED" && jj describe -m "deliberate wip" >/dev/null 2>&1 )

DIRTY_MARKED="$(new_repo dirty-marked)"      # @ has edits AND a bookmark
echo wip > "$DIRTY_MARKED/wip.txt"
( cd "$DIRTY_MARKED" && jj bookmark set feature -r @ >/dev/null 2>&1 )

CLEAN="$(new_repo clean)"                    # @ empty

EMPTY_BM="$(new_repo empty-bookmark)"        # bookmark on an EMPTY described commit
( cd "$EMPTY_BM" && jj describe -m "docs: a message with nothing behind it" >/dev/null 2>&1 \
  && jj bookmark set main -r @ >/dev/null 2>&1 )

FULL_BM="$(new_repo full-bookmark)"          # bookmark on a commit with real changes
echo real > "$FULL_BM/real.txt"
( cd "$FULL_BM" && jj describe -m "feat: real work" >/dev/null 2>&1 \
  && jj bookmark set main -r @ >/dev/null 2>&1 )

# A repo whose bookmark ALREADY matches its remote: the push would send nothing.
# Built with a real `jj git push` to a local bare remote, so `@origin` is genuine
# rather than simulated.
SYNCED="$TMPROOT/synced"
REMOTE="$TMPROOT/remote.git"
git init -q --bare "$REMOTE" 2>/dev/null
mkdir -p "$SYNCED"
( cd "$SYNCED"
  jj git init . >/dev/null 2>&1
  echo real > real.txt
  jj describe -m "feat: real work" >/dev/null 2>&1
  jj bookmark set main -r @ >/dev/null 2>&1
  jj git remote add origin "$REMOTE" >/dev/null 2>&1
  # Modern jj creates AND tracks a new remote bookmark from a plain push;
  # `--allow-new` does not exist and makes the push fail outright.
  jj git push --bookmark main >/dev/null 2>&1 )

echo "== check A: re-parenting away from UNNAMED work must BLOCK =="
run 2 "$DIRTY_BARE" "positional target"          'jj new main'
run 2 "$DIRTY_BARE" "insert-after"               'jj new -A somechange'
run 2 "$DIRTY_BARE" "attached --insert-after="   'jj new --insert-after=somechange'
run 2 "$DIRTY_BARE" "target plus a redirect"     'jj new main 2>&1 | tail -2'
run 2 "$DIRTY_BARE" "through bash -c"            "bash -c 'jj new main'"

echo
echo "== check A: a NAMED change is safe to leave — must PASS =="
# This is the class the predecessor blocked wrongly. A described or bookmarked
# commit can be found again by name; starting a sibling off it is routine.
run 0 "$DIRTY_NAMED"  "described @"              'jj new main'
run 0 "$DIRTY_MARKED" "bookmarked @"             'jj new main'
run 0 "$DIRTY_BARE"   "child of @ strands nothing" 'jj new'
run 0 "$DIRTY_BARE"   "explicit child of @"      'jj new @'
run 0 "$DIRTY_BARE"   "child with a message"     'jj new -m "wip"'
run 0 "$CLEAN"        "empty @, nothing to lose" 'jj new main'
run 0 "$DIRTY_BARE"   "override disengages A"    'JJ_ALLOW_STRANDING=1 jj new main'

echo
echo "== check B: pushing an EMPTY commit must BLOCK =="
# The damage itself, caught wherever it came from — including the sequence in
# which check A was correctly silent.
run 2 "$EMPTY_BM" "explicit --bookmark"          'jj git push --bookmark main'
run 2 "$EMPTY_BM" "short -b"                     'jj git push -b main'
run 2 "$EMPTY_BM" "attached --bookmark="         'jj git push --bookmark=main'
run 2 "$EMPTY_BM" "after another command"        'jj describe -m x && jj git push --bookmark main'

echo
echo "== check B: a real commit pushes freely — must PASS =="
run 0 "$FULL_BM"  "non-empty bookmark"           'jj git push --bookmark main'
run 0 "$EMPTY_BM" "override disengages B"        'JJ_ALLOW_EMPTY_PUSH=1 jj git push --bookmark main'
# Each check owns its own override, so disabling one must NOT disable the other.
# This case is asserted in the BLOCK direction on purpose: reaching for the
# stranding override must not quietly buy you an empty push as well.
run 2 "$EMPTY_BM" "the OTHER override does not"  'JJ_ALLOW_STRANDING=1 jj git push --bookmark main'
run 0 "$EMPTY_BM" "unknown bookmark is silent"   'jj git push --bookmark nosuchbookmark'

echo
echo "== MENTIONING is not RUNNING — must PASS =="
# Assembled from pieces so this FILE cannot trip a gate that matches raw text.
NEW_MAIN="jj new"" main"
PUSH="jj git"" push --bookmark main"
run 0 "$DIRTY_BARE" "grepped in docs"            "rg -n '$NEW_MAIN' docs/"
run 0 "$DIRTY_BARE" "named in an echo"           "echo \"never use $NEW_MAIN here\""
run 0 "$DIRTY_BARE" "quoted in a commit message" "jj describe -m \"fix: $NEW_MAIN strands work\""
run 0 "$EMPTY_BM"   "push named in a heredoc"    "cat > brief.txt <<EOF
tell the helper to avoid $PUSH
EOF"
run 0 "$DIRTY_BARE" "a path ending in jj"        './tools/notjj new main'
run 0 "$DIRTY_BARE" "not jj at all"              'git status'

echo
echo "== unresolvable target directory: stay silent, never guess =="
# `cd \"\$T/ws\"` reaches the hook UNEXPANDED — the variable is set inside this very
# command. Querying the wrong repo would produce a confident wrong answer.
run 0 "$DIRTY_BARE" "cd through an unexpanded var" 'cd "$T/ws" && jj new main'

echo
echo "== check C: a push that sends NOTHING must BLOCK =="
# jj reports `already matches` and exits 0, so a no-op push reads exactly like a
# successful one. Measured: four branches were reported as pushed when not one had
# moved, because the `jj bookmark set` before them had been refused (jj declines a
# backwards/sideways move without --allow-backwards) and its error was redirected away.
# A fixture that cannot be built must FAIL, never skip. A skipped assertion reads as
# a passing suite while testing nothing — the same silent-success shape this very
# check exists to catch. The first version of this block skipped, and the reason
# (no author configured, so the push was refused) went unnoticed.
if [ -z "$(cd "$SYNCED" && jj log --no-graph -r 'main@origin' -T commit_id 2>/dev/null)" ]; then
  fail=$((fail + 1))
  printf '  FAIL  could not build the synced fixture — check C was never exercised\n'
else
  run 2 "$SYNCED" "local already matches remote"  'jj git push --bookmark main'
  run 0 "$SYNCED" "override disengages C"         'JJ_ALLOW_NOOP_PUSH=1 jj git push --bookmark main'
  # Each check owns its override: the empty-push one must NOT buy you a no-op push.
  run 2 "$SYNCED" "a DIFFERENT override does not" 'JJ_ALLOW_EMPTY_PUSH=1 jj git push --bookmark main'
  # A hook runs BEFORE the command does, so for a chain that MOVES the bookmark and
  # then pushes it, the state read here is the state from before the move. Measured:
  # this gate blocked its own author's `describe && bookmark set && push`, and blocked
  # the whole chain, so not one step ran. Crying wolf on a correct chain trains the
  # override reflex that let an empty commit reach main to begin with.
  run 0 "$SYNCED" "chain moves the bookmark first" 'jj bookmark set main -r @ && jj git push --bookmark main'
  run 0 "$SYNCED" "describe, set, then push"       'jj describe -m x && jj bookmark set main -r @ --allow-backwards && jj git push --bookmark main'
  # ...but a chain that moves a DIFFERENT bookmark must still be caught.
  run 2 "$SYNCED" "chain moves another bookmark"   'jj bookmark set other -r @ && jj git push --bookmark main'
fi
run 0 "$FULL_BM" "no remote at all: silent"      'jj git push --bookmark main'

echo
printf 'passed=%d failed=%d\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1
