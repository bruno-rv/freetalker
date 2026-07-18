# CONTEXT

Glossary of canonical terms for FreeTalker. Terms only — no implementation details.

## Noise Suppression

Reduction of non-speech environmental sound (wind, music, steady background noise) in the microphone signal before transcription. Explicitly does **not** include removing competing human speech (other voices) — that is a distinct capability (speaker isolation) and out of scope.

## Voice Isolation

The macOS system microphone mode (Control Center), user-controlled, that applies Apple's ML-based speech enhancement. Distinct from Noise Suppression: FreeTalker cannot enable it programmatically; it only becomes available to the user when the app captures through a voice-processing audio unit.

## Recording

A single mic capture session, from capture start to stop, producing the sample buffer handed to transcription. Settings that affect capture take effect at the start of the next Recording, never mid-Recording.

## Backup Bundle

A single user-readable JSON file containing the user's configuration: settings, templates, and snippets. Explicitly excludes secrets (API keys), Dictation History, and Scratchpad content. Restoring a Backup Bundle overwrites settings and merges templates/snippets — it never deletes existing user data.

## Dictation Language Set

The user-chosen subset (minimum one) of the curated supported languages that constrains spoken-language auto-detection during on-device transcription. Cloud transcription does not honor the set (its interface accepts only a single forced language). Distinct from output/translation languages: the Dictation Language Set governs what the user speaks, not what the app writes.

## Dictation History

The persisted record of past dictations (the library). Distinct from the Backup Bundle (which never contains it) and from Usage Statistics (which are derived from it and cease to exist when it is deleted).

## Permission Diagnosis

An on-demand check that verifies real capability (e.g. whether the event tap actually receives events, whether the microphone delivers signal) rather than trusting what the system's permission database reports. Exists because granted-looking permissions can be silently stale.

## Notchpad

The recording/status surface anchored to the built-in display's camera housing (the notch). When enabled and a notched display is awake, it replaces the floating recording HUD and transient flashes on that display, with full control parity. When no notched display is available (clamshell, external-only), the floating HUD remains the surface — the notch is never emulated on notchless screens.
