---
name: orchestrate-features
description: Orchestrator playbook for Montage feature work - splitting FEATURES.md rows into small agent tasks, how many feature agents to run at once, file-area ownership, briefing feature-dev agents, integrating ready branches on a batch branch with ONE scripts/check_clean.sh --ui per batch, merging with scripts/merge_agent.sh, docs-only changes, failed batches, resuming interrupted agents. Use when planning, launching, integrating or merging feature agents (main session only).
---

# Orchestrating feature agents

Why this shape (measured 2026-10): agents spent 73 % of wall-clock waiting on gates; check_clean failed mostly on load
flakes (22 % with no other heavy run, 67 % with 4+); the same work was fully gated 2-3x. So: few agents, small items,
agents run only the quick gate, one full gate per batch.

## 1. Plan
- Items of 1-3 FEATURES.md rows of ONE area (`python3 scripts/feature_status.py --list todo --area <PREFIX>`).
  Small items return fast and conflict less; a whole area per agent produced 6-10 h runs with repeated gates.
- At most 3-4 feature agents at once (2 test slots machine-wide; each agent's builds + check_fast need one).
- Ownership by file area (docs/ARCHITECTURE.md §17 work map): never two concurrent agents in the same directory.
  Shared hotspots (model fields, `EditorStore.swift`, `CoreShaders.swift`, `BuiltinInspector.swift` sections,
  `Package.swift`, `app/Tests/ui_map.txt`): allow additive edits, expect trivial merge conflicts; serialize big ones.
- Agents do not edit docs/STATUS.md / docs/FEATURES.md: you write statuses from their reports (one docs commit per batch).

## 2. Launch
Agent tool, `subagent_type: "feature-dev"`, `isolation: "worktree"`. Brief (short; the agent definition has the workflow):
row IDs, owned directories, things NOT to touch, any owner decisions, the commit trailer, "report in the feature-dev
format". Don't paste docs: the agent greps what it needs.

## 3. Integrate a batch (main session, from the main checkout /Users/lulupointu/Development/local-capcut)
When 2-4 branches are ready (or 1 if nothing else is close), and no other batch gate is running:
1. `git worktree add .claude/worktrees/batch-<n> -b batch-<n> main`
2. In it, for each ready branch: `git merge --no-ff -m "batch-<n>: <branch> (<row IDs>)" <branch>`.
   Conflict you can't resolve with both intents kept → leave that branch out (`git merge --abort`) and send it back.
3. If you resolved code conflicts by hand: `swift build --build-tests` first (5 min beats a 25 min failed gate).
4. Commit the FEATURES.md / STATUS.md updates for these rows on the batch branch now (docs-only), so main doesn't move
   under the gate.
5. `scripts/check_clean.sh --ui` in the batch worktree, Bash `run_in_background: true`; wait for the notification.
   Never more than one batch gate at a time; don't start other heavy runs meanwhile.
6. `CLEAN CHECKOUT OK` → from the main checkout: `scripts/merge_agent.sh batch-<n>` (checks the stamp names the exact
   batch HEAD in mode ui, ff-only merges main, builds the app, removes the batch .build). `--check-only` verifies first.
7. Clean up: `git worktree remove .claude/worktrees/batch-<n>`, the merged agent worktrees, `scripts/cleanup.sh`.

## 4. Failed batch
- Read the `✘` lines and `build/check_clean-uitest/<script>/failure.png` in the batch worktree. Map each failure to a
  branch by area (ui_map.txt rule / owned dirs / `git log main..batch-<n> -- <path>`).
- `failed twice` in an area a branch touched → real: SendMessage the agent (failure lines + PNG path), drop the branch:
  new batch branch from main with the others (never `reset --hard` the old one), re-gate.
- Failure in an area no branch touched → load flake or pre-existing bug on main: check `scripts/slots.sh status` / the
  load at that time; re-run the gate ONCE. Second failure of the same test → it's real (fix it or get it fixed); a
  quarantine entry needs a dated reason and is the owner's call, never a way to pass a batch.
- `flaky (passed on retry)` lines don't fail the batch; collect them in STATUS.md; repeated offenders get a fix task.

## 5. Main moved while a batch was gated
- Only docs/ commits on main since: `git merge main` in the batch worktree (or rebase), then
  `scripts/merge_agent.sh batch-<n> --docs-delta-ok` (accepts the stamp when nothing outside docs/ differs from the
  gated commit; tests depend on docs/ only through its existence, `TestMedia.repoRoot`, never its content).
- Code moved on main: re-gate (merge main into the batch, `check_clean.sh --ui` again). Avoid this by merging batches
  one at a time.
- Docs-only branches (diff vs main only under docs/, CLAUDE.md, .claude/): no gate; `scripts/merge_agent.sh <branch>
  --skip-gate-check --no-build-app` after `git diff --name-only main...<branch>` confirms it.

## 6. Interrupted agents
- Session restart / auth / account switch stops agents; the worktree keeps the work. If the agent is still addressable:
  SendMessage it "continue". Otherwise start a NEW feature-dev agent WITHOUT `isolation`, pinned to the existing path:
  "Continue <IDs> in worktree <abs path> (branch <b>). First: `/usr/bin/git -C <abs path> log --oneline main..HEAD`
  and `status`; do not redo committed work; run every command from that path." The worktree, not the agent, is the
  source of truth. Uncommitted changes there are the previous agent's work in progress: keep them.
- A hung agent run: `scripts/slots.sh status`; idle holders are reclaimed after 20 min automatically;
  `scripts/kill_tests.sh --dir <worktree>` stops only Montage test processes of that worktree.
