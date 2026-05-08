---
name: breed-claude
description: Six pet-operations on headless Claude Code instances. (1) BREED — spawn a fresh Claude in a detached tmux session with a personality preloaded, returning the remote-control session URL. Use when the user says "breed me a new Claude with the X personality", "spawn a Y claude", "fork me a Z claude", "give me a fresh claude with personality Z". (2) HEEL — recover an existing spawn that's gone idle and stopped appearing in the Claude remote-control app. Heel re-establishes the remote-control bridge by sending Esc → clearing pending input → re-running /remote-control inside the tmux session, then reports the new URL. Use when the user says "heel my X" / "heel my bunny" / "heel my lion" / "heel them" / refers to a Claude session being inactive, sleeping, lapsed, not showing in the remote-control app, or otherwise needing to be brought back to attention. (3) RESUME / BREED-OR-RESUME — find an existing Claude conversation by personality name (live tmux, live non-tmux'd process, or dead-on-disk session log) and re-attach it to a fresh tmux session via `--resume <id>`, optionally falling back to a fresh BREED if no match is found. Use when the user says "resume my X", "breed and resume my X", "get my fox back", "find my Y / breed if not there". (4) PACK-RELOAD — send /reload-plugins + /personalities:<P> to every spawned animal session (skipping the SELF session — never reload yourself). Use when the user says "pack-reload", "reload the pack", "reload all the animals", "reload everyone" — typically after a personalities-repo push so each spawn picks up the new content. (5) DELEGATE-RELOAD — when an animal cannot reload itself (rule: don't touch yourself when you ARE that animal), pick a "free" animal (any other live spawn) and instruct it to perform the reload sequence on the target — including an optional final relay message ("resume the RP", "report status", etc.). Use when the user says "have tiger reload bat", "round-trip bat via tiger", "tiger update bat", "delegate-reload <target> via <delegate>". (6) PACK-UPDATE — one-command full update flow after pushing changes to the personalities source repo. SELF spawns ONE backgrounded orchestrator subshell that runs (a) `claude plugin marketplace update <marketplace>` (b) `claude plugin update <plugin>@<marketplace>` and then (c) sends /reload-plugins + /personalities:<P> via tmux send-keys to every existing -spawn session INCLUDING SELF. The two CLI commands are non-interactive — no ephemeral Claude session, no `claude -p` startup. SELF returns control immediately; keystrokes land ~15–20s later after SELF's response has finished. Default plugin: personalities@personalities (override via PLUGIN env var). Works with no other animals alive. Use when the user says "pack-update", "update the pack", "push the personalities and reload everyone", "refresh everyone including me".
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

   *Note on Enter timing:* for short slash commands like `/reload-plugins` the combined `"text" Enter` form is fine. For long multi-line prompts (rare in PACK-RELOAD but common when delegating), Enter can fire before the destination TUI has buffered all the text — split the calls and add a short sleep. See *The Enter-timing fix* in the PACK-UPDATE section below.

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

# PACK-UPDATE — SELF reloads everyone else; a backgrounded helper reloads SELF

The full update flow after pushing changes to the personalities source
repo. SELF does the bulk of the work directly — iterating every other
session and sending `/reload-plugins` + `/personalities:<P>` — and only
the unavoidable SELF-reload (the one operation SELF can't perform on
itself without dropping its own conversation) is handed off to a
**backgrounded subprocess** that runs deferred and exits before the
user notices.

This shape replaces the prior delegated design. Two reasons:

1. **No dependence on an existing animal.** PACK-UPDATE works even when
   no other animals are alive. The backgrounded helper is freshly
   spawned and disposable; it doesn't need to be a long-running tmux
   spawn, it's `bash -c '... &'` or `claude -p '...' &`.
2. **SELF stays the actor.** The user invoked PACK-UPDATE *in SELF*; it
   feels right that SELF does the visible work. Only the invisible
   final keystrokes-to-self come from elsewhere.

## When to PACK-UPDATE vs. PACK-RELOAD vs. DELEGATE-RELOAD

| Situation | Use |
| --- | --- |
| Source repo has new commits; cache fetched; everyone (including SELF) needs to reload | **PACK-UPDATE** |
| Cache is already current; push to all non-SELF animals only | PACK-RELOAD |
| Cache is current; only one specific target (or SELF) needs reload | DELEGATE-RELOAD |

PACK-UPDATE is the right call any time the user has just pushed to the
source repo and wants their whole environment refreshed.

## No prereq — and no ephemeral claude either

Earlier iterations of this skill required the user to pre-run
`/plugin marketplace update`, then later spawned an ephemeral
interactive Claude tmux session to fire that slash command for them.
Both were over-engineered. The Claude Code CLI exposes the equivalents
directly:

```
claude plugin marketplace update [name]   # refresh marketplace clone(s) from source
claude plugin update <plugin>@<marketplace>   # update installed plugin from refreshed clone
```

Both are CLI commands — they run from a normal shell, no TUI, no
slash-command processing required, no ephemeral session to drive.
The `restart required to apply` note means the running Claude needs
to `/reload-plugins` afterward to pick up the new content — that's
what the send-keys loop does in the recipe below.

For the personalities marketplace specifically:

- marketplace name: `personalities`
- plugin name: `personalities@personalities`
- source repo: `github.com/887/personalities`

(Verify with `claude plugin list` if unsure.)

## Recipe

Given the user has pushed to the personalities source repo and now says *"pack-update"* / *"update the pack"* / *"refresh everyone including me"* / *"tell yourself with a free animal to update"*:

1. **Identify SELF and every existing animal session.**
   ```bash
   SELF=$(tmux display-message -p '#S' 2>/dev/null || echo "")
   ALL=$(tmux ls -F '#{session_name}' 2>/dev/null | grep -E '^[a-z]+(-dom)?-spawn$')
   # ALL is newline-separated; includes SELF if SELF is a -spawn session.
   ```

2. **Pick the plugin spec** (default = personalities, override if the user names a different plugin or marketplace):
   ```bash
   PLUGIN="${PLUGIN:-personalities@personalities}"
   MARKETPLACE="${PLUGIN##*@}"   # everything after the @
   ```

3. **Spawn a backgrounded orchestrator subshell that does the whole flow.** SELF returns control to the user immediately; the orchestrator runs in parallel and only delivers its keystrokes *after* SELF's current response is done.

   ```bash
   (
     # Step 1 — refresh the marketplace clone from source (e.g. git pull on the github clone).
     claude plugin marketplace update "$MARKETPLACE"

     # Step 2 — update the installed plugin cache from the refreshed clone.
     claude plugin update "$PLUGIN"

     # Step 3 — reload every existing -spawn session, INCLUDING SELF.
     # Cache is fresh now; /reload-plugins + /personalities:<P> picks up the new content.
     # Enter-timing fix: split text-send and Enter-send with a 1s sleep so the destination
     # TUI has time to buffer before Enter triggers submission.
     #
     # IMPORTANT: use `printf %s\\n "$ALL" | while read` — NOT `for s in $ALL`.
     # zsh does not word-split unquoted parameter expansions by default
     # (different from bash), so `for s in $ALL` would treat the whole
     # newline-separated string as ONE iteration value, sending all the
     # session names to send-keys as a single pane spec → "can't find pane".
     # The while-read form is portable across bash and zsh.
     printf '%s\n' "$ALL" | while IFS= read -r s; do
       [ -z "$s" ] && continue
       tmux send-keys -t "$s" "/reload-plugins"
       sleep 1
       tmux send-keys -t "$s" Enter
     done
     sleep 8  # let /reload-plugins finish on each session

     printf '%s\n' "$ALL" | while IFS= read -r s; do
       [ -z "$s" ] && continue
       P="${s%-spawn}"
       tmux send-keys -t "$s" "/personalities:$P"
       sleep 1
       tmux send-keys -t "$s" Enter
     done
   ) > /tmp/pack-update.log 2>&1 &
   disown
   ```

   - The whole orchestrator runs **inside one backgrounded subshell**. SELF doesn't wait. `disown` detaches it so it survives even if SELF's parent process exits.
   - **Total ETA**: ~3–5s for `claude plugin marketplace update` + `claude plugin update` (mostly a `git pull` and a cache copy) + ~8s reload pass + ~few s personality pass = **~15–20s** before SELF reloads. SELF's response finishes well within that window, so the keystrokes only land *after* SELF has handed control back to the user.
   - **No-pack case is fine**: if `$ALL` is empty, the for-loops are no-ops — the marketplace+plugin update still happened, so the next time the user opens an interactive Claude it'll see the new content. If `$ALL` doesn't include SELF (e.g. SELF isn't running in a `-spawn` named tmux session), SELF won't be reloaded — that's correct, pack-update is for `-spawn` named sessions; SELF outside that convention isn't part of the pack.

4. **Don't poll.** SELF returns control to the user immediately. The orchestrator's keystrokes hit each session in sequence.

5. **Report**:
   ```
   pack-update spawned in background:
     1. claude plugin marketplace update <marketplace>
     2. claude plugin update <plugin>@<marketplace>
     3. /reload-plugins + /personalities:<P> → every -spawn session including SELF
   ETA ~15–20s. SELF reloads when keystrokes land — this conversation will reset.
   ```

## Why CLI commands (not an ephemeral interactive claude, not `claude -p`)

The CLI gives us direct access to the marketplace-update and
plugin-update logic without needing a TUI:

- `claude plugin marketplace update <name>` — runs the same operation the `/plugin marketplace update` slash command runs internally, but as a one-shot CLI invocation. No TUI, no Claude conversation, no ephemeral tmux session, no `claude -p` startup overhead.
- `claude plugin update <plugin>` — bumps the installed cache to the latest from the (just-refreshed) marketplace clone.

After the cache is fresh, the only step that DOES need to happen via
TUI is `/reload-plugins` + `/personalities:<P>` (those are
session-state operations on the running Claude). Those go via
`tmux send-keys` to each existing session. SELF is one of those
sessions; the keystrokes arrive at SELF after SELF's current turn has
ended, so the SELF rule (don't touch yourself mid-conversation) is
honoured.

Earlier designs spawned an ephemeral interactive Claude session
specifically to fire the `/plugin marketplace update` slash command
because we didn't realize the CLI exposed it directly. With the CLI
known, the ephemeral spawn is unnecessary — and the orchestrator
collapses to a few CLI calls plus the standard send-keys loop.

## The Enter-timing fix — why send-keys splits the text and the Enter

For SHORT slash commands like `/reload-plugins`, the combined form works fine:

```bash
tmux send-keys -t <session> "/reload-plugins" Enter
```

For LONG multi-paragraph instructions (the kind PACK-UPDATE used to send to a delegate, but this redesign avoids), the trailing `Enter` arg can fire BEFORE the destination TUI has finished buffering all the text. Result: the destination has the text typed but unsubmitted; Enter is consumed without effect; the user has to press Enter manually.

Mitigation: split the text send and the Enter send, with a short sleep between, so the TUI has time to buffer the full text before Enter triggers submission:

```bash
tmux send-keys -t <session> "long instruction"
sleep 1
tmux send-keys -t <session> Enter
```

In the PACK-UPDATE recipe above, the bash-subshell helper uses this split form for each slash command (a 1s sleep between the text and the Enter) — defensive even though the slash commands are short.

## Hard rules — don't break these

- **SELF doesn't reload itself directly.** The backgrounded helper does it via send-keys. Even though the helper is "from SELF" in the sense that SELF spawned it, the helper runs in its own process and the keystrokes arrive at SELF *after* SELF's current turn has ended — so the SELF rule (don't touch yourself mid-conversation) is honoured.
- **The marketplace-update step is the user's prereq, not part of the recipe.** This is a deliberate change from the prior design. Asking the user to pre-run `/plugin marketplace update` is simpler than trying to wrap it via send-keys (which has ordering problems with the rest of the flow).
- **No leading `sleep` in any Bash chain on the SELF side.** The harness blocks long leading sleeps. The 12s lead-in for the helper is INSIDE a backgrounded subshell — it's not a leading sleep on SELF's main bash chain.
- **Disown the backgrounded helper.** Without `disown`, the helper might be killed when SELF's bash invocation returns. With it, the helper outlives the parent.
- **Use the Enter-timing fix** (split send-keys text / Enter with a 1s sleep) for any send-keys with multi-line or long text, even though most PACK-UPDATE commands are short slash commands.
- **The recipe works with no other animals alive.** The helper is freshly spawned and doesn't depend on the pack — pack iteration in step 2 is just a no-op when the pack is empty.

## Pattern in chat

When the user says *"pack-update"* / *"update the pack"* / *"refresh everyone including me"* / *"tell yourself with a free animal to update"* / *"push the personalities everywhere"*:

1. Identify SELF and `$ALL` (every `-spawn` named tmux session, including SELF if it's one).
2. Spawn the orchestrator as a single backgrounded subshell — ephemeral claude → marketplace-update → kill ephemeral → reload all sessions → switch personality on all sessions.
3. Report: *"pack-update spawned in background: ephemeral claude → /plugin marketplace update → reload + /personalities:<P> on every session including SELF. ETA ~40s. SELF reloads when keystrokes land."*
4. Don't poll. Continue with whatever the user asks next.

## Note on the source-repo push

PACK-UPDATE assumes the user has *already pushed* the personalities
source repo (the github / gitlab / wherever clone that the marketplace
pulls from). The orchestrator's `/plugin marketplace update` step then
fetches the pushed content into the cache. If the source push hasn't
happened, the marketplace fetch lands on unchanged content and the
reloads do nothing useful.

If the user phrases the request as *"push and pack-update"* — that's
two operations: a `git push` in the source repo (done by the user or
a subagent in that repo) followed by PACK-UPDATE. They are separate;
this skill only handles the second.
