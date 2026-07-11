# Task 2 report

## Result

Implemented the shared rejecting download coordinator and the MainActor speech-model store, including the engine event boundary, synchronous fallback support labels, bounded one-shot remote support refresh, automatic non-user default correction, exact cache resolution/detection/sizing/deletion, and manual download ownership.

## Files

- `Sources/FreeTalker/Settings/SpeechModelStore.swift`
- `Sources/FreeTalker/SelfCheck.swift`
- `.superpowers/sdd/task-2-report.md`

## TDD evidence

- RED: `make selfcheck` failed to compile with `cannot find 'SpeechModelStore' in scope` and `cannot find 'SpeechModelDownloadCoordinator' in scope` after the resolver, detection, size, deletion, eligibility, sibling-preservation, and contention checks were added first.
- GREEN: `make selfcheck` built the release executable and reported `SelfCheck PASSED` without network access or real downloads.
- Hygiene: `git diff --check` completed without errors.

## Self-review

- The coordinator claims its actor slot before its first await and rejects contention with the active variant; its production method is the sole wrapper around `WhisperKit.download`.
- Detection requires the three model directories WhisperKit 0.18 unconditionally loads (`AudioEncoder`, `MelSpectrogram`, and `TextDecoder`); the optional decoder-prefill model is not treated as mandatory.
- Resolver, scan, and delete share one standardized URL mapping. Deletion resolves symlinks, requires strict containment below the repo root, and cannot delete the root or siblings.
- Filesystem scans, recursive sizing, and deletion run in detached tasks when invoked by the store; published mutations remain MainActor-isolated.
- No engine, lifecycle, Settings UI, or README files were changed.

## Commits

- Recorded in the commit containing this report.
