# Feature-team agent guide (read after BRIEF.md)

Repo: /Users/lulupointu/Development/local-capcut (main branch = integration branch). You work in your own git worktree/branch.

## Before coding
1. Read docs/BRIEF.md, docs/ARCHITECTURE.md (esp. the registries, "How to add X", §17 work map), and the docs/UX.md + docs/UX_AI.md
   sections for your area (look at the referenced screenshots in docs/ux/). UX parity with CapCut is part of "done".
   The big docs (FEATURES 196 KB, UX 87 KB, STATUS 52 KB) are grepped, not read whole; the project skills
   (`add-feature`, `write-ui-script`, `run-gates`, `montage-gotchas`) hold the distilled workflow and gotchas.
2. Find your rows in docs/FEATURES.md. You own them: implement as many as possible, P0 first, then P1, then P2. Skip rows with status `wontdo` (owner decision) — never implement them.

## Definition of done (per feature)
- Functionality matches the FEATURES.md row; UX (placement, controls, defaults, flow, feedback) matches UX.md as closely as possible.
- Every user-visible string localized en + fr (use the CapCut French glossary in UX.md §10 for terminology).
- Tests: model/engine logic unit-tested; render/export behaviour covered by a render test; UI verified by an offscreen screenshot
  (scripts/screenshot.sh) that you actually LOOK at. Interaction tests via the UI test driver once it exists (see ARCHITECTURE.md).
- Performance: no main-thread blocking; nothing that regresses the perf smoke test. Think "base MacBook Air 8 GB".
- Row status reported to the orchestrator: done / partial (say what's missing) / blocked (why), with the proposed
  FEATURES.md Status text. The orchestrator writes docs/FEATURES.md and docs/STATUS.md (one docs commit per batch), so
  feature branches don't conflict on them; edit them yourself only when your brief says so.

## Rules
- Stay inside your owned directories; edits to shared hotspots (model fields, EditorStore, CoreShaders, Package.swift, registries'
  lists) must be small and additive. Don't refactor other teams' code.
- Never send mouse/keyboard input to the screen and never activate apps (other agents work in parallel); launch the app only via
  scripts/screenshot.sh or in the background.
- Keep each commit building. Commit messages end with:
  Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>
  (use `/usr/bin/git -c user.name=Montage -c user.email=dev@montage.local commit ...`; in an isolated worktree bare `git`
  is rewritten by the rtk hook and refused — see CLAUDE.md "Shell in an isolated worktree")
- Long runs (build, tests, gates): Bash `run_in_background: true`, then wait for the completion notification. Never poll
  with `until grep …; sleep` loops. Stop your own stuck run with `scripts/kill_tests.sh`, not `kill`.

## Gate policy (owner-approved 2026-10-21): agents run the quick check, the orchestrator the full one
- **Feature agents**: targeted tests while iterating (`scripts/test.sh --filter X`, `scripts/uitest.sh <scripts>`), then
  `scripts/check_fast.sh` once on the final commit (must print FAST CHECK OK). Feature agents do NOT run
  `scripts/check_clean.sh` and do not merge.
- **Orchestrator**: integrates 1..N ready branches on a batch branch (`batch-<n>`, its own worktree, merge commits on
  top of main), commits the FEATURES / STATUS updates there, runs `scripts/check_clean.sh --ui` ONCE in the batch
  worktree, then `scripts/merge_agent.sh batch-<n>`. merge_agent refuses unless the stamp `build/check_clean.ok` names
  the exact batch HEAD in mode ui (`--docs-delta-ok` also accepts a gated commit whose tree differs only under docs/,
  e.g. after merging docs-only commits from main; `--check-only` verifies without merging). Playbook: the
  `orchestrate-features` skill. The full gate still runs on every line of code that reaches main — once.

## Test tools
- **Quick check: `scripts/check_fast.sh`** (typically 5–12 min). Incremental build of your working tree
  (uncommitted changes included), every unit test, and only the UI scripts relevant to `git diff main...HEAD` + your
  uncommitted files: a 5-script smoke set + scripts linked to the changed lines (test IDs / l10n keys reached from the
  changed declarations, driver actions, state-dump keys; `scripts/ui_select.py`, docs/TESTING.md) + changed scripts /
  fixtures / baselines; `app/Tests/ui_map.txt` only holds always / fallback directory rules. `--list` shows what it would run and why;
  `--unit-filter <re>` narrows the unit tests; `--base HEAD~1` checks only your last commit's UI area; `--all-ui` runs every
  script (still incremental). A one-file change measured 6 min (980 unit tests + 11 UI scripts); while iterating prefer
  the targeted runs, and run check_fast once on the final commit. Single files: `scripts/test.sh --filter X`, `scripts/uitest.sh app/Tests/UIScripts/x.json`.
  Intel (x86_64) build: `scripts/test_x86.sh [--filter X]` runs Core / Effects / Engine tests as x86_64 under Rosetta
  (CPU code paths only: Metal still runs on the Apple GPU). Float16 doesn't exist on x86_64: use `Half` (MontageCore).
- **Full gate (orchestrator, once per batch): `scripts/check_clean.sh --ui`** (fresh clean checkout of HEAD, ~980 unit
  tests, every UI script, 16–35 min). It fails when a file under app/ or scripts/ is git-ignored and only counts committed
  files, so a build that works only because of uncommitted or ignored local files is caught: commit everything you need.
  On success it writes `build/check_clean.ok` (commit, date, mode) for `scripts/merge_agent.sh`. Don't re-run it to
  debug: fix with targeted runs / check_fast, then gate once more.
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

## Finishing (feature agent)
1. Commit everything (untracked / ignored files under app/ or scripts/ fail the batch gate). If main moved:
   `/usr/bin/git rebase main` in your worktree, resolving conflicts with BOTH sides' intent kept.
2. `scripts/check_fast.sh` on that final commit: must print FAST CHECK OK.
3. Report "ready" (format below). Don't merge into main yourself, don't run check_clean, never force-push or reset main.
   The orchestrator integrates your branch into a batch, gates the batch and merges it with `scripts/merge_agent.sh`;
   if the batch gate finds a failure in your area you get it back by message.

## Final reply to the orchestrator
The report format of `.claude/agents/feature-dev.md` (STATUS / BRANCH / ROWS / GATE / TARGETED / TOUCHED OUTSIDE AREA /
BASELINES / NOTES, ≤ 30 lines). Do not paste code.

## Project tracker
docs/STATUS.md tracks workstreams, open cross-team requests and decisions; the orchestrator maintains it. Put cross-team
requests (one line each) and resolved requests in your report's NOTES.
`scripts/feature_status.py` summarises FEATURES.md (`--list partial --area TL` for details).

## AI models in tests
The owner allows installing any AI models needed to run tests (2026-10-19). Install via the app's model manager paths
(Application Support) or scripts; never commit model files. Model-gated UI scripts (`requires.models`) should be run, not skipped,
when your work touches AI features.
