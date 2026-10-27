#!/bin/bash
# Downloads, license-checks, transcodes and analyses the bundled music + sound-effect library (AU-001/002/025).
# Development time only — Valse itself never goes online. Sources: scripts/content/{music,sfx}_sources.json
# (CC0 / public domain only, pinned SHA-256). Output: the audio cache ($VALSE_CONTENT_CACHE, default
# ~/Library/Caches/ValseDev/content/out — never committed) and the committed manifest
# app/Sources/ValseEngine/Resources/ContentLibrary/content_manifest.json. scripts/build_app.sh bundles the cache.
# Usage: scripts/fetch_music_pack.sh [--pin] [--only music|sfx] [--no-analyze] [--force-encode] [--budget-mb 150]
# Needs: python3, ffmpeg/ffprobe (Homebrew), afconvert (macOS), swift.
set -euo pipefail
cd "$(dirname "$0")/.."
exec python3 -I scripts/content/fetch_content.py "$@"
