# hooks — PreToolUse(Bash) gates

Gates that live here are **tool-level and project-agnostic**: they block a command
that *succeeds while doing the wrong thing*, for reasons that hold in any repo,
in any language. That is the bar for inclusion, and it is narrow on purpose — see
"What does NOT belong here" below.

Clone this repo on the other machine, run `install.sh`, paste the settings
snippet. No package, no build step. `install.sh` **symlinks** back into the
checkout, so from then on `git pull` is the whole update path — don't copy the
files out.

## The gates

| Hook | Scope | Installs to | Needs |
| --- | --- | --- | --- |
| `rg-flag-gate.py` | user (all projects) | `~/.claude/hooks/` | `python3` |
| `jj-no-interactive.py` | user (all projects) | `~/.claude/hooks/` | `python3` |
| `git-no-interactive.py` | user (all projects) | `~/.claude/hooks/` | `python3` |
| `jj-no-update-stale.py` | user (all projects) | `~/.claude/hooks/` | `python3` |

`_shellscan.py` is a shared helper the others import, not a hook. It is not symlinked
and does not need to be: each hook resolves its own symlink back into this repo,
so the module is found beside the real file. That is another reason these are
symlinked rather than copied — a lone copied hook has no module to import.

### `rg-flag-gate.py` — ripgrep short flags that mean something else

Two grep habits are silently wrong in ripgrep:

- **`-r` is `--replace=TEXT`**, not grep's recursive — ripgrep recurses by
  default. `rg -rn 'pat' .` parses as `--replace=n` and rewrites every match to
  the literal `n`. **Exit 0, no error, output destroyed.**
  ([anthropics/claude-code#62016](https://github.com/anthropics/claude-code/issues/62016))
- **`-E` is `--encoding=ENC`**, not grep's extended-regex — ripgrep is already
  extended-regex, so `-E` is never needed for alternation. `rg -E 'a|b' f`
  consumes the pattern as an encoding name.

The smoking gun that `-r` is `--replace` and not a display bug: a search for
`cross_org_peek` came back as `n` — a string containing no letter `n`. Impossible
under any rendering theory, exactly what `--replace=n` does.

Long forms pass through: say `--replace=` or `--encoding=` and the gate agrees you
meant it.

This qualifies as shareable because it encodes a fact about **ripgrep**, not a
preference about a codebase. It is wrong to type `rg -rn` anywhere, by anyone.

### `jj-no-interactive.py` — jj commands that would open an editor and hang

An agent has no terminal to type into. A jj command that opens `$EDITOR`, a diff
editor, or a merge tool therefore does **not fail** — it waits forever, holding
the tool call open until it times out. Nothing errors, nothing prints, and the
transcript shows a command that simply never returned. For unattended work that
is the worst failure shape there is: no signal at all.

Blocked, with the non-interactive form named in the message. Each rule was read
off `jj help` rather than assumed:

| Blocked | Use instead |
| --- | --- |
| `-i` / `--interactive`, any subcommand | select with explicit paths |
| `--tool <t>` — jj's own help says it *implies* `--interactive` | omit it; `--tool :ours`/`:theirs`/`:none` are non-interactive builtins and **do** pass |
| `describe` / `commit` with no `-m`/`--message`/`--stdin` | `-m "msg"`, or `-m "$(cat msg.txt)"` for a long one |
| `--editor` — forces an editor open *even alongside* `-m` | drop it |
| `split` — "Starts a diff editor", always | `jj new` + `jj squash --into`, or squash by path |
| `diffedit` — exists only to open a diff editor | edit files and let jj snapshot, or `jj restore --from` |
| `resolve` with neither `-l/--list` nor a builtin tool | `--list` to inspect, then edit the real conflict markers |

Override for a human at a real terminal: `JJ_GATE_ALLOW_INTERACTIVE=1`.

This qualifies as shareable on the same test as the rg gate: it encodes a fact
about **jj plus the absence of a tty**, true in every repository. Note what it
deliberately does *not* do — it takes no position on squashing, merge method, or
commit shape. Those are project decisions and belong to the project.

### `git-no-interactive.py` — the same hazard, in git

Git has the larger surface of the two, and the two failure shapes are worth
keeping apart:

- **Opens `$GIT_EDITOR` → hangs.** `git commit` with no message flag, `--amend`
  without `--no-edit`, `git rebase -i`, `git tag -a` without `-m`, `git notes
  add`/`edit`, `git branch --edit-description`, `git config --edit`, and every
  `-e/--edit` form. No error, no output — the call sits there until it times out.
- **Reads a TUI off stdin → exits 0 having done nothing.** `git add -p`/`-i`,
  `git commit -p`, `-p` on `checkout`/`restore`/`reset`/`stash push`, `git clean
  -i`, `git am -i`, `git mergetool`, `git difftool` without `--no-prompt`. These
  don't hang: they hit EOF immediately and return success having staged, cleaned,
  or applied *nothing*. That is the `rg -r` shape — succeeds while doing the wrong
  thing — so they are blocked too.

**Every rule was probed against real git, not recalled.** `GIT_EDITOR` set to a
script that logs and then sleeps, stdin at `/dev/null`, under `timeout`, with a
control case in each run that had to report a hang or the run was thrown away.
That control earned its keep three times: one harness ran the *label* as the
command, another had `git clean -fd` delete the probe editor out of the repo it
was probing, and both produced a clean sheet of plausible "no editor" rows. A
uniform negative is usually a broken measurement, not a finding.

Six verdicts came out opposite to what the flag names suggest, and each is a
regression case in the suite:

| Looks blockable | Actually | Why |
| --- | --- | --- |
| `git commit --squash=<c>` | **blocks** | unlike `--fixup`, it does *not* supply a finished message — the editor still opens |
| `git commit --fixup=<c>` | passes | builds the message itself |
| `git commit -c <c>` | **blocks** | lowercase `-c` is `--reedit-message` |
| `git commit -C <c>` | passes | uppercase `-C` is `--reuse-message`, no editor |
| `git commit -i` | passes | for `commit`, `-i` is `--include` — *not* interactive (whereas `git add -i` is) |
| `git merge`, `git revert` | passes | their editor is tty-conditional; with no terminal, git writes the default message |

`git commit -am "msg"` also has to pass, which means short-flag **clusters** must
be unbundled — a whole-token check misses the `m` in `-am` and blocks the single
most common commit form. `--allow-empty-message`, by contrast, does *not* skip the
editor, so it is not treated as a message flag.

Override for a human at a real terminal: `GIT_GATE_ALLOW_INTERACTIVE=1`.

Shareable on the same test as its siblings: it encodes a fact about **git plus the
absence of a tty**. It takes no position on commit shape, squash-merges, rebase
policy, or branch naming — `git rebase <upstream>`, `git merge --no-ff`, and
`git commit --amend --no-edit` all pass, because whether you *should* run them is
the project's call, not this hook's.

### `jj-no-update-stale.py` — `jj workspace update-stale` destroys work unrecoverably

Refused outright. An agent cannot tell from the outside whether the target
workspace has un-snapshotted files in it, and if it does they are gone for good —
so the only safe default is to stop and let a human look.

When workspace A rebases or describes a commit that workspace B has checked out,
jj marks B *stale*. `jj workspace update-stale` in B then re-checks-out the new
commit, **overwriting B's on-disk files**. jj does not snapshot B first, so
un-snapshotted work there is destroyed with **no op-log record** — jj never saw
it, so `jj undo` cannot help. Unrecoverable by design.

What makes a guard necessary rather than merely nice is the second-order trap:
snapshotting a *stale* workspace **fails**, because jj refuses to run there. So
the obvious defensive sequence — snapshot first, then update-stale — silently
no-ops on step one and then destroys the work on step two. Being careful by hand
is not sufficient, which is why this is mechanical.

Rescue procedure, named in the block message: read what is on disk (jj cannot help
— that is the problem), `cp -a <workspace> /tmp/ws-rescue`, then deliberately
`JJ_ALLOW_UNSAFE_UPDATE_STALE=1 jj workspace update-stale`, then put back what you
rescued. If the workspace is empty or disposable, the override alone is the whole
procedure.

An earlier cut of this hook took the backup *itself* — tar the workspace, then
allow the command. That was too much: a gate that copies gigabytes is doing work
the human should be deciding about, and it made the failure modes (disk full,
partial copy, excludes wrong) the gate's problem rather than obviously nobody's.
Refusing is smaller, and it puts the judgement where it belongs.

The override is scoped **per command segment**, not across the whole string.
Checking the string was an accidental escape hatch:
`JJ_ALLOW_UNSAFE_UPDATE_STALE=1 ls; jj workspace update-stale` would have disabled
the gate for a command the override was never attached to. It does carry into
`bash -c '…'`, because there it really does reach the inner command through the
environment. Both directions are regression cases.

**Why user scope, emphatically.** It encodes a fact about jj, so it passes the bar
like its siblings. But it also *cannot work* as a project hook. Project hooks are
registered as `${CLAUDE_PROJECT_DIR:-.}/.claude/hooks/…`, and `CLAUDE_PROJECT_DIR`
is unset whenever the session root is not the repo. An orchestrator session
driving several `jj workspace add` checkouts from a different cwd therefore
enforces **zero** gate legs — verified by running a command the project gate
should have blocked and watching it sail through to jj untouched. That is exactly
the multi-workspace arrangement where staleness arises and where update-stale gets
run, so a project-scoped copy of this guard is inert precisely when it is needed.
Anything standing between an agent and **irreversible data loss** has to be user
scope for that reason alone.

## What does NOT belong here

**A hook that enforces one project's conventions.** The distinction is whether the
hook would be *correct* in a repo that has never heard of the project it came from.

Worked example, because I got this wrong: foundlings has a
`vcs-gate.py` blocking `jj squash`, PR squash-merges, whole-branch rebases, and
`jj new <target>` while `@` is dirty. I briefly shipped it here labelled "any `jj`
repo". That was wrong — its own error message says *"Repo rule (CLAUDE.md): we
keep commits separate — no squashing"*, which is that repo's decision. Plenty of
jj repos squash deliberately, and squash-merge is the default on many forges.
Installing it elsewhere would impose one project's convention as if it were a
tool-level truth, and the person hitting it would have no idea why.

Its second check (`jj new` stranding a dirty `@`) describes a real jj hazard that
would bite anyone — but *blocking* it is still a policy call, and it is entangled
with check A in one file and one message vocabulary. It stays with the repo whose
rules it enforces: `foundlings/.claude/hooks/vcs-gate.py`, version-controlled
there, gated by that repo's own history.

Keeping it out also removes a duplication: while it lived in both places the two
copies could drift, and nothing would say which was authoritative.

**Rule of thumb.** Encodes a fact about a *tool* (`rg` flags, a shell parsing
trap) → shareable, put it here. Encodes a decision about a *codebase* (commit
shape, merge method, branch policy) → belongs to that codebase, in its own
`.claude/hooks`, tracked in its own history.

## Install

```sh
./install.sh
```

**Symlinks, not copies** — per the hard rule in [`../CLAUDE.md`](../CLAUDE.md):
this repo is the source of truth, so every install points back at a checkout and
`git pull` alone updates behaviour. A copy keeps working while going stale, which
is the worst failure shape for a safety gate: it still runs, just not the version
you think it is.

**Corollary, and it applies to Claude too: do not edit the installed path.**
Editing `~/.claude/hooks/rg-flag-gate.py` edits *this repo's* file through the
symlink — a real change that is uncommitted and invisible, showing up only in
`git status` here. Edit the file in this repo and commit it.

An existing **real file** at a destination is left alone rather than clobbered:
the script reports whether it differs and prints the `diff` and `ln -sfn`
commands. A file that is version-controlled at its destination is never touched at
all, because replacing it with a symlink would commit the symlink.

The script does **not** edit any `settings.json` — it prints the snippet and you
merge it, because a settings file is hand-owned and clobbering someone's other
hooks to save a paste is a bad trade.

### Registration

`~/.claude/settings.json`:

```json
{ "hooks": { "PreToolUse": [ { "matcher": "Bash", "hooks": [
  { "type": "command", "command": "python3 $HOME/.claude/hooks/rg-flag-gate.py" },
  { "type": "command", "command": "python3 $HOME/.claude/hooks/jj-no-interactive.py" },
  { "type": "command", "command": "python3 $HOME/.claude/hooks/git-no-interactive.py" },
  { "type": "command", "command": "python3 $HOME/.claude/hooks/jj-no-update-stale.py" }
] } ] } }
```

Project-settings hooks are **hot-reloaded** — editing `settings.json` mid-session
registers the hook immediately and it takes effect on the next matching tool call.
No restart. So if a freshly-added hook does *not* appear in `/hooks`, that is a
real wiring problem (bad JSON, wrong path, non-executable script), not a stale
session. `/hooks` is read-only; there is no in-session approve step.

## Tests

```sh
bash tests/rg-flag-gate.sh         # 26 cases
bash tests/jj-no-interactive.sh    # 50 cases
bash tests/git-no-interactive.sh   # 119 cases
bash tests/jj-no-update-stale.sh   # 33 cases
```

Each harness invokes the **real** hook with synthetic `PreToolUse` payloads — no
double of the hook itself. Neither needs a repo: both decide from the command
string alone, which is the point — a command that would hang must be refused
*before* it runs, not diagnosed after.

Every case asserts **both** directions. A gate is only trustworthy once it has
been observed *blocking* what it must block; a suite that only checked the pass
direction would go green against a hook that returns 0 unconditionally — which is
precisely how the first cut of this hook shipped broken (it read the script from
stdin, so the payload never arrived and everything passed).

### Why the false-positive cases outnumber the true positives

A gate that blocks correct commands gets routed around, and the workaround is
indiscriminate — for a gate with an override env var, it switches the whole check
off. So a false positive is not cosmetic; it is how the real protection gets
disabled.

This hook shipped with one: it used `shlex.split`, which returns `2>/dev/null;` as
a single opaque token matching no separator. The scanner therefore never saw the
command boundary and kept attributing later flags to `rg` — it blocked
`rg -n pat f 2>/dev/null; jj file list -r main`, where the `-r` is jj's. Fixed by
lexing with `punctuation_chars=True` so operators arrive as their own tokens.
Regression case: `the recorded false positive`. Verified by running the suite
against the pre-fix hook — 3 failures, all green after. A fix whose test never
failed against the broken version is not evidence of anything.

### When there is no broken version to test against

The git suite passed 116/116 on its first run, which is not evidence either — the
same sheet of greens is what a hook returning 0 unconditionally produces. So it was
run against three deliberate mutants instead, and it has to kill all three:

| Mutant | Expected | Observed |
| --- | --- | --- |
| `verdict()` returns `None` always (allow everything) | every block case fails | 54 failures |
| scan raw `shlex.split` tokens instead of command positions | the mention/boundary cases fail | 54 failures |
| `shorts()` ignores clusters longer than one letter | `git commit -am` false-positives | caught, plus `rebase -im` |

Mutant 2 is the one that matters most: it fails *pass*-direction cases, so it
proves the suite constrains over-blocking and not just under-blocking.
