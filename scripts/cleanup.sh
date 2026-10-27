#!/bin/bash
# Frees disk space left behind by agents and test runs (safe to run any time, from any checkout).
#   1. `git worktree prune`; clean-check worktrees ($TMPDIR/valse-clean.*) older than --hours are removed
#   2. .build of every worktree whose branch is already merged into main, unless the worktree is in use: a process
#      has its cwd inside it, or its .build was written in the last --hours (the main checkout is never touched)
#   3. $TMPDIR/valse-* leftovers older than --hours (the shared synthetic-media cache valse-test-media-v1 is kept),
#      and the montage-* ones of checkouts from before the Montage → Valse rename
#   4. dead / hung test-slot locks (scripts/slots.sh reclaim)
#   --merged-worktrees: step 2 instead removes the .build of every worktree whose HEAD commit (branch or detached) is
#      an ancestor of main or of a batch-* branch (its work is integrated), whose `git status` is clean (untracked files
#      ignored: scratch) and that no process uses (cwd or open file inside it), however recently it was built.
#      Orchestrator duty after each batch merge and whenever free disk < 10 GB (orchestrate-features skill).
# Usage: scripts/cleanup.sh [--dry-run] [--hours 3] [--merged-worktrees]
set -euo pipefail
cd "$(dirname "$0")/.."
DRY=0; HOURS=3; MERGED_WT=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run|-n) DRY=1; shift;;
    --hours) HOURS="$2"; shift 2;;
    --merged-worktrees) MERGED_WT=1; shift;;
    -h|--help) sed -n '2,14p' "$0"; exit 0;;
    *) echo "unknown arg $1"; exit 2;;
  esac
done
MAIN="$(cd "$(git rev-parse --git-common-dir)/.." && pwd -P)"
TMPD="${VALSE_REAL_TMPDIR:-${TMPDIR:-/tmp}}"; TMPD="$(cd "$TMPD" && pwd -P)"
MINS=$(( HOURS * 60 ))
FREED=0
SCRATCH_LIST="$(mktemp -t valse-cleanup-list)"
trap 'rm -f "$SCRATCH_LIST" "$SCRATCH_LIST.f"' EXIT
say() { if [[ $DRY == 1 ]]; then echo "would remove: $*"; else echo "removed: $*"; fi; }
kb() { du -sk "$1" 2>/dev/null | awk '{print $1}'; }
human() { awk -v k="$1" 'BEGIN { if (k > 1048576) printf "%.1f GB", k / 1048576; else printf "%.0f MB", k / 1024 }'; }
zap() { # path label
  local k; k="$(kb "$1")"; k="${k:-0}"
  say "$2 ($(human "$k"))"
  FREED=$(( FREED + k ))
  [[ $DRY == 1 ]] || rm -rf "$1"
}
# cwd of every process we can see: a directory containing one is in use
CWDS="$(lsof -a -d cwd -Fn 2>/dev/null | sed -n 's/^n//p' | sort -u)"
in_use() {
  local d c; d="$(cd "$1" 2>/dev/null && pwd -P)" || return 1
  while IFS= read -r c; do [[ "$c" == "$d" || "$c" == "$d"/* ]] && return 0; done <<< "$CWDS"
  return 1
}

INTEGRATION=""; OPEN=""
if [[ $MERGED_WT == 1 ]]; then
  # integration branches: main + every local batch-*
  INTEGRATION="main $(git -C "$MAIN" for-each-ref --format='%(refname:short)' 'refs/heads/batch-*' | tr '\n' ' ')"
  # every file any process has open (an editor indexer, a running build inside .build/…)
  OPEN="$(lsof -Fn 2>/dev/null | sed -n 's/^n\(\/.*\)/\1/p' | sort -u)"
fi
opened_in() { # dir → 0 if a process has a file open inside it
  local d; d="$(cd "$1" 2>/dev/null && pwd -P)" || return 1
  awk -v p="$d/" 'index($0, p) == 1 { f = 1; exit } END { exit !f }' <<< "$OPEN"
}

echo "▶ worktrees (main checkout: $MAIN$([[ $MERGED_WT == 1 ]] && echo "; --merged-worktrees: HEAD in $INTEGRATION"))"
[[ $DRY == 1 ]] || git -C "$MAIN" worktree prune
WTLIST="$(git -C "$MAIN" worktree list --porcelain | awk '/^worktree /{w=substr($0,10)} /^branch /{b=substr($0,8)} /^detached/{b="(detached)"} /^$/{print w "\t" b; w=""; b=""} END{if (w != "") print w "\t" b}')"
while IFS=$'\t' read -r WT BR; do
  [[ -z "$WT" ]] && continue
  WTP="$(cd "$WT" 2>/dev/null && pwd -P || echo "$WT")"
  [[ "$WTP" == "$MAIN" ]] && continue
  if [[ "$WTP" == "$TMPD"/valse-clean.* || "$WTP" == "$TMPD"/valse-run-* \
        || "$WTP" == "$TMPD"/montage-clean.* || "$WTP" == "$TMPD"/montage-run-* ]]; then   # pre-rename names
    if [[ -n "$(find "$WTP" -maxdepth 0 -mmin +"$MINS" 2>/dev/null)" ]] && ! in_use "$WTP"; then
      say "stale clean-check worktree $WTP"
      [[ $DRY == 1 ]] || { git -C "$MAIN" worktree remove --force "$WTP" 2>/dev/null || rm -rf "$WTP"; }
    fi
    continue
  fi
  [[ -d "$WTP/.build" ]] || continue
  [[ "$WTP" == "$MAIN/build/check_clean-cache/"* ]] && continue   # check_clean.sh's warm gate worktrees: never
  B="${BR#refs/heads/}"
  if [[ $MERGED_WT == 1 ]]; then
    H="$(git -C "$WTP" rev-parse HEAD 2>/dev/null || true)"
    INTO=""
    for R in $INTEGRATION; do
      if [[ -n "$H" ]] && git -C "$MAIN" merge-base --is-ancestor "$H" "$R" 2>/dev/null; then INTO="$R"; break; fi
    done
    if [[ -z "$INTO" ]]; then echo "  keep $WTP/.build ($B @ ${H:0:7}: not in main / batch-*)"; continue; fi
    if [[ "$B" == "$INTO" && "$INTO" != main ]]; then echo "  keep $WTP/.build (the $B worktree itself)"; continue; fi
    # HEAD = an integration tip: maybe a worktree just made from it (a new agent before its first commit)
    if [[ "$H" == "$(git -C "$MAIN" rev-parse "$INTO")" && -n "$(find "$WTP/.build" -maxdepth 3 -mmin -"$MINS" -print -quit 2>/dev/null)" ]]; then
      echo "  keep $WTP/.build ($B = the tip of $INTO and built in the last $HOURS h: a fresh worktree?)"; continue
    fi
    if [[ -n "$(git -C "$WTP" status --porcelain --untracked-files=no 2>/dev/null || echo "?")" ]]; then
      echo "  keep $WTP/.build ($B in $INTO, but uncommitted changes)"; continue
    fi
    if in_use "$WTP" || opened_in "$WTP"; then echo "  keep $WTP/.build ($B in $INTO, but a process uses it)"; continue; fi
    zap "$WTP/.build" "$WTP/.build ($B @ ${H:0:7} is in $INTO)"
    continue
  fi
  if [[ "$BR" == "(detached)" ]] || ! git -C "$MAIN" merge-base --is-ancestor "$B" main 2>/dev/null; then
    echo "  keep $WTP/.build ($B: not merged into main)"; continue
  fi
  if in_use "$WTP"; then echo "  keep $WTP/.build ($B merged, but a process runs inside it)"; continue; fi
  if [[ -n "$(find "$WTP/.build" -maxdepth 3 -mmin -"$MINS" -print -quit 2>/dev/null)" ]]; then
    echo "  keep $WTP/.build ($B merged, but built in the last $HOURS h)"; continue
  fi
  zap "$WTP/.build" "$WTP/.build ($B merged into main)"
done <<< "$WTLIST"

echo "▶ \$TMPDIR/valse-* older than $HOURS h ($TMPD)"
# processes running inside $TMPDIR (a live UI test / clean check): their top-level entry is kept
BUSY="$(while IFS= read -r c; do if [[ "$c" == "$TMPD"/* ]]; then echo "$TMPD/$(cut -d/ -f1 <<< "${c#"$TMPD"/}")"; fi; done <<< "$CWDS" | sort -u)"
LIST="$SCRATCH_LIST"
find "$TMPD" -maxdepth 1 \( -name 'valse-*' -o -name 'montage-*' \) ! -name '*-test-media-v1' -mmin +"$MINS" 2>/dev/null | sort > "$LIST"
if [[ -n "$BUSY" ]]; then grep -vxF "$BUSY" "$LIST" > "$LIST.f" || true; mv "$LIST.f" "$LIST"; fi
N="$(wc -l < "$LIST" | tr -d ' ')"
if [[ $DRY == 1 ]]; then
  K="$( (tr '\n' '\0' < "$LIST" | xargs -0 du -sk 2>/dev/null || true) | awk '{ t += $1 } END { printf "%d", t }')"
  echo "  would remove $N entries ($(human "$K"))"
else
  B="$(df -k "$TMPD" | awk 'NR == 2 { print $4 }')"
  tr '\n' '\0' < "$LIST" | xargs -0 rm -rf 2>/dev/null || true
  K=$(( $(df -k "$TMPD" | awk 'NR == 2 { print $4 }') - B )); (( K < 0 )) && K=0
  echo "  removed $N entries ($(human "$K"))"
fi
FREED=$(( FREED + K ))
[[ $DRY == 1 ]] || git -C "$MAIN" worktree prune   # clean-check worktrees whose temp dir was just removed
CACHE="$TMPD/valse-test-media-v1"
[[ -d "$CACHE" ]] && echo "  kept the synthetic test-media cache $CACHE ($(human "$(kb "$CACHE")"); delete it by hand if needed, it regenerates)"

echo "▶ test slots"
[[ $DRY == 1 ]] && scripts/slots.sh status || scripts/slots.sh reclaim
echo "$([[ $DRY == 1 ]] && echo "would free" || echo "freed") $(human "$FREED") in total; free now: $(df -h "$MAIN" | awk 'NR == 2 {print $4}')"
