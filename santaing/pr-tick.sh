#!/usr/bin/env bash
# pr-tick.sh — tick (or untick) ONE checklist line in a PR description.
#
#   pr-tick.sh <pr> "<text unique to the item>"          # - [ ] -> - [x]
#   pr-tick.sh <pr> "<text unique to the item>" --undo   # - [x] -> - [ ]
#   pr-tick.sh --dry-run "<text>" [--undo] < body.md    # transform stdin, print result
#
# GitHub has no per-checkbox API: the web UI's checkbox click also rewrites the
# whole body. This script does that round trip itself, so a lane spends one
# short command per tick instead of reading and re-writing its PR description.
#
# Refuses (exit 2) when the text matches no checklist line or more than one, so
# a vague match never ticks the wrong item.
set -euo pipefail

usage() { sed -n '2,6p' "$0" >&2; exit 2; }

flip() { # flip <needle> <undo:0|1>   (stdin -> stdout)
  python3 -c '
import sys
needle, undo = sys.argv[1], sys.argv[2] == "1"
src, dst = ("- [x]", "- [ ]") if undo else ("- [ ]", "- [x]")
lines = sys.stdin.read().split("\n")
hits = [i for i, l in enumerate(lines)
        if l.lstrip().startswith(("- [ ]", "- [x]", "- [X]")) and needle in l]
if len(hits) != 1:
    sys.stderr.write(f"pr-tick: {len(hits)} checklist lines match {needle!r}; need exactly 1\n")
    sys.exit(2)
i = hits[0]
l = lines[i].replace("- [X]", "- [x]", 1)
if src not in l:
    sys.stderr.write(f"pr-tick: already {dst}: {l.strip()}\n")
else:
    lines[i] = l.replace(src, dst, 1)
sys.stdout.write("\n".join(lines))
' "$1" "$2"
}

[ $# -ge 2 ] || usage
if [ "$1" = "--dry-run" ]; then
  undo=0; [ "${3:-}" = "--undo" ] && undo=1
  flip "$2" "$undo"
  exit 0
fi

pr="$1"; needle="$2"; undo=0; [ "${3:-}" = "--undo" ] && undo=1
body="$(gh pr view "$pr" --json body -q .body)"
new="$(printf '%s' "$body" | flip "$needle" "$undo")"
[ "$new" = "$body" ] && exit 0
printf '%s' "$new" | gh pr edit "$pr" --body-file - >/dev/null
printf 'pr-tick: #%s %s\n' "$pr" "$(printf '%s' "$new" | grep -F -- "$needle" | head -1 | sed 's/^ *//')"
