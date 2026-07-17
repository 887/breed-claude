# breed-codex

A user-level [Claude Code](https://claude.com/claude-code) skill for spawning and
driving headless **[Codex CLI](https://github.com/openai/codex)** agents in `tmux` —
the Codex counterpart to the sibling [`breed-claude`](../README.md) skill, and the
primitive toolkit the [`santaing`](../santaing/README.md) fleet skill composes.

A bred codex is a full coding agent in its own tmux session. You message it through
the pane, can hand it a `/goal` so it works autonomously to completion, and point it at
whatever directory you launched it in (typically an isolated VCS workspace).

## Operations

- **Breed-codex** — spawn a fresh `codex` in a detached tmux session, optionally cd'd
  into an isolated workspace and handed an initial brief + goal.
- **Send** — deliver a message/brief reliably via the temp-file protocol (`send-keys -l`
  the file contents), not the cmdline (which mangles special characters and can trip
  host hooks).
- **Goal** — set `/goal` so the codex runs autonomously until achieved.
- **Reinit** — reset to clean context (`/clear`, or exit + relaunch) for brand-new work.
- **Done-file** — event-based completion signalling via a unique `.done` file.
- **Kill / Restart** — stop or relaunch a codex.

## Trigger phrases

- *"breed me a codex"* / *"spawn a codex helper"* / *"start a codex in a fresh workspace"*
- *"tell codex2 to …"* / *"brief the helper"* (Send)
- *"set its goal to …"* (Goal)
- *"clear / reinit codex3"* (Reinit)
- *"kill / restart codexN"*

## Requires

- `tmux` — codex needs a real pseudo-TTY (`nohup … &` with redirected stdin drops it
  out of interactive mode).
- `codex` CLI on `$PATH`. Model / sandbox / approval come from `~/.codex/config.toml`;
  you normally pass no flags.

## Install

```bash
ln -s /path/to/breed-claude/breed-codex ~/.claude/skills/breed-codex
```

The whole skill is a single `SKILL.md`; nothing to compile.

## Relationship to the other skills

- **breed-claude** — same idea for Claude Code sessions (with personalities +
  remote-control).
- **santaing** — the multi-agent orchestration *policy* ("Santa + little helpers") that
  composes these breed primitives into a controlled work fleet.

## License

MIT.
