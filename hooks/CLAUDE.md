# CLAUDE.md — `breed-claude/hooks`

**There is only `gate.py`. Never register a second PreToolUse hook.**

`gate.py` is the one dispatcher, registered once in `~/.claude/settings.json`
with `"matcher": "Bash"`. Every gate — including one that needs a different
`tool_name` (Edit, Write, NotebookEdit, MultiEdit, …) — is wired INTO
`gate.py`'s own dispatch, not given its own `PreToolUse` entry.

A hook file can exist on disk (symlinked via `install.sh`) without being wired
into `gate.py`'s dispatch — that means it is written but **not installed**.
Check `gate.py`'s own routing (it reads `tool_input.command` and runs `GATES`
against it) before assuming a hook that exists is active.

Do not widen `settings.json`'s matcher to add tool names, and do not add a
second entry to the `PreToolUse` array. `gate.py` runs on Bash only — not on
file edits. If a new gate needs a different `tool_name` or payload shape, ask
the user before changing *how* gate.py decides what to run, not just *whether*
to run something.
