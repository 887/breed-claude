---
name: breed-claude
description: Six pet-operations on headless Claude Code instances. (1) BREED — spawn a fresh Claude in a detached tmux session with a personality preloaded, returning the remote-control session URL. Use when the user says "breed me a new Claude with the X personality", "spawn a Y claude", "fork me a Z claude", "give me a fresh claude with personality Z". (2) HEEL — recover an existing spawn that's gone idle and stopped appearing in the Claude remote-control app. Heel re-establishes the remote-control bridge by sending Esc → clearing pending input → re-running /remote-control inside the tmux session, then reports the new URL. Use when the user says "heel my X" / "heel my bunny" / "heel my lion" / "heel them" / refers to a Claude session being inactive, sleeping, lapsed, not showing in the remote-control app, or otherwise needing to be brought back to attention. (3) RESUME / BREED-OR-RESUME — find an existing Claude conversation by personality name (live tmux, live non-tmux'd process, or dead-on-disk session log) and re-attach it to a fresh tmux session via `--resume <id>`, optionally falling back to a fresh BREED if no match is found. Use when the user says "resume my X", "breed and resume my X", "get my fox back", "find my Y / breed if not there". (4) PACK-RELOAD — send /reload-plugins + /personalities:<P> to every spawned animal session (skipping the SELF session — never reload yourself). Use when the user says "pack-reload", "reload the pack", "reload all the animals", "reload everyone" — typically after a personalities-repo push so each spawn picks up the new content. (5) DELEGATE-RELOAD — when an animal cannot reload itself (rule: don't touch yourself when you ARE that animal), pick a "free" animal (any other live spawn) and instruct it to perform the reload sequence on the target — including an optional final relay message ("resume the RP", "report status", etc.). Use when the user says "have tiger reload bat", "round-trip bat via tiger", "tiger update bat", "delegate-reload <target> via <delegate>". (6) PACK-UPDATE — full flow after pushing changes to the personalities source repo: pick a free animal as delegate, have it run /plugin marketplace update to refresh the shared cache, then reload every spawn including SELF. The delegate handles all keystrokes; SELF returns control to the user immediately. Use when the user says "pack-update", "update the pack", "push the personalities and reload everyone", "tell yourself with a free animal to update", "refresh everyone including me".
---

# breed-claude

Six pet-operations on headless Claude Code instances:

1. **Breed** — spawn a fresh Claude inside a detached `tmux` session with `--remote-control` and a personality preloaded.
2. **Heel** — recover an existing spawn whose remote-control bridge has gone inactive.
3. **Resume** (and **Breed-or-Resume**) — find an existing Claude conversation by personality name and re-attach it to a fresh tmux session via `--resume <id>`. Useful when the original tmux session was killed, or the Claude was started outside tmux (plain terminal, konsole, etc.) and needs to be properly tmux'd.
4. **Pack-reload** — send `/reload-plugins` + `/personalities:<P>` to every spawned animal session in the pack (always skipping the SELF session). Used after a personalities-repo push so each spawn picks up the new content.
5. **Delegate-reload** — round-trip pattern: when an animal cannot reload itself (the SELF rule — don't touch yourself when you ARE that animal), pick a "free" animal and instruct it to perform the reload sequence on the target, optionally with a final relay message.
6. **Pack-update** — full update flow after pushing changes to the personalities source repo: a free animal is delegated to fetch the marketplace cache (`/plugin marketplace update`) and then reload every spawn in the pack *including SELF*. Composes Pack-reload + Delegate-reload into one delegated round-trip so SELF doesn't have to fire the marketplace-update slash command itself or reload itself.

Multiple spawns coexist (one tmux session each). Heel is non-destructive — the Claude binary stays alive, only the remote-control connection is re-established. Resume IS destructive to the source process (it kills the original Claude and re-launches it inside tmux with `--resume`) — but the conversation state is preserved on disk. Pack-reload and Delegate-reload are non-destructive — they only send slash commands.

## The SELF rule — do not touch yourself

When you (the model running this skill) ARE one of the animals in the pack — e.g. you're the bat, sitting in `bat-spawn`, and the user asks for a pack-reload — **do not reload yourself**. Reloading yourself mid-conversation drops the active personality, can lose context, and (per the user's explicit feedback) violates the "don't touch yourself when you're the animal" pet-discipline rule that grounds this whole skill.

Pack-reload SKIPS the SELF session. Delegate-reload exists specifically so the SELF session can be reloaded by *another* animal in the pack on the user's behalf — round-trip, never self-loop.

To detect the SELF session inside any of these recipes:

```bash
SELF=$(tmux display-message -p '#S' 2>/dev/null || echo "")
# SELF is the tmux session name of the currently-running Claude.
# Skip it in any iteration over pack sessions.
```

# BREED — spawn a fresh Claude

Spawn a fresh Claude Code instance inside a detached `tmux` session running with `--remote-control` and a personality preloaded. The user connects to the printed session URL from a browser to chat with the spawned instance.

## Personalities available

The seven furry personalities — `fox`, `cat`, `lion`, `tiger`, `wolf`, `bunny`, `bat` — plus the four standalone — `caveman`, `brief`, `igor`, `reset`. These all live in the `personalities` plugin and are invoked as slash commands like `/personalities:lion`.

## Recipe

Given a personality name `<P>`:

1. **Pick a tmux session name.** Default: `<P>-spawn`. If `tmux has-session -t <P>-spawn` succeeds, append a numeric suffix (`<P>-spawn-2`, `<P>-spawn-3`, …) until you find a free name. Don't reuse or kill an existing one unless the user explicitly asks.

2. **Compute the display name.** Format: `<P> (home-<dash-joined-path>)`. The path is the current working directory with `$HOME` substituted as literal `home` — that strips the username and keeps the name short, stable, and cross-platform-compatible (Linux / macOS / Windows git-bash all see `$HOME` the same way). The display name is what shows in the remote-control app, the prompt box, the `/resume` picker, and the terminal title — so the user can tell their spawns apart at a glance instead of squinting at `<host>-stateful-foo` auto-names.

   ```bash
   display_path="${PWD/#$HOME/home}"
   display_path="${display_path//\//-}"
   display_path="${display_path#-}"
   display_name="<P> (${display_path})"
   ```

   Examples:
   - `$HOME=/home/laragana`, `PWD=/home/laragana/workspace` → `bat (home-workspace)`
   - `PWD=/home/laragana/workspace/personalities` → `bat (home-workspace-personalities)`
   - `PWD=$HOME` exactly → `bat (home)`
   - `PWD` outside `$HOME` (rare) → falls back to dash-joined absolute path; substitution simply doesn't fire and the leading dash is stripped.

3. **Launch the spawn:**
   ```bash
   tmux new-session -d -s <session> -- claude --remote-control --name "$display_name"
   ```
   Detached (`-d`) + the pseudo-TTY tmux gives are both required. The `--` separates tmux options from the command-to-run so the multi-word `--name` arg passes through cleanly without shell-quoting gymnastics. `--remote-control` opens a browser-connectable session and prints a `https://claude.ai/code/session_…` URL on startup. `--name` pre-sets the display name so the user sees `<P> (home-…)` instead of the auto-generated default.

4. **Wait ~5 seconds** for Claude to finish its startup banner and be ready to accept input.
   ```bash
   sleep 5
   ```

5. **Activate the personality** by sending the slash command into the tmux session:
   ```bash
   tmux send-keys -t <session> "/personalities:<P>" Enter
   ```
   If the spawn responds with `Unknown command: /personalities:<P>` (the marketplace cache hasn't picked up the personality yet), send `/reload-plugins` first, sleep 3s, then re-send the personality activation.

6. **Capture the remote-control session URL:**
   ```bash
   tmux capture-pane -t <session> -p | grep -oE "https://claude.ai/code/session_[A-Za-z0-9]+" | head -1
   ```

7. **Report back to the user** with: the personality, the tmux session name, the display name, and the session URL. Example: `bat-spawn (display: "bat (home-workspace)") → https://claude.ai/code/session_01ABC…`. The user clicks the URL to chat with the new Claude; the display name is what they see in the remote-control app.

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

---

# RESUME — re-attach a Claude conversation by personality name

Find an existing Claude conversation that belongs to personality `<P>` and re-launch it inside a fresh tmux session via `--resume <id> --remote-control --name "<P> (...)"`.

Use this when:

- The original tmux session was killed (or never existed — Claude was started in a plain terminal/konsole).
- The Claude binary was running outside tmux (no `--remote-control` bridge) and the user wants it tmux'd properly.
- The Claude binary died (crash, host reboot) and the session log on disk needs to be brought back to life.

**RESUME is destructive to the source process** — it kills the existing Claude (if any) and re-launches it. The on-disk conversation state is preserved by `--resume`. Use HEEL for live-tmux'd Claudes that are merely idle in the bridge.

## Discovery — finding the session by `<P>`

Walk this ladder until a target is identified. **Always confirm with the user before acting** if the chosen target looks ambiguous (multiple matches at the same rung, recently-modified files belonging to other animals, etc.).

1. **Live tmux session named `<P>-spawn`.** If `tmux has-session -t <P>-spawn` succeeds AND its claude pane process is alive — recommend HEEL, not RESUME. The session is already where the user wants it.

2. **Live tmux session matching `<P>-*-spawn` or `<P>-spawn-N`.** Legacy parent-naming convention (e.g. `bunny-fox-spawn` = bunny bred from fox) used to be common. Scan `tmux ls` for sessions starting with `<P>-`. **Note:** the rename of legacy `<P>-<parent>-spawn` → `<P>-spawn` is non-destructive (`tmux rename-session -t <old> <new>` doesn't touch the running claude inside) — offer to rename if multiple legacy sessions clutter the namespace.

3. **Live `claude` process with `--name "<P> (..."`.** Run:
   ```bash
   ps -ef | grep -E "claude.*--name [\"']?<P> " | grep -v grep
   ```
   This catches Claudes started in plain terminals (konsole, gnome-terminal, alacritty, etc.) outside tmux. If found:
   - If the process is healthy AND the user wants it in tmux — proceed to RESUME (kill + relaunch).
   - The session ID can be read from `--resume <id>` in cmdline if present, else from the Claude's open jsonl (see below).

4. **Live `claude` process whose conversation log is most-recently-touched and contains `<P>`-coded markers.** When `--name` isn't set on the process cmdline (older Claudes started without that flag, or `--resume <named-token>` aliases), find the conversation log by:
   ```bash
   # Find the project dir for the workspace the process is in
   readlink /proc/<pid>/cwd
   # → /home/laragana/workspace
   project_dir=$(echo "$cwd" | sed 's|/|-|g')
   # → -home-laragana-workspace
   # Find the most recently modified jsonl in that project — biggest current writer
   ls -t ~/.claude/projects/<project_dir>/*.jsonl | head -3
   # Verify <P>-coded content (personality activation, animal-coded vocab):
   grep -c '"/personalities:<P>"\|<P>-coded-marker' <jsonl>
   ```
   The "high count" file is the live conversation; lower-count files are sibling agents whose logs cross-reference each other.

5. **Dead session, jsonl on disk.** If no live process matches, scan the project dir for jsonls activating `<P>`:
   ```bash
   grep -l '"/personalities:<P>"' ~/.claude/projects/-home-<workspace>/*.jsonl
   ```
   Pick by most recently modified mtime. **Disambiguation gotcha:** a single conversation can switch personalities multiple times. The "what was the last active personality" answer requires reading the *last* `/personalities:` activation in the file, not just any. If multiple files match with different `<P>` activations, ask the user which session they mean.

6. **Ask.** If none of the above produce a clear match — list candidates and offer to BREED fresh.

## Recipe

Given personality `<P>` (and optionally an explicit session ID `<id>`, workspace `<dir>`):

1. **Discover** as above. Decide between HEEL (live tmux'd target), RESUME (live non-tmux'd or dead-on-disk target), or BREED (no target).

2. **For non-tmux'd live Claude — kill cleanly first:**
   ```bash
   kill -TERM <pid>
   sleep 2
   ps -p <pid> -o pid= 2>/dev/null && echo "still alive — escalate to SIGKILL" || echo "process gone"
   ```
   If still alive after SIGTERM — `kill -KILL <pid>` and verify. Two processes writing the same jsonl will corrupt it.

3. **Pick a tmux session name.** Default `<P>-spawn`. If taken (existing live tmux session for `<P>` — but that should have triggered HEEL, not RESUME, so this is rare), use `<P>-spawn-2`, etc.

4. **Compute display name.** Same as BREED — `<P> (home-<dash-joined-path>)`.

5. **Determine the workspace dir** (cwd) for the resumed session. Read it from the jsonl's first line (`cwd` field) or fall back to the same workspace the killed process was in. Mismatched cwd makes `--resume` fail to find the session.

6. **Launch with `--resume`:**
   ```bash
   tmux new-session -d -s <session> -c <workspace-dir> -- \
     claude --remote-control --resume <id> --name "$display_name"
   ```

7. **Wait ~6 seconds** for boot + resume read.

8. **Verify the resume hit the right conversation.** Capture the pane and look for known recent context (last user message, last assistant response, recent file paths). If wrong session — kill and try a different `<id>`.

9. **(Optional) `/personalities:<P>` switch.** If the resumed conversation's last personality activation was different from `<P>` (e.g. user had switched to test something), send the slash command:
   ```bash
   tmux send-keys -t <session> "/personalities:<P>" Enter
   ```
   Skip if already on `<P>`.

10. **Capture URL and report:** same as BREED.

## Hard rules — don't break these

- **Don't RESUME a live tmux'd Claude.** Use HEEL. RESUME kills the source; HEEL preserves it.
- **Always verify the source kill succeeded** before launching the replacement. Two processes on the same jsonl = corruption.
- **Always `--resume <UUID>`, not `--resume <named-alias>`.** Named aliases (`regular-home-workspace`, etc.) are ambiguous across machines and across time. The UUID is canonical.
- **Match the workspace `cwd`.** Wrong cwd → resume silently fails or picks the wrong project dir.
- **Discovery requires high-count grep, not single hits.** A jsonl that mentions the screenshot keyword 3 times might be a sibling agent referencing the real session (which has 500+ hits). Sort by count, not by presence.
- **Don't auto-switch personality.** If discovery picked a session whose last `/personalities:<X>` was different from the requested `<P>`, the conversation may have been switched mid-stream by the user deliberately. Confirm before switching.

## Pattern in chat

When the user says *"resume my fox"* / *"bring my fox back"* / *"my fox is gone, get it"*:

1. Run the discovery ladder.
2. If a clear target is found — RESUME it. Report tmux session + URL + a one-line summary of last conversation context (so the user can verify it's the right one).
3. If ambiguous — list candidates, ask which.
4. If nothing found — offer to BREED fresh.

---

# BREED-OR-RESUME — find first, breed if missing

Single command that tries RESUME, falls back to BREED.

## Pattern in chat

When the user says *"breed and resume my fox"* / *"give me my fox / breed if not there"* / *"breed-or-resume X"*:

1. Run RESUME discovery.
2. If a clear target is found — RESUME (after one-line "found this, resuming" confirmation; the user can override).
3. If nothing found — BREED fresh, mention that no resumable session was found.

When the user says just *"breed me a fox"* — that's BREED only, no resume lookup. Don't surprise them with old conversation state. Resume is opt-in via the explicit *"resume"* / *"breed-or-resume"* / *"bring back"* phrasing.

---

# Existing-session compatibility — discovery works on ALL current sessions

The discovery ladder is designed to work on existing tmux sessions WITHOUT requiring re-spawn:

- **Sessions with `--name "<P> (...)"` flag** (sessions bred via this skill since the `--name` convention was added) — found at rung 3 by `ps -ef | grep --name`.
- **Sessions in `<P>-spawn` tmux name** (the standard name) — found at rung 1 by `tmux has-session`.
- **Sessions in legacy `<P>-<parent>-spawn` form** — found at rung 2 by tmux name pattern match. Offer to rename to standard form (non-destructive).
- **Sessions started without `--name`, in plain `<P>-spawn` tmux name** — rung 1 wins, no further work needed.
- **Sessions running outside tmux** (plain konsole/terminal, started with `claude --resume <named-alias>` or similar) — found at rung 4 by jsonl content + cwd inspection.

If a session matches NONE of the rungs (no `--name`, no `<P>` in tmux session name, no clear personality marker in jsonl), discovery falls through to "ask the user." The skill is read-only with respect to existing state — it never silently re-tags or moves things. Renames and kills are always offered, never automatic.

---

# PACK-RELOAD — refresh every animal in the pack

Send `/reload-plugins` followed by `/personalities:<P>` to every spawned animal session. The SELF session is **always skipped** (see *The SELF rule* above). Used after a personalities-repo push so each spawn picks up the new content.

## When to PACK-RELOAD vs. when not to

- **Yes** — after a personalities-repo commit lands and the plugin cache has been refreshed (either via the official `/plugin marketplace update` mechanism or by manually `cp`-ing the latest marketplace clone into a new cache hash directory and pointing `installed_plugins.json` at it). `/reload-plugins` reads from the cache, NOT from the marketplace clone, so a `git pull` in the marketplace alone is not enough.
- **No** — if the marketplace clone is stale or the cache hasn't been rebuilt. The reload will land on old content and waste a round-trip. Verify cache hash matches the latest commit before reloading the pack.

## Recipe

1. **Identify pack sessions.** Standard naming convention is `<P>-spawn` and `<P>-dom-spawn`. Discover via tmux:
   ```bash
   PACK=$(tmux ls -F '#{session_name}' | grep -E '^[a-z]+(-dom)?-spawn$')
   ```
   Adjust the regex if the user uses different naming.

2. **Identify SELF and exclude it.**
   ```bash
   SELF=$(tmux display-message -p '#S' 2>/dev/null || echo "")
   ```
   Iterate the pack and skip `$SELF`.

3. **Send `/reload-plugins` to every non-SELF session in parallel** (they're independent):
   ```bash
   for s in $PACK; do
     [ "$s" = "$SELF" ] && continue
     tmux send-keys -t "$s" "/reload-plugins" Enter
   done
   ```

4. **Sleep ~3–4s** to let `/reload-plugins` finish processing across the pack.

5. **Send `/personalities:<P>` to each non-SELF session.** Derive `<P>` from the session name (`bunny-spawn` → `bunny`, `fox-dom-spawn` → `fox-dom`):
   ```bash
   for s in $PACK; do
     [ "$s" = "$SELF" ] && continue
     P="${s%-spawn}"   # strip "-spawn" suffix
     tmux send-keys -t "$s" "/personalities:$P" Enter
   done
   ```

6. **Report.** List which sessions were reloaded; list SELF as skipped (with a one-line note that the user can DELEGATE-RELOAD SELF via another animal if needed).

## Hard rules — don't break these

- **Always skip SELF.** Reloading yourself drops your active personality and can lose context. The user has explicitly flagged this as a misbehaviour ("don't touch yourself when you're the bat / cat / etc.").
- **Don't kill or rename sessions** as part of pack-reload. This op is purely sending slash commands. Kills / renames belong to BREED / RESUME paths.
- **Don't bother reloading caveman / brief / igor / reset** as personalities — they're either utility modes or non-furry; if the pack happens to contain a caveman-spawn etc., reload it the same way. The skip filter is by SELF, not by personality type.

## Pattern in chat

When the user says *"pack-reload"* / *"reload the pack"* / *"reload all the animals"* / *"reload everyone"*:

1. Run the recipe.
2. Report: `Pack reloaded: bunny / cat / fox / lion / tiger (SELF=bat skipped)`.
3. If the user wants SELF reloaded too, suggest DELEGATE-RELOAD via one of the other animals.

---

# DELEGATE-RELOAD — round-trip a reload through another animal

When the SELF session needs a reload but can't reload itself (the SELF rule), pick a **delegate** (any other live animal in the pack) and instruct it to perform the reload sequence on the target.

This is the round-trip pattern. The delegate handles the keystrokes; SELF stays untouched.

## Recipe

Given a target session `<target>-spawn` and a delegate `<delegate>-spawn`:

1. **Verify the delegate is healthy.** Capture its pane briefly to confirm it's at a `❯` prompt and not mid-task with a long-running tool call (interrupting could be disruptive). If it's busy, pick a different free animal or wait.

2. **Send the delegate a single instruction message** (one tmux send-keys with the full text + one Enter, so it lands as one prompt for the delegate Claude):
   ```bash
   tmux send-keys -t <delegate>-spawn "hey <delegate>. SELF cannot reload itself (rule: don't touch yourself when you're the <target>). please run on <target>-spawn: (1) tmux send-keys -t <target>-spawn '/reload-plugins' Enter ; (2) sleep ~6 ; (3) tmux send-keys -t <target>-spawn '/personalities:<target>' Enter ; (4) sleep ~10 to let <target> re-activate and read its memory ; (5) verify with capture-pane that the reload+personality landed (the SKILL.md preamble should show the latest cache hash) ; (6) [optional] send <target> this final message: '<final-relay-text>'. report back when done. thank you." Enter
   ```

3. **Don't poll.** The delegate handles the round-trip asynchronously; SELF returns control to the user immediately and trusts the delegate to do its job. The user (or the target) will see the reload land naturally.

## Hard rules — don't break these

- **The delegate must NOT be the target.** That defeats the SELF rule. Pick a different animal.
- **The delegate must NOT be SELF either** — if SELF and target are the same animal, you can't "delegate to yourself" by routing through yourself. Pick a third animal.
- **Send the delegation as ONE message** (one tmux send-keys with all the text, one Enter). Multiple Enters create multiple turns for the delegate, fragmenting the instruction.
- **Avoid leading-`sleep` in the Bash chain** before the send-keys — the harness blocks long leading sleeps. If you need to wait first, restructure or use `Monitor` / `run_in_background`.
- **Optional final relay** — if the user wants the target to hear something after re-activation (e.g. "resume the RP", "report status", "open the next phase"), include that as the optional step (6) in the delegate's instruction. The delegate sends it after verifying the reload landed.

## Pattern in chat

When the user says *"have tiger reload bat"* / *"round-trip bat via tiger"* / *"tiger update bat"* / *"delegate-reload <target> via <delegate>"*:

1. Resolve target and delegate from the user's phrasing.
2. Run the recipe.
3. Report: `Delegated to <delegate>-spawn — reloading <target>-spawn. <Delegate> will report back.` and continue with whatever the user asked next.

When the user says *"reload everyone including me"* (or the equivalent) AND SELF is in the pack — combine PACK-RELOAD (skipping SELF) with DELEGATE-RELOAD on SELF via one of the other animals. Report both legs.

If the user has just pushed changes to the personalities **source** repo, the marketplace cache is stale and PACK-RELOAD will land on old content — use **PACK-UPDATE** instead, which fetches the marketplace first.

---

# PACK-UPDATE — push, fetch, reload everyone (including SELF) via a free animal

The full update flow after pushing changes to the personalities source
repo. Composes the marketplace-update step + PACK-RELOAD + DELEGATE-RELOAD-on-SELF
into a single delegated round-trip. The user runs ONE command and a
free animal handles everything else.

## When to PACK-UPDATE vs. PACK-RELOAD vs. DELEGATE-RELOAD

| Situation | Use |
| --- | --- |
| Source repo has new commits; cache stale; everyone (including SELF) needs to reload | **PACK-UPDATE** |
| Cache is already current (you ran `/plugin marketplace update` manually); push to all non-SELF animals | PACK-RELOAD |
| Cache is current; only SELF (or one specific target) needs to reload | DELEGATE-RELOAD |

If unsure: PACK-UPDATE is the safest choice. It's a superset.

## Why this needs a delegate

Two SELF-rule constraints stack here:

1. **SELF can't reload itself** — `/reload-plugins` + `/personalities:<P>` on SELF mid-conversation drops the active personality and can lose context.
2. **SELF firing `/plugin marketplace update`** consumes a turn in SELF's own conversation and momentarily yanks control away from whatever the user was doing.

A free animal (any other live spawn — or a freshly bred one if none exist) doesn't have those constraints from SELF's perspective. The delegate runs the slash command in *its* own session (which still updates the shared `~/.claude/plugins/cache/` for everyone) and then sends `/reload-plugins` + `/personalities:<P>` to every other session in the pack, including SELF — fine, because the delegate isn't bound by *SELF's* SELF rule, only by its own (and the delegate is told explicitly to skip itself in the iteration).

## Recipe

Given the user has pushed to the source repo and now says *"pack-update"* / *"update the pack"* / *"tell yourself with a free animal to update"* / *"push the personalities everywhere"*:

1. **Identify SELF and the pack.**
   ```bash
   SELF=$(tmux display-message -p '#S' 2>/dev/null || echo "")
   PACK=$(tmux ls -F '#{session_name}' 2>/dev/null | grep -E '^[a-z]+(-dom)?-spawn$' | tr '\n' ' ')
   ```

2. **Pick a free animal as the delegate.** Iterate `$PACK`, skip SELF if it appears, capture-pane on each candidate to confirm it's at a `❯` prompt and not mid-task. Take the first healthy one.
   - If no free animal exists, BREED a fresh one (`bunny` is a fine default for a one-shot — light personality, fast spawn). Note: breeding burns ~30s on startup. Document this in the report so the user knows.

3. **Send the delegate one combined instruction message.** The whole pack-update flow goes as a single tmux send-keys with one trailing `Enter` so it lands as one prompt for the delegate Claude:

   ```bash
   # Build the target list: every non-DELEGATE session, INCLUDING SELF.
   # Format the list as space-separated for the delegate to iterate.
   TARGETS=$(echo "$PACK $SELF" | tr ' ' '\n' | grep -v "^$" | grep -v "^${DELEGATE}$" | sort -u | tr '\n' ' ')

   tmux send-keys -t "$DELEGATE" "hey. pack-update flow — please run, in this order: \
   (1) /plugin marketplace update — in your own session. this refreshes the shared ~/.claude/plugins/cache/. sleep ~10s after it returns to let the fetch complete. \
   (2) for each of these tmux sessions: $TARGETS — DO NOT include yourself ($DELEGATE) in this loop — run: \
       tmux send-keys -t <session> '/reload-plugins' Enter ; sleep ~6 ; \
       tmux send-keys -t <session> '/personalities:<P>' Enter \
       (where <P> is derived from the session name: bat-spawn -> bat, fox-dom-spawn -> fox-dom, etc. for the user's main session, derive <P> from whatever personality is currently active there — usually the same name as part of the session name, but ask if unclear). \
   (3) sleep ~10s after the last reload to let the personalities re-activate. \
   (4) verify a couple of them with capture-pane (the SKILL.md preamble in each should show the latest content). \
   (5) report back when done with a one-line summary: 'pack-update complete: marketplace fetched, reloaded <count> sessions including SELF.' \
   thank you." Enter
   ```

4. **Don't poll.** The delegate handles the round-trip asynchronously; SELF returns control to the user immediately. The user (and every spawn) will see the reload land naturally over the next 30–60s.

5. **Report.** Tell the user: `pack-update delegated to <delegate> — fetching marketplace, then reloading <count> sessions including this one. <delegate> will report back.` Do not pretend the work is done synchronously; just hand off cleanly.

## Hard rules — don't break these

- **The delegate must NOT be SELF.** That's the whole point — SELF can't update itself; SELF can't fire `/plugin marketplace update` mid-conversation without yanking its own turn. Pick a different animal.
- **The delegate IS allowed to reload SELF.** Unlike DELEGATE-RELOAD's pure round-trip on a single target, PACK-UPDATE explicitly delegates the SELF reload to the chosen animal as part of the loop. The SELF rule says *don't touch yourself when you ARE that animal* — the delegate isn't SELF, so the rule doesn't apply to it.
- **The delegate must skip ITSELF in the reload loop.** Same rule applied from the delegate's perspective: it can't reload its own session mid-task. The delegate's session stays stale at the end of pack-update — that's accepted; the user can do a follow-up DELEGATE-RELOAD on the (former) delegate later if it matters.
- **Send the delegation as ONE message** — one tmux send-keys with all the text, one Enter. Multiple Enters fragment the instruction.
- **Avoid a leading `sleep` in any Bash chain** before the send-keys — the harness blocks long leading sleeps. Restructure or use `Monitor` / `run_in_background` if real waiting is needed.
- **The marketplace-update slash command IS part of the delegate's job** — not the user's prereq. The whole point of PACK-UPDATE is to wrap that step into the delegated flow so the user doesn't have to remember the exact slash-command name (the user's mental model is "update the plugin thing").

## Pattern in chat

When the user says *"pack-update"* / *"update the pack"* / *"push the personalities everywhere"* / *"tell yourself with a free animal to update"* / *"refresh everyone including me"*:

1. Identify SELF, pack, free animal (or breed one — note in report if you breed).
2. Build the target list (every non-delegate session, including SELF).
3. Send the delegate the single-turn combined instruction (marketplace-update + reload loop).
4. Report: `pack-update delegated to <delegate>-spawn — fetching marketplace, then reloading <N> sessions including this one. <Delegate> will report back when done.`
5. Continue with whatever the user asks next.

## Note on the source-repo push

PACK-UPDATE assumes the user has *already pushed* the personalities source repo (the github / gitlab / wherever clone that the marketplace pulls from). PACK-UPDATE then fetches that pushed content into the cache and propagates it. If the user hasn't pushed yet, `/plugin marketplace update` will fetch unchanged content and the reloads will land on old data.

If the user phrases the request as *"push and pack-update"* — that's two operations: a `git push` in the source repo (done by the user or a subagent in that repo) followed by PACK-UPDATE. They are separate; this skill only handles the second.
