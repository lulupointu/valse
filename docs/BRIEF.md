# Project brief (read first — every agent)

Goal: build a local-only clone of CapCut (desktop) **with all its Pro features**, named **"Montage"** (working name).
- Runs 100% locally: no network calls, no accounts, no cloud AI. All AI features use on-device models/frameworks.
- Fully localized in **French** and English (follows system language, switchable in Settings).
- Success criteria: (1) feature completeness vs CapCut Pro, (2) smooth UX even on a base MacBook Air (Apple Silicon, 8 GB RAM).
- "Feature" means functionality AND CapCut's easy UX: same discoverability, flows, number of clicks, immediate feedback. Reference UX is documented in docs/UX.md (from the real CapCut app). Clone features and UX, not internal structure.

## Platform & stack
- Must run on macOS (Apple Silicon, incl. base MacBook Air 8 GB). Cross-platform is a bonus, not a requirement.
- Stack (DECIDED, see docs/STACK.md): native Swift 6 — SwiftUI + AppKit (custom-drawn timeline/canvas), AVFoundation/VideoToolbox,
  Metal (+ Core Image) compositing shared by preview & export, Apple on-device AI (Vision, Speech, Translation, Core ML) + whisper.cpp
  where better, AVAudioEngine. SwiftPM multi-module, CLI-buildable. Deployment target macOS 14+.
- Mandatory from day one (benchmark lessons): proxy media / preview cache (4K HEVC scrub & decoder memory are the bottleneck on 8 GB).

## Working rules
- Once they exist, read docs/ARCHITECTURE.md before coding and respect module boundaries. Update docs when you change contracts.
- Every user-visible string goes through localization (en + fr). No hard-coded UI strings.
- Every feature must ship with verification: unit tests for engine/model logic, and render/export tests where relevant (render a few frames or a short export, check with ffprobe/pixel asserts).
- Keep the build and tests green. Never leave the tree broken.
- Track progress in docs/FEATURES.md (status column).
