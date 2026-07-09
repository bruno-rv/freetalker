# FreeTalker — Context

Glossary of canonical terms. No implementation details.

## Terms

**Dictation** — one unit of the core flow: user holds the push-to-talk key, speaks, releases; the spoken audio becomes a Refined Output inserted at the cursor of the frontmost app.

**Push-to-talk (PTT)** — the configurable hold-to-record hotkey. Recording lasts exactly as long as the key is held.

**Transcript** — the raw text produced by the Transcription Engine from a Dictation's audio, before any restructuring. Language (English or Brazilian Portuguese) is auto-detected per Dictation.

**Refined Output** — the text produced by applying the Active Template to a Transcript. This is what gets inserted at the cursor.

**Template** — a stored, user-editable instruction set that transforms a Transcript into a Refined Output (tone, structure, output shape). Ships with four built-ins: Clean Dictation (default), Refined Message, Refined Prompt, Email.

**Built-in Template** — one of the four Templates the app ships with. A Built-in Template the user has never edited may be silently upgraded when the app improves its default instructions; an edited one is never touched.

**Disfluency** — speech noise in a Transcript that carries no meaning: fillers ("um", "uh", "hmm"), stutters, repeated words, and false starts. Templates remove Disfluencies when producing a Refined Output.

**Self-correction** — a speaker revising themselves mid-Dictation ("I'll do A… actually, I'll do B"). Only the final intent ("I'll do B") belongs in the Refined Output.

**Active Template** — the single currently-selected Template, switched from the menu bar. Every Dictation uses it; there is no per-dictation picker.

**Transcription Engine** — the component turning audio into a Transcript. Local-first (on-device Whisper) with an optional user-configured cloud engine.

**Post-Processor** — the component applying a Template to a Transcript. Cloud (BYOK) whenever the user has a fully configured cloud provider (key, endpoint, model); otherwise the on-device Apple model. Never selected per Template.

**BYOK** — "bring your own key": cloud engines/models are only ever used with the user's own API credentials, never a bundled key.

**Library** — the local, searchable archive of all past Dictations: Transcript, Refined Output, Template used, timestamp. Supports full-text search and Re-processing. Audio is not retained.

**Re-process** — taking an existing Library entry's Transcript and running it through a different Template to produce a new Refined Output.
