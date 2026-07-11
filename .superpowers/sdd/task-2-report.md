# Context plan task 2 report: local OCR and automatic styles

## Status

DONE

## Changes

- Added `VisionOCRServicing` and a local Apple Vision implementation. Recognition is memory-only,
  runs inside an autorelease pool, and caps returned OCR text at 12,000 characters.
- Added deterministic `AutomaticStyleClassifier` classifications for email, conversational,
  document, and technical contexts. Known application identity wins weaker title/content signals.
- Added rule-first template resolution. A valid explicit App Rule always wins automatic style;
  automatic style fills the gap and the active template remains the final fallback.
- Added an AppleFM-only `process(..., context:)` overload. The shared `PostProcessor` contract and
  `CloudLLMProcessor` API remain unchanged and cannot accept local context.
- Added local prompt framing that labels captured content as untrusted reference data, explicitly
  rejects embedded instructions, caps it, and XML-escapes delimiter characters before insertion.
- Added focused tests for all four classifications, determinism/priority, manual precedence,
  automatic fallback, delimiter injection resistance, context/OCR caps, actual `CGImage` release,
  and compile-time cloud API omission.

## TDD evidence

### RED

```text
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter AutomaticStyleTests
```

Exited 1 with the expected missing `AutomaticStyleClassifier`, `VisionOCRService`, and
`buildLocalProcessorInstructions` symbols.

A later focused red cycle for app-signal precedence failed because code-like email context was
incorrectly classified as technical:

```text
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter knownApplicationTypeOutranksIncidentalContext
```

### GREEN

```text
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter AutomaticStyleTests
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build
```

Both exited 0; 12 focused tests passed and the debug build completed.

## Concerns

- Screenshot acquisition and permission UI remain Task 3 responsibilities. This task guarantees
  the OCR service does not retain its input image after recognition and caps/releases it in focused
  regression coverage.
