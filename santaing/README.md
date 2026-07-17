# santaing

A user-level [Claude Code](https://claude.com/claude-code) skill for running a **fleet
of headless coding agents as a controlled workshop**. You are **Santa** — the
orchestrator that owns the canonical checkout, the pushes, and the merge gate. The
tmux agents (Codex or Claude sessions) are your **little helpers**: a dynamic number of
them, each in its own isolated VCS workspace, fanning out to do the heavy
implementation while you integrate, verify, and ship.

Repo-, VCS-, and build-tool-agnostic — nothing about any specific project is hardwired.
It composes the [`breed-codex`](../breed-codex/README.md) and
[`breed-claude`](../README.md) primitives for the per-agent mechanics.

## The one rule

**Santa owns the integration boundary; helpers never cross it.**

- **Helpers** implement in their own workspace and may run the **cheap local check**.
  They never push, never run the full gate, never merge, never touch the canonical
  checkout or each other's workspace.
- **Santa alone** pulls each helper's work onto the target branch, resolves conflicts,
  runs the **full gate**, fixes what it flags, and **pushes/merges**.

Shorthand: **helpers check; Santa gates + pushes + merges.**

## What it covers

- Dependency-aware workspace planning before fan-out (parallelize only what's actually
  independent; base dependent slices deliberately).
- The lifecycle: prep + rebase target → initialize each helper with a temp-file brief
  (read the repo docs first) → wait for acknowledgement → set `/goal` → monitor
  (event-based `.done` files + a heartbeat, read the pane to unstick) → collect +
  integrate onto the target + run the gate + push → reassign.
- Fan-out: a helper can spawn its own subagents for a broad slice; the integration
  boundary still holds at the top.

## Trigger phrases

- *"go santaing"* / *"santa this plan"*
- *"drive the fleet on <branch>"* / *"fan the helpers out on X"*
- *"orchestrate the codexes to build Y"*

## Requires

- `tmux`, and at least one helper runtime (`codex` and/or `claude`) on `$PATH`.
- A project with an isolated-workspace mechanism (`jj` workspaces, `git worktree`, or
  equivalent) and a cheap check + a full gate you can distinguish.

## Install

```bash
ln -s /path/to/breed-claude/santaing ~/.claude/skills/santaing
```

## License

MIT.
