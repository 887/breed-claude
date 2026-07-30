# statusline — the Claude Code status line

`model | dir | jj change · bookmark | context used | burn rate | weekly quota`

Shareable for the same reason the [`hooks`](../hooks/) are: it encodes facts about
**tools** — the Claude Code status-line JSON contract, jj's templating, the shape of
the usage payload — not a preference about any one codebase. Nothing in it is
host-specific, so a clone plus `install.sh` is the whole setup.

## What it shows, and the two non-obvious bits

- **model** and **dir** (basename only — a full path eats the line).
- **jj change + nearest bookmark**, via
  `jj log -r @ --ignore-working-copy -T 'change_id.shortest(8)'`.
  **`--ignore-working-copy` is load-bearing, not a micro-optimisation.** A status
  line runs on a timer, and without that flag every render would SNAPSHOT the working
  copy — mutating the repo as a side effect of *displaying* it, racing anything else
  holding the working-copy lock. The `jj` calls also carry a 2 s timeout and swallow
  `OSError` so a missing `jj`, or a directory that is not a repo, degrades to "no jj
  segment" instead of an error line.
- **context used**, as a percentage of the model's real window. The window is read
  from the model id, including the `[1m]` suffix — a 1M-context session must not be
  measured against a 200k denominator, or the number is wrong in the direction that
  matters (it under-reports pressure right when you are deciding whether to compact).
- **burn rate** and the **weekly quota** with its reset time, when the payload
  carries them; absent rather than zero when it does not.

## Install

```sh
./install.sh          # from hooks/, which installs this too
```

It symlinks to `~/.claude/statusline.py` and prints the `settings.json` block:

```json
{ "statusLine": { "type": "command", "command": "python3 ~/.claude/statusline.py", "padding": 0 } }
```

**Symlink, never a copy** — the hard rule from [`../CLAUDE.md`](../CLAUDE.md): this
repo is the source of truth, so `git pull` alone updates behaviour, and editing the
installed path edits *this repo's* file through the link (real, uncommitted, and
invisible except in `git status` here).

## Absent, not zero

Every segment is omitted when its input is missing, rather than rendered as `0`.
That is the repo-wide habit of keeping "no data" distinguishable from "measured
zero" — a status line claiming `0%` burn reads as a fact, and a wrong fact on
screen is worse than a shorter line.
