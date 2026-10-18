#!/bin/bash
# Builds the on-device AI sidecar runtimes (never committed, never linked into the app):
#   whisper-cli  (whisper.cpp, MIT, Metal)        → speech recognition (Transcriber)
#   demucs       (demucs.cpp, MIT, Accelerate BLAS) → music stem separation (StemSeparator)
#   llama-completion (llama.cpp, MIT, Metal)    → local LLM for AI writer / clipper (LlamaRuntime)
# and installs them into ~/Library/Application Support/Montage/bin (found by WhisperRuntime / DemucsRuntime).
# `--bundle build/Montage.app` also copies them into Contents/Helpers for a self-contained app.
# Models are downloaded separately from the app's AI models sheet.
# Usage: scripts/build_ai_runtimes.sh [--bundle path/to/Montage.app] [--only whisper|demucs|llama]
set -euo pipefail
cd "$(dirname "$0")/.."
BUNDLE=""; ONLY=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --bundle) BUNDLE="$2"; shift 2;;
    --only) ONLY="$2"; shift 2;;
    *) echo "unknown arg $1"; exit 2;;
  esac
done
WORK="build/ai-runtimes"; mkdir -p "$WORK"
DEST="$HOME/Library/Application Support/Montage/bin"; mkdir -p "$DEST"
WHISPER_TAG=v1.8.2
DEMUCS_REV=main
LLAMA_TAG=b11700

if [[ -z "$ONLY" || "$ONLY" == whisper ]]; then
  [[ -d "$WORK/whisper.cpp" ]] || git clone -q --depth 1 --branch "$WHISPER_TAG" https://github.com/ggml-org/whisper.cpp "$WORK/whisper.cpp"
  cmake -S "$WORK/whisper.cpp" -B "$WORK/whisper.cpp/build" -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF \
        -DGGML_METAL=ON -DGGML_METAL_EMBED_LIBRARY=ON -DWHISPER_BUILD_TESTS=OFF >/dev/null
  cmake --build "$WORK/whisper.cpp/build" --target whisper-cli -j 8 >/dev/null
  cp "$WORK/whisper.cpp/build/bin/whisper-cli" "$DEST/whisper-cli"
  echo "installed $DEST/whisper-cli"
fi

if [[ -z "$ONLY" || "$ONLY" == demucs ]]; then
  [[ -d "$WORK/demucs.cpp" ]] || git clone -q --depth 1 --branch "$DEMUCS_REV" --recurse-submodules https://github.com/sevagh/demucs.cpp "$WORK/demucs.cpp"
  cmake -S "$WORK/demucs.cpp" -B "$WORK/demucs.cpp/build" -DCMAKE_BUILD_TYPE=Release -DCMAKE_POLICY_VERSION_MINIMUM=3.5 >/dev/null
  cmake --build "$WORK/demucs.cpp/build" --target demucs_mt.cpp.main -j 8 >/dev/null
  cp "$WORK/demucs.cpp/build/demucs_mt.cpp.main" "$DEST/demucs"
  echo "installed $DEST/demucs"
fi

if [[ -z "$ONLY" || "$ONLY" == llama ]]; then
  [[ -d "$WORK/llama.cpp" ]] || git clone -q --depth 1 --branch "$LLAMA_TAG" https://github.com/ggml-org/llama.cpp "$WORK/llama.cpp"
  cmake -S "$WORK/llama.cpp" -B "$WORK/llama.cpp/build" -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF -DGGML_METAL=ON \
        -DGGML_METAL_EMBED_LIBRARY=ON -DLLAMA_CURL=OFF -DLLAMA_BUILD_TESTS=OFF -DLLAMA_BUILD_SERVER=OFF >/dev/null
  cmake --build "$WORK/llama.cpp/build" --target llama-completion -j 8 >/dev/null
  cp "$WORK/llama.cpp/build/bin/llama-completion" "$DEST/llama-completion"
  echo "installed $DEST/llama-completion"
fi

if [[ -n "$BUNDLE" ]]; then
  mkdir -p "$BUNDLE/Contents/Helpers"
  for b in whisper-cli demucs llama-completion; do [[ -x "$DEST/$b" ]] && cp "$DEST/$b" "$BUNDLE/Contents/Helpers/$b"; done
  codesign --force --deep --sign - "$BUNDLE" >/dev/null 2>&1 || true
  echo "bundled into $BUNDLE/Contents/Helpers"
fi
