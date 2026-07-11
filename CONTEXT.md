# FreeTalker — Context

Glossary of canonical terms. No implementation details.

## Terms

**Dictation** — one unit of the core flow: user holds the push-to-talk key, speaks, releases; the spoken audio becomes a Refined Output inserted at the cursor of the frontmost app.

**Push-to-talk (PTT)** — the configurable hold-to-record hotkey. Recording lasts exactly as long as the key is held.

**Transcript** — the raw text produced by the Transcription Engine from a Dictation's audio, before any restructuring. Language (English or Brazilian Portuguese) is auto-detected per Dictation unless a Language Pin, per-app language rule, or Recording Panel choice forces it.

**Refined Output** — the text produced by applying the Active Template to a Transcript. This is what gets inserted at the cursor.

**Template** — a stored, user-editable instruction set that transforms a Transcript into a Refined Output (tone, structure, output shape). Ships with four built-ins: Clean Dictation (default), Refined Message, Refined Prompt, Email.

**Built-in Template** — one of the four Templates the app ships with. A Built-in Template the user has never edited may be silently upgraded when the app improves its default instructions; an edited one is never touched.

**Disfluency** — speech noise in a Transcript that carries no meaning: fillers ("um", "uh", "hmm"), stutters, repeated words, and false starts. Templates remove Disfluencies when producing a Refined Output.

**Self-correction** — a speaker revising themselves mid-Dictation ("I'll do A… actually, I'll do B"). Only the final intent ("I'll do B") belongs in the Refined Output.

**Active Template** — the single currently-selected Template, switched from the menu bar or cycled from the Recording Panel (both change the same global selection, which a Dictation reads when it stops). There is no per-dictation template override; per-app rules may substitute a different Template at stop time.

**Transcription Engine** — the component turning audio into a Transcript. Local-first (on-device Whisper) with an optional user-configured cloud engine.

**Speech Model** — one on-device Whisper variant (differing in size, speed, and accuracy) usable by the local Transcription Engine. Models are downloaded on demand, exactly one is Active at a time, and only multilingual variants (English + Portuguese capable) are offered. Downloaded models can be deleted, except the Active one.

**Post-Processor** — the component applying a Template to a Transcript. Cloud (BYOK) whenever the user has a fully configured cloud provider (key, endpoint, model); otherwise the on-device Apple model. Never selected per Template.

**BYOK** — "bring your own key": cloud engines/models are only ever used with the user's own API credentials, never a bundled key.

**Library** — the local, searchable archive of all past Dictations: Transcript, Refined Output, Template used, timestamp. Supports full-text search, Re-processing, and deletion (single Dictation or the entire archive). The Library never stores audio; transient on-disk debug audio may exist outside it (a copy of the most recent recording, and recordings whose transcription failed) and is purged when the archive is cleared.

**Re-process** — taking an existing Library entry's Transcript and running it through a different Template to produce a new Refined Output, saved as a new Library entry pointing back at its source.

**Redo Last** — a dedicated optional hotkey that re-inserts the newest Library entry's Refined Output at the current cursor. It never re-processes and never records; it is unbound until the user assigns a key.

**Spoken Command** — an English phrase spoken during a Dictation that is interpreted as an instruction instead of being transcribed: "new paragraph", "new line", "quote … unquote", "bullet point", "numbered list", "all caps … end caps", and "scratch that" (removes the most recent sentence or clause). Commands work regardless of the Dictation's language.

**Language Pin** — a persistent setting (Auto, English, Portuguese) that forces the Transcript's language instead of auto-detection. A per-app language rule overrides the pin for that app; a Recording Panel language choice overrides both, for that Dictation only.

**Recording Panel** — the expanded HUD shown while recording. Offers: cancel, finish-and-paste, finish-and-paste raw (verbatim Transcript, skipping the Post-Processor but still saved to the Library under the template name "Raw Transcript"), a one-shot language choice, Active Template cycling, and hands-free lock.
