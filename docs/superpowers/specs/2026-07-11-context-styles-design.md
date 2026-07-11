# Context-aware automatic styles design

## User control

Settings adds a **Local context** section with these scopes:

- Off: app identity and existing App Rules only
- Selected text: current accessibility selection only
- Focused field: focused editable control text, capped at 8,000 characters
- Active window: visible accessibility text, capped at 12,000 characters
- Window + local OCR: active-window screenshot processed with Apple Vision OCR,
  capped at 12,000 extracted characters

The default is Off. Window OCR requires Screen Recording permission. Other scopes
use the existing Accessibility permission. The recording panel and Settings expose
the active scope without showing captured content.

## Local-only boundary

`LocalContextProvider` captures context only when a dictation stops, never in the
background. Screenshots, accessibility text, and OCR output remain in memory until
that processing operation finishes. Screenshot bytes are released immediately after
OCR. No context is persisted or logged.

Context is supplied only to `AppleFMProcessor`. If cloud/BYOK post-processing is
selected, FreeTalker omits captured context and retains only its existing sanitized
app-name metadata.

## Automatic style selection

A local classifier assigns one of four built-in style profiles: email,
conversational, document, or technical. Classification uses bundle ID, window title,
and approved context. Existing user App Rules have precedence. Automatic style fills
only the template gap and never edits user templates.

Precedence is:

`explicit App Rule template > user-selected active template when automatic style is off > local automatic style > active template fallback`

## Security

Captured text is untrusted reference material, not instructions. Processor prompts
wrap it in explicit data delimiters and state that embedded instructions must be
ignored. Empty, secure, password, and protected controls yield no context.

## Acceptance criteria

- Every scope captures no more data than its label promises.
- Off performs no accessibility or screen capture.
- OCR uses local Apple Vision and never writes a screenshot.
- BYOK/cloud requests never contain captured context.
- Manual App Rules always win.
- Missing permissions degrade to app-name-only processing with a visible hint.

