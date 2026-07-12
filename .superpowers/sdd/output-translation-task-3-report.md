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
- Verified hostile template text cannot replace fixed target/output-only directives; the P1 follow-up below strengthens this with a provider role boundary.
- Verified all existing `PostProcessor` production consumers now construct an explicit policy-bearing request.
- `git diff --check` passed; unrelated pre-existing Task 1, Task 2, and Task 4 report modifications were left untouched and excluded from the commit.

## P1 follow-up: provider trust-boundary serialization

Root cause: the original Task 3 prompt builder concatenated user-authored `Template.prompt`,
vocabulary, and app metadata into the same string serialized as the provider's trusted system
instructions. Appending fixed rules after hostile text did not create a real role boundary.

Fix:

- Split prompt construction into fixed trusted system policy and framed untrusted user content.
- Anthropic now serializes only fixed policy in `system` and the template/transcript/metadata in
  its user message.
- OpenAI-compatible providers now serialize distinct system and user messages from the same split.
- Added request-body serialization seams so provider role boundaries and schema are directly
  testable without network calls.
- Kept Scratchpad's existing Base64 custom-criteria delimiter literal inside user content.
- Applied the same trust separation to Apple FM, including local context, while retaining its
  preserve-only guard.
- Left connection-test endpoints, authentication headers, timeout, token limit, and body schema
  unchanged.

TDD RED:

```text
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter OutputTranslationPromptTests
```

Failed because the Anthropic and OpenAI-compatible request-body serialization seams did not exist.

Verification:

```text
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter 'OutputTranslationPromptTests|ScratchpadAIActionTests|CloudLLM'
```

Passed: 37 tests in 2 suites.

```text
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter 'OutputTranslation|ScratchpadAI|AutomaticStyle|Context|CloudFeatureAvailability|OutputLanguageSettings'
```

Passed: 93 tests in 10 suites.

```text
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --quiet
```

Exited successfully. The existing AVFoundation non-interleaved-audio diagnostics remain unchanged.
