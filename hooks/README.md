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

`_shellscan.py` is a shared helper both import, not a hook. It is not symlinked
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
  { "type": "command", "command": "python3 $HOME/.claude/hooks/jj-no-interactive.py" }
] } ] } }
```

Project-settings hooks are **hot-reloaded** — editing `settings.json` mid-session
registers the hook immediately and it takes effect on the next matching tool call.
No restart. So if a freshly-added hook does *not* appear in `/hooks`, that is a
real wiring problem (bad JSON, wrong path, non-executable script), not a stale
session. `/hooks` is read-only; there is no in-session approve step.

## Tests

```sh
bash tests/rg-flag-gate.sh        # 26 cases
bash tests/jj-no-interactive.sh   # 43 cases
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
