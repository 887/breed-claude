#!/usr/bin/env bash
# Tests for set-elf-goal.sh with a stub `tmux`: the stub serves a canned pane and records send-keys.
#   case 1: menu names OUR brief  -> Enter pressed, then footer "Pursuing goal (2s)" -> exit 0
#   case 2: menu names ANOTHER objective -> Enter NEVER pressed, exit 1
#   case 3: no menu, footer already "Pursuing goal (4s)" naming our brief -> exit 0, no Enter
#   case 4: goal too long (brief path too long) -> exit 1 before sending anything
set -uo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
T="$(mktemp -d "${TMPDIR:-/tmp}/setgoal-test-XXXXXX")"
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin"
BRIEF="$T/brief-ours.md"; printf 'x\n' > "$BRIEF"
fail=0
ok() { printf 'ok   %s\n' "$1"; }
bad() { printf 'FAIL %s\n' "$1"; fail=1; }

# Stub tmux: state files drive the pane. `send-keys Enter` flips the pane to the "after" state.
cat > "$T/bin/tmux" <<'STUB'
#!/usr/bin/env bash
case "$1" in
  has-session) exit 0 ;;
  display-message) echo codex ;;
  capture-pane) cat "$STUB_PANE" ;;
  send-keys) shift; if printf '%s' "$*" | grep -q 'Enter'; then echo ENTER >> "$STUB_LOG"; [ -f "$STUB_AFTER" ] && cp "$STUB_AFTER" "$STUB_PANE"; fi ;;
  load-buffer|paste-buffer|delete-buffer) : ;;
  *) : ;;
esac
STUB
chmod +x "$T/bin/tmux"
# Stub talk-to-elf (delivery is not under test here).
printf '#!/usr/bin/env bash\nexit 0\n' > "$T/talk"; chmod +x "$T/talk"

run() { PATH="$T/bin:$PATH" STUB_PANE="$T/pane" STUB_AFTER="$T/after" STUB_LOG="$T/log" TALK="$T/talk" POLL=0 "$HERE/set-elf-goal.sh" "$@" >"$T/out" 2>&1; }

CODEX='  ← for agents · ? for shortcuts'

# case 1: overlay menu (other text shares the rows; a multibyte bullet shifts byte offsets)
printf '• You ran something   Replace goal?\n  └ output here         New objective: Santa'"'"'s binding assignment in\n                       %s (read it first);\n                       replaces older goals\n\n                       › 1. Replace current goal  Set the new objective\n                         2. Cancel                Keep the current goal\n%s\n' "$BRIEF" "$CODEX" > "$T/pane"
printf '› Ask Codex to do anything\n  GPT  · ~/x · Pursuing goal (2s)\n%s\nSanta'"'"'s binding assignment in %s\n' "$CODEX" "$BRIEF" > "$T/after"
: > "$T/log"; rm -f "$T/out"
if run elf9 "$BRIEF" --wait 6 && grep -q ENTER "$T/log" && grep -q 'PURSUING' "$T/out"; then ok "case1 enter pressed on our menu, pursuit proven"; else bad "case1: $(cat "$T/out")"; fi

# case 2: someone else's objective
printf '• x   Replace goal?\n  └ y         New objective: do something else entirely at /tmp/other.md\n\n                       › 1. Replace current goal  Set the new objective\n                         2. Cancel                Keep the current goal\n%s\n' "$CODEX" > "$T/pane"
rm -f "$T/after"; : > "$T/log"
if run elf9 "$BRIEF" --wait 3; then bad "case2 should fail"; elif ! grep -q ENTER "$T/log"; then ok "case2 never pressed Enter on a foreign menu"; else bad "case2 pressed Enter on foreign menu"; fi

# case 3: no menu, already pursuing our brief
printf '› Ask Codex to do anything\n  GPT · Pursuing goal (4s)\n%s\nSanta'"'"'s binding assignment in %s\n' "$CODEX" "$BRIEF" > "$T/pane"
: > "$T/log"
if run elf9 "$BRIEF" --wait 6 && ! grep -q ENTER "$T/log"; then ok "case3 pursuing without a menu"; else bad "case3: $(cat "$T/out")"; fi

# case 4: goal over the byte limit
LONG="$T"; for n in 1 2 3 4 5 6; do LONG="$LONG/$(printf 'd%.0s' $(seq 1 60))"; done; mkdir -p "$LONG"; printf 'x\n' > "$LONG/b.md"
if run elf9 "$LONG/b.md" --wait 3; then bad "case4 should fail"; elif grep -q 'too long' "$T/out"; then ok "case4 refuses an over-long goal"; else bad "case4: $(cat "$T/out")"; fi

exit $fail
