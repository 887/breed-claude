# hooks — PreToolUse(Bash) gates

Two `PreToolUse` gates on the `Bash` tool. Each blocks a command that *succeeds*
while doing the wrong thing — the failure mode a human never catches by reading
output, because there is no error to read.

Plain text on purpose: copy this directory to another machine, run `install.sh`,
paste the settings snippet. No package, no build step.

## The gates

| Hook | Scope | Installs to | Needs |
| --- | --- | --- | --- |
| `rg-flag-gate.py` | user (all projects) | `~/.claude/hooks/` | `python3` |
| `vcs-no-squash-gate.sh` | project (any `jj` repo) | `<repo>/.claude/hooks/` | `bash`, `jq`, `jj` |

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

### `vcs-no-squash-gate.sh` — two independent VCS safety checks

Each carries its **own** override, so disabling one never disables the other.

**A. No squash / no rewrite of shared history** (`FOUNDLINGS_ALLOW_HISTORY_REWRITE=1`)
blocks `jj squash`, `gh pr merge --squash`, `merge_method=squash`,
`jj rebase -b/--branch`, and any history-rewriting op (`describe`/`squash`/
`abandon`/`edit`/`metaedit`) aimed at an **already-bookmarked** revision.

Rationale: a jj change ID is durable across rebases and amends while a git hash
is not, so squashing destroys the only stable identifier the work has.

**B. No `jj new` stranding of a dirty `@`** (`FOUNDLINGS_ALLOW_JJ_NEW_STRANDING=1`)
blocks `jj new <target>` (a positional revset other than `@`, or `-A`/`-B`) while
`@` has real content. Those edits do **not** travel to the new commit — they stay
behind as a sibling and `@` becomes empty off the target. Nothing errors, so the
mistake is silent. The right move when `@` is dirty is `jj rebase -r @ -d <target>`.

Never blocked: the child-of-`@` forms (`jj new`, `jj new @`), or an already-empty
`@` where there is nothing to strand.

Check A is jj/gh-specific but repo-agnostic. The `FOUNDLINGS_` override prefix is
historical; rename it in your copy if you like — it appears in the hook and in
its message text.

## Install

```sh
./install.sh                 # user-scope hooks -> ~/.claude/hooks/
./install.sh /path/to/repo   # also install project-scope hooks into that repo
```

Existing files are backed up to `<name>.bak-<timestamp>` rather than
overwritten. The script does **not** edit any `settings.json` — it prints the
snippet and you merge it, because a settings file is hand-owned and clobbering
someone's other hooks to save a paste is a bad trade.

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
  { "type": "command", "command": "bash \"${CLAUDE_PROJECT_DIR:-.}/.claude/hooks/vcs-no-squash-gate.sh\"", "timeout": 30 }
] } ] } }
```

Project-settings hooks are **hot-reloaded** — editing `settings.json` mid-session
registers the hook immediately and it takes effect on the next matching tool
call. No restart. So if a freshly-added hook does *not* appear in `/hooks`, that
is a real wiring problem (bad JSON, wrong path, non-executable script), not a
stale session. `/hooks` is read-only; there is no in-session approve step.

## Tests

```sh
bash tests/rg-flag-gate.sh          # 26 cases
bash tests/vcs-no-squash-gate.sh    # 21 cases, builds throwaway jj repos
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
- `vcs-no-squash-gate.sh` cut its segment at the first `;&|`, so
  `jj new 2>&1 | tail` reduced to the fragment `2>` — not a flag, not `@`, so it
  was read as a revset target. Fixed by stripping redirections before the
  positional scan.

Regression cases for both are in the harnesses (`the recorded false positive`,
`bare jj new + stderr dup (the bug)`). Verified by running the suites against
the pre-fix hooks: 3 rg failures and 4 vcs failures, all green after. A fix
whose test never failed against the broken version is not evidence of anything.
