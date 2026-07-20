---
name: santaing
description: Run a fleet of headless coding agents as a controlled workshop — YOU are Santa (the orchestrator that owns the canonical checkout, the pushes, and the merge gate); the agents are your little helpers (a dynamic number of Codex/Claude sessions in tmux, each in its own isolated VCS workspace) that fan out and do the heavy implementation while you integrate, verify, and ship. Use when the user says "go santaing", "drive the fleet", "orchestrate the codexes", "use the helpers to build X", "santa this plan", "fan the helpers out on <plan/branch>", or otherwise asks you to coordinate several tmux agents toward one goal while you keep sole control of pushes and gate checks. The core discipline: helpers only run the cheap local check and never push; Santa alone pushes, runs the full gate, fixes, and merges. Repo-, VCS-, and build-tool-agnostic — nothing about a specific project is hardwired. Composes the breed-codex (and breed-claude) primitives for spawning/briefing/goal-setting/monitoring individual agents.
---

# santaing

**You are Santa. The tmux agents are your little helpers in the workshop.**

Santaing is a pattern for driving a *dynamic* fleet of headless coding agents (Codex
or Claude sessions in `tmux`) toward a single objective — a plan, a branch, a set of
work packages — while **you alone** keep control of the repository's integration
points. You don't do the big implementation grind yourself; you orchestrate helpers
who do, and you integrate, verify, and ship their output.

This skill is **policy and choreography**. The per-agent mechanics (spawn, brief,
`/goal`, `/clear`, done-file, kill/restart) live in **breed-codex** (for Codex) and
**breed-claude** (for Claude); santaing composes them.

Nothing here is tied to a specific repo, VCS, or build tool. Throughout, substitute:

| Placeholder | Meaning | Common instances |
| --- | --- | --- |
| `<REPO>` | the project being worked on | any repo — never hardwire a name |
| `<VCS>` | the version-control system | `jj` (colocated), `git` |
| `<WORKSPACE-NEW>` | recipe to make an **isolated** checkout | `jj workspace add` / a `just`/make target / `git worktree add` |
| `<CHECK>` | the **cheap** local build/type check helpers may run | `cargo check`, `tsc --noEmit`, `go build ./...`, `pytest -q` subset |
| `<GATE>` | the **full** pre-push gate only Santa runs | `cargo clippy -D warnings` + fmt + lint + tests + deny |
| `<TARGET>` | the branch/PR the fleet's work lands on | the plan/feature branch Santa owns |

---

## The one rule that defines santaing

**Santa owns the integration boundary; helpers never cross it.**

- **Santa (you) alone**: owns the canonical checkout, **pushes**, runs the **full
  `<GATE>`**, fixes gate failures, resolves conflicts, and **merges**. You pull each
  helper's changes into `<TARGET>` and you are the only one who touches the remote.
- **Helpers only**: implement in their **own isolated workspace**, and may run the
  **cheap, scope-limited `<CHECK>`** (e.g. `cargo check -p <touched-crate>`) to
  sanity-check their edits. They do **not** push, do **not** run the full
  `<GATE>`/whole-project clippy/lint/test sweep — not just because it's wasteful and
  not their job, but because **each full build cold-populates that workspace's own
  multi-GB output tree (`target/` etc.), times N helpers in parallel, which fills the
  disk** (see the disk/artifact hard rule below) — do **not** merge, and do **not**
  touch the canonical checkout or each other's workspace.

If you remember one thing: **helpers `<CHECK>`; Santa `<GATE>` + push + merge.** Santa
is the only one at the sleigh.

---

## Roles and topology

```
                ┌─────────────────────────────────────────┐
                │  SANTA  (you, the orchestrator)          │
                │  • owns the canonical checkout           │
                │  • owns <TARGET> branch + all pushes     │
                │  • runs the full <GATE>, fixes, merges   │
                │  • briefs, goals, monitors, integrates   │
                └───────┬───────────────┬───────────────┬──┘
                        │               │               │
            brief+goal  │   brief+goal  │   brief+goal  │   (temp-file protocol)
                        ▼               ▼               ▼
                 ┌───────────┐   ┌───────────┐   ┌───────────┐
                 │ helper A  │   │ helper B  │   │ helper C  │   (dynamic count)
                 │ codex/... │   │ codex/... │   │ codex/... │
                 │ own wkspc │   │ own wkspc │   │ own wkspc │
                 │  <CHECK>  │   │  <CHECK>  │   │  <CHECK>  │
                 └─────┬─────┘   └─────┬─────┘   └─────┬─────┘
                       │ .done         │ .done         │ .done
                       └───────────────┴───────────────┘
                          Santa collects, integrates onto <TARGET>,
                          runs <GATE>, pushes.
```

- **Dynamic number of helpers.** Use as many as the work parallelizes into and no
  more. You do **not** have to keep every helper busy at once — schedule them: a
  helper that finishes picks up the next independent slice. Idle helpers are fine;
  over-subscribing dependent work is not.
- **Santa may also run a helper** on its own checkout if that's convenient — but keep
  the roles straight: when you're acting as Santa you push/gate; a helper never does.
- **Isolation is mandatory.** Every helper works in its **own** `<WORKSPACE-NEW>`
  checkout so concurrent edits never collide. In a colocated `<VCS>` (e.g. `jj`), use
  the VCS's workspace mechanism, **not** a shared-HEAD `git checkout`/`git worktree`,
  which would yank sibling workspaces onto the same branch.

---

## Dependency-aware workspace planning (do this before fanning out)

Parallel work is only safe when the slices are independent. Before you spawn helpers:

1. **Map the dependency graph of the work.** Which slices are independent? Which
   depend on another slice's output? (E.g. WP-2 and WP-3 build on WP-1's new module.)
2. **Base each helper's workspace correctly.**
   - Independent slices → each helper's workspace off the **current `<TARGET>` tip**.
   - A dependent slice → either base its workspace off the **parent slice's** change
     (so it sees that code) and accept the serialization, or give it its **own fresh
     workspace off `<TARGET>`** and have Santa integrate the parent first, then rebase.
   Decide deliberately and write it down; don't let a hidden dependency turn into a
   merge conflict you discover at integration time.
3. **Rebase `<TARGET>` onto the latest mainline FIRST**, before creating helper
   workspaces, so everyone branches from current reality.

> This is the **composable-not-hierarchical** gate applied to *work scheduling*: name
> the real dependency web among the slices before you flatten it into a parallel
> fan-out; a slice you wrongly treated as independent is a dropped edge that returns
> as a conflict.

---

## The lifecycle

### 0. Prep (Santa, once)

- Update the canonical checkout; **rebase `<TARGET>` onto latest mainline**.
- Map the work into slices + their dependency graph (above).
- Decide how many helpers and which slice each starts on.
- Ensure helpers exist (BREED-CODEX / BREED-CLAUDE) — one tmux session each, each in
  its own `<WORKSPACE-NEW>`.

### 1. Initialize each helper (fresh context)

A freshly-spawned or reused helper is **dumb about the project** until told otherwise.
For **brand-new** work, give it a clean slate first (**REINIT**: `/clear`, or
exit+relaunch codex in its window — you can also just close the tmux session and breed
a new one; whichever is cleaner).

Then hand it an **initialization brief via the temp-file protocol** (never the
cmdline — special characters and hook-trigger strings mangle or block):

- Have it read the project's `README`, `AGENTS.md`/`CLAUDE.md`, contributing +
  implementation/house-rules docs, and skim recent history, so it relearns how the
  repo works.
- Give it its **slice**: exactly what to build, the acceptance criteria, and the
  guardrails — **work only in your assigned workspace `<DIR>`; drive everything through
  `<VCS>`; you may run `<CHECK>` but NOT the full gate; you do NOT push and you do NOT
  merge; write the done-file when complete.**
- End with *"Work through THIS message first and confirm you understand before doing
  anything; do not modify or inspect any workspace yet."*
- **Wait for the helper to go idle and read back its acknowledgement** before setting
  its goal. A helper that misread the brief will happily do the wrong thing for an
  hour.

### 2. Set the goal (autonomous run)

Once acknowledged, set the helper's **`/goal`** (GOAL op) so it runs to completion
autonomously. The goal must restate the terminal done-condition and the guardrails,
and must include **writing the unique `.done` file** on completion (DONE-FILE op).

### 3. Monitor — an EDGE-TRIGGERED watcher, not a done-file

**A `.done` file encodes exactly ONE state: "finished AND remembered to write it".**
It is structurally silent on every real failure mode:

- blocked on a dialog waiting for a keypress (update prompt, hook-trust prompt,
  "retry with a faster model" — each blocks *forever* and says nothing);
- went idle without writing a report (quit early, goal silently paused);
- the tmux session died;
- still "working" but thrashing the machine.

Those are the failures that actually cost hours, and a done-file cannot express any
of them — it just never appears, so **"not there yet" looks identical to "dead 40
minutes ago."**

**Arm a persistent watcher instead** (`watch-elves.sh`, shipped next to this file),
run through the `Monitor` tool so each stdout line becomes one event:

```bash
<skill-dir>/watch-elves.sh <report-dir> codex codex2 codex3
```

It emits seven signals, and **only on a state transition**:

| Event | Trigger | Your response |
|---|---|---|
| `REPORT-READY` | report file appears (+ line count + first 300 chars) | verify → integrate → gate → push |
| `DIALOG` | pane matches an update / trust / allow / retry prompt | send the keypress |
| `WORKING` | pane shows a tool call in flight | nothing — it's healthy |
| `IDLE-STALL` | N idle ticks, **no** report | re-nudge; it quit early |
| `IDLE-DONE` | idle **with** a report | collect and integrate |
| `DEAD` | `tmux has-session` fails | re-breed that helper |
| `DISK`/`MEM` | `< 60G` free, or `> 4G` swapped | stagger the builds, reclaim a workspace |

**Four design rules that make it work — keep them if you rewrite it:**

- **Edge-triggered, never level-triggered.** It stores prior state per helper and
  speaks only on a transition, so a helper working 40 minutes produces exactly ONE
  `WORKING` line, not 40. Otherwise monitoring itself floods your context — which is
  the very problem monitoring was supposed to solve.
- **`IDLE-STALL` vs `IDLE-DONE` is the whole trick.** Same observable condition (the
  pane stopped moving); the presence of the report file disambiguates *finished* from
  *gave up*. This is precisely the distinction a bare `.done` file cannot make, and
  "helper went idle with gates red" is the single most common way a fleet silently
  stops making progress.
- **Debounce idle by 2 ticks.** Codex briefly stops printing between tool calls; a
  1-tick trigger cries wolf constantly.
- **Guard the machine, not just the fleet.** N concurrent Rust builds is exactly the
  shape that fills a disk. The resource check wakes you *before* the machine dies
  instead of after.

**Portability:** state lives in files, not `declare -A` — macOS ships bash 3.2, which
has no associative arrays. (Learned the hard way: the first version died instantly on
`declare: -A: invalid option`.) A restarted watcher therefore resumes with its
edge-detection intact instead of re-announcing everything.

**After unsticking, re-confirm the helper is back ON its goal.** Answering a prompt or
clearing a menu frequently leaves an autonomous agent **paused, not resumed** — a
codex drops to `Goal paused (/goal resume)` and then sits idle forever. Every unstick
ends with: capture the footer, and if it is not actively pursuing, resume/re-set the
goal. An unstuck helper that isn't pursuing its goal is still effectively stuck — it
just looks calm. (The watcher will tell you: it reappears as `IDLE-STALL`.)

**Arm it at dispatch time, not later.** "No watcher armed" is a real failure the user
will feel as silence.

**It disarms itself — and that is deliberate.** Once every watched helper is terminal
(`IDLE-DONE` or `DEAD`) for two consecutive passes, it emits `FLEET-COMPLETE` and
exits. `IDLE-STALL` is NOT terminal: a stalled helper needs a nudge, not abandonment,
so the watch stays armed. Pass `WATCH_STAY=1` when you intend to reassign helpers and
want one watcher across the whole session.

Why this is built in rather than left to the orchestrator: an edge-triggered watcher
with nothing left to report is **indistinguishable from one that is not running**. A
forgotten watcher therefore polls a finished fleet indefinitely and stays silent about
it — which is exactly how this was found (a watcher ran ~2.5 hours against an elf whose
work had already been integrated). "Remember to stop it" is not a control when the
failure mode is silence.

### 4. Collect + integrate (Santa)

When a helper signals done:

1. Read its `.done` (branch/change id + its `<CHECK>` status), then **delete the
   done-file** so the next assignment starts clean.
2. **Pull its change into `<TARGET>`** from its workspace (VCS-appropriate: fetch the
   change / cherry-pick / merge the workspace's commit). Do the integration work on the
   canonical checkout you own — helpers never do it.
3. **Resolve conflicts** and reconcile against anything you've already integrated.
4. **Run the full `<GATE>`** on `<TARGET>`. Fix whatever it flags — *this is Santa's
   job, not the helper's.* (You may hand a well-scoped fix back to a helper, but the
   gate itself runs on your checkout.)
5. **Push `<TARGET>`.** Only Santa pushes.

### 5. Reassign or wind down

**Wind-down is a step, not an afterthought.** When the objective is done: confirm the
watcher has disarmed (`FLEET-COMPLETE`, or stop it explicitly if you passed
`WATCH_STAY=1`), delete the report files so a stale one cannot read as "finished" for
the next assignment, and reclaim each helper's workspace and its multi-GB output tree.
A fleet that is "done" but still holding watchers, reports, and workspaces is not done.


- A finished helper gets its **next independent slice** (REINIT for clean context →
  initialize → goal). Schedule to keep progress flowing without over-subscribing
  dependent work.
- When the objective is complete, do a final `<GATE>` + push, update any plan/ledger
  the project expects, and (optionally) wind helpers down — but helpers usually should
  outlive a single objective, so don't kill them unless asked.

---

## Fan-out — helpers can recurse

A helper is itself a capable agent: if you tell it to **"fan out"**, it can spawn its
own subagents to parallelize *its* slice. Use this when a single slice is itself broad
(a sweep, an audit, a wide refactor). You stay Santa at the top; the helper becomes a
sub-orchestrator for its slice. The integration boundary rule still holds all the way
down: **only Santa (the top) pushes and runs the gate**; a fanned-out helper collects
its subagents' work in its own workspace and hands the single result up to you.

---

## Hard rules — don't break these

- **Only Santa pushes, runs `<GATE>`, and merges.** Helpers run `<CHECK>` at most.
  This is the whole point; if a helper pushes, the discipline is gone.
- **Heavy builds live in ONE checkout — never multiplied across the N helper
  workspaces (the disk/artifact bomb).** Every isolated `<WORKSPACE-NEW>` has its
  **own build-output tree** (`target/`, `node_modules/.cache`, `__pycache__`, a Go
  build cache, …). A **full**, whole-project build — a workspace-wide lint
  (`cargo clippy --workspace --all-targets --all-features`), a full test sweep
  (`cargo nextest run` / `go test ./...` / the whole `pytest`), or any cold
  build-the-world — cold-populates a **multi-GB output tree, times N helpers, in
  parallel**. That slows every machine to a crawl and can **fill the disk to the
  point the whole run dies**. So:
  - **Helpers run ONLY the cheap, scope-limited `<CHECK>`** in their workspace
    (`cargo check -p <touched-crate>`, `tsc --noEmit` on the touched project) —
    never `--all-targets`/`--all-features`/a full sweep there.
  - **The full `<GATE>` and any whole-project verification/closeout run once,
    SEQUENTIALLY, in the single canonical checkout** — one **warm** output tree
    reused across every slice, not N cold ones. Finish one slice's gate+merge, then
    the next; don't fan the heavy builds back out.
  - If the closeout must itself be driven by an agent, point **one dedicated
    closeout helper at the canonical checkout** (not at each slice's own workspace),
    so the heavy builds still hit a single output tree while the original helpers
    stay parked in their workspaces.
  - **Reclaim each helper's workspace as its slice merges** (drop the workspace + its
    output tree; e.g. `jj workspace forget <name>` + remove the dir) so idle
    multi-GB targets don't pile up. Watch free disk across the run; if it drops
    toward a danger threshold, stop and reclaim before continuing.
- **Every helper works in its own isolated `<WORKSPACE-NEW>`.** Never two agents in one
  checkout. In a colocated `<VCS>`, use its workspace mechanism, never a shared-HEAD
  worktree/checkout that would drag siblings onto another branch.
- **Rebase `<TARGET>` onto mainline before fanning out**, and integrate onto `<TARGET>`
  — never let helpers target mainline directly.
- **Brief via the temp-file protocol, never the cmdline.** Write the brief with a file
  tool; `cat` it; `send-keys -l`; separate Enter. This avoids special-char mangling and
  host-hook trigger strings.
- **Wait for acknowledgement before setting a goal.** Confirm the helper understood the
  brief; only then `/goal`.
- **Keep every active helper on a LIVE goal — this is how they keep working.**
  Autonomous helpers (codex especially — it's lazy) only keep grinding while a goal is
  active; a plain message will NOT sustain a long run, and a goal silently **pauses**
  after any interruption. So: after the brief is acknowledged → set the goal; after any
  unstick/answer/correction → re-confirm it's `Pursuing goal` and resume if paused. A
  helper off its goal produces nothing and never writes its done-file — it's silently
  idle, not working.
- **Unique, cleaned-up report files.** Mint fresh (or delete stale first); delete on
  collect. A leftover report is a false "finished" — and it will also make the watcher
  call a fresh assignment `IDLE-DONE` the moment it pauses.
- **Arm the watcher at dispatch time.** A fleet running with no watcher is a fleet you
  will discover is dead 40 minutes late. The report file alone cannot tell you.
- **Map dependencies before parallelizing.** An unnoticed dependency edge becomes a
  merge conflict. Base dependent slices deliberately.
- **Don't over-subscribe or busy-wait.** Idle helpers are fine; scheduling dependent
  work in parallel is not. Never hand-poll `capture-pane` in a loop — arm the
  edge-triggered watcher (step 3) and let it wake you.
- **Reinit for new work.** Old context bleeds into new slices — `/clear` or
  exit+relaunch (or close+re-breed the session) before a brand-new assignment.
- **Intent over wording.** These recipes are defaults; adapt the choreography to the
  actual task. If a step doesn't fit the work in front of you, do the thing the pattern
  is *for* (parallelize safely, keep the integration boundary, ship verified work),
  not the literal step.

---

## Pattern in chat

When the user says *"go santaing"* / *"drive the fleet on <plan/branch>"* / *"fan the
helpers out on X"* / *"orchestrate the codexes to build Y"*:

1. **Prep** — rebase `<TARGET>` onto mainline; map the work into slices + dependencies;
   decide helper count and starting slices.
2. **Ensure helpers** — spawn/reuse one tmux agent per active slice, each in its own
   `<WORKSPACE-NEW>` (breed-codex / breed-claude).
3. **Initialize each** — reinit for clean context; temp-file brief (read repo docs +
   the slice + guardrails); wait for acknowledgement.
4. **Goal each** — set `/goal` with the terminal done-condition + the `.done` file.
5. **Monitor** — arm `watch-elves.sh` via `Monitor` at dispatch; act on its events
   (`DIALOG` → keypress, `IDLE-STALL` → re-nudge, `DEAD` → re-breed, `DISK` → reclaim).
6. **Integrate** — on each done: pull the change onto `<TARGET>`, resolve, run `<GATE>`,
   fix, **push** (Santa only).
7. **Reassign** — hand finished helpers the next independent slice; repeat until the
   objective is done; final `<GATE>` + push + update any project ledger.

Report progress as a fleet status: per-helper (session, slice, state: briefed /
pursuing / done / stuck / integrated) plus what's on `<TARGET>` and what's left.
