#!/bin/bash
# Orchestrator: merge a gated branch — a batch branch (several feature branches integrated, docs/AGENT_GUIDE.md) or one agent branch.
#   1. checks the branch passed the full gate: a check_clean.ok stamp (written by scripts/check_clean.sh --ui on success,
#      in <its worktree>/build/, or the file given with --stamp) names the branch head, mode "ui"
#   2. fast-forwards main (in the main checkout) to the branch — never a merge commit, never a reset
#   3. scripts/build_app.sh in the main checkout (build/Montage.app)
#   4. removes that worktree's .build (≈ 0.85 GB; the worktree and branch are kept)
# Usage: scripts/merge_agent.sh <branch> [--check-only] [--stamp <file>] [--docs-delta-ok] [--skip-gate-check] [--no-build-app] [--keep-build]
#   --check-only     only verify the gate (exit 0 = mergeable as far as the gate goes), merge nothing
#   --stamp <file>   read this check_clean.ok instead of <branch worktree>/build/check_clean.ok (the hash must still match)
#   --docs-delta-ok  also accept a stamp for an earlier commit whose tree is identical to the head everywhere except
#                    under docs/ (a rebase over docs-only commits, e.g. STATUS / FEATURES updates). Tests depend on
#                    docs/ only through its existence (TestMedia.repoRoot looks for it); none reads its content
set -euo pipefail
BR=""; GATE=1; APP=1; KEEP=0; CHECK_ONLY=0; STAMP_ARG=""; DOCS_OK=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-gate-check) GATE=0; shift;;
    --no-build-app) APP=0; shift;;
    --keep-build) KEEP=1; shift;;
    --check-only) CHECK_ONLY=1; shift;;
    --stamp) STAMP_ARG="$2"; shift 2;;
    --docs-delta-ok) DOCS_OK=1; shift;;
    -h|--help) sed -n '2,13p' "$0"; exit 0;;
    -*) echo "unknown arg $1"; exit 2;;
    *) BR="$1"; shift;;
  esac
done
[[ -n "$BR" ]] || { sed -n '2,13p' "$0"; exit 2; }
cd "$(dirname "$0")/.."
MAIN="$(cd "$(git rev-parse --git-common-dir)/.." && pwd -P)"
HEAD_HASH="$(git -C "$MAIN" rev-parse --verify --quiet "refs/heads/$BR")" || { echo "✘ no branch $BR"; exit 1; }
WT="$(git -C "$MAIN" worktree list --porcelain | awk -v b="refs/heads/$BR" '/^worktree /{w=substr($0,10)} $0 == "branch " b {print w}')"
echo "▶ $BR @ $(git -C "$MAIN" rev-parse --short "$HEAD_HASH")${WT:+ (worktree $WT)}"

if [[ $GATE == 1 ]]; then
  STAMP="${STAMP_ARG:-${WT:+$WT/build/check_clean.ok}}"
  if [[ -z "$STAMP" || ! -f "$STAMP" ]]; then
    echo "✘ no passing gate for $BR (no ${STAMP:-worktree build/check_clean.ok}): run scripts/check_clean.sh --ui in its worktree (or --skip-gate-check)"; exit 1
  fi
  read -r S_HASH S_DATE S_MODE < "$STAMP"
  if [[ "$S_MODE" != ui ]]; then
    echo "✘ the last passing gate ($S_DATE) was mode $S_MODE, not --ui: re-run scripts/check_clean.sh --ui${WT:+ in $WT}"; exit 1
  fi
  if [[ "$S_HASH" == "$HEAD_HASH" ]]; then
    echo "✔ gate: check_clean --ui passed for this commit ($S_DATE)"
  elif [[ $DOCS_OK == 1 ]] && git -C "$MAIN" cat-file -e "$S_HASH^{commit}" 2>/dev/null \
       && git -C "$MAIN" diff --quiet "$S_HASH" "$HEAD_HASH" -- . ':(exclude)docs'; then
    echo "✔ gate: check_clean --ui passed for $(git -C "$MAIN" rev-parse --short "$S_HASH") ($S_DATE); the head differs from it only under docs/:"
    git -C "$MAIN" diff --stat "$S_HASH" "$HEAD_HASH" | tail -1 | sed 's/^/    /'
  else
    echo "✘ the last passing gate ($S_MODE, $S_DATE) was for $(git -C "$MAIN" rev-parse --short "$S_HASH" 2>/dev/null || echo "$S_HASH"), not $BR @ $(git -C "$MAIN" rev-parse --short "$HEAD_HASH")"
    if git -C "$MAIN" cat-file -e "$S_HASH^{commit}" 2>/dev/null; then
      N="$(git -C "$MAIN" diff --name-only "$S_HASH" "$HEAD_HASH" -- . ':(exclude)docs' | wc -l | tr -d ' ')"
      if [[ $N == 0 ]]; then echo "  only docs/ changed since: pass --docs-delta-ok"
      else echo "  $N file(s) outside docs/ changed since the gated commit"; fi
    fi
    echo "  re-run scripts/check_clean.sh --ui${WT:+ in $WT} (or pass --skip-gate-check)"; exit 1
  fi
fi

[[ "$(git -C "$MAIN" symbolic-ref --short -q HEAD)" == main ]] || { echo "✘ the main checkout ($MAIN) is not on main"; exit 1; }
if ! git -C "$MAIN" merge-base --is-ancestor main "$HEAD_HASH"; then
  echo "✘ $BR does not contain main @ $(git -C "$MAIN" rev-parse --short main): no fast-forward possible (rebase it on main and re-gate)"; exit 1
fi
if [[ $CHECK_ONLY == 1 ]]; then echo "CHECK OK $BR (fast-forward possible; nothing merged)"; exit 0; fi
BEFORE="$(git -C "$MAIN" rev-parse --short main)"
if ! git -C "$MAIN" merge --ff-only "$HEAD_HASH"; then   # the gated commit, even if the branch moved meanwhile
  echo "✘ fast-forward failed: main moved (rebase $BR on main and re-run the gate) or local changes in $MAIN block it"; exit 1
fi
echo "✔ main $BEFORE → $(git -C "$MAIN" rev-parse --short main)"

if [[ $APP == 1 ]]; then
  LOG="$MAIN/build/merge_agent-build_app.log"; mkdir -p "$MAIN/build"
  if (cd "$MAIN" && scripts/build_app.sh) > "$LOG" 2>&1; then echo "✔ $(tail -1 "$LOG") built"
  else echo "✘ build_app.sh failed (see $LOG)"; tail -5 "$LOG"; exit 1; fi
fi

if [[ $KEEP == 0 && -n "$WT" && "$(cd "$WT" && pwd -P)" != "$MAIN" && -d "$WT/.build" ]]; then
  SZ="$(du -sh "$WT/.build" 2>/dev/null | awk '{print $1}')"
  rm -rf "$WT/.build"
  echo "✔ removed $WT/.build ($SZ)"
fi
echo "MERGED $BR"
