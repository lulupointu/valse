#!/bin/bash
# Runs the unit tests as an x86_64 (Intel) build under Rosetta on an Apple Silicon host.
# `swift test --arch x86_64` builds fine but cannot run: SwiftPM's swiftpm-testing-helper is arm64-only and can't
# load an x86_64 test bundle. This script builds the x86_64 test bundle, then runs it through a tiny x86_64 copy of
# that helper (dlopen the bundle, call its `main`), which Rosetta executes.
# Note: Metal under Rosetta still runs on the Apple GPU — this checks the CPU / x86 code paths (Float16 replacement,
# SIMD, floating point), not Intel GPUs.
# Usage: scripts/test_x86.sh [--filter <regex>]… [--skip <regex>]… [other swift-testing args]
#   default filter: the Core, Effects and Engine suites (MONTAGE_X86_ALL=1 → every test target)
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build
source scripts/lib.sh
source scripts/slots.sh; slots_acquire
if ! /usr/bin/arch -x86_64 /usr/bin/true 2>/dev/null; then echo "Rosetta is not installed (softwareupdate --install-rosetta)"; exit 1; fi
if ! run_watched build/build-x86.log swift build --arch x86_64 --build-tests; then
  grep -E "error:|HUNG" build/build-x86.log | sort -u | head -30 >&2 || true
  echo "X86_64 BUILD FAILED (see build/build-x86.log)"; exit 1
fi
BIN=.build/x86_64-apple-macosx/debug
BUNDLE="$BIN/MontagePackageTests.xctest/Contents/MacOS/MontagePackageTests"
# named like SwiftPM's helper: MontageProcess.isUnitTest recognises the test process by this name
RUNNER="$BIN/x86-runner/swiftpm-testing-helper"
if [[ ! -x "$RUNNER" || scripts/test_x86.sh -nt "$RUNNER" ]]; then
  printf '%s\n' '#include <dlfcn.h>' '#include <stdio.h>' \
    'int main(int argc, char **argv) {' \
    '  void *h = dlopen(argv[2], RTLD_LAZY | RTLD_FIRST);' \
    '  if (!h) { fprintf(stderr, "dlopen: %s\n", dlerror()); return 1; }' \
    '  int (*m)(int, char **) = (int (*)(int, char **))dlsym(h, "main");' \
    '  if (!m) { fprintf(stderr, "no main in the test bundle\n"); return 1; }' \
    '  return m(argc, argv);' \
    '}' > "$BIN/x86-runner.c"
  mkdir -p "$BIN/x86-runner"
  clang -arch x86_64 -mmacosx-version-min=13.0 -o "$RUNNER" "$BIN/x86-runner.c"
fi
ARGS=("$@")
if [[ ${#ARGS[@]} == 0 && "${MONTAGE_X86_ALL:-0}" != 1 ]]; then
  ARGS=(--filter 'MontageCoreTests\.' --filter 'MontageEffectsTests\.' --filter 'MontageEngineTests\.')
fi
use_private_tmpdir test-x86
DEV="$(xcode-select -p)/Platforms/MacOSX.platform/Developer"
LOG=build/test-x86.log
# Known Rosetta issue: after many audio renders, Apple's translated AudioQueue server thread (AQServer) can trap in its
# caulk allocator (EXC_BAD_INSTRUCTION, exit 132) — not reproducible test by test. A crashed run is resumed: suites
# that already finished are skipped (up to 4 resumes); the crash is reported.
: > "$LOG"; SKIP=(); CRASHES=0; CODE=1
for attempt in 1 2 3 4 5; do
  set +e
  # The runner is an x86_64-only binary, so it runs under Rosetta without `arch` (which would strip DYLD_* variables).
  DYLD_FRAMEWORK_PATH="$DEV/Library/Frameworks" DYLD_LIBRARY_PATH="$DEV/usr/lib" \
    run_watched "$LOG.part" "$RUNNER" --test-bundle-path "$BUNDLE" --testing-library swift-testing \
    --xunit-output build/test-x86-xunit.xml ${ARGS[@]+"${ARGS[@]}"} ${SKIP[@]+"${SKIP[@]}"}
  CODE=$?
  set -e
  cat "$LOG.part" >> "$LOG"
  [[ $CODE == 132 || $CODE == 134 || $CODE == 139 ]] || break
  CRASHES=$((CRASHES + 1))
  echo "x86 test process crashed (exit $CODE, attempt $attempt) during: $(grep -E 'Test .* started' "$LOG.part" | tail -1)"
  while read -r suite; do SKIP+=(--skip "\.${suite}(/|\$)"); done < <(grep -oE 'Suite [A-Za-z0-9_]+ (passed|failed)' "$LOG.part" | awk '{print $2}' | sort -u)
done
rm -f "$LOG.part"
grep -E "✘|Test run with|HUNG" "$LOG" | grep -vE "^\s*$" | tail -60 || true
PASSED=$(grep -cE "✔ Test .* passed after" "$LOG" || true)
FAILED=$(grep -cE "✘ Test .* failed after" "$LOG" || true)
echo "x86 tests: $PASSED passed, $FAILED failed, $CRASHES Rosetta AQServer crash(es) resumed"
if [[ $CODE == 0 && $FAILED == 0 ]]; then echo "X86 TESTS GREEN"; exit 0; fi
echo "X86 TESTS FAILED (exit $CODE, see $LOG)"; exit 1
