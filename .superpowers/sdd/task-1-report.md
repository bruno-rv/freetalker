# Task 1 implementation report

## Result

Implemented PLAN.md approach items 1 and 2: the pure multilingual speech-model catalog and the persisted `AppSettings` selection/user-intent contract.

Implementation commit: `1a701f55ec0349b9a9dfd2da4ff1c5eaa4393bd5`

## TDD evidence

### RED

Command:

```text
make selfcheck
```

Expected failure excerpt (exit 2):

```text
Sources/FreeTalker/SelfCheck.swift:249:23: error: cannot find 'SpeechModelCatalog' in scope
Sources/FreeTalker/SelfCheck.swift:296:35: error: value of type 'AppSettings' has no member 'whisperModel'
Sources/FreeTalker/SelfCheck.swift:304:18: error: value of type 'AppSettings' has no member 'applyAutomaticWhisperModel'
Sources/FreeTalker/SelfCheck.swift:308:18: error: value of type 'AppSettings' has no member 'setWhisperModelFromUser'
make: *** [build] Error 1
```

The checks failed because the requested catalog and settings APIs did not yet exist.

### GREEN

Command:

```text
make selfcheck
```

Output (exit 0):

```text
swift build -c release
Building for production...
[6/7] Linking FreeTalker
Build complete! (8.76s)
.build/release/FreeTalker --self-check
SelfCheck: found 3 input device(s): HD Webcam C615, MacBook Pro Microphone, Continuity iPhone Microphone
SelfCheck PASSED (...)
```

Additional scope check:

```text
git diff --check
```

Output: empty (exit 0).

## Files changed

- `Sources/FreeTalker/Settings/SpeechModelCatalog.swift`
  - Seven curated multilingual variants in required display order.
  - Explicit device-default preference order.
  - Pure lookup, normalization/legacy alias, and best-supported resolution helpers.
  - Documents `.en`, `distil-*`, and large-v2 exclusions.
- `Sources/FreeTalker/Settings/AppSettings.swift`
  - Persisted `@Published` model and user-intent state.
  - Synchronous, support-independent initialization normalization.
  - Separate user and automatic update APIs.
- `Sources/FreeTalker/SelfCheck.swift`
  - Catalog uniqueness, multilingual, metadata, order/coverage, lookup, normalization, support-set, persistence, user-intent, and automatic-update checks.

## Self-review

- Scope is limited to the three implementation/check files authorized by the brief, plus this required report.
- `AppSettings` has no engine or asynchronous support dependency.
- Unknown and empty support sets resolve deterministically to the static default; unknown support values are not accidentally treated as default support.
- Prefixless aliases are accepted for all catalog entries by one generic normalization rule.
- Automatic updates preserve existing user intent, making the API suitable for device correction and safe reload-failure reverts.
- No store, engine, UI, filesystem, download, or network behavior was added.

Concerns: approximate sizes for base/small/medium are display estimates and may vary with packaged artifacts; the IDs and explicitly specified size labels are exact.
