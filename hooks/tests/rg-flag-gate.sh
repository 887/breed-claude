#!/usr/bin/env bash
# ============================================================================
# Test harness for ~/.claude/hooks/rg-flag-gate.py
# ============================================================================
# The gate blocks ripgrep short flags that silently mean something other than
# their grep namesake: `-r` is --replace=TEXT (rg recurses by default) and `-E`
# is --encoding=ENC (rg is already extended-regex). Both produce wrong output at
# exit 0, which is why they are worth failing at the call site.
#
# Both directions matter, and the false-positive direction matters MORE than it
# looks: a gate that blocks correct commands trains you to work around it, and
# the workaround is indiscriminate. The recorded false positive was
# `rg -n pat f 2>/dev/null; jj file list -r main`, where the `-r` belongs to jj.
# The cause was tokenisation, not the flag table: `shlex.split` returns
# `2>/dev/null;` as ONE token that matches no separator, so the scanner never
# saw the command boundary and kept attributing later flags to rg.
#
# Run: bash ~/.claude/hooks/tests/rg-flag-gate.sh

set -uo pipefail

HOOK="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/rg-flag-gate.py"
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

echo "== must BLOCK: the two colliding short flags on rg =="
run 2 "-r alone"                      "rg -r x pat ."
run 2 "-rn cluster"                   "rg -rn pat ."
run 2 "-rln cluster"                  "rg -rln pat ."
run 2 "-E alone"                      "rg -E 'a|b' file"
run 2 "-nE cluster"                   "rg -nE pat file"
run 2 "rg after a pipe"               "cat f | rg -r x pat"
run 2 "rg after xargs"                "find . -type f | xargs rg -rn pat"
run 2 "rg as a path"                  "/opt/homebrew/bin/rg -rn pat ."
run 2 "second command is the bad rg"  "ls -l; rg -rn pat ."

echo "== must PASS: correct rg usage =="
run 0 "-n"                            "rg -n pat ."
run 0 "-ln"                           "rg -ln pat ."
run 0 "-C context"                    "rg -C 3 pat ."
run 0 "-e explicit pattern"           "rg -e -leading-dash ."
run 0 "long --replace is explicit"     "rg --replace=x pat ."
run 0 "long --encoding is explicit"    "rg --encoding=utf-8 pat ."
run 0 "flags past -- are operands"     "rg pat -- -weird-file"

echo "== must PASS: -r/-E belonging to a DIFFERENT command =="
run 0 "grep -rn is a different tool"  "grep -rn pat ."
run 0 "sort -r after rg"              "rg -n pat . | sort -r"
run 0 "ls -lr before rg"              "ls -lr | rg -n pat"
run 0 "jj -r before rg, piped"        "jj file list -r main | rg -n pat"
run 0 "jj -r AFTER rg, semicolon"     "rg -n pat f; jj file list -r main"
run 0 "the recorded false positive"   "rg -n pat .gitignore 2>/dev/null; jj file list -r main x 2>/dev/null | rg -n pat | head -5"
run 0 "redirect then another cmd -r"  "rg -n pat f 2>/dev/null && sort -r f"
run 0 "glued pipe then sort -r"       "rg -n pat f|sort -r"
run 0 "subshell boundary"             "(rg -n pat f); tar -rf a.tar b"
run 0 "no rg at all"                  "grep -E 'a|b' file"

echo
echo "== a NEWLINE ends a command — line 2+ must be seen (measured: it was not) =="
# `shlex` treats \n as plain whitespace, so `cd /tmp<newline>rg -rn pat .` lexed as ONE
# segment whose command word is `cd`; the real command became mere arguments and
# no gate saw it. Every hook here was bypassable by this shape.
run 2 "bad flag on line 2"            'cd /tmp
rg -rn pat .'
run 2 "bad flag after a heredoc"       'cat <<EOF
body
EOF
rg -rn pat .'
run 0 "safe rg over two lines"         'cd /tmp
rg -n pat .'
run 0 "flag named in a 2-line message" 'git commit -m "note
never pass rg -rn here"'

echo
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
