#!/usr/bin/env bash
# ============================================================================
# Test harness for hooks/jj-stale-backup.py
# ============================================================================
# Unlike its siblings this hook TAKES AN ACTION — it copies the workspace before
# allowing the command — so the suite has to assert two different things:
#
#   1. Decision cases, from the command string alone, no repo needed (as the
#      other harnesses do): does it fire on a real `jj workspace update-stale`,
#      and stay out of the way otherwise?
#   2. That the backup ACTUALLY HAPPENS, against a real jj workspace. A guard
#      that returns 0 without copying anything is WORSE than no guard: it prints
#      reassurance and then lets the destructive command run. So the effect is
#      asserted, not just the exit code. That case is skipped (loudly) if jj is
#      not installed.
#
# Run: bash tests/jj-stale-backup.sh

set -uo pipefail

HOOK="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/jj-stale-backup.py"
[ -f "$HOOK" ] || { echo "cannot find hook at $HOOK" >&2; exit 1; }

pass=0
fail=0

# Every decision case runs with a scratch backup dir and a cwd that is NOT a jj
# workspace, so an allowed case cannot copy anything by accident.
SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT
export JJ_STALE_BACKUP_DIR="$SANDBOX/backups"

run() {   # run <expected-exit> <label> <command> [cwd]
  local want="$1" label="$2" cmd="$3" cwd="${4:-$SANDBOX/notarepo}" got
  mkdir -p "$cwd"
  got="$(
    python3 - "$cmd" "$cwd" <<'PY' | python3 "$HOOK" >/dev/null 2>&1; echo $?
import json, sys
print(json.dumps({"tool_name": "Bash", "cwd": sys.argv[2],
                  "tool_input": {"command": sys.argv[1]}}))
PY
  )"
  if [ "$got" = "$want" ]; then
    pass=$((pass + 1)); printf '  ok    (exit %s) %s\n' "$got" "$label"
  else
    fail=$((fail + 1)); printf '  FAIL  (exit %s, want %s) %s\n' "$got" "$want" "$label"
  fi
}

echo "== must BLOCK: update-stale where the workspace cannot be backed up =="
# cwd is a real directory but NOT inside a jj workspace -> nothing to back up,
# so allowing it would be allowing an unguarded update-stale.
run 2 "cwd is not a jj workspace"      'jj workspace update-stale'
run 2 "with a cd to a non-workspace"   "cd $SANDBOX/notarepo && jj workspace update-stale"
run 2 "cd to a missing directory"      'cd /nonexistent/definitely && jj workspace update-stale'
run 2 "after another command"          'jj st; jj workspace update-stale'
run 2 "through bash -c"                "bash -c 'jj workspace update-stale'"
run 2 "with -R before the subcommand"  'jj -R /tmp workspace update-stale'
run 2 "chained with &&"                'jj workspace list && jj workspace update-stale'
# MEASURED live: `cd "$T/ws" && jj workspace update-stale` reaches the hook with
# `$T` UNEXPANDED, because the variable is set inside this same command and the
# shell has not run yet. Still blocked — guessing a tree would back up the wrong
# files and then allow the clobber — but the message must name the variable rather
# than report a missing path, which is what sent me hunting the wrong cause.
run 2 "cd through an unexpanded var"   'cd "$T/ws" && jj workspace update-stale'
run 2 "unexpanded var, no quotes"      'cd $WS && jj workspace update-stale'
run 2 "command substitution in the cd" 'cd "$(pwd)/ws" && jj workspace update-stale'

echo
echo "== must PASS: not this command at all =="
run 0 "plain status"                   'jj st'
run 0 "workspace list"                 'jj workspace list'
run 0 "workspace add"                  'jj workspace add ../ws-1'
run 0 "workspace forget"               'jj workspace forget ws-1'
run 0 "describe with a message"        'jj describe -m wip'
run 0 "not jj at all"                  'git status'
run 0 "no jj anywhere"                 'ls -la'

echo
echo "== must PASS: MENTIONED, not run (the predecessor grepped text and fired) =="
STALE="jj workspace ""update-stale"
run 0 "grepping for it"                "rg -n '$STALE' docs/"
run 0 "explaining it in an echo"       "echo \"never run $STALE in a dirty ws\""
run 0 "naming it in a commit message"  "jj describe -m \"docs: why $STALE destroys work\""
run 0 "in a heredoc brief"             "cat > brief.txt <<EOF
do not run $STALE
EOF"
run 0 "inside a python string"         "python3 -c \"print('$STALE')\""
run 0 "a path merely ending in jj"     './tools/notjj workspace update-stale'

echo
echo "== override =="
run 0 "override as an assignment"      'JJ_ALLOW_UNSAFE_UPDATE_STALE=1 jj workspace update-stale'
run 2 "override merely MENTIONED"      'echo "set JJ_ALLOW_UNSAFE_UPDATE_STALE=1" && jj workspace update-stale'

echo
echo "== the backup must ACTUALLY HAPPEN (real jj workspace) =="
if ! command -v jj >/dev/null 2>&1; then
  echo "  SKIP  jj not installed — the effect assertion did not run"
else
  REPO="$SANDBOX/repo"
  mkdir -p "$REPO"
  (
    cd "$REPO"
    export JJ_CONFIG=/dev/null JJ_USER=t JJ_EMAIL=t@e
    jj git init . >/dev/null 2>&1
  ) || { echo "  SKIP  could not create a jj repo"; }

  if [ -e "$REPO/.jj" ]; then
    printf 'canary content\n' > "$REPO/unsnapshotted.txt"
    mkdir -p "$REPO/target"; printf 'huge build output\n' > "$REPO/target/junk.o"

    before="$(find "$JJ_STALE_BACKUP_DIR" -maxdepth 1 -type d 2>/dev/null | wc -l)"
    run 0 "allowed in a real workspace"  'jj workspace update-stale' "$REPO"
    after="$(find "$JJ_STALE_BACKUP_DIR" -maxdepth 1 -type d 2>/dev/null | wc -l)"

    if [ "$after" -gt "$before" ]; then
      pass=$((pass + 1)); printf '  ok    a backup directory was created\n'
    else
      fail=$((fail + 1)); printf '  FAIL  NO backup directory was created (guard is a no-op!)\n'
    fi

    copy="$(find "$JJ_STALE_BACKUP_DIR" -maxdepth 2 -name unsnapshotted.txt 2>/dev/null | head -1)"
    if [ -n "$copy" ] && grep -q "canary content" "$copy"; then
      pass=$((pass + 1)); printf '  ok    the un-snapshotted file was preserved verbatim\n'
    else
      fail=$((fail + 1)); printf '  FAIL  the un-snapshotted file was NOT backed up\n'
    fi

    if find "$JJ_STALE_BACKUP_DIR" -path '*/target/*' 2>/dev/null | grep -q .; then
      fail=$((fail + 1)); printf '  FAIL  target/ was copied — the excludes are not working\n'
    else
      pass=$((pass + 1)); printf '  ok    target/ was excluded from the copy\n'
    fi

    if find "$JJ_STALE_BACKUP_DIR" -maxdepth 2 -name '.jj' 2>/dev/null | grep -q .; then
      fail=$((fail + 1)); printf '  FAIL  .jj was copied — the excludes are not working\n'
    else
      pass=$((pass + 1)); printf '  ok    .jj was excluded from the copy\n'
    fi
  fi
fi

echo
printf 'passed=%d failed=%d\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1
