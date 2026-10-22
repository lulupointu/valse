# Montage: agent playbook (loaded every turn: keep it short)

Montage is a native macOS video editor (CapCut parity, local-first). Swift 6, SwiftPM only (no Xcode project), deployment
target macOS 13 (Apple Silicon + Intel), UI in en + fr. Built ONLY by Claude agents: an orchestrator (main session)
and feature agents in git worktrees under `.claude/worktrees/`. The main checkout is the integration branch `main`.

## Module map (`app/Sources/`, deps flow left to right; details: docs/ARCHITECTURE.md §1)
- `MontageCore`: time, model (Project/Timeline/Track/Clip), `TimelineOps`, commands + undo, persistence, L10n. Foundation only.
- `MontageEffects`: content registries (effects, transitions, animations, stickers, text styles), shaders.
- `MontageEngine`: Metal compositor (`FrameRenderer`), playback, export, media probe, proxies, caches, `JobQueue`. No AppKit.
- `MontageAI`: AI tools, model catalog, speech, Vision mattes, TTS. `MontageUI`: `EditorStore`, panels, timeline, inspector,
  Home, UI test driver (`MontageUI/Testing/`). `MontageApp`: `main.swift`. `MontageTestSupport`: test helpers.
- Tests: `app/Tests/Montage*Tests/` (unit), `app/Tests/UIScripts/*.json` (UI scripts), `app/Tests/Baselines/` (PNG
  baselines, `macos13/` overrides), `app/Tests/ui_map.txt` (smoke / always / fallback rules; check_fast selection = `scripts/ui_select.py --explain`), `app/Tests/quarantine.txt`.

## Docs (never read the big ones whole: grep your section / row ID, then read that range)
- docs/BRIEF.md (goal), docs/AGENT_GUIDE.md (workflow + gate policy), docs/ARCHITECTURE.md (§11 l10n, §12 registries,
  §16 "How to add X", §17 work map = who owns which directory), docs/TESTING.md (UI DSL, baselines, perf).
- docs/FEATURES.md (196 KB, rows by ID), docs/UX.md / UX_AI.md (87 / 53 KB, screenshots in docs/ux/), docs/STATUS.md (tracker).
- Skills (load instead of re-reading docs): `add-feature`, `run-gates`, `write-ui-script`, `montage-gotchas`,
  `orchestrate-features` (orchestrator only). Agent definition for feature work: `.claude/agents/feature-dev.md`.

## Commands (all exist in scripts/; `-h` prints usage)
| What | Command |
|---|---|
| unit tests (l10n check + build + tests, retries) | `scripts/test.sh [--filter <Suite or regex>]` |
| UI scripts | `scripts/uitest.sh app/Tests/UIScripts/<name>.json …` (`--update-baselines`, `--no-build`, `--timeout <s>`) |
| feature-agent gate | `scripts/check_fast.sh` (`--list` = which UI scripts and why, `--unit-filter <re>`, `--base <ref>`, default = nearest of main / batch-*) |
| batch gate (orchestrator) | `scripts/check_clean.sh --ui` (clean checkout of HEAD, every test; writes build/check_clean.ok) |
| merge (orchestrator) | `scripts/merge_agent.sh <branch> [--check-only] [--docs-delta-ok]` |
| look at the UI | `scripts/screenshot.sh --demo --offscreen` (then Read the PNG) |
| slots / disk / stop own runs | `scripts/slots.sh status`, `scripts/cleanup.sh --dry-run`, `scripts/kill_tests.sh --dry-run` |
| app bundle | `scripts/build_app.sh [--host-only]`; Intel unit tests: `scripts/test_x86.sh [--filter X]` |
| feature counts | `python3 scripts/feature_status.py --list partial --area TL` |

## Gate policy (2026-10-21, owner-approved: agents run the quick check, the orchestrator the full one)
- Feature agent: targeted tests while iterating (`scripts/test.sh --filter …`, `scripts/uitest.sh <your scripts>`), then
  `scripts/check_fast.sh` once on the final commit (must print FAST CHECK OK). Do NOT run `check_clean.sh`.
- Orchestrator: integrates 1..N ready branches on a batch branch, runs `scripts/check_clean.sh --ui` ONCE for the batch
  HEAD, then `scripts/merge_agent.sh <batch>` (refuses unless that exact HEAD passed; `--docs-delta-ok` = only docs/ differ).
- "flaky (passed on retry)" lines are bug reports: mention them in your report. Never add your own failure to quarantine.txt.

## Hard rules
- Never send real mouse/keyboard input, never activate apps or open windows on screen. UI = `scripts/uitest.sh` /
  `scripts/screenshot.sh --offscreen` only (offscreen window, synthetic in-process events).
- Commit in your worktree only: `/usr/bin/git -c user.name=Montage -c user.email=dev@montage.local commit -m "<ID>: …"`,
  message ending with the `Co-Authored-By:` trailer you were given. Every commit builds. Never push, never
  `reset --hard`, never force anything, never merge into main (the orchestrator does, via merge_agent.sh).
- Don't edit docs/STATUS.md or docs/FEATURES.md unless your brief says so: report row statuses, the orchestrator writes them.
- The machine is shared and never quiet (up to 10+ heavy runs). Heavy scripts take a slot (scripts/slots.sh) and may print
  "waiting for test slot…": that is normal, keep waiting. Never run two of your own heavy runs at once.
- Anything > 1 min (`swift build`, test.sh, uitest.sh, check_fast.sh): Bash `run_in_background: true`, then end your turn
  and wait for the completion notification. NEVER write `until grep …; do sleep …; done` / `sleep N; cat log` polling.
- Stop your own hung run with `scripts/kill_tests.sh` (only Montage test processes of your checkout), never `kill`/`pkill`.
- Stay in the directories your work-map area owns; shared hotspots (model fields, EditorStore, Package.swift, registry lists)
  get small additive edits only.

## Shell in an isolated worktree (most refused commands came from these)
The worktree guard refuses any command it cannot prove stays inside your worktree. To pass it:
- git: always `/usr/bin/git <subcommand> …` run from the worktree (cwd). Bare `git` is rewritten to `rtk git` by the rtk hook
  and refused; so are `git -C <main checkout>`, `git -C .`, and `rtk proxy git`. Read main with `/usr/bin/git log main`.
- One plain command per call (chain with `&&` only simple ones). No shell variables (`W=…; $W`), no `for` loops over
  computed values, no `$(…)`, no `python3 - <<EOF`, no `cat > file <<EOF`. Write scripts with the Write tool into your
  scratchpad, run `python3 -I <file>`. Edit files with Edit, never `sed -i` / `perl -pi`.
- Regex alternations in quoted args (`--filter "A|B"`) combined with redirects, `;` or env prefixes were refused: run
  `scripts/test.sh --filter 'A|B'` as the whole command (its log is build/test.log anyway), or one `--filter` per run.
- Write files only in your worktree or scratchpad (paths spelled out in full).

## rtk hook (token compressor)
The PreToolUse hook rewrites `git grep cat head tail ls find wc ps swift …` into `rtk …` (compressed output). Absolute
paths are never rewritten: `/usr/bin/git`, `/usr/bin/grep`, `/usr/bin/tail`, `/bin/cat`, `/bin/ps`; neither is `scripts/*.sh`.
- Parsing logs (exact lines, counts, `✘`/`failed:` lines in build/test.log, build/check_fast-*.log): use `/usr/bin/grep`
  / `/usr/bin/tail`, or the Read tool with offset/limit.
- `rtk proxy <cmd>` = run `<cmd>` unfiltered. Use it outside isolated worktrees when a compressed summary hides what you
  need (e.g. raw `swift test` output); inside a worktree prefer the absolute-path binaries (`rtk proxy git` is refused).
