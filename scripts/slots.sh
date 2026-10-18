# Machine-wide semaphore for heavy runs (swift build/test, UI scripts, perf), shared by every checkout / worktree.
# Source it, then call `slots_acquire` (one of MONTAGE_SLOTS slots, default 2) or `slots_acquire_all` (exclusive:
# every slot — scripts/perf.sh, so timings are not disturbed by other teams). Released on exit (`slots_release`,
# chain it from your own EXIT trap if you set one). Nested scripts (check_clean → test.sh) reuse the parent's slot.
# Locks are mkdir directories under /tmp/montage-locks holding the owner's PID; a lock whose PID is dead is reclaimed.
# MONTAGE_NO_SLOTS=1 skips locking entirely.
SLOTS_DIR="${MONTAGE_LOCK_DIR:-/tmp/montage-locks}"
SLOTS_N="${MONTAGE_SLOTS:-2}"
SLOTS_HELD=()

_slot_try() { # dir → 0 if acquired
  local d="$1"
  if mkdir "$d" 2>/dev/null; then echo $$ > "$d/pid"; SLOTS_HELD+=("$d"); return 0; fi
  local pid; pid="$(cat "$d/pid" 2>/dev/null || true)"
  if [[ -z "$pid" ]]; then
    # being created right now, or the creator died before writing its PID: reclaim if older than 30 s
    local m; m="$(stat -f %m "$d" 2>/dev/null || echo 0)"
    if (( $(date +%s) - m > 30 )); then rm -rf "$d"; fi
    return 1
  fi
  if ! kill -0 "$pid" 2>/dev/null; then rm -rf "$d"; _slot_try "$d"; return $?; fi
  return 1
}

_slots_wait_msg() {
  local holders; holders="$(cat "$SLOTS_DIR"/*/pid 2>/dev/null | tr '\n' ' ')"
  echo "waiting for test slot… (held by PIDs: ${holders:-?}; ${SLOTS_DIR})" >&2
}

slots_acquire() {
  [[ "${MONTAGE_NO_SLOTS:-0}" == 1 || -n "${MONTAGE_SLOT_HELD:-}" ]] && return 0
  mkdir -p "$SLOTS_DIR"
  local waited=0 i
  trap slots_release EXIT
  while true; do
    # an exclusive run (perf) is waiting or running: don't take new slots
    if [[ -d "$SLOTS_DIR/exclusive" ]] && ! _slot_stale "$SLOTS_DIR/exclusive"; then :
    else
      for ((i = 0; i < SLOTS_N; i++)); do
        if _slot_try "$SLOTS_DIR/slot.$i"; then export MONTAGE_SLOT_HELD=1; return 0; fi
      done
    fi
    (( waited % 30 == 0 )) && _slots_wait_msg
    sleep 2; waited=$((waited + 2))
  done
}

_slot_stale() { # dir → 0 if its owner is dead, or it has had no PID for 30 s (and removes it)
  local pid; pid="$(cat "$1/pid" 2>/dev/null || true)"
  if [[ -n "$pid" ]] && ! kill -0 "$pid" 2>/dev/null; then rm -rf "$1"; return 0; fi
  if [[ -z "$pid" ]]; then
    local m; m="$(stat -f %m "$1" 2>/dev/null || echo 0)"
    if (( $(date +%s) - m > 30 )); then rm -rf "$1"; return 0; fi
  fi
  return 1
}

slots_acquire_all() {
  [[ "${MONTAGE_NO_SLOTS:-0}" == 1 || -n "${MONTAGE_SLOT_HELD:-}" ]] && return 0
  mkdir -p "$SLOTS_DIR"
  local waited=0 i
  trap slots_release EXIT
  until _slot_try "$SLOTS_DIR/exclusive"; do
    (( waited % 30 == 0 )) && _slots_wait_msg
    sleep 2; waited=$((waited + 2))
  done
  for ((i = 0; i < SLOTS_N; i++)); do
    until _slot_try "$SLOTS_DIR/slot.$i"; do
      (( waited % 30 == 0 )) && _slots_wait_msg
      sleep 2; waited=$((waited + 2))
    done
  done
  export MONTAGE_SLOT_HELD=1
}

slots_release() {
  local d
  for d in ${SLOTS_HELD[@]+"${SLOTS_HELD[@]}"}; do
    [[ "$(cat "$d/pid" 2>/dev/null)" == "$$" ]] && rm -rf "$d"
  done
  SLOTS_HELD=()
}
