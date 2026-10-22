#!/usr/bin/env bash
# ============================================================================
# Test harness for ~/.claude/hooks/find-root-gate.py
# ============================================================================
# The gate blocks filesystem-wide scans: a scanner (find, fd, du, tree, ncdu, rg,
# ag, ack, recursive grep, ls -R) whose operand is `/`, a mounted drive, or $HOME.
# `find / -maxdepth 6 -name x` on a failing drive is the incident behind it.
#
# False positives matter as much: scoped paths, relative paths, shallow looks and
# prose that merely mentions the words must pass.
#
# Run: bash ~/.claude/hooks/tests/find-root-gate.sh

set -uo pipefail

HOOK="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/find-root-gate.py"
[ -f "$HOOK" ] || { echo "cannot find hook at $HOOK" >&2; exit 1; }

pass=0
fail=0

# run <expected-exit> <label> <command>
run() {
  local want="$1" label="$2" cmd="$3" got
  got="$(
    python3 - "$cmd" <<'PY' | python3 "$HOOK" >/dev/null 2>&1; echo $?
import json, sys
print(json.dumps({"tool_input": {"command": sys.argv[1]}}))
PY
  )"
  if [ "$got" = "$want" ]; then
    pass=$((pass + 1)); printf '  ok    (exit %s) %s\n' "$got" "$label"
  else
    fail=$((fail + 1)); printf '  FAIL  (exit %s, want %s) %s\n' "$got" "$want" "$label"
  fi
}

echo "== must BLOCK: scans of a broad root =="
run 2 "the incident"                    "find / -maxdepth 6 -name remote.lock -path '*.qew*'"
run 2 "find /"                          "find / -name x"
run 2 "find //"                         "find // -name x"
run 2 "find /*"                         "find /* -name x"
run 2 "find a drive"                    "find /media/games -name x"
run 2 "find /mnt/disk"                  "find /mnt/disk -type f"
run 2 "find /home"                      "find /home -name x"
run 2 "find home dir"                   "find /home/someone -name x"
run 2 "find ~"                          "find ~ -name x"
run 2 "find \$HOME"                     'find $HOME -type f'
run 2 "find after leading -L"           "find -L / -name x"
run 2 "find after a pipe"               "echo a | find / -name x"
run 2 "find in a second command"        "ls; find / -name x"
run 2 "find under xargs"                "echo / | xargs find / -name x"
run 2 "depth 2 is still broad"          "find / -maxdepth 2 -name x"
run 2 "fd on /"                         "fd pattern /"
run 2 "du -a /"                         "du -a /"
run 2 "tree /"                          "tree /"
run 2 "rg over /"                       "rg pat /"
run 2 "rg over a drive"                 "rg pat /media/games"
run 2 "grep -r over /"                  "grep -rn pat /"
run 2 "grep -R over home"               "grep -R pat ~"
run 2 "ls -R /"                         "ls -R /"
run 2 "/usr tree"                       "find /usr -name x"

echo "== must PASS: scoped, shallow, relative and prose =="
run 0 "find ."                          "find . -name x"
run 0 "find a scoped repo"              "find /media/games/code/foundlings -name x"
run 0 "find a relative dir"             "find target -name '*.so'"
run 0 "find a deep path"                "find /tmp/user/scratch -name y"
run 0 "find a dir under home"           "find ~/.claude/skills -name SKILL.md"
run 0 "shallow find /"                  "find / -maxdepth 1"
run 0 "shallow find drive"              "find /media/games -maxdepth 1 -name x"
run 0 "fd shallow"                      "fd -d 1 pattern /"
run 0 "du -d 1"                         "du -d 1 /media/games"
run 0 "tree -L 1"                       "tree -L 1 /"
run 0 "rg in a dir"                     "rg pat crates"
run 0 "rg stdin"                        "echo x | rg pat"
run 0 "grep without -r"                 "grep pat /etc/hosts"
run 0 "ls /"                            "ls /"
run 0 "ls -l /media"                    "ls -l /media"
run 0 "prose mentions find /"           "echo find / is bad"
run 0 "override for one command"        "CLAUDE_ALLOW_ROOT_SCAN=1 find / -name x"
run 0 "override applies to its command only" "CLAUDE_ALLOW_ROOT_SCAN=1 ls; find . -name x"

echo
printf 'passed %s, failed %s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
