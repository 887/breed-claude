# breed-claude

A user-level [Claude Code](https://claude.com/claude-code) skill for spawning a fresh Claude instance in a detached `tmux` session with a personality preloaded and `--remote-control` open. Hands back a `https://claude.ai/code/session_…` URL the user can connect to from any browser.

Useful when you want a second (or third, or fifth) Claude running in parallel, each in its own character, each independently attachable.

## Trigger phrases

- *"breed me a new Claude with the lion personality"*
- *"spawn a wolf claude"*
- *"fork me a tiger"*
- *"give me a fresh claude with the bunny personality"*

## Install

Drop the directory at `~/.claude/skills/breed-claude/` and Claude Code picks it up on next session start (or `/reload-plugins`). The whole skill is a single `SKILL.md`; nothing to compile.

```bash
git clone git@github.com:887/breed-claude.git ~/.claude/skills/breed-claude
```

## Requires

- `tmux` (the spawned Claude needs a real pseudo-TTY — `nohup` with redirected stdin won't work, see `SKILL.md` for the full reasoning)
- `claude` CLI on `$PATH` with `--remote-control` available
- The [`personalities`](https://github.com/887/personalities) plugin installed if you want to spawn one of its characters; otherwise the skill works for any slash-invocable personality you have available.

## What it does

Given a personality name `<P>`:

1. `tmux new-session -d -s <P>-spawn "claude --remote-control"`
2. Wait ~5s for the spawned Claude to be ready.
3. `tmux send-keys -t <P>-spawn "/personalities:<P>" Enter` to activate.
4. Capture the remote-control URL from the pane and report it back.

Multiple spawns coexist — name conflicts get a numeric suffix (`<P>-spawn-2`, `-3`, …).

## License

MIT.
