# CLAUDE.md — `breed-claude/hooks`

**There is only `gate.py`. Never register a second PreToolUse hook.**

`gate.py` is the one dispatcher, registered once in `~/.claude/settings.json`
with `"matcher": "Bash"`. Every gate — including one that needs a different
`tool_name` (Edit, Write, NotebookEdit, MultiEdit, …) — is wired INTO
`gate.py`'s own dispatch, not given its own `PreToolUse` entry.

A hook file can exist on disk (symlinked via `install.sh`) without being wired
into `gate.py`'s dispatch — that means it is written but **not installed**.
Check `gate.py`'s own routing (currently Bash-only: it reads
`tool_input.command` and runs `GATES` against it) before assuming a hook that
exists is active. `jj-no-edit-on-pushed.py` is the known example: the file and
its symlink exist, but nothing invokes it, **by decision, not oversight** — see
below.

Do not widen `settings.json`'s matcher to add tool names, and do not add a
second entry to the `PreToolUse` array. If a new gate needs a different
`tool_name` or payload shape, that routing belongs inside `gate.py` — ask the
user before changing *how* gate.py decides what to run, not just *whether* to
run something.

## `jj-no-edit-on-pushed.py` stays uninstalled — decided, don't re-propose

It guards editing a file while `@` sits on an already-pushed commit (jj has no
staging area, so the edit silently amends the pushed commit). The only way to
catch that is a matcher covering Edit/Write/NotebookEdit/MultiEdit, since
Claude Code's hook dispatch is matcher-based BEFORE any hook code runs — there
is no way to see those tool calls from a Bash-only matcher, full stop.

Asked and explicitly rejected: running a hook on every file edit was judged
not worth it for what this one gate catches. Leave it unwired. If this
tradeoff is revisited, that is a new decision to ask for, not something to
infer from the file existing.
