# Voice editing and snippets design

## Voice editing

A configurable **Voice Edit** hotkey requires an editable selection. Activating it
captures an `InsertionTarget`, the selected text, and a selection fingerprint, then
records a spoken instruction. `LocalEditService` uses Apple Foundation Models to
produce a replacement locally.

The original application remains unchanged until a preview sheet appears with the
instruction, original text, proposed text, and actions for Replace selection, Copy
result, and Cancel.

Confirm revalidates the frontmost app, focused element, and selection fingerprint.
If any changed, replacement is refused and Copy remains available. The preview is
discarded when closed and is never added to Library or logs.

## Snippets

Settings gains a **Snippets** editor. Each snippet has a unique name, one or more
normalized trigger phrases, and an expansion. Trigger matching is exact after
case-folding, punctuation trimming, and whitespace normalization. A trigger may
belong to only one snippet; ambiguous legacy data opens a chooser instead of inserting.

Voice Edit recognizes snippet triggers before local generative editing. A matched
snippet uses the same preview sheet and confirmation requirement. Snippet expansions
are local SQLite data and may contain multiple lines.

## Safety and accessibility

- No selection means no recording and a clear HUD error.
- Secure/password fields are rejected.
- Preview is keyboard navigable and exposes original/proposed text to VoiceOver.
- Replace is disabled when target revalidation fails.
- Local generation errors leave the original selection untouched.

## Acceptance criteria

- Voice edits never modify text before confirmation.
- A changed target cannot receive stale replacement text.
- Snippets never insert before confirmation.
- Trigger normalization is deterministic and duplicate triggers are rejected.
- Cancel leaves the destination untouched.
- Selected text, instructions, and previews remain local and memory-only.

