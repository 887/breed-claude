# hooks — PreToolUse(Bash) gates

Two `PreToolUse` gates on the `Bash` tool. Each blocks a command that *succeeds*
while doing the wrong thing — the failure mode a human never catches by reading
output, because there is no error to read.

Plain text on purpose: clone this repo on the other machine, run `install.sh`,
paste the settings snippet. No package, no build step. `install.sh` **symlinks**
back into the checkout, so from then on `git pull` is the whole update path —
don't copy the files out.

## The gates

| Hook | Scope | Installs to | Needs |
| --- | --- | --- | --- |
| `rg-flag-gate.py` | user (all projects) | `~/.claude/hooks/` | `python3` |
| `vcs-gate.py` | project (any `jj` repo) | `<repo>/.claude/hooks/` | `python3`, `jj` |

Scope is a property, not a folder — the table states it, so the files stay flat
and either one can be installed at either scope if you want it there.

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
`cross_org_peek` came back as `n` — a string containing no letter `n`.
Impossible under any rendering theory, exactly what `--replace=n` does.

Long forms pass through: say `--replace=` or `--encoding=` and the gate agrees
you meant it.

### `vcs-gate.py` — two independent VCS safety checks

Each carries its **own** override, so disabling one never disables the other.

**A. No squash / no rewrite of shared history** (`VCS_GATE_ALLOW_HISTORY_REWRITE=1`)
blocks `jj squash`, `gh pr merge --squash`, `merge_method=squash`,
`jj rebase -b/--branch`, and any history-rewriting op (`describe`/`squash`/
`abandon`/`edit`/`metaedit`) aimed at an **already-bookmarked** revision.

Rationale: a jj change ID is durable across rebases and amends while a git hash
is not, so squashing destroys the only stable identifier the work has.

**B. No `jj new` stranding of a dirty `@`** (`VCS_GATE_ALLOW_JJ_NEW_STRANDING=1`)
blocks `jj new <target>` (a positional revset other than `@`, or `-A`/`-B`) while
`@` has real content. Those edits do **not** travel to the new commit — they stay
behind as a sibling and `@` becomes empty off the target. Nothing errors, so the
mistake is silent. The right move when `@` is dirty is `jj rebase -r @ -d <target>`.

Never blocked: the child-of-`@` forms (`jj new`, `jj new @`), or an already-empty
`@` where there is nothing to strand.

**What check B actually does, measured** — not data loss, silent displacement. jj
snapshots the working copy into `@` before any command, then `jj new <target>`
makes a *new* empty commit off the target the working copy:

```
BEFORE  @ = ylrtnzww  empty=false   wip.txt on disk
AFTER   @ = qvkkkymv  empty=true    wip.txt GONE from the working dir
        ylrtnzww  empty=false  <- content safe, now an unnamed head
```

The content is recoverable via `jj log`, but the files vanish from your directory
and `jj st` says "no changes". If you then bookmark and push you push the **empty**
commit. The recommended remedy is verified too: `jj rebase -r @ -d <target>` keeps
the same change ID, moves the parent, and leaves the files in place.

**It scans command POSITIONS, not command text.** This is what makes it usable.
The original shell version pattern-matched the raw string, so any command that
merely *mentioned* a gated phrase was blocked — `rg 'jj squash' CLAUDE.md`, an
`echo` explaining the rule, an inline `jj describe -m` whose message quotes it, a
heredoc brief telling a helper what to avoid. Measured against a dirty `@`: **7 of
7** such commands tripped. It was self-demonstrating: the shell command written to
*test* the false positive was blocked by its own test data. Now the string is
segmented on real shell operators, each segment's command word is resolved
(skipping env assignments and `sudo`/`env`/`time`), and a check fires only when
that word is actually `jj` or `gh` — so quoted text, which stays one token, can
never be a command. Heredoc bodies are stripped as data, and `bash -c '…'` is
recursed into, which closes a false *negative* the text grep could not even see.

Check A is jj/gh-specific but repo-agnostic. The overrides were named
`FOUNDLINGS_ALLOW_*` while the hook lived in one project; they were renamed to
`VCS_GATE_ALLOW_*` when it became shared, because a project-branded env var on a
portable hook is just wrong. **The old names no longer work — there is no compat
alias**, so any muscle memory or script using them will find the gate still
blocking. A namespace was kept rather than going bare (`ALLOW_HISTORY_REWRITE`):
these variables disable safety checks, and a generic name is one an unrelated
tool could plausibly set, which would silently switch a gate off.

## Install

```sh
./install.sh                 # user-scope hooks -> ~/.claude/hooks/
./install.sh /path/to/repo   # also install project-scope hooks into that repo
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

An existing **real file** at a destination is left alone, not clobbered: the
script reports whether it differs and prints the `diff` and `ln -sfn` commands.
That case is a repo which **tracks its own** `.claude/hooks` (foundlings does) —
replacing a tracked file with a symlink would commit the symlink. So the shared
copy and a tracking repo's copy can drift, and the installer surfaces that rather
than silently picking a winner.

The script does **not** edit any `settings.json` — it prints the snippet and you
merge it, because a settings file is hand-owned and clobbering someone's other
hooks to save a paste is a bad trade.

### Registration

`~/.claude/settings.json` (user scope):

```json
{ "hooks": { "PreToolUse": [ { "matcher": "Bash", "hooks": [
  { "type": "command", "command": "python3 $HOME/.claude/hooks/rg-flag-gate.py" }
] } ] } }
```

`<repo>/.claude/settings.json` (project scope):

```json
{ "hooks": { "PreToolUse": [ { "matcher": "Bash", "hooks": [
  { "type": "command", "command": "python3 \"${CLAUDE_PROJECT_DIR:-.}/.claude/hooks/vcs-gate.py\"", "timeout": 30 }
] } ] } }
```

Project-settings hooks are **hot-reloaded** — editing `settings.json` mid-session
registers the hook immediately and it takes effect on the next matching tool
call. No restart. So if a freshly-added hook does *not* appear in `/hooks`, that
is a real wiring problem (bad JSON, wrong path, non-executable script), not a
stale session. `/hooks` is read-only; there is no in-session approve step.

## Tests

```sh
bash tests/rg-flag-gate.sh   # 26 cases
bash tests/vcs-gate.sh       # 31 cases, builds throwaway jj repos
```

Both harnesses invoke the **real** hook with synthetic `PreToolUse` payloads —
no double of the hook itself. The vcs harness creates temp `jj` repos per case
because check B asks jj whether `@` is empty, so a dirty `@` is the only way to
exercise it; nothing touches your working repo.

Every case asserts **both** directions. A gate is only trustworthy once it has
been observed *blocking* what it must block — a suite that only checks the pass
direction would go green against a hook that returns 0 unconditionally, which is
precisely how the first cut of `rg-flag-gate.py` shipped broken (it read the
script from stdin, so the payload never arrived and everything passed).

### Why the false-positive cases outnumber the true positives

A gate that blocks correct commands gets routed around, and the workaround is
its override env var — which also disables the case the gate exists to catch. So
a false positive is not cosmetic; it is how the real protection gets switched
off. Both hooks shipped with one, from the **same** root cause: a shell operator
glued to adjacent text (`2>/dev/null;`, `2>&1`, `cmd|rg`) is not recognised as a
command boundary, so a later command's flag gets attributed to the gated one.

- `rg-flag-gate.py` used `shlex.split`, which returns `2>/dev/null;` as one
  opaque token matching no separator. Fixed by lexing with
  `punctuation_chars=True` so operators arrive as their own tokens. Caught a
  real `-r` belonging to `jj file list`.
- `vcs-gate.py` (then a shell script) cut its segment at the first `;&|`, so
  `jj new 2>&1 | tail` reduced to the fragment `2>` — not a flag, not `@`, so it
  was read as a revset target. Fixed by stripping redirections before the
  positional scan.

Regression cases for both are in the harnesses (`the recorded false positive`,
`bare jj new + stderr dup (the bug)`). Verified by running the suites against
the pre-fix hooks: 3 rg failures and 4 vcs failures, all green after. A fix
whose test never failed against the broken version is not evidence of anything.
