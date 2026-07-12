# Output translation design

## Summary

FreeTalker will separate the language a user speaks from the language it
inserts. Speech recognition will continue to use **Spoken language**, while a
new **Output language** will control whether API post-processing preserves the
source language or translates the final text.

Settings will provide a persistent output-language default. The floating
launcher and active recording HUD will provide a recording-scoped override.
Translation will use the configured cloud API model in the same processing
pass that applies the selected template. FreeTalker will always retain the raw
source transcript so a failed translation can be retried or explicitly
replaced with the source.

Library entries will gain non-destructive saved translation variants. Users
can translate existing refined text or, when no refined text exists, the raw
transcript without replacing the original entry.

## Goals

- Make spoken-language recognition and output-language translation distinct.
- Default output to **Same as spoken** and let users change the default.
- Let users override output language from the launcher and recording HUD for
  the next or current recording.
- Support Same as spoken, English, Portuguese, Mandarin Chinese, Hindi,
  Spanish, Standard Arabic, French, and German.
- Run template application and translation in one cloud API request.
- Share one canonical API eligibility rule and explanation across live
  translation, Scratchpad AI actions, and Library translation.
- Retain raw source text and provide explicit recovery when translation fails.
- Add non-destructive translation variants to existing Library entries.
- Disclose when text is sent to the configured API endpoint.

## Non-goals

- Expanding the spoken-language choices beyond Automatic, English, and
  Portuguese in this version.
- Sending an output language to WhisperKit or Cloud STT as an input-language
  hint.
- Translating audio directly through a speech-translation endpoint.
- Translating without an eligible configured cloud API model.
- Falling back to Apple Foundation Models, another provider, or a local model.
- Replacing original Library transcripts or refined output with translations.
- Automatically translating existing Library entries in bulk.
- Detecting or guaranteeing a user's dialect within a language family.

## Supported languages

`OutputLanguage` will define these choices in this order:

- Same as spoken.
- English.
- Portuguese.
- Mandarin Chinese.
- Hindi.
- Spanish.
- Standard Arabic.
- French.
- German.

The five additions besides English and Portuguese follow total-speaker
rankings, with German included as an explicit product requirement. Rankings
can vary when sources count Chinese and Arabic varieties separately. See
[Ethnologue's methodology note](https://stg.ethnologue.com/insights/ethnologue200/)
and this
[2025 Ethnologue-based comparison](https://philologicalscience.com.ua/web/uploads/pdf/International%20Journal%20of%20Philology_29_2_2025.pdf-55-78.pdf).

Store a stable language identifier separately from the localized display
label. Persist **Same as spoken** as the default. Unknown or legacy stored
values must normalize to **Same as spoken**.

## Language semantics

### Spoken language

**Spoken language** means the language present in the audio. It remains:

- Automatic.
- English.
- Portuguese.

It continues to resolve through the established one-shot selection, App Rule,
and `languagePin` precedence. Only this resolved value may flow into
WhisperKit or Cloud STT language parameters.

### Output language

**Output language** means the language of the final inserted or saved text.
**Same as spoken** instructs post-processing to preserve the transcript's
language. Any named language instructs the configured cloud model to produce
the final text in that language.

The UI must use explicit labels such as **Speak: English** and
**Output: Portuguese**. It must not call output translation a dictation
language or imply that selecting Portuguese makes English audio Portuguese
before transcription.

## Settings and recording overrides

Settings will add **Default output language**, initially
**Same as spoken**. The setting applies when a recording has no explicit
output override.

The floating launcher and recording HUD will expose the complete output
language list. Their selection represents one recording-scoped override:

1. A recording-scoped output language wins.
2. The Settings default applies when no override exists.

An override selected before recording applies to the next recording. A change
made in the active HUD applies to that recording. The launcher and HUD must
show the same active value while the recording exists. The override clears
after successful completion, cancellation, or terminal failure and must not
silently become the persisted default.

The default and override affect output processing only. They must never alter
spoken-language resolution or an App Rule's input-language behavior.

## API eligibility and user guidance

Translation is API-only. It is enabled only when
`AppSettings.cloudLLMSnapshot.eligibility` is
`CloudLLMEligibility.eligible`. Live dictation, Scratchpad, and Library must
reuse this canonical result instead of duplicating URL, model, key, provider,
or loopback checks. The existing keyless exception for an eligible
OpenAI-compatible HTTP loopback endpoint remains valid.

Translation controls remain visible when unavailable but are disabled. Hover
help and accessibility help must explain the applicable reason and direct the
user to **Settings > General > Cloud post-processing**. Scratchpad AI controls
must use the same API-dependency wording so users understand that both features
require a configured API model.

At minimum, guidance distinguishes:

- Missing or invalid base URL or model.
- Missing API key for a provider that requires one.
- An unavailable configuration captured after a request began.

Tooltips are supplemental. Disabled controls must expose the same explanation
to assistive technologies.

## Processing architecture

Introduce a separate `OutputLanguage` model. Do not reuse raw STT language
strings as the output-policy type. Resolve each recording to one immutable
processing policy:

- Preserve the source language.
- Translate to a specific supported output language.

Capture one `CloudLLMSettingsSnapshot` when processing starts. Use that same
snapshot for eligibility, endpoint, model, and credentials throughout the
request so the gate and request cannot observe different settings.

### One-pass processing

For a named output language, one API request will both apply the selected
formatting template and translate the result:

1. Transcribe audio using only the resolved spoken-language hint.
2. Preserve the raw transcript and its detected or resolved source language.
3. Capture the template and recording output policy.
4. Send one request to the configured cloud model.
5. Require only the final formatted text in the requested output language.
6. Route the result to the captured destination.

For **Same as spoken**, the processor applies the template and preserves the
source language. Existing behavior for a workflow that does not require cloud
processing remains unchanged; output translation itself never uses a local
processor.

Processor instructions must encode preservation and translation as mutually
exclusive fixed directives. A user template is untrusted content and cannot
override the selected target, request a different language, or request
commentary around the result. Fixed system instructions must take precedence
and require text-only output.

Do not fall back to `AppleFMProcessor`, a different cloud provider, or raw text
when a requested translation fails. Such a fallback could insert text in a
language the user did not choose.

## Destination routing

The existing explicit recording destination remains authoritative:

- External dictation validates and inserts into the previously captured
  external target through the existing safe-insertion path.
- Scratchpad dictation resolves and replaces its stable editor destination.

The selected output policy travels with the recording destination through
transcription, processing, retry, cancellation, and completion. Window focus
must not change either destination or language while asynchronous work runs.
Scratchpad translation must never paste into another application. External
translation must never replace a later Scratchpad selection.

## Failure and recovery

FreeTalker must retain the raw source transcript until the recording reaches a
resolved outcome. If translation fails, returns empty text, is canceled, or
finds that the captured API configuration is no longer usable, it must not
silently insert source text.

The HUD or Scratchpad reports **Translation failed** and offers:

- **Retry translation**, using a fresh eligible settings snapshot while
  retaining the original source transcript, template, output language, and
  destination safety checks.
- **Insert source text**, an explicit action that bypasses translation and
  inserts the retained source through the same captured destination.

If the destination changed or became unsafe while the request was pending,
FreeTalker must not overwrite newer content. It preserves the result for copy
or the established manual-insertion recovery path. Cancellation never inserts
either the translation or source text automatically.

Concurrent Settings changes do not mutate an in-flight request. A retry may
use the new valid configuration only after the user chooses it.

## Library translations

Each Library entry preserves its current raw transcript and refined output.
Add **Translate...** to an entry and present the named output languages. The
action uses refined output when it is nonempty; otherwise, it uses the raw
transcript.

A successful result is stored as a translation variant on the same Library
entry. Each variant records at least:

- Parent entry identifier.
- Stable target-language identifier.
- Translated text.
- Creation and update timestamps.

Add a database migration for variants. Enforce one variant per parent entry
and target language with a database uniqueness constraint, not UI logic alone.
Migration must preserve every existing entry and be safe to run exactly once
through the established schema-version mechanism.

The Library detail view lets users switch among **Original** and saved
translations. A variant can be copied, inserted through the normal explicit
Library action, retried, or regenerated. Translating to a language that already
has a variant asks the user to confirm replacement. Replacement updates that
variant atomically and does not create a duplicate or alter the original.

API errors, empty output, cancellation, concurrent entry deletion, or failed
storage leave the original and every existing variant unchanged. Translation
is visible but disabled without canonical API eligibility and presents the
same hover and accessibility help as live translation and Scratchpad AI.

## History metadata

New dictation history records must retain:

- Raw source transcript.
- Final output when one exists.
- Detected or resolved source language.
- Requested output language or **Same as spoken**.

This metadata supports source recovery and makes translated output
distinguishable from transcription. It must not contain API keys, request
headers, provider credentials, or full generated prompts.

## Privacy and security

The UI must state that translation sends text to the API endpoint configured
under **Cloud post-processing**. The disclosure applies to:

- Live transcripts selected for output translation.
- Scratchpad text selected for an AI action or translation.
- Library text selected for translation.

Keep API keys in Keychain and use the existing redacted settings snapshot.
Never store credentials, headers, or generated request prompts in Library
variants, logs, recovery state, or analytics. Preserve existing trust-boundary
validation for endpoint eligibility and external insertion.

## Test strategy

### Unit and integration tests

Add focused tests for:

- Stable identifiers, labels, ordering, persistence, and invalid fallback for
  every output-language choice, including German.
- Strict separation between spoken language and output language at WhisperKit,
  Cloud STT, post-processing, and retry boundaries.
- Settings default and recording override precedence, launcher/HUD
  synchronization, and clearing on success, cancellation, and failure.
- Canonical API eligibility and identical disabled help across launcher, HUD,
  Scratchpad, and Library.
- One-pass template and translation requests.
- Mutually exclusive preserve and translate directives.
- Hostile templates that attempt to change the target language or output
  additional commentary.
- The absence of Apple Foundation Models and provider fallback for translation.
- External and Scratchpad destination routing with focus changes and
  concurrent edits.
- Raw-source retention, retry, explicit source insertion, empty output,
  cancellation, and configuration changes.
- Library migration from the current schema, variant uniqueness, confirmed
  replacement, atomic failure, and preservation of originals.
- Library source selection: refined output first, raw transcript otherwise.
- Privacy-safe persistence and logging.

### Manual verification matrix

Verify release builds with an eligible configured provider and without one:

- Speak English and output Portuguese, then reverse the pair.
- Exercise every supported named output language, including German.
- Confirm **Same as spoken** preserves English and Portuguese.
- Change the launcher override before recording and the HUD override during
  recording; confirm it clears afterward.
- Complete, cancel, fail, and retry recordings in an external application and
  Scratchpad.
- Verify disabled tooltip and VoiceOver guidance without an eligible API.
- Verify disclosure text for live, Scratchpad, and Library requests.
- Translate a Library original, switch variants, regenerate with confirmation,
  copy, insert, and relaunch to confirm persistence.
- Change API configuration during a request and confirm the in-flight snapshot
  remains stable.
- Exercise the HUD and launcher over another application's full-screen Space.

Run the focused test targets, the full test suite, release assembly, and code
signing checks before completion.

## Acceptance criteria

- Users can distinguish spoken language from output language everywhere.
- Settings defaults output to **Same as spoken** and persists a valid choice.
- Launcher and HUD can override output per recording without changing the
  persisted default.
- Overrides synchronize while active and clear on every terminal path.
- Named output translation works only with canonical cloud API eligibility.
- Translation and Scratchpad AI show consistent API requirements through
  hover and accessibility help.
- Templates cannot override a fixed preserve or target-language directive.
- Translation uses one cloud request for formatting and target-language output
  and never falls back to Apple Foundation Models or another provider.
- Failed translation inserts nothing automatically and offers retry or
  explicit source insertion from the retained raw transcript.
- External and Scratchpad results reach only their captured destinations.
- Library translations are durable, unique per target, replaceable with
  confirmation, and never alter the original entry.
- Existing Library data survives migration unchanged.
- Stored history identifies source and requested output languages without
  storing secrets or request prompts.
- Automated and manual verification cover every supported language and all
  success, failure, cancellation, and configuration-change paths.
