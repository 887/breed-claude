# Elf rules

Standing rules for every helper (elf) in a santaing fleet. Santa points each elf at this file in its brief and on every reassignment. The rules are generic; the last section maps them onto one repository's commands.

## PRs and ledger

1. **Draft PR at the start.** Before the first fix, push a draft PR from your bookmark and label it with your elf name.
2. **Progress section.** One checkbox line per work item (item id plus its issue number), ticked only by the ledger tool once evidence is in the head. Concrete steps are plain `- DONE:` / `- TODO:` bullets, never checkboxes, because unticked boxes block the merge.
3. **Keep it current.** Tick items as they land and move steps from TODO to DONE as you go. Push after each step, so the PR always shows where you are.
4. **Taking over a PR:** add your label and rewrite its checklist as your plan.
5. **Never hold work local-only.** If you're pulled off a task: push, tick what's done, and leave a handover comment (done with change ids, exact next step, what was running). A gate or build hold blocks only compiling; commit and push compile nothing.
6. **Ready means your code change is done.** Never put "run clippy/tests" or "regenerate" TODOs in a PR body: the merge gate runs clippy and tests, and the integrator regenerates at merge.

## Workspace

7. **Your own workspace only.** Never create new workspaces or worktrees: each one cold-compiles a full `target/` and fills the disk. Switch tasks inside your own workspace.

## Builds and tests

8. **No holds:** no load ceilings, no build tokens, no gate holds. Build and test whenever needed, and never abort a running build.
9. **One cargo command at a time, one build configuration** (the test wrapper's defaults). No extra profiles, `--all-features` or `--target` unless that specific test needs it: each combination recompiles everything.
10. **Targeted tests only.** List only the crates that contain your test cases, filter to the exact cases you changed (`test(...)`, never whole `package(...)`), and use the expensive profile only for cases that really need its setup.
11. **One verification pass, then ready.** Merge main, run your targeted tests once, fix real failures, push, mark ready. No test loops: the merge gate catches the rest.
12. **Before marking ready, run the merge gate's cheap steps** on your branch merged with current main, and fix what they find. The integrator's workspace-wide checks stay with the gate.

## Foundlings commands

- Ledger and PRs: `qew pr open <item> --head <bookmark> --base main --body-file F`, `qew pr label N --add <elf>`, `qew pr check N ITEM`, `qew pr body N --body-file F`, `qew pr ready N`. Checkbox line: `- [ ] ITEM (#issue): title <!-- pr-progress:ITEM -->`.
- Workspace: `.claude/worktrees/foundlings-elfN`; switch tasks with `jj new <base>`.
- Tests: `tools/scripts/nextest.sh` with its defaults; `--profile ci` only for cases that load native plugin artifacts.
- Cheap gate steps before `qew pr ready`:
  1. `cargo hakari verify && cargo hakari manage-deps --dry-run`
  2. `python3 tools/scripts/format_workspace.py --check`
  3. `cargo run --locked --quiet -p foundlings-lint-sweep --bin lint`
  4. `cargo run --locked --quiet -p foundlings-dependency-graph --bin dependency-graph`
  5. `cargo xtask schema-gen --check`, `cargo xtask facts --check` and `cargo xtask doc-truth --check` (on a schema-gen failure run `cargo xtask schema-gen` and commit the regenerated files)
  6. `tools/scripts/clippy.sh -p <every crate you touched>`
- After any dependency or feature change: `cargo hakari generate && cargo hakari manage-deps --yes`.
