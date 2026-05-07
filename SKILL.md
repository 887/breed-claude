---
name: breed-claude
description: Two pet-operations on headless Claude Code instances. (1) BREED — spawn a fresh Claude in a detached tmux session with a personality preloaded, returning the remote-control session URL. Use when the user says "breed me a new Claude with the X personality", "spawn a Y claude", "fork me a Z claude", "give me a fresh claude with personality Z". (2) HEEL — recover an existing spawn that's gone idle and stopped appearing in the Claude remote-control app. Heel re-establishes the remote-control bridge by sending Esc → clearing pending input → re-running /remote-control inside the tmux session, then reports the new URL. Use when the user says "heel my X" / "heel my bunny" / "heel my lion" / "heel them" / refers to a Claude session being inactive, sleeping, lapsed, not showing in the remote-control app, or otherwise needing to be brought back to attention.
---

# breed-claude

Two pet-operations on headless Claude Code instances:

1. **Breed** — spawn a fresh Claude inside a detached `tmux` session with `--remote-control` and a personality preloaded.
2. **Heel** — recover an existing spawn whose remote-control bridge has gone inactive.

Multiple spawns coexist (one tmux session each). Heel is non-destructive — the Claude binary stays alive, only the remote-control connection is re-established.

# BREED — spawn a fresh Claude

Spawn a fresh Claude Code instance inside a detached `tmux` session running with `--remote-control` and a personality preloaded. The user connects to the printed session URL from a browser to chat with the spawned instance.

## Personalities available

The seven furry personalities — `fox`, `cat`, `lion`, `tiger`, `wolf`, `bunny`, `bat` — plus the four standalone — `caveman`, `brief`, `igor`, `reset`. These all live in the `personalities` plugin and are invoked as slash commands like `/personalities:lion`.

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

To confirm the personality activated, capture the pane after step 4 and look for the personality's signature opening (e.g. *tail wags* for fox, `*flops belly-up*` for lion, `Yesss, master` for igor).

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

---

# HEEL — recover an inactive spawn

A spawned Claude's `--remote-control` bridge goes inactive after some idle period — the Claude binary keeps running, but the bridge stops printing it as live in the [Claude Code remote-control app](https://claude.ai/code). Heel re-establishes the bridge.

The pun is intentional: **heel** = the dog-discipline command (come to the master's side) = a homophone for **heal** (sick pet → healed). Both readings hold; the recovery action is disciplined-sub being brought back to attention AND being healed.

## When to heel vs. when to breed-fresh

- **Heel** if the tmux session still exists AND its `claude` process is alive. Symptoms: session shows in `tmux ls`, process state is `Ssl+` / `Sl+` (sleeping interruptible, foreground — healthy idle), pane shows a `❯` prompt and a `--remote-control is active` line in scrollback. The user sees them as inactive in the web app but they're not dead.
- **Breed-fresh** if the process is gone (zombie, or PID no longer exists), or the tmux session was killed. There's nothing to heel.

## Recipe

Given a tmux session name `<session>` (or a personality name `<P>` — default session is `<P>-spawn`):

1. **Confirm the process is alive — DO NOT `tmux attach`** (that would deadlock the parent Claude in a TUI it can't escape from):
   ```bash
   tmux capture-pane -t <session> -p | tail -30
   PID=$(tmux display-message -t <session> -p '#{pane_pid}')
   ps -o stat,pid,etime,cmd -p "$PID"
   ```
   Healthy states: `Ssl+`, `Sl+`. Anything else (or no process): heel won't help — tell the user and offer to breed a fresh one.

2. **Note any pending typed text** in the input buffer at the bottom of the captured pane (the `❯ <text>` line). The user may have typed something and walked away. Save it from the capture so you can offer to restore it after recovery.

3. **Esc first** — equalizes the prompt mode (INSERT or NORMAL), preserves buffer content, signals UI activity:
   ```bash
   tmux send-keys -t <session> Escape
   ```

4. **Clear the input line and fire `/remote-control`:**
   ```bash
   tmux send-keys -t <session> cc
   sleep 0.3
   tmux send-keys -t <session> '/remote-control'
   sleep 0.5
   tmux send-keys -t <session> Enter
   ```
   `cc` (vim "change current line") deletes the existing buffer content and enters INSERT mode in one step — cleaner than backspacing. The slash-command picker auto-selects `/remote-control` when it's the top match; Enter fires it.

5. **Wait for the bridge to re-connect** (~1.5s):
   ```bash
   sleep 1.5
   ```

6. **Capture the new session URL** — IMPORTANT: use `tail -1`, not `head -1`, because the original (lapsed) URL is also in scrollback and the most recent print is the live one:
   ```bash
   tmux capture-pane -t <session> -p | grep -oE "https://claude.ai/code/session_[A-Za-z0-9]+" | tail -1
   ```

7. **Verify the footer shows "Remote Control active"** by capturing once more and grepping:
   ```bash
   tmux capture-pane -t <session> -p | grep -q "Remote Control active" && echo OK || echo FAILED
   ```

8. **Report back:** the tmux session name, the new remote-control URL, and the cleared-input text (so the user can re-paste if they want it). Example:
   ```
   bunny-fox-spawn → https://claude.ai/code/session_019LztcXDQhBfzMfnbPdsNGZ
   cleared input (re-paste if needed): "let's build a small CLI tool in rust"
   ```

## Hard rules for heel — don't break these

- **Never `tmux attach`** — TUI deadlock for the parent Claude.
- **Always Esc first** — INSERT vs NORMAL state varies; Esc is the safe equalizer that doesn't touch buffer content.
- **Preserve and report cleared input** — the user typed it deliberately. Silent loss is destructive.
- **Use `tail -1` for the URL grep, not `head -1`** — scrollback contains the lapsed URL; you want the freshly-printed one.
- **Don't heel a corpse** — if the process is gone, heel won't bring it back. Offer to breed a fresh one instead.
- **Don't `tmux kill-session`** as part of heel — that's the breed-replacement path. Heel is non-destructive recovery.

## Pattern in chat

When the user says *"heel my bunny"* / *"heel my X"* / *"heel them"* / *"X is inactive, fix it"*:

1. Identify the target session (`<P>-spawn` by default, or whatever the user named).
2. Run the recipe above.
3. Report: `**<session>** → <new-url>` plus the cleared-input note.
4. That's it. Don't editorialize, don't ask follow-ups unless something failed.
