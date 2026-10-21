---
name: run-gates
description: Which Montage test / gate command to run when (scripts/test.sh, uitest.sh, check_fast.sh, check_clean.sh), how to run it without polling, and how to read the result - flaky vs failed vs quarantined, "waiting for test slot", HUNG / TIMEOUT runs, DISK FULL. Use before running any test or gate, when a gate fails, or when a run seems stuck.
---

# Running Montage tests and gates

## Which check when
| Moment | Who | Command | Typical time |
|---|---|---|---|
| iterating on logic | feature agent | `scripts/test.sh --filter <Suite>` (or `'SuiteA\|SuiteB'`, as the whole command) | 2-6 min (incremental build) |
| iterating on UI | feature agent | `scripts/uitest.sh app/Tests/UIScripts/<a>.json <b>.json` | ~20-60 s / script + build |
| what would check_fast pick, and why? | feature agent | `python3 scripts/ui_select.py --explain` (or `check_fast.sh --list`; `--commit <sha>` replays one commit) | seconds |
| done, final commit | feature agent | `scripts/check_fast.sh` (all unit tests + UI scripts selected from your diff vs main) | 5-15 min |
| only the last commit's UI area | feature agent | `scripts/check_fast.sh --base HEAD~1` | |
| batch of ready branches | orchestrator only | `scripts/check_clean.sh --ui` in the batch worktree | 8-16 min (unit ∥ UI, 4 UI apps, warm build) + the perf gate |
| Intel code paths (Float16 etc.) | if you touched CPU math | `scripts/test_x86.sh --filter X` | |
| perf-sensitive change | when asked | `scripts/perf.sh` (takes ALL slots: avoid on a busy machine) | |

Feature agents never run `check_clean.sh`: the orchestrator runs it once per batch (docs/AGENT_GUIDE.md).
`check_clean.sh --ui` also runs `scripts/perf.sh --no-smoke` (exclusive slot) once the concurrent unit + UI phases are done
(`--serial`: after the UI suite) and the gate has released its own slot, so the batch gate
checks the perf budgets (bench/perf_thresholds.json + perf.sh's `UNIT_TIMING` tests).

## Perf under load (docs/TESTING.md "perf.sh load rule")
- Correctness tests never assert wall clock (`TimingBudget.limit` = nil outside `MONTAGE_PERF=1`); thread-CPU (`_cpu_`),
  memory and the gross ×4 GPU-time bounds always gate.
- In perf.sh, wall-clock and GPU-time metrics (`launch_ms`, `_wall_`, `_gpu_`, unit wall-clock / strict GPU budgets) gate
  only while the 1-min load average stays ≤ the core count (sampled before / after each part). Above it perf.sh waits
  ≤ 5 min (`MONTAGE_PERF_LOAD_WAIT`), measures again, then reports each as `UNRELIABLE (load X > cores Y)` without gating.
  `MONTAGE_PERF_CORES` overrides the core count (also for TimingBudget).
- check_clean then prints `perf: N metrics unverified due to load` and the stamp `build/check_clean.ok` gets
  `perf-unverified=N` (merge_agent.sh still accepts it and prints a note). Say so in the batch report; re-run
  `scripts/perf.sh` on a quieter machine if the batch touched perf-sensitive code.
Don't use `check_fast.sh --all-ui` as a substitute for the batch gate.

check_fast's UI scripts come from `scripts/ui_select.py`: derived from your changed lines (changed declaration → test
IDs / l10n keys / dump keys → scripts whose JSON uses them) + changed scripts / fixtures / baselines + the 5-script
smoke set; `app/Tests/ui_map.txt` is only smoke / `always` / directory-fallback rules. If your script is missing from
`--explain`, the UI it drives lacks a `.testID` the script uses: add one (write-ui-script skill), don't add a ui_map rule.
`scripts/test_ui_select.py` (run by test.sh) tests the selector itself.

## How to run (no polling)
- Bash tool with `run_in_background: true`, command exactly e.g. `scripts/check_fast.sh` (no `> log; echo EXIT` wrappers
  needed, the tool keeps the output). End your turn; you are notified when it exits. Then read the output file.
- Never `until /usr/bin/grep -q … ; do sleep 30; done`, never `sleep 240; cat …`: refused or wasteful.
- One heavy run of yours at a time. Don't start the next while one is waiting for a slot.

## Reading results
- Final lines: `ALL GREEN` (test.sh), `UI tests: P passed, F failed, S skipped, K flaky…, Q quarantined…` (uitest.sh),
  `FAST CHECK OK` / `FAST CHECK FAILED` (check_fast), `CLEAN CHECKOUT OK` / `FAILED` (check_clean).
- Logs: `build/test.log` (unit; failures marked `✘`), `build/test-retry.log`, `build/check_fast-unit.log`,
  `build/check_fast-ui.log`, `build/check_fast-selection.txt` (why each UI script ran), `build/uitest/<script>/`
  (`report.json`, `failure.json`, `failure.png`, snapshots, `*.diff.png`; first attempt in `<script>.attempt1/`).
  check_clean copies failures to `build/check_clean-{build,test,test-retry,ui}.log` and `build/check_clean-uitest/`.
- Parse with `/usr/bin/grep -E '✘|failed:|error:' build/test.log` or the Read tool (rtk-rewritten `grep`/`tail` may summarise).
- Open failure PNGs / diff PNGs with Read and LOOK before deciding anything.

## Flaky, failed, quarantined, skipped
- Every failed unit test / UI script is retried once, alone (UI retry first waits ≤ 60 s for the load to drop).
- `⚠ flaky (passed on retry)` / `flaky (passed on retry):` = not gating, but a bug report: if it is in your area, fix
  the wait (see the write-ui-script skill); otherwise name it in your report.
- `✘ failed twice` / `failed:` = gating. If it is in code you touched, it is yours. If clearly unrelated (other area,
  also fails on main), say so with evidence (script, error line, `/usr/bin/git log main` of that area); don't quarantine it.
- `quarantined (failed, not gating)` = listed in `app/Tests/quarantine.txt` (`<unit|ui> <id> <date> <reason>`, validated
  by `python3 scripts/testlib.py check-quarantine`). Never add your own new failure there. Remove an entry when you fix it.
- The quarantine is EMPTY (DX-C fixed the 8 former "load flakes" and emptied it; audio_online was a real bug). Keep it empty.
  Instead of quarantining: reproduce with `--no-retry` (optionally under load), read failure.json / the PNGs, fix the
  wait (state-based `waitFor`, see write-ui-script) or the app; if it is not your area, report script + error line +
  evidence to the orchestrator, who files it. A test is never quarantined to make a gate green.
- `⚠ slow expect` / `⚠ click warning` (uitest.sh, per script and counted in the `UI tests:` line) are not gating but
  are quality signals (late UI reaction; a click that missed or whose target was rebuilt): mention them in your report.
- `skipped` (UI exit code 3) = unmet `requires` (AI model / content pack / minOS). Not a failure.

## Waiting, hangs, disk
- `waiting for test slot… (held by PIDs …)` = machine-wide semaphore (/tmp/montage-locks, 2+ slots, FIFO queue). Normal under load;
  keep waiting (the notification comes when your run finishes). `scripts/slots.sh status` shows holders, age, idle time.
  Dead holders and holders idle (< 2 CPU-s) for 20 min are reclaimed automatically; `scripts/slots.sh reclaim` forces a sweep.
- `HUNG` (test.sh / build: no output and ~0 % CPU for 10 min) or `TIMEOUT (HUNG) after 120s` (one UI script): stacks are
  in the log / `build/uitest/<script>/hang-sample.txt`. Read them: a hang at 0 % CPU in AVFoundation reads inside async
  tests is the cooperative-pool deadlock (montage-gotchas). A UI script TIMEOUT is usually a `waitFor` that never
  becomes true or a modal loop ("event queue did not drain").
- Your own run stuck (e.g. you started the wrong thing): `scripts/kill_tests.sh --dry-run`, then `scripts/kill_tests.sh`
  (only Montage test processes of your checkout). Never `kill`/`pkill` other PIDs.
- `DISK FULL` (< 5 GB): `scripts/cleanup.sh --dry-run`, then `scripts/cleanup.sh`.
- No test summary / crash: `build/test.log` tail shows `◇ Test … started` for the last test; rerun that suite alone.
