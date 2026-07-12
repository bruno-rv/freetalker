# Local voice-profile calibration

`VoiceProfileCalibration` is a local SwiftPM operator tool. It is not shipped in
`FreeTalker.app`, does not enable voice identity in the product, and does not
select production thresholds.

## Prepare a consent manifest

Use only recordings whose participants explicitly approved this calibration.
Give every participant, session, sample, and expected diarized speaker a
pseudonymous ID; do not put names, email addresses, or other identifying text in
those fields. Every sample must set `consentConfirmed` to `true` and reference an
existing absolute local media path.

The version 1 JSON shape is:

```json
{
  "version": 1,
  "samples": [
    {
      "sampleID": "sample-001",
      "participantID": "participant-01",
      "sessionID": "session-01",
      "mediaPath": "/absolute/local/path/sample.wav",
      "microphone": "built-in",
      "environment": "quiet-room",
      "expectedSpeakerID": "SPEAKER_00",
      "consentConfirmed": true
    }
  ]
}
```

The manifest must contain at least two participants and at least two distinct
sessions for each participant. Enrollment and query data are always taken from
different sessions. Validation is fail-closed: unsupported versions, blank IDs,
duplicate sample IDs, relative or missing media, missing consent, or an invalid
cohort stop the run before extraction.

Keep the manifest and media outside Git. `calibration-data/` is ignored only as
a convenience; an ignored path is not an access-control boundary.

## Run locally

The report directory must not already exist, which prevents an accidental
overwrite:

```sh
make calibrate-voice-profiles MANIFEST=/absolute/path/to/consented-manifest.json
```

The command writes JSON and Markdown under
`.codex/sdd/reports/voice-profile-calibration/`. The directory is mode `0700`
and report files are mode `0600`. Audio is read directly from the manifest path;
the tool does not copy or cache audio, embeddings, or model bytes.

Reports contain only model metadata, aggregate cohort counts, distributions,
bins, threshold-grid observations, runner-up-margin observations, and
pseudonymous rejected sample IDs. They contain no raw vectors, source paths,
microphone values, environment values, or participant IDs.

## Limitations

This is measurement evidence, not proof that a voice belongs to a person and
not authorization to enable matching in the app. Cohort size, recording
conditions, microphones, diarization mistakes, and model changes all limit how
well results generalize. A human must review the evidence before a separate
product plan records any constants and the exact model fingerprint.

Embeddings stay in process memory and are released promptly after aggregate
calculation. Swift arrays use managed and copy-on-write storage, so the tool
cannot reliably guarantee zeroization of every memory copy. Do not use this tool
on a machine or account whose local process memory is outside the consented
trust boundary.

## Delete local data

After review, delete both the source samples/manifest and generated reports with
the normal secure-data process for the machine. For example, after confirming
the paths:

```sh
rm -rf /absolute/path/to/calibration-data
rm -rf .codex/sdd/reports/voice-profile-calibration
```

Deleting the report directory is also required before a subsequent run.
