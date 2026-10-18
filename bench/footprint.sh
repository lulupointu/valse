#!/bin/bash
# Supplementary memory metric: phys_footprint (what Activity Monitor's "Memory" column and jetsam use; includes
# IOSurface/GPU allocations, does NOT double-count shared framework pages like summed RSS does).
# For each stack: launch the 4-layer (then 8-layer) preview, wait 12 s, sum `footprint` over the app, its
# descendants and the helper processes spawned for it (VideoToolbox XPC, WebKit XPC). 60 s cooldown between runs.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; P="$ROOT/prototypes"; M="$ROOT/bench/media"
OUT="$ROOT/bench/results/footprint.jsonl"; : > "$OUT"
COOLDOWN="${COOLDOWN:-60}"
HELPERS='^(VTDecoderXPCService|VTEncoderXPCService|com\.apple\.WebKit\..*)$'

measure() { # stack layers prefix -- command...
  local s=$1 L=$2 pre=$3; shift 4
  /bin/ps -axo pid= > /tmp/fp_before.$$
  ( "$@" >/dev/null 2>&1 ) & local sub=$!
  sleep 12
  # family: descendants of the subshell + new helper processes
  local pids; pids=$(/bin/ps -axo pid=,ppid=,comm= | awk -v root=$sub -v re="$HELPERS" -v bf=/tmp/fp_before.$$ '
    BEGIN { while ((getline l < bf) > 0) { gsub(/ /,"",l); before[l]=1 } }
    { pid=$1; pp[pid]=$2; c=$3; for (i=4;i<=NF;i++) c=c" "$i; n=split(c, parts, "/"); name[pid]=parts[n] }
    END { fam[root]=1; grew=1; while (grew) { grew=0; for (p in pp) if (!(p in fam) && (pp[p] in fam)) { fam[p]=1; grew=1 } }
          for (p in name) if (!(p in before) && name[p] ~ re) fam[p]=1;
          for (p in fam) printf "%s ", p }')
  local total=0 detail=""
  for p in $pids; do
    local kb; kb=$(footprint -p "$p" 2>/dev/null | awk '/Footprint:/ { for (i=1;i<=NF;i++) if ($i=="Footprint:") { v=$(i+1); u=$(i+2); if (u=="MB") v*=1024; if (u=="GB") v*=1048576; if (u=="B") v/=1024; print int(v); exit } }')
    [ -n "$kb" ] && total=$((total + kb)) && detail="$detail [$(/bin/ps -o comm= -p "$p" | sed "s#.*/##")]:$((kb/1024))MB"
  done
  echo "[footprint] $s L=$L total=$((total/1024)) MB :$detail" >&2
  echo "{\"stack\":\"$s\",\"metric\":\"${pre}_footprint_mb\",\"value\":$((total/1024)),\"unit\":\"MB\"}" | tee -a "$OUT"
  sleep 12
  pkill -P $sub 2>/dev/null; kill $sub 2>/dev/null; wait $sub 2>/dev/null
  pkill -f "$P/$s/" 2>/dev/null; sleep 2; pkill -9 -f "$P/$s/" 2>/dev/null
  rm -f /tmp/fp_before.$$
  sleep "$COOLDOWN"
}

for L in 4 8; do
  pre=preview; [ $L = 8 ] && pre=preview8
  measure swift-native $L $pre -- env MONTAGE_LAYERS=$L "$P/swift-native/build/Montage.app/Contents/MacOS/Montage" preview --media "$M" --seconds 20 --timeout 60
  measure electron-web $L $pre -- "$P/electron-web/out/Montage-darwin-arm64/Montage.app/Contents/MacOS/Montage" --media="$M" --models="$P/electron-web/models" --out="$P/electron-web/.bench-out" --bench=preview --seconds=20 --timeout=60 --layers=$L
  measure tauri-rust $L $pre -- env MONTAGE_LAYERS=$L MONTAGE_BENCH=preview MONTAGE_DURATION=20 MONTAGE_MEDIA="$M" "$P/tauri-rust/target/release/bundle/macos/MontageProto.app/Contents/MacOS/montage-proto"
  measure qt-cpp $L $pre -- env MONTAGE_LAYERS=$L "$P/qt-cpp/deploy/Montage.app/Contents/MacOS/Montage" --media "$M" --mode preview --seconds 20 --seeks 0
done
