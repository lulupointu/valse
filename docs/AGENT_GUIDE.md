# Feature-team agent guide (read after BRIEF.md)

Repo: /Users/lulupointu/Development/local-capcut (main branch = integration branch). You work in your own git worktree/branch.

## Before coding
1. Read docs/BRIEF.md, docs/ARCHITECTURE.md (esp. the registries, "How to add X", §17 work map), and the docs/UX.md + docs/UX_AI.md
   sections for your area (look at the referenced screenshots in docs/ux/). UX parity with CapCut is part of "done".
2. Find your rows in docs/FEATURES.md. You own them: implement as many as possible, P0 first, then P1, then P2. Skip rows with status `wontdo` (owner decision) — never implement them.

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

## Testing: two-stage gate (T1)
- **Stage 1 — while iterating: `scripts/check_fast.sh`** (typically 5–12 min). Incremental build of your working tree
  (uncommitted changes included), every unit test, and only the UI scripts relevant to `git diff main...HEAD` + your
  uncommitted files: a smoke set + `app/Tests/ui_map.txt` (source dir → scripts) + scripts that use a test ID / l10n key
  found in a changed Swift file + changed scripts / fixtures / baselines. `--list` shows what it would run and why;
  `--unit-filter <re>` narrows the unit tests; `--base HEAD~1` checks only your last commit's UI area; `--all-ui` runs every
  script (still incremental). Run it as often as you like (a one-file change measured 6 min: 980 unit tests + 11 UI scripts).
  Single files: `scripts/test.sh --filter X`, `scripts/uitest.sh app/Tests/UIScripts/x.json`.
  Intel (x86_64) build: `scripts/test_x86.sh [--filter X]` runs Core / Effects / Engine tests as x86_64 under Rosetta
  (CPU code paths only: Metal still runs on the Apple GPU). Float16 doesn't exist on x86_64: use `Half` (MontageCore).
- **Stage 2 — once, just before "ready to merge": `scripts/check_clean.sh --ui`** (fresh clean checkout, ~970 unit tests,
  every UI script, 16–33 min). Only this one proves the branch; it writes `build/check_clean.ok` for the merge.
  Don't run stage 2 repeatedly to debug: fix with stage 1 / single scripts, then run stage 2 once more.
- **Flaky vs failing.** Every failed unit test / UI script is retried once, alone. Passing on the retry prints
  "flaky (passed on retry)" and does not fail the gate. Failing twice fails it, unless the test is in
  `app/Tests/quarantine.txt` (still run and reported, not gating; each entry has a date and a reason). Don't quarantine
  your own new failures; a test you broke is a failure. Fix flaky tests when you own them and remove their entry.
- **Hangs.** test.sh / uitest.sh / check_clean kill a run with no output and ~0 % CPU for 10 min (`MONTAGE_HANG_MINUTES`).
  They dump `sample` stacks into the log and fail with "HUNG". A UI script past its timeout is sampled (`hang-sample.txt`).
- **Slots / disk.** Heavy runs share machine-wide slots. `scripts/slots.sh status` shows who holds them; dead holders,
  and holders idle for 20 min, are reclaimed automatically (with a printed line). The gates fail fast below 5 GB free:
  run `scripts/cleanup.sh --dry-run`, then `scripts/cleanup.sh`. Test temp files are deleted on exit (private TMPDIR per run).
- **Real-like media.** `RealLikeMedia` (MontageTestSupport) and `fixtures/real/` (iPhone HEVC Main10 HLG portrait with a
  face and speech, English speech with a pause, 120 BPM music) cover player / colour / thumbnail / waveform / beat
  paths. Prefer them over testsrc patterns for media features. Owner clips are opt-in only (`MONTAGE_REAL_FOOTAGE`), never commit them.

## Integrating (you do it yourself, at least once at the end; earlier for big milestones)
1. `git fetch` is not needed (same repo). In your worktree: `git rebase main` (main = the main repo's branch), resolve conflicts
   preserving BOTH sides' intent, run `scripts/check_fast.sh` (must print FAST CHECK OK).
   Then commit everything and run `scripts/check_clean.sh --ui` (must print CLEAN CHECKOUT OK). It fails when a file under
   app/ or scripts/ is git-ignored, and it builds and tests a fresh worktree of HEAD, so a build that only works
   because of uncommitted or ignored local files is caught. Do this before reporting "ready to merge".
   The orchestrator merges with `scripts/merge_agent.sh <branch>`: it checks the gate stamp, ff-merges, runs build_app
   and removes the worktree's .build.
2. Try to fast-forward main to your branch: `git -C /Users/lulupointu/Development/local-capcut merge --ff-only <your-branch>`.
   If it fails because main moved, repeat from 1. Never force-push, never reset main, never merge with failing tests.
   If the ff-merge is blocked by a permission check, don't retry or work around it: just report "ready to merge: <branch> @ <hash>, rebased on <main hash>, tests green" and the orchestrator merges it.
   If the main checkout has uncommitted changes blocking the ff merge, use `git -C <repo> update-ref` ONLY if the working tree
   files involved are untouched; otherwise report it.

## Final reply to the orchestrator (UNDER 200 words)
Features done / partial / blocked (counts + IDs of partial/blocked), how verified, merged to main yes/no (commit hash), notable
issues for other teams. Do not paste code.

## Project tracker
docs/STATUS.md tracks workstreams, open cross-team requests and decisions. When you depend on another team, add a row to
"Cross-team requests" (keep it one line). When you resolve someone's request, move it to "Done cross-team items".
`scripts/feature_status.py` summarises FEATURES.md (`--list partial --area TL` for details).

## AI models in tests
The owner allows installing any AI models needed to run tests (2026-10-19). Install via the app's model manager paths
(Application Support) or scripts; never commit model files. Model-gated UI scripts (`requires.models`) should be run, not skipped,
when your work touches AI features.
