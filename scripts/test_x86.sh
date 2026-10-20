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
set +e
# The runner is an x86_64-only binary, so it runs under Rosetta without `arch` (which would strip DYLD_* variables).
DYLD_FRAMEWORK_PATH="$DEV/Library/Frameworks" DYLD_LIBRARY_PATH="$DEV/usr/lib" \
  run_watched "$LOG" "$RUNNER" --test-bundle-path "$BUNDLE" --testing-library swift-testing \
  --xunit-output build/test-x86-xunit.xml ${ARGS[@]+"${ARGS[@]}"}
CODE=$?
set -e
grep -E "✘|Test run with|HUNG" "$LOG" | grep -vE "^\s*$" | tail -60 || true
if [[ $CODE == 0 ]] && grep -qE "Test run with [0-9]+ tests? .*passed" "$LOG"; then echo "X86 TESTS GREEN"; exit 0; fi
echo "X86 TESTS FAILED (exit $CODE, see $LOG)"; exit 1
