#!/bin/bash
# Machine-wide semaphore for heavy runs (swift build/test, UI scripts, perf), shared by every checkout / worktree.
# Source it, then call `slots_acquire` (one of the slots) or `slots_acquire_all` (exclusive: every slot —
# scripts/perf.sh, so timings are not disturbed by other teams). Released on exit (`slots_release`; the EXIT hook is
# chained through scripts/lib.sh `on_exit`, so callers may add their own hooks). Nested scripts (check_clean → test.sh)
# reuse the parent's slot (MONTAGE_SLOT_HELD).
#
# Locks are mkdir directories under /tmp/montage-locks (MONTAGE_LOCK_DIR) holding the owner's PID, its start time,
# command and directory. A lock is RECLAIMED (and the reclaim printed) when its holder
#   - is dead (or its PID was reused by another process), or
#   - has been idle for MONTAGE_SLOT_IDLE_MIN minutes (default 20): its whole process tree used < 2 CPU-seconds in
#     that time (a hung run). The idle holder's process tree is killed so it cannot resume later.
# Slot count: MONTAGE_SLOTS, default max(2, cores / 5). Slot 0 is always offered; the others only while the 1-min load
# average is below MONTAGE_SLOT_MAX_LOAD (default 3 × cores), so an overloaded machine runs fewer gates at once.
# MONTAGE_NO_SLOTS=1 skips locking entirely.
#
# Run directly:  scripts/slots.sh status    holders, age, CPU, idle time
#                scripts/slots.sh reclaim   reclaim dead / idle slots now
SLOTS_DIR="${MONTAGE_LOCK_DIR:-/tmp/montage-locks}"
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
_SLOTS_CORES="$(sysctl -n hw.ncpu 2>/dev/null || echo 8)"
SLOTS_N="${MONTAGE_SLOTS:-$(( _SLOTS_CORES / 5 > 2 ? _SLOTS_CORES / 5 : 2 ))}"
SLOTS_IDLE_SECS=$(( ${MONTAGE_SLOT_IDLE_MIN:-20} * 60 ))
[[ -n "${MONTAGE_SLOT_IDLE_SECS:-}" ]] && SLOTS_IDLE_SECS="$MONTAGE_SLOT_IDLE_SECS"   # tests of the reclaim itself
SLOTS_MAX_LOAD="${MONTAGE_SLOT_MAX_LOAD:-$(( _SLOTS_CORES * 3 ))}"
SLOTS_HELD=()
_SLOTS_CMD="$0${*:+ $*}"   # the sourcing script and its arguments (positional parameters are inherited by `source`)

_slot_lstart() { ps -o lstart= -p "$1" 2>/dev/null | tr -s ' '; }

_slot_write() { # dir: fill in the owner record (we just created the dir)
  local d="$1"
  echo "$$" > "$d/pid.tmp"
  _slot_lstart $$ > "$d/start"
  echo "$_SLOTS_CMD" > "$d/cmd"
  pwd > "$d/cwd"
  echo "$(date +%s) $(tree_cpu $$)" > "$d/activity"
  mv "$d/pid.tmp" "$d/pid"
}

# _slot_check <dir> → 0 if the lock was reclaimed (removed); prints why. Also refreshes its activity record.
_slot_check() {
  local d="$1" pid now
  [[ -d "$d" ]] || return 0
  pid="$(cat "$d/pid" 2>/dev/null || true)"
  now=$(date +%s)
  if [[ -z "$pid" ]]; then
    # being created right now, or the creator died before writing its PID: reclaim if older than 30 s
    local m; m="$(stat -f %m "$d" 2>/dev/null || echo "$now")"
    if (( now - m > 30 )); then rm -rf "$d"; echo "slots: reclaimed $(basename "$d") (no owner PID for $(( now - m )) s)" >&2; return 0; fi
    return 1
  fi
  local what; what="$(cat "$d/cmd" 2>/dev/null || echo '?') in $(cat "$d/cwd" 2>/dev/null || echo '?')"
  if ! kill -0 "$pid" 2>/dev/null; then
    rm -rf "$d"; echo "slots: reclaimed $(basename "$d") from dead PID $pid ($what)" >&2; return 0
  fi
  if [[ -f "$d/start" && "$(cat "$d/start")" != "$(_slot_lstart "$pid")" ]]; then
    rm -rf "$d"; echo "slots: reclaimed $(basename "$d") from PID $pid (PID reused by another process; was $what)" >&2; return 0
  fi
  # a holder that is itself waiting for more slots (slots_acquire_all) touches its heartbeat: not idle
  if [[ -f "$d/heartbeat" ]] && (( now - $(stat -f %m "$d/heartbeat" 2>/dev/null || echo 0) < 60 )); then return 1; fi
  local cpu since base
  cpu="$(tree_cpu "$pid")"
  { read -r since base < "$d/activity"; } 2>/dev/null || { since=$now; base=$cpu; echo "$now $cpu" > "$d/activity" 2>/dev/null; }
  if (( cpu - base > 2 || base - cpu > 2 )); then
    echo "$now $cpu" > "$d/activity" 2>/dev/null || true; return 1
  fi
  if (( now - since >= SLOTS_IDLE_SECS )); then
    local mins=$(( (now - since) / 60 ))
    kill_tree "$pid" >/dev/null 2>&1 || true
    rm -rf "$d"
    echo "slots: reclaimed $(basename "$d") from PID $pid — idle (~0 % CPU incl. children) for ${mins} min, process tree killed ($what)" >&2
    return 0
  fi
  return 1
}

_slot_try() { # dir → 0 if acquired
  local d="$1"
  if mkdir "$d" 2>/dev/null; then _slot_write "$d"; SLOTS_HELD+=("$d"); return 0; fi
  if _slot_check "$d" && mkdir "$d" 2>/dev/null; then _slot_write "$d"; SLOTS_HELD+=("$d"); return 0; fi
  return 1
}

slots_sweep() { # check every lock (refreshes idle tracking; reclaims dead / idle holders)
  local d
  for d in "$SLOTS_DIR"/slot.* "$SLOTS_DIR"/exclusive; do [[ -d "$d" ]] && _slot_check "$d"; done
  return 0
}

_slots_wait_msg() {
  local holders; holders="$(cat "$SLOTS_DIR"/*/pid 2>/dev/null | tr '\n' ' ')"
  echo "waiting for test slot… (held by PIDs: ${holders:-?}; scripts/slots.sh status for details)" >&2
}

_slots_load_ok() { # 0 when the 1-min load average is below SLOTS_MAX_LOAD
  local l; l="$(sysctl -n vm.loadavg 2>/dev/null | awk '{ printf "%d", $2 }')"
  (( ${l:-0} < SLOTS_MAX_LOAD ))
}

slots_acquire() {
  [[ "${MONTAGE_NO_SLOTS:-0}" == 1 || -n "${MONTAGE_SLOT_HELD:-}" ]] && return 0
  mkdir -p "$SLOTS_DIR"
  local waited=0 i
  on_exit slots_release
  while true; do
    slots_sweep
    # an exclusive run (perf) is waiting or running: don't take new slots
    if [[ ! -d "$SLOTS_DIR/exclusive" ]]; then
      for ((i = 0; i < SLOTS_N; i++)); do
        (( i > 0 )) && ! _slots_load_ok && break
        if _slot_try "$SLOTS_DIR/slot.$i"; then export MONTAGE_SLOT_HELD=1; return 0; fi
      done
    fi
    (( waited % 30 == 0 )) && _slots_wait_msg
    sleep 2; waited=$((waited + 2))
  done
}

slots_acquire_all() {
  [[ "${MONTAGE_NO_SLOTS:-0}" == 1 || -n "${MONTAGE_SLOT_HELD:-}" ]] && return 0
  mkdir -p "$SLOTS_DIR"
  local waited=0 i
  on_exit slots_release
  until _slot_try "$SLOTS_DIR/exclusive"; do
    (( waited % 30 == 0 )) && _slots_wait_msg
    sleep 2; waited=$((waited + 2))
  done
  for ((i = 0; i < SLOTS_N; i++)); do
    until _slot_try "$SLOTS_DIR/slot.$i"; do
      touch "$SLOTS_DIR/exclusive/heartbeat" 2>/dev/null || true
      (( waited % 30 == 0 )) && _slots_wait_msg
      sleep 2; waited=$((waited + 2))
    done
  done
  rm -f "$SLOTS_DIR/exclusive/heartbeat"
  export MONTAGE_SLOT_HELD=1
}

slots_release() {
  local d
  for d in ${SLOTS_HELD[@]+"${SLOTS_HELD[@]}"}; do
    [[ "$(cat "$d/pid" 2>/dev/null)" == "$$" ]] && rm -rf "$d"
  done
  SLOTS_HELD=()
}

slots_status() {
  local d pid now; now=$(date +%s)
  echo "slots: $SLOTS_N (cores $_SLOTS_CORES, extra slots only while load < $SLOTS_MAX_LOAD; load now $(sysctl -n vm.loadavg | awk '{print $2}')), idle reclaim after $(( SLOTS_IDLE_SECS / 60 )) min — $SLOTS_DIR"
  for d in "$SLOTS_DIR"/slot.* "$SLOTS_DIR"/exclusive; do
    [[ -d "$d" ]] || continue
    pid="$(cat "$d/pid" 2>/dev/null || echo '?')"
    local since base; { read -r since base < "$d/activity"; } 2>/dev/null || { since=$now; base=0; }
    kill -0 "$pid" 2>/dev/null || pid="$pid(dead)"
    printf "  %-10s PID %-6s held %4d min, idle %3d min, cpu %5ss  %s  (%s)\n" "$(basename "$d")" "$pid" \
      $(( (now - $(stat -f %m "$d/pid" 2>/dev/null || stat -f %m "$d")) / 60 )) $(( (now - since) / 60 )) "$(tree_cpu "$pid" 2>/dev/null)" \
      "$(cat "$d/cmd" 2>/dev/null)" "$(cat "$d/cwd" 2>/dev/null)"
  done
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  set -uo pipefail
  mkdir -p "$SLOTS_DIR"
  case "${1:-status}" in
    status) slots_status;;
    reclaim) slots_sweep; slots_status;;
    *) sed -n '2,20p' "$0"; exit 2;;
  esac
fi
