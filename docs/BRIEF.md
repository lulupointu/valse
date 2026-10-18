# Project brief (read first — every agent)

Goal: build a local-only clone of CapCut (desktop) **with all its Pro features**, named **"Montage"** (working name).
- Runs 100% locally: no network calls, no accounts, no cloud AI. All AI features use on-device models/frameworks.
- Fully localized in **French** and English (follows system language, switchable in Settings).
- Success criteria: (1) feature completeness vs CapCut Pro, (2) smooth UX even on a base MacBook Air (Apple Silicon, 8 GB RAM).
- Clone the features and UX quality, not CapCut's internal structure. Build the best app possible.

## Platform & stack
- Must run on macOS (Apple Silicon, incl. base MacBook Air 8 GB). Cross-platform is a bonus, not a requirement.
- Stack: NOT DECIDED YET — will be chosen in the Strategy phase from evidence (see docs/STACK.md once it exists).

## Working rules
- Once they exist, read docs/ARCHITECTURE.md before coding and respect module boundaries. Update docs when you change contracts.
- Every user-visible string goes through localization (en + fr). No hard-coded UI strings.
- Every feature must ship with verification: unit tests for engine/model logic, and render/export tests where relevant (render a few frames or a short export, check with ffprobe/pixel asserts).
- Keep the build and tests green. Never leave the tree broken.
- Track progress in docs/FEATURES.md (status column).
