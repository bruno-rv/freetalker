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

## Review-finding fixes

Commit `3ad09192d134b9340baf88340b5edfe382c0139c` fixes failed-state persistence across scans, bounded remote support refresh without structured-scope waiting, atomic delete reservation/rollback/event exclusion, and coordinator-owned shared activity propagation. It also removes the tautological exact-path comparison while retaining standardized resolution and containment validation.

Focused regressions were added before the fixes. The RED command and relevant output were:

```text
$ make selfcheck
error: type 'SpeechModelStore' has no member 'merging'
error: type 'SpeechModelStore' has no member 'shouldApplyAutomaticDefault'
error: extra argument 'fallbackSupport' in call
error: type 'SpeechModelStore' has no member 'firstResult'
make: *** [build] Error 1
```

Final GREEN verification was:

```text
$ make selfcheck
Build complete! (10.02s)
SelfCheck: found 2 input device(s): HD Webcam C615, MacBook Pro Microphone
SelfCheck PASSED (...)

$ git diff --check
(no output; exit 0)
```
