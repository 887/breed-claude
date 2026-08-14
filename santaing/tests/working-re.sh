#!/usr/bin/env bash
# Behavioural test for WORKING_RE — six real pane cases, both directions.
RE="$1"
pass=0; fail=0
check() { # name expected(0=match,1=nomatch) text
  local name="$1" want="$2" text="$3"
  if printf '%s' "$text" | grep -qE "$RE"; then got=0; else got=1; fi
  if [ "$got" = "$want" ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "  FAIL $name (want=$want got=$got)"; fi
}
# MUST match (lane is working)
check "codex working"      0 '• Working (2m 44s • esc to interrupt) '
check "claude streaming"   0 '✻ Brewed for 4m 54s · ↓ 6.4k tokens'
check "claude bg terminal" 0 '· 1 background terminal running · /ps to view'
check "claude shell+mon"   0 '⏵⏵ bypass permissions on · 1 shell, 1 monitor'
check "claude monitor msg" 0 'Brewed for 4m 54s · 1 shell, 1 monitor still running'
check "codex bash running" 0 '⎿  Running… (10s · timeout 10m)'
# MUST NOT match (lane is genuinely idle)
check "claude idle prompt" 1 '❯ 
  Opus 5 (1M context) │ foundlings-elf5 │ ctx 205k/1.00M (21%) │ wk 21% used'
check "codex idle footer"  1 '› Write tests for @filename
  gpt-5.6-sol medium · ~/workspace/foundlings · foundlings'
check "codex goal achieved" 1 '─ Worked for 1h 20m 33s ───────────
› Explain this codebase'
echo "pass=$pass fail=$fail"
[ "$fail" = 0 ]
