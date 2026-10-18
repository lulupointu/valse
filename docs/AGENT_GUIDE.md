# Feature-team agent guide (read after BRIEF.md)

Repo: /Users/lulupointu/Development/local-capcut (main branch = integration branch). You work in your own git worktree/branch.

## Before coding
1. Read docs/BRIEF.md, docs/ARCHITECTURE.md (esp. the registries, "How to add X", §17 work map), and the docs/UX.md + docs/UX_AI.md
   sections for your area (look at the referenced screenshots in docs/ux/). UX parity with CapCut is part of "done".
2. Find your rows in docs/FEATURES.md. You own them: implement as many as possible, P0 first, then P1, then P2.

## Definition of done (per feature)
- Functionality matches the FEATURES.md row; UX (placement, controls, defaults, flow, feedback) matches UX.md as closely as possible.
- Every user-visible string localized en + fr (use the CapCut French glossary in UX.md §10 for terminology).
- Tests: model/engine logic unit-tested; render/export behaviour covered by a render test; UI verified by an offscreen screenshot
  (scripts/screenshot.sh) that you actually LOOK at. Interaction tests via the UI test driver once it exists (see ARCHITECTURE.md).
- Performance: no main-thread blocking; nothing that regresses the perf smoke test. Think "base MacBook Air 8 GB".
- FEATURES.md Status column updated: done / partial (say what's missing) / blocked (why).

## Rules
- Stay inside your owned directories; edits to shared hotspots (model fields, EditorStore, CoreShaders, Package.swift, registries'
  lists) must be small and additive. Don't refactor other teams' code.
- Never send mouse/keyboard input to the screen and never activate apps (other agents work in parallel); launch the app only via
  scripts/screenshot.sh or in the background.
- Keep each commit building. Commit messages end with:
  Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>
  (use `git -c user.name=Montage -c user.email=dev@montage.local commit ...`)

## Integrating (you do it yourself, at least once at the end; earlier for big milestones)
1. `git fetch` is not needed (same repo). In your worktree: `git rebase main` (main = the main repo's branch), resolve conflicts
   preserving BOTH sides' intent, run `scripts/test.sh` (must be green).
2. Fast-forward main to your branch: `git -C /Users/lulupointu/Development/local-capcut merge --ff-only <your-branch>`.
   If it fails because main moved, repeat from 1. Never force-push, never reset main, never merge with failing tests.
   If the main checkout has uncommitted changes blocking the ff merge, use `git -C <repo> update-ref` ONLY if the working tree
   files involved are untouched; otherwise report it.

## Final reply to the orchestrator (UNDER 200 words)
Features done / partial / blocked (counts + IDs of partial/blocked), how verified, merged to main yes/no (commit hash), notable
issues for other teams. Do not paste code.
