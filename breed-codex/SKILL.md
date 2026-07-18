---
name: breed-codex
description: Spawn and drive headless Codex CLI agents in tmux — the Codex counterpart to breed-claude, and the primitive toolkit the santaing fleet skill composes. Operations. (1) BREED-CODEX — spawn a fresh `codex` agent in a detached tmux session, optionally cd'd into an isolated VCS workspace and optionally handed an initial brief + goal. Use when the user says "breed me a codex", "spawn a codex helper", "start a codex in a fresh workspace", "give me another little helper". (2) SEND — deliver a message/brief to a codex session RELIABLY via the temp-file protocol (write to a file, `send-keys -l` the file contents, then Enter) instead of the cmdline, which mangles special characters. Use whenever you need to hand a codex a multi-line instruction. (3) GOAL — set a codex's `/goal` so it works autonomously until done. (4) REINIT — reset a codex to a clean slate for brand-new work, either by sending `/clear` or by exiting+relaunching `codex` in the same tmux window. Use when the user says "clear the codex", "reinit that helper", "give it fresh context". (5) DONE-FILE — the event-based completion signal: instruct a codex to write a unique `.done` file when its goal completes so an orchestrator can watch a path instead of polling panes. (6) KILL / RESTART — stop a codex or restart it in place. Use when the user says "kill codex2", "restart that helper". This skill owns the codex-in-tmux mechanics; santaing owns the multi-agent orchestration policy on top of it.
---

# breed-codex

Spawn and drive headless **Codex CLI** agents inside `tmux` sessions. This is the
Codex analogue of the `breed-claude` skill (which does the same for Claude Code),
and it is the low-level primitive toolkit that the **santaing** fleet-orchestration
skill composes into a "Santa + little helpers" workshop.

A bred codex is a fully-capable coding agent running in its own tmux session. You
talk to it by sending messages into the pane; it can be given a `/goal` so it works
autonomously until the goal is achieved; and it works out of whatever directory you
launched it in (typically an isolated VCS workspace so several helpers don't collide).

Operations:

1. **Breed-codex** — spawn a fresh `codex` in a detached tmux session.
2. **Send** — hand a codex a message/brief reliably (temp-file protocol).
3. **Goal** — set `/goal` so it runs autonomously to completion.
4. **Reinit** — reset a codex to clean context for new work (`/clear`, or exit+relaunch).
5. **Done-file** — event-based completion signalling via a unique `.done` file.
6. **Kill / Restart** — stop or relaunch a codex.

## Requires

- `tmux` — codex needs a real pseudo-TTY. A detached tmux session provides one;
  `nohup codex … &` with redirected stdin drops codex into a non-interactive mode.
- `codex` CLI on `$PATH` (`codex --version` → `codex-cli 0.x`). Model, sandbox, and
  approval policy come from `~/.codex/config.toml` — you normally pass no flags.
- (Optional) an instruction file codex reads on startup. Codex reads `AGENTS.md`
  (project root, then `~/.codex/AGENTS.md`). On this setup `~/.codex/AGENTS.md` is a
  symlink to the global Claude instructions, so a codex inherits the same house rules
  a Claude would — but **do not assume** a bred codex knows a specific repo's rules
  until you have told it to read that repo's `README` / `AGENTS.md` / `CLAUDE.md` /
  contributing docs. Fresh codexes are dumb about the local project by default.

---

# BREED-CODEX — spawn a fresh codex

## Recipe

Given a desired session name `<S>` (default `codex`, then `codex2`, `codex3`, … —
match whatever numbering the fleet already uses) and a working directory `<DIR>`
(default: the current repo checkout; for a fleet helper, an **isolated** workspace —
see santaing):

1. **Pick a free session name.** If `tmux has-session -t <S>` succeeds, bump the
   numeric suffix until free. Don't reuse or kill an existing session unless asked.

   ```bash
   S=codex
   while tmux has-session -t "$S" 2>/dev/null; do
     n="${S##codex}"; S="codex$(( ${n:-1} + 1 ))"
   done
   ```

2. **Launch codex detached, in the chosen working directory.** Two equivalent forms —
   prefer the `--` form so codex starts directly and you don't race a shell prompt:

   ```bash
   # Preferred: launch codex directly as the session command, in <DIR>.
   tmux new-session -d -s "$S" -c "<DIR>" -- codex

   # Equivalent when you want a shell first (e.g. to make the workspace, then start):
   tmux new-session -d -s "$S" -c "<DIR>"
   tmux send-keys -t "$S" "codex" Enter
   ```

   Notes:
   - `-c <DIR>` sets the pane's working directory; alternatively pass `codex -C <DIR>`
     to set codex's working root explicitly (useful if the pane and the agent root
     should differ).
   - Model / sandbox / approval come from `~/.codex/config.toml`. Only pass
     `-m <model>` / `-s <sandbox>` / `-a <approval>` to override per-spawn.

3. **Wait for codex to be ready** (banner + prompt). ~4–6 seconds is typical:

   ```bash
   sleep 5
   ```

   Confirm readiness by capturing the pane and looking for the input prompt (the
   `›` line and the `gpt-…` status footer):

   ```bash
   tmux capture-pane -t "$S" -p | tail -6
   ```

4. **(Optional) hand it an initial brief** — see **SEND** below. For a fleet helper
   starting brand-new work, the brief should tell it to read the repo's `README` /
   `AGENTS.md` / `CLAUDE.md` / contributing + implementation docs and confirm
   understanding *before* touching anything.

5. **(Optional) set a goal** — see **GOAL** below.

6. **Report back:** the session name, the working directory, and (if set) the initial
   brief/goal. Example: `codex3 → cwd <DIR> (briefed; goal set: "…")`.

## Hard rules

- **Never** `nohup codex … > log 2>&1 &`. Redirected stdin makes codex go
  non-interactive. The tmux pseudo-TTY is what keeps it interactive.
- **Don't kill or reuse** an existing codex session unless the user asks — each is its
  own conversation and may be mid-task.
- **One codex per session.** Don't start a second `codex` in a pane that already runs
  one.

---

# SEND — deliver a message/brief reliably (temp-file protocol)

The cmdline mangles multi-line text and special characters, and a literal command
string can trip host PreToolUse hooks (e.g. a VCS gate that scans the command text
for `git`/`jj` history-rewrite patterns). **Always route a non-trivial message
through a temp file** and send the file's contents with `send-keys -l` (literal).

## Recipe

Given a session `<S>` and message text:

1. **Write the message to a temp file** (a scratch dir is ideal):

   ```bash
   BRIEF=/tmp/codex-brief-$S.txt   # or a session scratchpad path
   # …write the message into "$BRIEF" with the Write tool (not echo/heredoc,
   #   so no trigger strings ever appear on a command line)…
   ```

2. **Send the file contents literally, then Enter as a separate keystroke** (the
   split avoids Enter firing before the TUI has buffered a long paste):

   ```bash
   MSG="$(cat "$BRIEF")"
   tmux send-keys -t "$S" -l "$MSG"
   sleep 1
   tmux send-keys -t "$S" Enter
   ```

   `-l` sends the text **literally** so tmux does not interpret words like `Enter`,
   `C-u`, or key names inside your message. The trailing Enter is sent WITHOUT `-l`
   so it submits.

3. **Confirm it landed** — capture the pane and verify the message is in the input box
   (or that codex has started `Working …`):

   ```bash
   tmux capture-pane -t "$S" -p | tail -8
   ```

## When you need the codex to acknowledge first

For a briefing you want understood before work begins, end the brief with an explicit
instruction like *"Work through THIS message first and confirm you understand before
doing anything. Do not modify or inspect any workspace yet."* Then wait until the
codex goes idle and read back its acknowledgement before sending **GOAL**. (This is
the pattern santaing uses to initialize helpers.)

## Hard rules

- **Never build the message inline on the command line** (`echo "…"`, heredocs).
  Special characters, quotes, and trigger strings (`jj new`, `git rebase`, `$`, `` ` ``)
  either mangle or trip hooks. Write the file with the Write tool; `cat` it into a var;
  `send-keys -l`.
- **Split text and Enter** with a short sleep for long messages, or the submit can
  race the paste.
- **Slash commands go the same way** — `/goal …`, `/clear` are sent as literal text
  then Enter, exactly like any message.

---

# GOAL — make a codex work autonomously

Codex supports a `/goal` that keeps it working until the goal is achieved (the footer
shows `Pursuing goal (Ns)` while active and `Goal achieved (Nm)` when done). Set it
like any message.

**Why this is non-optional for autonomous work: codex is LAZY without a live goal.**
A codex that is *not* on an active goal stops the moment it answers your last message
and sits idle at the `›` prompt — a plain message (even a to-do list, or "keep
going") does **not** sustain a long autonomous grind; only an active `/goal` does.
Worse, a goal can silently **drop out**: after codex answers an interstitial prompt,
gets unstuck from a menu, or hits a pause, the footer often flips to `Goal paused
(/goal resume)` — and in that state it will sit idle **forever**, never reaching its
done-condition and never writing its done-file. So "is it *still* Pursuing goal?" is
something an orchestrator must **verify**, never assume.

## Recipe

Given a session `<S>` and goal text:

1. Compose the goal as a single self-contained instruction: the deliverable, the
   done-condition ("do not stop until …"), any hard constraints (e.g. "only run the
   cheap local check, never push/merge yourself"), and — for fleet use — the
   **done-file** to write on completion (see below).
2. Send it via the **SEND** protocol, prefixed with `/goal `.
3. Verify the footer switches to `Pursuing goal`:

   ```bash
   tmux capture-pane -t "$S" -p | tail -4   # expect "Pursuing goal (…s)"
   ```

## Hard rules

- **Make the done-condition explicit and terminal.** "Work on X until it is completely
  implemented and would pass the local check; then write the done-file; do not merge."
- **Encode the guardrails in the goal**, not just a prior message — the goal is what
  persists across the codex's autonomous loop.
- **Autonomous work REQUIRES an active `/goal` — codex does not self-continue without
  one.** If you want it to grind to completion, set a `/goal`; never rely on a normal
  message to keep a codex working over a long task. No goal ⇒ it answers once and idles.
- **Re-confirm the goal after ANY interruption.** Every time you answer a codex prompt,
  clear a menu, or send a correction, capture the footer afterward: if it is not
  `Pursuing goal`, send `/goal resume` (or re-set the goal). A `Goal paused (/goal
  resume)` footer means it has **stopped** and needs resuming — otherwise it idles
  silently and never writes its done-file. Treat an unstuck-but-not-pursuing codex as
  still stuck.

---

# REINIT — reset a codex to clean context

When a codex should start **brand-new, unrelated work**, give it a clean slate so old
context doesn't bleed in. Two ways:

- **`/clear`** — send `/clear` via the SEND protocol. Fast; keeps the same session and
  process. Follow with a fresh initialization brief (read the repo docs, then the task).
- **Exit + relaunch** — send `/exit` (or `Ctrl-c` twice) to quit codex, wait for the
  shell prompt, then start `codex` again in the same window. Use this when `/clear`
  isn't enough (a wedged TUI, a changed working dir, a model/flag change). This reuses
  the tmux session — no need to kill it.

  ```bash
  tmux send-keys -t "$S" -l "/exit"; sleep 0.5; tmux send-keys -t "$S" Enter
  sleep 3
  tmux send-keys -t "$S" "codex" Enter    # optionally: codex -C <NEW-DIR>
  sleep 5
  ```

Either way, **always re-initialize** a freshly-cleared/relaunched codex with a brief
that has it read the project's docs and your task prompt — a reset codex is dumb about
the repo again.

## Hard rules

- **Don't `/clear` a codex mid-task** unless you mean to discard its work-in-progress.
- **Prefer exit+relaunch over kill+breed** when you want to keep the tmux session name
  stable (fleets refer to helpers by session name).

---

# DONE-FILE — event-based completion signalling

Polling panes is noisy and racy. For orchestration, have each codex **write a unique
sentinel file when its goal completes**, and watch that path instead. This makes
completion event-based rather than poll-based.

## Convention

- Pick a unique, collision-free path per assignment, e.g.
  `<scratch>/<session>-<task-slug>.done` (unique so a stale file from a prior run can't
  be mistaken for the new one — mint a fresh name each assignment, or delete the old
  one first).
- The codex's **goal** must include: *"When the goal is fully complete, write the file
  `<PATH>` containing a one-line status (branch, change id, and PASS/FAIL of the local
  check). Do not write it until the work is actually complete."*
- The orchestrator watches for the file (a `Monitor`/until-loop on `test -f <PATH>`,
  or a periodic check), then reads it, then **deletes it** as part of collecting the
  result so the next assignment starts clean.

## Hard rules

- **Unique names, cleaned up.** A leftover `.done` from a previous task reads as
  "finished" when it isn't. Mint-fresh-or-delete-first, and delete on collect.
- **Done-file is a signal, not the result.** It says "come look"; the real evidence is
  the branch/commit the codex pushed to its workspace and its reported check status.
- **Belt and suspenders.** Pair the done-file watch with a periodic pane check-in so a
  crashed codex (which never writes the file) is still noticed.

---

# KILL / RESTART

- **Kill:** `tmux kill-session -t <S>`. List sessions with `tmux ls`. Codex sessions
  don't auto-terminate; the user usually wants helpers to outlive the orchestrator, so
  don't proactively clean them up.
- **Restart in place:** use **REINIT → exit + relaunch** to keep the session name.
- **Restart with a fresh workspace:** exit codex, `cd`/relaunch with `codex -C <NEW-DIR>`,
  or kill + BREED-CODEX into the new workspace.

---

# Codex specifics worth knowing

- **Startup:** interactive `codex` (no subcommand) launches the TUI. `codex exec` is the
  non-interactive one-shot mode — not what a persistent tmux helper wants.
- **Config over flags:** model / sandbox / approval live in `~/.codex/config.toml`. A
  fleet typically runs `approval_policy = "never"` + a permissive sandbox so helpers
  don't block on prompts — verify this matches the user's intent before breeding.
- **Instruction file:** codex reads `AGENTS.md` (repo root, then `~/.codex/AGENTS.md`).
  If the global one is symlinked to the shared house rules, a codex inherits them — but
  repo-specific rules still require an explicit "read these docs first" brief.
- **Working root:** `-C/--cd <DIR>` (or the tmux pane `-c <DIR>`) sets where codex
  operates. For fleets, point each helper at its own isolated VCS workspace.
- **Sending input:** everything (messages, `/goal`, `/clear`, `/exit`) goes through the
  same literal `send-keys -l` + separate-Enter protocol. Read the pane to confirm
  state (`Working … esc to interrupt` = busy; `›` prompt / status footer = idle;
  `Pursuing goal` / `Goal achieved` = goal states).

# Pattern in chat

- *"breed me a codex [in a fresh workspace]"* → BREED-CODEX (make/point-to the
  workspace, launch, optionally brief + goal), report session + cwd.
- *"tell codex2 to …"* / *"brief the helper"* → SEND (temp-file protocol).
- *"set its goal to …"* → GOAL.
- *"clear / reinit codex3"* → REINIT.
- *"kill / restart codexN"* → KILL / RESTART.

For running **several** codexes as a controlled work fleet — who owns pushes, who runs
the gate, how work is fanned out and merged back — that policy lives in the
**santaing** skill, which builds on these primitives.
