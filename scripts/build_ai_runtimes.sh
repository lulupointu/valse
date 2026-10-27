#!/bin/bash
# Builds the on-device AI sidecar runtimes (never committed, never linked into the app):
#   whisper-cli  (whisper.cpp, MIT)        → speech recognition (Transcriber)
#   demucs       (demucs.cpp, MIT, Accelerate BLAS) → music stem separation (StemSeparator)
#   llama-completion (llama.cpp, MIT)      → local LLM for AI writer / clipper (LlamaRuntime)
# as universal (arm64 + x86_64) binaries for macOS 13.0+, and installs them into
# ~/Library/Application Support/Valse/bin (found by WhisperRuntime / DemucsRuntime / LlamaRuntime).
#   arm64 slice:  ggml Metal backend (unchanged Apple Silicon behaviour), host-tuned CPU code.
#   x86_64 slice: ggml CPU backend only (its Metal backend doesn't support Intel / AMD GPUs well) with Accelerate BLAS
#                 and AVX2 / FMA / F16C / BMI2 (Haswell+, i.e. every Kaby Lake Mac); demucs -march=haswell.
# The runtimes take no GPU flag on the command line: macOS runs the slice matching the CPU.
# `--bundle build/Valse.app` also copies them into Contents/Helpers for a self-contained app.
# `--sse42` additionally builds test-only x86_64 binaries without AVX (build/ai-runtimes/sse42/, not installed): Rosetta
# can't run AVX2 code inside a macOS 13 VM, so VM smoke tests use these.
# Models are downloaded separately from the app's AI models sheet.
# Usage: scripts/build_ai_runtimes.sh [--bundle path/to/Valse.app] [--only whisper|demucs|llama] [--arch arm64|x86_64] [--sse42]
set -euo pipefail
cd "$(dirname "$0")/.."
BUNDLE=""; ONLY=""; ARCHS="arm64 x86_64"; SSE42=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --bundle) BUNDLE="$2"; shift 2;;
    --only) ONLY="$2"; shift 2;;
    --arch) ARCHS="$2"; shift 2;;
    --sse42) SSE42=1; shift;;
    *) echo "unknown arg $1"; exit 2;;
  esac
done
WORK="$PWD/build/ai-runtimes"; mkdir -p "$WORK"
DEST="${VALSE_AI_BIN_DIR:-$HOME/Library/Application Support/Valse/bin}"; mkdir -p "$DEST"   # override: VALSE_AI_BIN_DIR
WHISPER_TAG=v1.8.2
DEMUCS_REV=main
LLAMA_TAG=b11700
MINOS=13.0
JOBS="$(sysctl -n hw.ncpu)"
# demucs.cpp hard-codes "-Ofast -march=native …" in CMAKE_CXX_FLAGS_RELEASE before project(): replaced after project()
# for x86_64. -Ofast (finite-math-only) makes the x86_64 build output all-NaN stems (measured under Rosetta, AVX2 and
# SSE4.2 builds alike), so x86_64 uses -O3 with the remaining fast-math bits (reciprocal math, no signed zeros).
DM_X86='-O3 -fno-math-errno -freciprocal-math -fno-signed-zeros -DNDEBUG -DEIGEN_USE_BLAS'
printf 'set(CMAKE_CXX_FLAGS_RELEASE "%s %s")\n' "$DM_X86" "-march=haswell -mtune=skylake" > "$WORK/demucs-x86.cmake"
printf 'set(CMAKE_CXX_FLAGS_RELEASE "%s %s")\n' "$DM_X86" "-march=nehalem" > "$WORK/demucs-sse42.cmake"

# variant: arm64 | x86_64 | sse42 (x86_64 without AVX, test-only)
osx_flags() {
  local a="$1"; [[ "$a" == sse42 ]] && a=x86_64
  echo "-DCMAKE_OSX_ARCHITECTURES=$a -DCMAKE_OSX_DEPLOYMENT_TARGET=$MINOS"
}
# OpenMP off everywhere: CMake otherwise links Homebrew's arm64-only libomp.dylib (/opt/homebrew/opt/libomp), which a
# user's Mac doesn't have (ggml then uses its own thread pool).
ggml_flags() {
  echo -n "-DGGML_OPENMP=OFF "
  case "$1" in
    arm64) echo "-DGGML_METAL=ON -DGGML_METAL_EMBED_LIBRARY=ON";;
    x86_64) echo "-DGGML_METAL=OFF -DGGML_NATIVE=OFF -DGGML_SSE42=ON -DGGML_AVX=ON -DGGML_AVX2=ON -DGGML_FMA=ON -DGGML_F16C=ON -DGGML_BMI2=ON -DGGML_ACCELERATE=ON -DGGML_BLAS=ON";;
    sse42) echo "-DGGML_METAL=OFF -DGGML_NATIVE=OFF -DGGML_SSE42=ON -DGGML_AVX=OFF -DGGML_AVX2=OFF -DGGML_FMA=OFF -DGGML_F16C=OFF -DGGML_BMI2=OFF -DGGML_ACCELERATE=ON -DGGML_BLAS=ON";;
  esac
}
VARIANTS="$ARCHS"; [[ $SSE42 == 1 ]] && VARIANTS="$VARIANTS sse42"

# install <name> <built path relative to the build dir>: lipo the per-arch builds into DEST (sse42 → $WORK/sse42)
install_bin() {
  local name="$1" rel="$2" proj="$3" slices=() v
  for v in $ARCHS; do slices+=("$WORK/$proj/build-$v/$rel"); done
  lipo -create "${slices[@]}" -output "$DEST/$name"
  # self-contained: system libraries only (no Homebrew dylibs such as libomp / openssl)
  if otool -L "$DEST/$name" | grep -E '^[[:space:]]' | grep -vE '^[[:space:]]*/(usr/lib|System/Library)/' | grep -q .; then
    echo "error: $name links non-system libraries:" >&2; otool -L "$DEST/$name" >&2; exit 1
  fi
  echo "installed $DEST/$name ($(lipo -archs "$DEST/$name"))"
  if [[ $SSE42 == 1 ]]; then
    mkdir -p "$WORK/sse42"; cp "$WORK/$proj/build-sse42/$rel" "$WORK/sse42/$name"; echo "test-only SSE4.2 build: $WORK/sse42/$name"
  fi
}

if [[ -z "$ONLY" || "$ONLY" == whisper ]]; then
  [[ -d "$WORK/whisper.cpp" ]] || git clone -q --depth 1 --branch "$WHISPER_TAG" https://github.com/ggml-org/whisper.cpp "$WORK/whisper.cpp"
  for v in $VARIANTS; do
    # shellcheck disable=SC2046
    cmake -S "$WORK/whisper.cpp" -B "$WORK/whisper.cpp/build-$v" -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF \
          $(osx_flags "$v") $(ggml_flags "$v") -DWHISPER_BUILD_TESTS=OFF >/dev/null
    cmake --build "$WORK/whisper.cpp/build-$v" --target whisper-cli -j "$JOBS" >/dev/null
  done
  install_bin whisper-cli bin/whisper-cli whisper.cpp
fi

if [[ -z "$ONLY" || "$ONLY" == demucs ]]; then
  [[ -d "$WORK/demucs.cpp" ]] || git clone -q --depth 1 --branch "$DEMUCS_REV" --recurse-submodules https://github.com/sevagh/demucs.cpp "$WORK/demucs.cpp"
  for v in $VARIANTS; do
    inc=""
    [[ "$v" == x86_64 ]] && inc="-DCMAKE_PROJECT_INCLUDE=$WORK/demucs-x86.cmake"
    [[ "$v" == sse42 ]] && inc="-DCMAKE_PROJECT_INCLUDE=$WORK/demucs-sse42.cmake"
    # shellcheck disable=SC2046
    cmake -S "$WORK/demucs.cpp" -B "$WORK/demucs.cpp/build-$v" -DCMAKE_BUILD_TYPE=Release -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
          $(osx_flags "$v") $inc >/dev/null
    cmake --build "$WORK/demucs.cpp/build-$v" --target demucs_mt.cpp.main -j "$JOBS" >/dev/null
  done
  install_bin demucs demucs_mt.cpp.main demucs.cpp
fi

if [[ -z "$ONLY" || "$ONLY" == llama ]]; then
  [[ -d "$WORK/llama.cpp" ]] || git clone -q --depth 1 --branch "$LLAMA_TAG" https://github.com/ggml-org/llama.cpp "$WORK/llama.cpp"
  for v in $VARIANTS; do
    # shellcheck disable=SC2046
    cmake -S "$WORK/llama.cpp" -B "$WORK/llama.cpp/build-$v" -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF \
          $(osx_flags "$v") $(ggml_flags "$v") -DLLAMA_CURL=OFF -DLLAMA_OPENSSL=OFF -DLLAMA_BUILD_TESTS=OFF -DLLAMA_BUILD_SERVER=OFF >/dev/null
    cmake --build "$WORK/llama.cpp/build-$v" --target llama-completion -j "$JOBS" >/dev/null
  done
  install_bin llama-completion bin/llama-completion llama.cpp
fi

if [[ -n "$BUNDLE" ]]; then
  mkdir -p "$BUNDLE/Contents/Helpers"
  for b in whisper-cli demucs llama-completion; do [[ -x "$DEST/$b" ]] && cp "$DEST/$b" "$BUNDLE/Contents/Helpers/$b"; done
  codesign --force --deep --sign - "$BUNDLE" >/dev/null 2>&1 || true
  echo "bundled into $BUNDLE/Contents/Helpers"
fi
