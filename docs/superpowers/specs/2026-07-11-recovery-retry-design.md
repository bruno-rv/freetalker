# Recovery and retry design

## User experience

Library gains a **Recoveries** segment with a count badge. Each row shows capture
date, duration, failure reason, expiry, and actions for Play, Retry, and Delete.
Retry opens a sheet showing the original language, template, and current speech
model. The user may change the model or template before starting a new attempt.

## Capture and retention

Audio that fails transcription or produces no speech becomes a durable recovery
job before the failure is surfaced. The source WAV is stored atomically. Default
retention is 7 days and is configurable to 1, 7, 30, 90 days, or never.

Cleanup runs at launch and after a retention-setting change. It deletes only
terminal failed recovery jobs whose expiry has passed. Active, queued, processing,
or ready jobs are never cleanup-eligible.

## Retry lifecycle

A retry adds a `JobAttempt`; it does not replace the original job or source. The
source remains until all of these succeed:

1. transcription returns non-empty text;
2. the Dictation row is committed;
3. the job is marked ready.

Only then may the recovery WAV be removed. Post-processing failure saves the raw
transcript as a Dictation and does not return the job to Recoveries.

## Failure behavior

- Playback failure leaves the recovery intact.
- Missing or corrupt source becomes a visible unrecoverable state with Delete.
- App termination during retry returns the job to queued on the next launch.
- Manual deletion requires confirmation and removes only that job's owned WAV.

## Acceptance criteria

- Failed speech appears in Recoveries after relaunch.
- Retry can use a different downloaded speech model.
- A successful retry creates exactly one Dictation and removes the recovery WAV.
- Failed persistence never deletes source audio.
- Retention cleanup respects every supported duration and never deletes active work.
- All recovery operations remain local.

