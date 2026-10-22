---
name: add-feature
description: End-to-end checklist for implementing Montage feature rows from docs/FEATURES.md in a feature worktree - find the row and UX spec, locate the owning area in the ARCHITECTURE §17 work map, implement, unit test, UI script, l10n en+fr, targeted tests then check_fast, commit, report. Use when you are given feature IDs (e.g. "TL-012", "AI-031") or asked to build / finish a Montage feature.
---

# Implement Montage feature rows (feature agent)

Gate policy: you run targeted tests + `scripts/check_fast.sh`; the orchestrator runs `check_clean.sh --ui` per batch.
Commands below are exact; see CLAUDE.md "Shell in an isolated worktree" for the forms the guard accepts.

## 1. Understand (read narrowly: these docs are huge)
- Row: `/usr/bin/grep -n "<ID>" docs/FEATURES.md` then Read only those lines (+ the area's `## ` header line for context).
  Skip `wontdo` rows. Note P0/P1/P2 and what "done" means in the row.
- UX: `/usr/bin/grep -n "<keyword>" docs/UX.md docs/UX_AI.md docs/UX_GAPS.md`, Read that section; open the referenced
  `docs/ux/*.png` with Read. Parity with CapCut (placement, controls, defaults, feedback) is part of done.
- Owner: docs/ARCHITECTURE.md §17 work map (`/usr/bin/grep -n "^## 17" docs/ARCHITECTURE.md`) → your directories and the
  area section (§17b-g). Recipes: §16 "How to add X"; registries §12; l10n §11.
- Load `montage-gotchas` before touching media / playback / async / SwiftUI state / persistence.

## 2. Implement
- Stay in the owned directories. Shared hotspots (Clip/Project fields, `EditorStore.swift`, `CoreShaders.swift`,
  `BuiltinInspector.swift` sections, `Package.swift`) get small additive edits only.
- Model change: field with a default (decode old files), migration step if needed, persistence round-trip test.
- Undoable edits: `TimelineOps` (pure) + `EditCommand` + store method; inspector writes via `Bind` / `ClipParamRow`.
- Background / ML work via `JobQueue` (`heavy: true` for ML). No main-thread blocking (target: 8 GB MacBook Air).
- macOS 13: Perception wrapping, `#available` fallbacks; Intel: no `Float16`.
- Add `.testID("area.thing")` to every control you add.

## 3. Strings (en + fr)
- New keys in your feature's table `app/Sources/<Module>/Resources/{en,fr}.lproj/<Table>.strings`, both languages,
  French "vous" + UX.md §10 glossary. `tr("key")` / `Text(loc:)` only. `python3 scripts/l10n_check.py` (test.sh runs it).

## 4. Tests
- Unit: logic in MontageCore / Engine / Effects / AI unit tests (`app/Tests/Montage<Module>Tests/`); renders via a render
  test; real media via `RealLikeMedia`. Async waits on the task / state, never on wall-clock (montage-gotchas).
- UI: one script per user flow (load the `write-ui-script` skill): drive the real UI, `waitFor` state, `expect` the
  model, element-scoped snapshot with a baseline you LOOK at. Give the UI `.testID`s the script uses (that is how check_fast selects it); check with
  `python3 scripts/ui_select.py --explain`.
- Look at the UI at least once: `scripts/screenshot.sh --demo --offscreen` or your script's PNGs (Read them).

## 5. Verify (Bash `run_in_background: true` for each, wait for the notification)
1. `scripts/test.sh --filter <YourSuite>` until green.
2. `scripts/uitest.sh app/Tests/UIScripts/<yours>.json …` until green (and `"lang": "fr"` variant if layout-sensitive).
3. Commit (`/usr/bin/git add <paths>` then `/usr/bin/git -c user.name=Montage -c user.email=dev@montage.local commit -m "<ID>: …"`
   with the Co-Authored-By trailer). Untracked or git-ignored files under app/ or scripts/ break the clean gate: commit them.
4. Update your base if it moved. Your base is what your worktree was made from: `main`, or the `batch-<n>` branch your
   brief names (check: the `diff base:` line of `python3 scripts/ui_select.py --explain`). Based on main:
   `/usr/bin/git rebase main`. Based on `batch-<n>`: `/usr/bin/git rebase batch-<n>` (NOT main: rebasing a batch-based
   branch onto main drags the batch's unmerged commits into your branch); if the batch was merged meanwhile, rebasing on
   main is right. Resolve keeping both sides' intent; never `reset --hard`, never `rebase --skip` a commit with real changes.
5. `scripts/check_fast.sh` once on the final commit → must print `FAST CHECK OK` (its first line names the diff base it
   picked automatically: the nearest of main / batch-*; `--base <ref>` overrides). Fix real failures; flaky lines go in
   the report. Do NOT run `scripts/check_clean.sh` and do NOT merge into main.

## 6. Report (format: .claude/agents/feature-dev.md "Report")
Branch, HEAD SHA, base main SHA, rows done / partial (what is missing) / blocked (why), gate evidence (the
`FAST CHECK OK` line, unit count, UI scripts run, any flaky lines), files outside your area, macos13 baselines affected,
proposed FEATURES.md status text per row (the orchestrator writes docs/FEATURES.md and docs/STATUS.md).
