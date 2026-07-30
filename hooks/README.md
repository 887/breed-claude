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
  { "type": "command", "command": "python3 $HOME/.claude/hooks/rg-flag-gate.py" }
] } ] } }
```

Project-settings hooks are **hot-reloaded** — editing `settings.json` mid-session
registers the hook immediately and it takes effect on the next matching tool call.
No restart. So if a freshly-added hook does *not* appear in `/hooks`, that is a
real wiring problem (bad JSON, wrong path, non-executable script), not a stale
session. `/hooks` is read-only; there is no in-session approve step.

## Tests

```sh
bash tests/rg-flag-gate.sh   # 26 cases
```

The harness invokes the **real** hook with synthetic `PreToolUse` payloads — no
double of the hook itself.

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
