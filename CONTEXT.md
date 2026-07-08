# FreeTalker — Context

Glossary of canonical terms. No implementation details.

## Terms

**Dictation** — one unit of the core flow: user holds the push-to-talk key, speaks, releases; the spoken audio becomes a Refined Output inserted at the cursor of the frontmost app.

**Push-to-talk (PTT)** — the configurable hold-to-record hotkey. Recording lasts exactly as long as the key is held.

**Transcript** — the raw text produced by the Transcription Engine from a Dictation's audio, before any restructuring. Language (English or Brazilian Portuguese) is auto-detected per Dictation.

**Refined Output** — the text produced by applying the Active Template to a Transcript. This is what gets inserted at the cursor.

**Template** — a stored, user-editable instruction set that transforms a Transcript into a Refined Output (tone, structure, output shape). Ships with four built-ins: Clean Dictation (default), Refined Message, Refined Prompt, Email.

**Active Template** — the single currently-selected Template, switched from the menu bar. Every Dictation uses it; there is no per-dictation picker.

**Transcription Engine** — the component turning audio into a Transcript. Local-first (on-device Whisper) with an optional user-configured cloud engine.

**Post-Processor** — the component applying a Template to a Transcript. Local-first (on-device Apple model) with optional user-supplied cloud API key (BYOK) per heavier Templates.

**BYOK** — "bring your own key": cloud engines/models are only ever used with the user's own API credentials, never a bundled key.

**Library** — the local, searchable archive of all past Dictations: Transcript, Refined Output, Template used, timestamp. Supports full-text search and Re-processing. Audio is not retained.

**Re-process** — taking an existing Library entry's Transcript and running it through a different Template to produce a new Refined Output.
