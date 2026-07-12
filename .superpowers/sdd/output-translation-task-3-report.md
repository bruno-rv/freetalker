# Task 3 Report: Typed one-pass cloud translation processing

## Result

- Added `PostProcessingRequest` and changed `PostProcessor` to accept the typed request.
- Centralized mutually exclusive preserve/translate directives and the output-only rule at the end of the processor system prompt.
- Added `TranslationService`, which accepts only named translation policies, evaluates the supplied cloud snapshot once, makes one cloud processor call with that same snapshot, trims success output, and throws typed errors for unavailable configuration and empty output.
- Kept Apple Foundation Models preserve-only by rejecting translation before model availability or invocation.
- Updated dictation, reprocessing, local-context, and Scratchpad arbitrary-action consumers to pass `.preserveSource` explicitly.
- Made `Template` explicitly `Sendable` so it can be carried by `PostProcessingRequest` without unchecked concurrency conformance.

## TDD evidence

RED:

```text
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter 'OutputTranslationPromptTests|ScratchpadAIActionTests'
```

Failed at compile time because `PostProcessingRequest`, `TranslationService`, the request-based prompt builder, and Apple FM's translation rejection did not exist. This was the expected contract failure before production changes.

GREEN:

```text
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter 'OutputTranslationPromptTests|ScratchpadAIActionTests'
```

Passed: 35 tests in 2 suites.

Regression suites:

```text
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter 'AI|AutomaticStyle|Context'
```

Passed: 71 tests in 7 suites.

Full suite:

```text
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
```

Passed. The pre-existing FluidAudio unhandled-resource warning remains unchanged.

## Self-review

- Verified named translation has no call to `resolveActiveProcessor` and no Apple FM path.
- Verified the service does not return source text on empty output or processor error.
- Verified every translation target uses its canonical prompt name and no translation prompt contains the preserve-source directive.
- Verified hostile template text precedes fixed target/output-only rules and cannot replace those final directives.
- Verified all existing `PostProcessor` production consumers now construct an explicit policy-bearing request.
- `git diff --check` passed; unrelated pre-existing Task 1, Task 2, and Task 4 report modifications were left untouched and excluded from the commit.
