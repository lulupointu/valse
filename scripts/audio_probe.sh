#!/bin/bash
# BUG-CUT-AUDIO-HOLE part 5: build the standalone audio timing probe (scripts/audio_probe/AudioTimingProbe.swift) for
# macOS 13 and run it on this Mac and/or in the macOS 13 Tart VM. Opt-in investigation tool: no test or gate uses it.
#
#   scripts/audio_probe.sh [--host] [--vm] [--x86] [--logs] -- <probe command and options>
#     --host   run on this Mac (default when neither --host nor --vm is given)
#     --vm     run in the Tart VM `ventura13` (started headless if stopped: --no-graphics, never on screen; stopped
#              again afterwards unless --keep-vm). ssh admin@<ip> with your key (first time: docs/TESTING.md
#              "macOS 13 VM for engine probes").
#     --x86    build x86_64 too (universal binary; on the host it runs under Rosetta with `arch -x86_64`)
#     --logs   also print the unified-log lines of the probe process (AudioQueue / time-stretcher / AQME) for the run
#     --app    instead of the probe: build the release app (build_app.sh --host-only --no-content, or --x86 for
#              universal) and run `Valse --preview-audio-check` (PreviewAudio, the real ValseEngine code: the scenarios
#              of PreviewAudioTests, then PlaybackEngineAudioTests' end-to-end ones through PlaybackEngine, with their
#              thresholds); no command needed. Log: build/audio_probe/<host|vm>-app.log
#   Output: build/audio_probe/<host|vm>-<command>.log (also printed). Examples:
#     scripts/audio_probe.sh --vm -- matrix
#     scripts/audio_probe.sh --host --vm -- player --algo spectral --rate 1 --speed 1
#     scripts/audio_probe.sh --vm -- replacement
#     scripts/audio_probe.sh --host --vm --app
set -euo pipefail
cd "$(dirname "$0")/.."
HOST=0; VM=0; X86=0; LOGS=0; KEEP=0; APP=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --host) HOST=1 ;;
    --vm) VM=1 ;;
    --app) APP=1 ;;
    --x86) X86=1 ;;
    --logs) LOGS=1 ;;
    --keep-vm) KEEP=1 ;;
    --) shift; break ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    *) break ;;
  esac
  shift
done
[[ $HOST == 0 && $VM == 0 ]] && HOST=1

# start the VM headless if needed; sets SSH / IP / STARTED
vm_up() {
  TART=~/bin/tart; VMNAME=ventura13
  STARTED=0
  if ! $TART list | grep -q "$VMNAME.*running"; then
    $TART run "$VMNAME" --no-graphics >/dev/null 2>&1 &
    STARTED=1
  fi
  IP=$($TART ip "$VMNAME" --wait 120)
  SSH=(ssh -o BatchMode=yes -o StrictHostKeyChecking=no "admin@$IP")
  for _ in $(seq 60); do "${SSH[@]}" true 2>/dev/null && break; sleep 2; done
}
vm_down() { if [[ $STARTED == 1 && $KEEP == 0 ]]; then $TART stop "$VMNAME" >/dev/null 2>&1 || true; fi; }

if [[ $APP == 1 ]]; then
  OUT=build/audio_probe
  mkdir -p "$OUT/pa-media"
  if [[ $X86 == 1 ]]; then scripts/build_app.sh --no-content >&2; else scripts/build_app.sh --host-only --no-content >&2; fi
  if [[ $HOST == 1 ]]; then
    RUN=(build/Valse.app/Contents/MacOS/Valse); [[ $X86 == 1 ]] && RUN=(arch -x86_64 "${RUN[@]}")
    VALSE_MUTE_AUDIO=1 "${RUN[@]}" --preview-audio-check "$PWD/$OUT/pa-media" | tee "$OUT/host-app.log"
  fi
  if [[ $VM == 1 ]]; then
    vm_up
    tar -C build -czf "$OUT/Valse-app.tgz" Valse.app
    "${SSH[@]}" 'rm -rf ~/probe/app && mkdir -p ~/probe/app ~/probe/pa-media'
    scp -q -o BatchMode=yes "$OUT/Valse-app.tgz" "admin@$IP:probe/app/Valse-app.tgz"
    "${SSH[@]}" 'cd ~/probe/app && tar -xzf Valse-app.tgz'
    ARCH=""; [[ $X86 == 1 ]] && ARCH="arch -x86_64 "
    "${SSH[@]}" "VALSE_MUTE_AUDIO=1 ${ARCH}~/probe/app/Valse.app/Contents/MacOS/Valse --preview-audio-check ~/probe/pa-media" | tee "$OUT/vm-app.log"
    vm_down
  fi
  exit 0
fi
[[ $# -gt 0 ]] || { echo "usage: $0 [--host] [--vm] [--x86] [--logs] -- <command> [options]"; exit 2; }
CMD="$1"
OUT=build/audio_probe
mkdir -p "$OUT/media"
SRC=scripts/audio_probe/AudioTimingProbe.swift
BIN="$OUT/AudioTimingProbe"
if [[ ! -x "$BIN" || "$SRC" -nt "$BIN" || $X86 == 1 ]]; then
  xcrun swiftc -swift-version 5 -O -target arm64-apple-macos13.0 "$SRC" -o "$BIN.arm64"
  if [[ $X86 == 1 ]]; then
    xcrun swiftc -swift-version 5 -O -target x86_64-apple-macos13.0 "$SRC" -o "$BIN.x86_64"
    lipo -create "$BIN.arm64" "$BIN.x86_64" -output "$BIN"
  else
    cp "$BIN.arm64" "$BIN"
  fi
fi

if [[ $HOST == 1 ]]; then
  START=$(date +"%Y-%m-%d %H:%M:%S")
  RUN=("$BIN"); [[ $X86 == 1 ]] && RUN=(arch -x86_64 "$BIN")
  "${RUN[@]}" "$@" --dir "$PWD/$OUT/media" | tee "$OUT/host-$CMD.log"
  if [[ $LOGS == 1 ]]; then
    log show --start "$START" --info --debug --style compact --predicate 'process == "AudioTimingProbe"' \
      | grep -Ei 'stretch|timepitch|time-pitch|tido|spec|nutp|ipto|latency|AQME|AudioQueue|AQ ' | tee -a "$OUT/host-$CMD.log" || true
  fi
fi

if [[ $VM == 1 ]]; then
  TART=~/bin/tart; VMNAME=ventura13
  STARTED=0
  if ! $TART list | grep -q "$VMNAME.*running"; then
    $TART run "$VMNAME" --no-graphics >/dev/null 2>&1 &
    STARTED=1
  fi
  IP=$($TART ip "$VMNAME" --wait 120)
  SSH=(ssh -o BatchMode=yes -o StrictHostKeyChecking=no "admin@$IP")
  for _ in $(seq 60); do "${SSH[@]}" true 2>/dev/null && break; sleep 2; done
  "${SSH[@]}" 'mkdir -p ~/probe/media'
  scp -q -o BatchMode=yes "$BIN" "admin@$IP:probe/AudioTimingProbe"
  START=$("${SSH[@]}" 'date +"%Y-%m-%d %H:%M:%S"')
  "${SSH[@]}" "~/probe/AudioTimingProbe $* --dir ~/probe/media" | tee "$OUT/vm-$CMD.log"
  if [[ $LOGS == 1 ]]; then
    "${SSH[@]}" "log show --start '$START' --info --debug --style compact --predicate 'process == \"AudioTimingProbe\"'" \
      | grep -Ei 'stretch|timepitch|time-pitch|tido|spec|nutp|ipto|latency|AQME|AudioQueue|AQ ' | tee -a "$OUT/vm-$CMD.log" || true
  fi
  if [[ $STARTED == 1 && $KEEP == 0 ]]; then $TART stop "$VMNAME" >/dev/null 2>&1 || true; fi
fi
