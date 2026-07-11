# Task 1 report: context scope and Accessibility capture

## Status

DONE

## Changes

- Added persisted `LocalContextScope` values for Off, selected text, focused field,
  active window, and window OCR. Unset or invalid persisted values resolve to Off.
- Added immutable `Sendable` app identity, field, window, processing-context, and
  capture-result snapshots. Only strings and the bundle identifier cross the AX boundary.
- Added a `@MainActor` fakeable Accessibility adapter and `LocalContextProvider`.
  `AXUIElement` values remain private stack/local implementation details of the real adapter.
- Off returns immediately without consulting the adapter. Selected text reads only the AX
  selection; focused field text is capped at 8,000 characters; active-window visible text is
  capped at 12,000 characters.
- Secure/password/protected controls yield no text, including secure descendants during active
  window traversal.
- Missing Accessibility permission returns app name/bundle identity only with a typed
  `accessibilityPermissionRequired` limitation and performs no AX content read.
- Window OCR currently captures app/window metadata only and performs no text or screenshot
  capture; OCR remains explicitly deferred to Task 2.

## TDD evidence

### RED

Command:

```text
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter LocalContextProviderTests
```

Result: exit 1 with the expected missing-production API failures, including:

```text
error: cannot find type 'AccessibilityContextProviding' in scope
error: cannot find 'AccessibilityLocalContextProvider' in scope
error: value of type 'AppSettings' has no member 'localContextScope'
```

### GREEN

Focused command:

```text
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter LocalContextProviderTests
```

Result: exit 0; 8 tests in `LocalContextProviderTests` passed.

Coverage includes every scope and call boundary, both character caps, secure-field rejection,
missing-permission degradation, Off's zero-call guarantee, and default/persisted settings.

### Full verification

Command:

```text
make test && DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build -c release && git diff --check
```

Result: exit 0; 75 tests in 7 suites passed, the release build completed, and
`git diff --check` produced no output.

## Self-review

- The provider checks Off before app identity or permission, so it makes exactly zero adapter
  calls.
- App identity comes from `NSWorkspace`, not AX, and is captured before the permission gate;
  this makes app-name-only degradation possible without querying protected UI content.
- Each non-OCR scope has a distinct adapter method, preventing selected-text capture from
  accidentally reading a full field or active-window content.
- The real adapter rejects both the secure text-field role and `AXProtectedContent`, and active
  window traversal stops at protected subtrees.
- AX traversal applies the 12,000-character budget while walking as well as at the provider
  output boundary, avoiding an oversized intermediate visible-text snapshot.
- `windowOCR` does not call the active-window text path and cannot accidentally collect AX text.
- Tests use an injected adapter and isolated `UserDefaults` suite; they do not inspect the real
  screen or request system permission.

## Concerns

None.

## Review follow-up: bounded cyclic traversal and PID-consistent capture

### Findings resolved

- Replaced recursive AX traversal with an iterative stack over a fakeable node adapter and
  adapter-defined stable identity. A visited set prevents cycles and duplicate reads.
- Defined exact traversal ceilings of 12,000 characters, 5,000 unique nodes, and depth 64.
  Traversal does not request children after reaching any applicable ceiling.
- The app-name, bundle-id, and PID snapshot is read once per provider capture. Every focused
  element/window request receives that captured PID and the real adapter creates its AX app
  root from that PID without another `NSWorkspace` lookup.
- Invalid persisted context-scope strings normalize to Off and are rewritten as the canonical
  `off` raw value during `AppSettings` initialization.

### TDD evidence

RED command:

```text
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter 'LocalContextProviderTests|AccessibilityTreeReaderTests'
```

Result: exit 1 with expected missing PID-aware adapter and tree-reader APIs, including:

```text
error: extra argument 'pid' in call
error: cannot find type 'AccessibilityNodeAdapting' in scope
error: cannot find 'AccessibilityTreeReader' in scope
```

GREEN focused command:

```text
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter 'LocalContextProviderTests|AccessibilityTreeReaderTests'
```

Result: exit 0; 14 tests in 2 suites passed. New tests cover a cycle, a 10,000-deep
tree, a 10,000-child textless tree, exact node/depth/character read ceilings, app focus changing
after the identity snapshot, and invalid persisted scope normalization.

### Verification

```text
make test && DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build -c release && git diff --check
```

Result: exit 0; 81 tests in 8 suites passed, the release build completed, and
`git diff --check` produced no output.
