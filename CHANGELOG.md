# Changelog

All notable project changes should be recorded here. Keep the format
lightweight and package-focused.

## Unreleased

## v0.3.4 - 2026-05-07

### Fixed

- Release asset generation now exports the Arch and Alpine package artifacts
  from the consolidated container smoke script.
- Tagged release builds now fail if a required package artifact is missing for
  the platform being built.

## v0.3.3 - 2026-05-07

### Fixed

- Fuzz gates now use explicit execution counts for smoke, release, and nightly
  parser fuzzing so the gate records actual parser exercise instead of elapsed
  wall-clock time after the Go fuzz worker rate plateaus.
- Alpine native PAM APK package files now include the APK architecture in the
  exported filename so `x86_64` and `aarch64` packages can coexist in one
  release directory and repository publication can index both.
- Alpine repository endpoint validation now checks both published APK indexes:
  `x86_64` and `aarch64`.

## v0.3.2 - 2026-05-06

### Fixed

- Apt repository smoke validation no longer requires `dpkg-architecture` or
  `dpkg-dev` on target hosts; it derives the exact Debian/Ubuntu multiarch PAM
  module path from the installed package architecture.
- CI fuzz smoke now uses a fixed execution count instead of a short wall-clock
  deadline, avoiding false failures on slower GitHub runners.
- Release operations now publish signed package repositories from immutable
  GitHub Release package files, wait for GitHub Pages deployment, and smoke
  live package-manager endpoints before calling a repository-backed release
  complete.
