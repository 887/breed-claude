#!/usr/bin/env bash
# Behavioural test: the input-box strip in watch-elves.sh must actually strip.
#
# This exists because the strip shipped once as a silent NO-OP — written as an
# escape sequence inside a single-quoted grep pattern, which matches the literal
# characters rather than the byte sequence. `bash -n` accepted it. Only a
# fixture with a real chevron row catches it, so that is what this does.
set -uo pipefail
cd "$(dirname "$0")/.."
fail=0

# Extract the exact capture pipeline from the script rather than restating it,
# so a future edit to the pattern is tested rather than shadowed by a copy.
pattern=$(grep -o "grep -v '\^\[\[:space:\]\]\*[^']*'" watch-elves.sh | tail -1)
[ -n "$pattern" ] || { echo "FAIL: no input-box strip found in watch-elves.sh"; exit 1; }

fixture=$(printf 'preceding output\n\xe2\x9d\xaf a suggested next input\n  Sonnet 5 | footer | 1 shell\n')

got=$(printf '%s\n' "$fixture" | eval "$pattern")

if printf '%s' "$got" | grep -q '❯'; then
    echo "FAIL: chevron row survived the strip — the pattern is a no-op"
    fail=1
else
    echo "ok: chevron row stripped"
fi

for keep in 'preceding output' '1 shell'; do
    if printf '%s' "$got" | grep -qF "$keep"; then
        echo "ok: kept '$keep'"
    else
        echo "FAIL: strip removed '$keep' — too greedy"
        fail=1
    fi
done

# The footer's WORKING tokens must survive, or every lane reads idle.
if printf '%s' "$got" | grep -qE '[0-9]+ shells?'; then
    echo "ok: WORKING footer token survives"
else
    echo "FAIL: WORKING footer token lost"
    fail=1
fi

exit $fail
