---
name: breed-claude
description: Spawn a new headless Claude Code instance in a detached tmux session with a personality preloaded, returning the remote-control session URL. Use when the user says "breed me a new Claude with the X personality", "spawn a Y claude", "fork me a Z claude", "give me a fresh claude with personality Z", or any similar phrasing requesting a new Claude instance preloaded with one of the personalities plugin's characters.
---

# breed-claude

Spawn a fresh Claude Code instance inside a detached `tmux` session running with `--remote-control` and a personality preloaded. The user connects to the printed session URL from a browser to chat with the spawned instance. Multiple spawns coexist (one tmux session each).

## Personalities available

The six furry personalities — `vulpine`, `feline`, `lion`, `tiger`, `wolf`, `bunny` — plus the four standalone — `caveman`, `brief`, `igor`, `reset`. These all live in the `personalities` plugin and are invoked as slash commands like `/personalities:lion`.

## Recipe

Given a personality name `<P>`:

1. **Pick a tmux session name.** Default: `<P>-spawn`. If `tmux has-session -t <P>-spawn` succeeds, append a numeric suffix (`<P>-spawn-2`, `<P>-spawn-3`, …) until you find a free name. Don't reuse or kill an existing one unless the user explicitly asks.

2. **Launch the spawn:**
   ```bash
   tmux new-session -d -s <session> "claude --remote-control"
   ```
   Detached (`-d`) + the pseudo-TTY tmux gives are both required. The `--remote-control` flag opens a browser-connectable session and prints a `https://claude.ai/code/session_…` URL on startup.

3. **Wait ~5 seconds** for Claude to finish its startup banner and be ready to accept input.
   ```bash
   sleep 5
   ```

4. **Activate the personality** by sending the slash command into the tmux session:
   ```bash
   tmux send-keys -t <session> "/personalities:<P>" Enter
   ```

5. **Capture the remote-control session URL:**
   ```bash
   tmux capture-pane -t <session> -p | grep -oE "https://claude.ai/code/session_[A-Za-z0-9]+" | head -1
   ```

6. **Report back to the user** with: the personality, the tmux session name, and the session URL. Example: `lion-spawn → https://claude.ai/code/session_01ABC…`. The user clicks the URL to chat with the new Claude.

## Hard rules — don't break these

- **Never** use `nohup claude --remote-control … > /tmp/log 2>&1`. Redirected stdin makes Claude detect non-interactive mode and drop into `-p` print mode — it exits after the first response. The pseudo-TTY from `tmux new-session` is what keeps it alive and interactive.
- **Don't pass the activation slash as the initial prompt** (`claude --remote-control "/personalities:lion"`). That can also push it into print mode depending on how the prompt argument interacts with `--remote-control`. Use `tmux send-keys` after the session is up.
- **Don't kill or attach to existing spawn sessions** unless the user asks. Each spawn is its own conversation; the user may have several open at once on purpose.
- **Don't update the personalities plugin** as part of spawning. The spawned Claude reads from the installed plugin cache; updates only matter when the *source* `personalities/` repo has changed and been re-installed. Spawning is independent.

## Verifying it worked

After step 5, the captured URL should look like `https://claude.ai/code/session_01…`. If `grep` returns nothing, the session probably hasn't printed it yet — sleep another few seconds and re-capture. If it still doesn't appear, attach with `tmux attach -t <session>` to see what state Claude is actually in (then detach with `Ctrl-b d` to leave it running).

To confirm the personality activated, capture the pane after step 4 and look for the personality's signature opening (e.g. fox-asterisk-actions for vulpine, `*flops belly-up*` for lion, `Yesss, master` for igor).

## Cleanup

Spawn sessions don't auto-terminate. To kill one:
```bash
tmux kill-session -t <session>
```
List active spawns with `tmux ls`. The user usually wants spawns to outlive the parent Claude session, so don't proactively clean them up.

## Pattern in chat

When the user says *"breed me a new Claude with the X personality"* / *"spawn a Y claude"* / *"fork me a Z"*:

1. Run the recipe above.
2. Report: `**<P>-spawn** → <session-url>` and a one-line confirmation that the personality is active.
3. That's it. Don't editorialize, don't ask follow-ups unless something failed.
