---
name: santaing
description: Run a fleet of headless coding agents as a controlled workshop — YOU are Santa, the orchestrator: you brief the helpers, make the decisions, keep the ledger, and touch NO checkout. Always create **rudolph**, a dedicated tmux integrator that owns the canonical checkout and is the only agent that merges. The elves (a dynamic number of Codex/Claude sessions in tmux, count and kind the user's call) each work an isolated VCS workspace on a long-lived branch per phase, push their own branch, open their own PR, and keep working without waiting. Use when the user says "go santaing", "drive the fleet", "orchestrate the codexes", "use the helpers to build X", "santa this plan", "fan the helpers out on <plan/branch>", or otherwise asks you to coordinate several tmux agents toward one goal. The core discipline: elves push branches and never merge; rudolph runs the full gate and merges; Santa orchestrates and never touches the canonical checkout. Never run the integrator as an orchestrator subagent — it reinitialises context every message and burns tokens rebuilding what a tmux agent simply keeps. Repo-, VCS-, and build-tool-agnostic — nothing about a specific project is hardwired. Composes the breed-codex (and breed-claude) primitives for spawning/briefing/goal-setting/monitoring individual agents.
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
| `<CHECK>` | the **cheap, scope-limited** check helpers may run — NEVER `--all-features`, `--all-targets`, `--workspace`, a full sweep, or `-p <composition-crate>` | `cargo check -p <crate>`, `cargo test -p <crate>`, `nextest -E 'test(x)'`, `tsc --noEmit` |
| `<GATE>` | the **full** gate only rudolph runs | `cargo clippy -D warnings` + fmt + lint + tests + deny |
| `<TARGET>` | the trunk the fleet's work lands on | `main`, or the phase branch rudolph owns |

---

## The one rule that defines santaing

**The integration boundary is owned by exactly one agent; helpers never cross it.**

That agent is **rudolph** — a dedicated tmux agent that owns the canonical checkout and
is the only one that merges. **Always create a rudolph.** Santa orchestrates and does
not touch the checkout.

- **Rudolph alone**: owns the canonical checkout, runs the **full `<GATE>`**, fixes gate
  findings, and **merges**. It is the only agent that writes to `<TARGET>`.
- **Santa (you)**: briefs helpers, makes decisions, keeps the ledger, and hands rudolph
  branches. **You do not touch the canonical checkout** — not `jj git fetch`, not
  `jj new`, not a rebase. Every one of those mutates shared state and will strand
  rudolph's working copy mid-verification. Verify through `git ls-remote` and `gh api`,
  which read the remote without touching local VCS state, or ask rudolph to run it.
- **Helpers (elves)**: implement in their **own isolated workspace**. They **push their
  own branch and open their own PR**; they never merge. **One standing branch and one
  open PR per lane** — name the branch after the lane's phase (`rp-lane`, `qq-lane`,
  `tj-lane`), not after the substep, so there is one obvious place every substep goes.
  **One open PR per lane at a time** — a lane pushes each new substep onto the SAME branch and lets the PR grow,
  and only opens a fresh PR once the integrator has merged the previous one. N open
  PRs from one lane multiply the integrator's verification work N times over the same
  phase, and the integrator is already the serial bottleneck. Letting them push means the
  push gate runs at their desk, surfacing findings where the author is — and it means
  they never idle waiting on integration.
  They may run the **cheap, scope-limited `<CHECK>`** (e.g. `cargo check -p <touched-crate>`).
  When a change alters a public signature they **enumerate the dependents and name them
  in the report** — they do NOT build the expensive ones; rudolph verifies those once, in
  the warm canonical tree. They **never** run the full `<GATE>`/whole-project sweep in
  their own workspace: **each full build cold-populates that workspace's own multi-GB
  output tree, times N helpers in parallel, which fills the disk** (see the disk/artifact
  hard rule below). And they never touch the canonical checkout or each other's workspace.

If you remember one thing: **elves `<CHECK>` + push their branch; rudolph `<GATE>` +
merges; Santa orchestrates and touches nothing.**

---

## Rudolph — the integrator, always a tmux agent

**Always create one.** Never run the integrator as an orchestrator subagent: a subagent
reinitialises its context on every message, so the integration knowledge — which
branches are dangerous, which conflicts must not be resolved, what was already verified
— is rebuilt from scratch each time and burns tokens doing it. A tmux agent keeps it.

```bash
# Launch a SHELL first, then the agent inside it. Never `-- claude` directly.
tmux new-session -d -s rudolph -c <CANONICAL-CHECKOUT>
tmux send-keys -t rudolph 'claude --name "rudolph (integrator)"' Enter
```

**Spawn every tmux agent through a shell — this applies to elves too.** `tmux
new-session -- claude` starts the harness with **no shell in its path**, so it inherits
the **tmux server's** environment, which is as old as the server. A profile fix
(`~/.zshenv`) reaches every shell including non-interactive ones — and cannot reach a
process that never ran one.

The failure is nasty because it is invisible and misattributed: on one machine the tmux
server predated a build-cache change, so harness-spawned agents carried a
`RUSTC_WRAPPER` pointing at an uninstalled binary. Every push died inside the gate, and
the gate reported it as a *documentation* failure — sending the author to audit docs
that were never wrong. Shell-spawned lanes on the same host pushed fine, which made it
look session-specific rather than structural.

**To repair an already-mis-spawned agent without losing its context:** take its session
id from `~/.claude/projects/<project-dir>/<id>.jsonl` (newest mtime), kill the tmux
session, recreate it running the shell, then `claude --resume <id>` inside it. The
conversation is on disk; only the process is replaced. **Verify the fix directly** —
`echo $RUSTC_WRAPPER` (or whatever the variable was) in the new session, before
concluding it worked.

Brief it once as a **standing role**, not a task. The brief must carry:

- **The boundary**: it merges, elves never do; Santa never touches its checkout.
- **Verify by CONTENT, not ancestry.** A change can be an ancestor of the trunk with its
  content absent. Pair every claim with a **control that must come out different** — a
  marker present after the merge and absent on the pre-merge revision.
- **Route stderr separately from stdout.** An error's text is non-empty and reads as
  success. This single habit catches more than any other.
- **Know which outputs are impossible, not merely wrong** — an empty trunk ref, a subset
  larger than its total, a test count from a run you watched compile. When one appears,
  **suspect the instrument, never the repository.** Impossibility ends the argument;
  a wrong value only starts one about methodology.
- **Freeze BEFORE the integrator starts, not alongside it.** The handshake has a race:
  a lane told "keep working locally" while a verification is already running may have
  pushed seconds earlier, and the integrator then discards evidence gathered against a
  head that moved. Send the freeze first, confirm the lane acknowledged it, and only
  then hand the PR over. When it races anyway, say plainly that the timing was yours —
  the lane followed the instruction it had.
- **The freeze never blocks a fix.** A frozen lane still owes pushes that make its
  branch verifiable — a rebase, a conflict resolution, a finding the integrator raised.
  The freeze protects verification **in progress**, nothing else; if the branch cannot be
  verified until the lane pushes, unfreeze, let it push, refreeze. This collides on first
  contact otherwise, and the collision looks like the lane being obstinate.
- **Tell a lane to rebase EARLY, not at merge time.** A long-lived branch drifts behind
  trunk while it works, and the cost is not the conflict — it is that every number the
  lane measured (floors, counts, ledger figures) describes a tree that no longer exists,
  and every check it ran was against the old base. Merging such a branch can silently
  carry an old ceiling forward and re-permit retired debt. Watch the fork distance and
  say so while the lane is still working; rebasing at merge time means verifying twice.
- **Check mergeability BEFORE spending verification.** A conflicting branch cannot be
  verified at all, so a full contract run against it is wasted from the first command.
  And the freeze below does not apply to it — there is nothing to protect while it cannot
  be verified, and resolving the conflict *requires* the push the freeze forbids. Unfreeze,
  let the lane rebase, re-freeze when it reports clean, and re-capture the base: the
  pre-rebase revision is void, not stale.
- **A branch under verification is frozen — tell the lane, do not just hope.** A lane
  that pushes while the integrator is verifying its PR invalidates every result gathered
  so far, and the only remedy is to discard the work and re-run it. The lane is not doing
  anything wrong; nothing tells it the integrator started. Santa announces "your branch is
  under verification, hold" and "merged, push freely" as an explicit handshake. This is
  the cheapest of the three head-movement defences and it prevents the problem the other
  two only detect.
- **Pin the head in the merge call itself, not in a check before it.** Comparing the
  head and then merging leaves a window; passing the expected revision to the merge API
  (`gh api ... -f sha=<verified-head>`) makes the platform reject the merge if the branch
  moved. **Evidence is only valid against the revision it was gathered on**, and standing
  branches move during verification, not merely before it.
- **Never squash** — change IDs are the durable identifiers a ledger cites.
- **Stop rather than resolve** a conflict in any shared bookkeeping file (allow-lists,
  ledgers). Those have no mechanically obvious side: one arm restores retired entries,
  the other silently drops live ones, and both produce a plausible file.
- **Do NOT fix gate findings — report them.** Leave a PR comment with the rule name, the
  file:line, the verbatim gate output, and what would satisfy it; tell Santa the PR
  failed and why; move to the next branch without blocking. **A fix by rudolph teaches
  nobody**: in one campaign the same lint was fixed by the integrator twice in an hour
  because the lane that produced it never saw the rule. A comment reaches the author.
  - **Carry the measurements, AND tell the lane to re-measure.** A comment naming the
    exact numbers saves the author a re-derivation — but on a **standing branch the lane
    keeps pushing to**, those numbers have a shelf life and the lane will invalidate them
    before it reads the comment. Numbers without "re-measure before you act on this" turn
    precision into a trap: the author fixes to a figure that was true when you measured
    and is wrong when they land it.
- **Never baseline, never gate-skip, never override** without explicit per-instance
  authorization from Santa. Only *who fixes* changed, not *whether* it gets fixed.
- **Report BOTH outcomes** — merged and failed — to Santa and on the PR. Santa needs both
  to tell an improving lane from a repeating one.
- **Report after each merge, not per queue** — and **report absences too**. A prediction
  that fails is as informative as one that holds.

## Elves — count and kind are the user's call

**How many elves and whether they are codex or claude is dynamic.** Ask or take the
user's stated preference; there is no fixed number. What is fixed is the shape:

- one isolated workspace each
- **a long-lived branch per phase**, not per task — each step is the base for the next,
  and re-deriving it is how a serial lane or a multi-step migration stalls
- before every step: fetch, rebase onto trunk, and **abandon changes that have become
  empty** — an empty change post-rebase is work that landed, not work lost
- after a step: push the branch, open or update the PR, **and immediately continue**

**Give each long-running phase a PERMANENT lane.** A phase that keeps getting picked up
and put down is re-derived every time; a permanent lane keeps the map in its head. Where
phases build on each other, this matters twice over:

- **Their work lands on trunk continuously, not at phase completion.** Rudolph merges
  what is ready as it is ready, even while the phase has work left.
- **Each rebases onto trunk at the start of every WP or substep**, so it picks up the
  others' landed work instead of diverging from it.
- Expect several phase PRs open and **growing** at once. Rudolph re-reads each head
  immediately before merging — the change-ID list it inspected may be short by then.

**When a lane's PR fails the gate, the LANE fixes it, not rudolph.** That is what makes
the permanent-lane arrangement compound: the author sees the rule and stops reproducing
it, instead of an integrator silently absorbing the same finding repeatedly.

**Re-arm the watcher whenever the fleet changes, and check what it actually counts.**
Replacing an agent, adding a lane, or losing one to a quota limit leaves the monitor
watching the old set. A watcher that counts *sessions* rather than *work* reports full
health while pointed at dead panes — a killed agent's tmux session still exists, so
"N/N alive" stays true while the lanes that replaced it are unwatched. Restate the
session list on every fleet change, and confirm the names you passed are the names
that are working.

**Watch for silent model changes and memory pressure — both look like healthy work.**
A tmux agent can fall back to a smaller model mid-run; the footer is the only place it
shows. An integrator on a 200k window carrying 400k of context keeps reasoning fluently
while dropping the verification history it is merging on. Check the model line, not the
output quality. Fix with `/model`, choosing the large-context variant explicitly — the
bare model name may select a smaller window.

**Size the fleet to the INTEGRATOR's throughput, not to the number of slices.**
One integrator verifying thoroughly is the serial constraint. Lanes that outproduce it
do not ship sooner — they queue, while contending for the same shared build cache and
slowing every lane including the integrator's own. If the queue keeps growing, park
lanes that already have a PR in it. Three lanes that merge beat five that wait.

**N lanes compiling at once is over-subscription, and the machine says so before you do.**
Watch swap, not just liveness. When it thrashes, park lanes rather than capping the
build's job count — the repo's `jobs` value is checked in and stands. Park the lanes
whose output is *already queued for merge*: more branches from them cannot help while
the integrator is the constraint. Tell a parked lane a kill by `signal: 9` is the
machine, not its branch, or it will diagnose a defect that is not there.

**Releasing a parked lane takes `/goal resume`, not a message.** An interrupted goal
shows `Goal stalled` and a plain instruction leaves it stalled — it acknowledges and
does nothing.

**A PR comment does not reach a lane. Santa relays every finding into the pane.**
A tmux lane reads its pane; nothing makes it poll GitHub. So a finding left only as a PR
comment lands where the one agent who must act on it never looks — and the failure is
silent in the worst way: the comment exists, it is correct, it is even courteous, and
the work simply never happens.

- **Rudolph reports each finding to Santa AND comments on the PR.** The comment is the
  durable record for humans and for the next integrator; the relay is what actually
  changes the code.
- **Santa relays it into the lane's pane**, in full — file, exact edit, and why no gate
  caught it. Do not summarise it to "see the PR comment".
- **The tell is repetition without motion:** the same finding commented twice and pushes
  landing in between that do not touch the named file. Read that as *not delivered*,
  not as *deprioritised*. Instruct rudolph to escalate rather than comment a third time —
  a third comment is the protocol failing louder, not working.
- **Numbers in a comment go stale on a standing branch.** Whenever a finding carries
  measured values, the relay must say **re-derive at the moment of commit, never copy
  the figure** — the lane's own progress is what invalidates it.

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

> **NEVER hand-roll `until [ -f <done> ]; do sleep …; done`.** That loop is
> *exactly* the blindness this whole section exists to remove: it can only ever fire
> on the one happy state and is structurally silent on a helper that blocked, paused
> to ask you a question, quit early, or died — so you sit waiting on a corpse. Reading
> this section and then writing that loop anyway (it has happened) defeats the point.
> The reflex when you want to "wait for the helper" is to **arm `watch-elves.sh`**,
> not to write a sleep-loop on the done-file.

**Arm the persistent watcher instead** (`watch-elves.sh`, shipped next to this file),
run through the `Monitor` tool so each stdout line becomes one event:

```bash
<skill-dir>/watch-elves.sh <report-dir> codex codex2 codex3 rudolph
```

**For a long campaign, arm `supervise-elves.sh` instead** (shipped next to this
file); it wraps the watcher and closes the one gap the watcher cannot close for
itself:

```bash
HB_EVERY=600 <skill-dir>/supervise-elves.sh <report-dir> codex codex2 codex3 rudolph
```

Edge-triggering is what keeps `watch-elves.sh` from becoming the context problem
it exists to solve — but it also means **a healthy quiet watcher and a dead one
emit exactly the same thing: nothing.** Silence is not evidence that the fleet is
fine. The supervisor adds three things: a `HEARTBEAT` on a fixed cadence (so
silence past ~2 beats is *diagnostic*), an append-only log so events survive the
harness task dying and can be read back afterwards, and auto-restart if the
watcher exits — with the restart emitted as its own event. Verify the monitor is
alive before you end a turn, not merely that you started one; the harness-side
task can die while the shell process lingers, so a process count is not proof.
The log is.

It emits seven signals, and **only on a state transition**:

| Event | Trigger | Your response |
|---|---|---|
| `REPORT-READY` | report file appears (+ line count + first 300 chars) | verify → integrate → gate → push |
| `DIALOG` | pane matches an update / trust / allow / retry prompt | send the keypress |
| `WORKING` | pane shows a tool call in flight | nothing — it's healthy |
| `IDLE-STALL` | N idle ticks, **no** report | re-nudge; it quit early **or is waiting on you** — read the pane: a helper that stopped to surface a genuine blocker (a move-map conflict, a missing decision) shows up here too, and the right response is to answer it + resume its goal, not just poke it |
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
5. **Merge to `<TARGET>`.** Only rudolph merges — never squash; change IDs are the durable identifiers a ledger cites.

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

- **Only rudolph merges and runs the full `<GATE>`.** Elves run `<CHECK>` and push their own branch; Santa touches no checkout at all.
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
    (`cargo check -p <touched-crate>`, `cargo test -p <touched-crate>`, a named
    `cargo nextest run -E 'test(x)'`, `tsc --noEmit` on the touched project).
    **FORBIDDEN in a helper workspace, with no exception worth the disk:**
    `--all-features`, `--all-targets`, the two together, `clippy` carrying either,
    `--workspace`, a full `nextest`/`go test ./...`/`pytest` sweep, and **`-p
    <composition-crate>`** — a crate that depends on everything (a kernel, a boot
    or wiring crate, the composition root) is a whole-workspace build wearing a
    `-p` costume, and its `--all-features` graph is the entire tree.
  - **This rule is broken by a SECOND, well-meant instruction — check every brief
    against it.** Measured: after a helper shipped an API change that broke a
    dependent crate, the orchestrator added "check every direct dependent" to the
    briefs. Correct instinct, ruinous mechanics — the dependent WAS the
    composition crate, so four helpers each cold-built the world in their own
    `target/`, and thirteen workspaces reached 60 GB. The orchestrator had quoted
    this very rule at them in the same brief.
  - **So verify dependents like this instead — report, then build ONCE.** The
    helper enumerates them (`cargo metadata` gives a real census, not a guess),
    checks only the ones that are genuinely cheap leaves, and **names the rest in
    its done-file**. Santa builds those in the canonical warm tree — which costs
    nothing extra, because the gate already compiles the world at push time. The
    check moves to where the build already happens.  
  - **The full `<GATE>` and any whole-project verification/closeout run once,
    SEQUENTIALLY, in the single canonical checkout** — one **warm** output tree
    reused across every slice, not N cold ones. Finish one slice's gate+merge, then
    the next; don't fan the heavy builds back out.
  - If the closeout must itself be driven by an agent, point **one dedicated
    closeout helper at the canonical checkout** (not at each slice's own workspace),
    so the heavy builds still hit a single output tree while the original helpers
    stay parked in their workspaces.
  - **Reclaim each helper's workspace IN THE SAME STEP as its merge** (drop the
    workspace + its output tree; e.g. `jj workspace forget <name>` + remove the
    dir). Not "at the end of the round" — the end of a round is when the next
    round starts, and a dead workspace is indistinguishable from a live one at a
    glance. Measured: twelve merged slices sat un-reclaimed at 54 GB while a
    thirteenth was still building. Tie it to the ledger update so it cannot be
    forgotten: merge, ledger, reclaim. Watch free disk across the run; if it drops
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
