#!/usr/bin/env bash
# ============================================================================
# Test harness for hooks/git-no-interactive.py
# ============================================================================
# Invokes the REAL hook with synthetic PreToolUse payloads. No git repo is needed:
# the decision is made entirely from the command string, which is the point — a
# command that would hang must be refused BEFORE it runs, not diagnosed after.
#
# Both directions are asserted, and the pass direction carries more cases than the
# block direction on purpose. A gate that over-blocks gets routed around via its
# override, which disables it wholesale — so a false positive is not cosmetic, it
# is how the protection gets switched off.
#
# Every expectation below was PROBED against real git (GIT_EDITOR set to a script
# that logs then sleeps, stdin at /dev/null, under `timeout`, with a control case
# that had to hang or the run was discarded) rather than recalled. The pairs that
# make that worth doing:
#   --fixup passes but --squash blocks;  -C passes but -c blocks;
#   `commit -i` is --include and passes, while `add -i` is a TUI and blocks;
#   bare `merge`/`revert` pass because their editor is tty-conditional.
#
# Run: bash tests/git-no-interactive.sh

set -uo pipefail

HOOK="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/git-no-interactive.py"
[ -f "$HOOK" ] || { echo "cannot find hook at $HOOK" >&2; exit 1; }

pass=0
fail=0

run() {   # run <expected-exit> <label> <command>
  local want="$1" label="$2" cmd="$3" got
  got="$(
    python3 - "$cmd" <<'PY' | python3 "$HOOK" >/dev/null 2>&1; echo $?
import json, sys
print(json.dumps({"tool_name": "Bash", "tool_input": {"command": sys.argv[1]}}))
PY
  )"
  if [ "$got" = "$want" ]; then
    pass=$((pass + 1)); printf '  ok    (exit %s) %s\n' "$got" "$label"
  else
    fail=$((fail + 1)); printf '  FAIL  (exit %s, want %s) %s\n' "$got" "$want" "$label"
  fi
}

echo "== must BLOCK: commit would open an editor =="
run 2 "bare commit"                    'git commit'
run 2 "commit -a"                      'git commit -a'
run 2 "commit --amend, no --no-edit"   'git commit --amend'
run 2 "commit --amend -a"              'git commit --amend -a'
run 2 "--squash does not give a msg"   'git commit --squash=HEAD'
run 2 "-e forces editor despite -m"    'git commit -m wip -e'
run 2 "--edit long form"               'git commit -m wip --edit'
run 2 "-c REedits (lowercase)"         'git commit -c HEAD'
run 2 "--reedit-message"               'git commit --reedit-message=HEAD'
run 2 "-t template"                    'git commit -t tmpl.txt'
run 2 "--template="                    'git commit --template=tmpl.txt'
run 2 "--allow-empty-message"          'git commit --allow-empty-message'
run 2 "commit -p is patch mode"        'git commit -p'
run 2 "commit --patch"                 'git commit --patch'
run 2 "-e inside a short cluster"      'git commit -ae'

echo
echo "== must BLOCK: other editor openers =="
run 2 "rebase -i"                      'git rebase -i main'
run 2 "rebase --interactive"           'git rebase --interactive origin/main'
run 2 "rebase -i in a cluster"         'git rebase -im main'
run 2 "rebase --edit-todo"             'git rebase --edit-todo'
run 2 "pull --rebase=interactive"      'git pull --rebase=interactive origin main'
run 2 "merge --edit"                   'git merge --edit side'
run 2 "merge -e"                       'git merge -e side'
run 2 "revert --edit"                  'git revert --edit HEAD'
run 2 "cherry-pick -e"                 'git cherry-pick -e abc123'
run 2 "tag -a without -m"              'git tag -a v1.0'
run 2 "tag --annotate without -m"      'git tag --annotate v1.0'
run 2 "tag -s without -m"              'git tag -s v1.0'
run 2 "notes add without -m"           'git notes add HEAD'
run 2 "notes append without -m"        'git notes append HEAD'
run 2 "notes edit takes no -m at all"  'git notes edit HEAD'
run 2 "branch --edit-description"      'git branch --edit-description'
run 2 "config --edit"                  'git config --edit'
run 2 "config -e"                      'git config -e'
run 2 "config edit subcommand"         'git config edit'
run 2 "add -e"                         'git add -e'
run 2 "add --edit"                     'git add --edit'

echo
echo "== must BLOCK: stdin TUIs that exit 0 having done nothing =="
run 2 "add -p"                         'git add -p'
run 2 "add --patch"                    'git add --patch'
run 2 "add -i"                         'git add -i'
run 2 "add --interactive"              'git add --interactive'
run 2 "checkout -p"                    'git checkout -p'
run 2 "restore -p"                     'git restore -p src/'
run 2 "reset -p"                       'git reset -p'
run 2 "stash push -p"                  'git stash push -p'
run 2 "clean -i"                       'git clean -i'
run 2 "am -i"                          'git am -i patch.mbox'
run 2 "mergetool"                      'git mergetool'
run 2 "difftool without --no-prompt"   'git difftool HEAD~1'

echo
echo "== must PASS: measured to need no editor =="
run 0 "commit -m"                      'git commit -m "a message"'
run 0 "commit -am (cluster carries m)" 'git commit -am "a message"'
run 0 "commit -a -m"                   'git commit -a -m wip'
run 0 "commit --message="              'git commit --message=wip'
run 0 "commit -F file"                 'git commit -F msg.txt'
run 0 "commit --file="                 'git commit --file=msg.txt'
run 0 "-C reuses (uppercase)"          'git commit -C HEAD'
run 0 "--reuse-message"                'git commit --reuse-message=HEAD'
run 0 "--fixup builds its own msg"     'git commit --fixup=HEAD'
run 0 "--amend --no-edit"              'git commit --amend --no-edit'
run 0 "--amend -m"                     'git commit --amend -m redone'
run 0 "commit -i is --INCLUDE"         'git commit -i src/f -m msg'
run 0 "--squash WITH -m"               'git commit --squash=HEAD -m "squash! x"'
run 0 "bare merge (tty-conditional)"   'git merge side'
run 0 "merge --no-ff"                  'git merge --no-ff side'
run 0 "merge -m"                       'git merge -m "merge side" side'
run 0 "plain rebase"                   'git rebase main'
run 0 "rebase --onto"                  'git rebase --onto main base topic'
run 0 "rebase --abort"                 'git rebase --abort'
run 0 "rebase --continue"              'git rebase --continue'
run 0 "pull --rebase (plain)"          'git pull --rebase origin main'
run 0 "bare revert"                    'git revert HEAD'
run 0 "revert --no-edit"               'git revert --no-edit HEAD'
run 0 "bare cherry-pick"               'git cherry-pick abc123'
run 0 "tag -a WITH -m"                 'git tag -a v1.0 -m "release"'
run 0 "tag -am cluster"                'git tag -am "release" v1.0'
run 0 "tag -a with -F"                 'git tag -a v1.0 -F notes.txt'
run 0 "lightweight tag"                'git tag v1.0'
run 0 "tag --list"                     'git tag --list'
run 0 "notes add -m"                   'git notes add -m note HEAD'
run 0 "notes show"                     'git notes show HEAD'
run 0 "difftool -y"                    'git difftool -y HEAD~1'
run 0 "difftool --no-prompt"           'git difftool --no-prompt HEAD~1'
run 0 "git add paths"                  'git add src/ tests/'
run 0 "git add -A"                     'git add -A'
run 0 "clean -n"                       'git clean -n'
run 0 "clean -fd"                      'git clean -fd'
run 0 "log -p is patch OUTPUT"         'git log -p -3'
run 0 "diff, show, status"             'git diff --stat && git show HEAD && git status'
run 0 "push, fetch"                    'git push origin main && git fetch --all'
run 0 "stash push with paths"          'git stash push -- src/f'
run 0 "checkout a branch"              'git checkout -b feature'
run 0 "restore with --source"          'git restore --source HEAD~1 -- src/f'
run 0 "reset --hard"                   'git reset --hard origin/main'

echo
echo "== must PASS: global flags before the subcommand =="
run 0 "-c consumes its value"          'git -c core.editor=false commit -m wip'
run 2 "-c value then bare commit"      'git -c user.name=x commit'
run 0 "-C <path> consumes its value"   'git -C /repo commit -m wip'
run 2 "-C <path> then bare commit"     'git -C /repo commit'
run 0 "--git-dir consumes its value"   'git --git-dir=/r/.git commit -m wip'
run 0 "no subcommand at all"           'git --version'
run 0 "git help"                       'git help commit'
run 0 "--help never runs the thing"    'git commit --help'
run 0 "-h short help"                  'git rebase -h'
run 0 "help on a TUI subcommand"       'git add --help'

echo
echo "== must PASS: MENTIONED, not run (command-position regression guard) =="
run 0 "grepping for it"                'rg "git commit" docs/'
run 0 "explaining it in an echo"       'echo "never run git rebase -i here"'
run 0 "naming it in a commit message"  'git commit -m "document why git add -p is banned"'
run 0 "in a heredoc brief"             'cat > brief.txt <<EOF
Do not run git commit without -m, and never git rebase -i.
EOF'
run 0 "inside a python string"         'python3 -c "print(\"git config --edit\")"'
run 0 "a path merely ending in git"    './tools/mygit commit'
run 0 "not git at all"                 'jj describe -m wip'
run 0 "no git anywhere"                'ls -la && echo done'

echo
echo "== must PASS: real invocation AFTER another command (boundary guard) =="
run 0 "redirect then a safe git"       'rg -n pat f 2>/dev/null; git status'
run 2 "redirect then a blocked git"    'rg -n pat f 2>/dev/null; git commit'
run 0 "pipeline into git apply"        'git diff | git apply --check'
run 2 "&& chain reaching a blocked one" 'git add -A && git commit'
run 0 "&& chain, all safe"             'git add -A && git commit -m wip && git push'
run 2 "bash -c hides nothing"          'bash -c "git commit"'
run 0 "bash -c with a safe one"        'bash -c "git commit -m wip"'

echo
echo "== override =="
run 0 "override as an assignment"      'GIT_GATE_ALLOW_INTERACTIVE=1 git commit'
run 2 "override merely MENTIONED"      'echo "set GIT_GATE_ALLOW_INTERACTIVE=1" && git commit'

echo
printf 'passed=%d failed=%d\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1
