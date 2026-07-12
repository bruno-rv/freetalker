# Local voice profiles design

## Purpose

FreeTalker can suggest known speakers across imported recordings while keeping
all voice analysis on the Mac. Voice profiles are convenience identifiers, not
authentication. A suggestion never becomes a confirmed identity without user
approval.

The feature uses FluidAudio's offline 256-dimensional speaker embeddings after
diarization. FreeTalker adds enrollment, encrypted persistence, conservative
matching, confirmation, and profile lifecycle management.

## Consent and local-only boundary

Creating and changing a voice profile always requires an explicit user action.
FreeTalker does not create profiles after a rename or confirmation alone.

- **Remember this voice** creates a profile after the user confirms the consent
  sheet.
- **Confirm speaker** assigns a suggested profile only within that recording.
- **Improve voice profile** is a separate confirmation that adds approved
  prototypes.
- **Forget voice** permanently deletes the profile and its prototypes.

FreeTalker never sends voice embeddings to cloud STT, BYOK post-processing,
prompts, analytics, logs, crash descriptions, or exports. The feature does not
retain enrollment audio. Existing recordings continue to follow their normal,
configurable retention policy.

The consent sheet explains that voice embeddings are biometric-like data,
recognition can be wrong, recordings or imitation can fool the matcher, and the
feature must not be used for authentication.

## Voice profile model

Profiles are global across imports. Users can disable voice matching globally or
for an individual import.

Each profile stores:

- A stable profile identifier and user-chosen display name.
- The embedding model identifier, revision, and vector dimension.
- Consent, creation, and last-improved timestamps.
- Several encrypted, defensively normalized voice prototypes.
- Quality and clean-speech duration metadata for each prototype.
- A derived aggregate embedding that can be recomputed from the prototypes.

FreeTalker stores multiple prototypes instead of one average. This represents
different microphones, rooms, and speaking conditions without training a custom
classifier. The profile has a fixed prototype limit. Improvement replaces
redundant or lower-value prototypes instead of accumulating data indefinitely.

FreeTalker validates every embedding before use. A valid embedding has exactly
256 finite values and a nonzero norm. FreeTalker L2-normalizes embeddings itself
rather than depending on FluidAudio's normalization behavior. It does not use
FluidAudio's optional PLDA representation as the canonical profile format.

## Enrollment and improvement

Enrollment begins from a diarized speaker in an import:

1. The user assigns the speaker a display name.
2. The user selects **Remember this voice**.
3. FreeTalker selects only eligible speech from that speaker.
4. The user reviews and confirms the local-only consent sheet.
5. FreeTalker creates several encrypted prototypes and the derived aggregate.

Eligible speech must meet calibrated minimum duration and quality requirements.
FreeTalker excludes overlapping speech, ambiguous diarization, very short
segments, invalid embeddings, and low-quality segments. An ineligible speaker
shows a specific explanation and remains renameable without enrollment.

Confirming a suggested identity does not alter the profile. The user must select
**Improve voice profile** and confirm a separate sheet. Only eligible segments
from that confirmed speaker can contribute new prototypes. Rejecting or ignoring
the improvement leaves the profile unchanged.

## Matching and suggestions

Matching runs locally after diarization and does not block transcript creation,
speaker renaming, or export.

For every discovered speaker, FreeTalker builds a robust representation from
clean, non-overlapping embeddings. It compares that representation with
compatible global profiles using cosine distance across the aggregate and
prototypes.

A suggestion appears only when all conditions pass:

- The profile and recording use the same compatible embedding model version.
- The speaker has enough eligible clean speech.
- The best match passes the calibrated conservative acceptance threshold.
- The best match has a calibrated margin over the runner-up.
- A one-to-one assignment can map each profile to at most one speaker in the
  recording.

FreeTalker prefers false negatives over incorrect identity suggestions. When
any condition fails, the speaker remains **Unknown** or retains its automatic
speaker number.

The UI distinguishes these states:

- **Speaker 1**: No reliable suggestion exists.
- **Possibly FreeTalker contributor**: A suggestion is waiting for confirmation.
- **FreeTalker contributor**: The user confirmed the identity for this recording.

Users can confirm, reject, choose another profile, or keep a recording-only
name. Rejected matches do not update profiles. Confirmed names immediately
propagate through the transcript and plain-text, Markdown, SRT, and VTT exports.

## Storage and encryption

FreeTalker encrypts every prototype and aggregate with AES-GCM. A random
encryption key lives in macOS Keychain. The database stores ciphertext, nonce,
authentication tag, model metadata, quality metadata, and profile relationships.

The existing restrictive database permissions and SQLite secure deletion remain
defense-in-depth. Voice-profile records use foreign keys with cascading
deletion. No encryption key or plaintext vector enters the database.

If the Keychain key is missing or inaccessible, FreeTalker marks profiles
unavailable. It does not generate a replacement key, overwrite ciphertext, or
silently reenroll speakers. The user can retry Keychain access or explicitly
delete the unavailable profiles.

Deleting a profile removes encrypted prototypes and pending match records. Names
that a user already confirmed in historical transcripts remain ordinary
transcript labels. Unconfirmed suggestions linked to the deleted profile revert
to unknown.

## Model compatibility

Each profile records a fingerprint of the embedding model and preprocessing
contract. FreeTalker never compares vectors produced by incompatible model
versions.

After an incompatible model change, affected profiles show **Needs
reenrollment**. Transcription and diarization continue normally. FreeTalker does
not transform old vectors or claim compatibility without calibration evidence.

## Calibration gate

Voice suggestions remain disabled in production until a local evaluation
confirms safe defaults for the exact FluidAudio model and preprocessing path.

The calibration spike measures:

- Same-person distances across sessions, microphones, distances, and rooms.
- Different-person distances, including similar-sounding voices.
- Effects of speech duration, overlap, noise, and diarization quality.
- False-match and missed-match rates at candidate thresholds.
- Stability of the runner-up margin and one-to-one assignment.

The result defines the acceptance threshold, runner-up margin, minimum
clean-speech duration, and quality floor. FluidAudio's clustering threshold is
not accepted as an identity threshold without this evidence.

## Failure behavior

- Invalid or malformed embeddings are discarded without failing the transcript.
- Ambiguous or low-confidence results remain unknown.
- Matching cancellation stops suggestion publication and leaves diarization
  intact.
- Profile decryption failure never exposes partial plaintext or changes labels.
- Storage failure leaves the existing profile unchanged.
- Profile improvement is transactional and cannot partially replace prototypes.
- Matching can be retried after transient local model or Keychain failures.

## Delivery phases

### Phase 1: Calibration spike

- Expose and defensively normalize offline FluidAudio embeddings.
- Build a non-production, local evaluation harness.
- Collect user-approved samples under varied recording conditions.
- Measure matching behavior and publish recommended conservative parameters.
- Keep identity suggestions disabled in the app.

### Phase 2: Product feature

- Add encrypted global profile storage and Keychain key management.
- Add explicit enrollment, improvement, and deletion flows.
- Add conservative post-diarization matching and one-to-one assignment.
- Add confirmation, rejection, alternate-profile, and unknown states.
- Add global and per-import matching controls.
- Add model compatibility and reenrollment behavior.
- Propagate confirmed names to transcript views and all export formats.

## Acceptance criteria

- No profile is created without **Remember this voice** confirmation.
- Confirming a match does not improve a profile.
- Improvement occurs only after separate **Improve voice profile** confirmation.
- No enrollment audio is retained by the profile feature.
- Every stored vector is validated, normalized, and encrypted with a
  Keychain-held key.
- Voice embeddings never cross a cloud, BYOK, logging, analytics, prompt, or
  export boundary.
- Suggestions require compatible models, sufficient clean speech, an acceptance
  threshold, and a runner-up margin.
- One profile can match at most one speaker per recording.
- Uncertain speakers remain unknown and never block transcription or export.
- Forgetting a profile removes its encrypted vectors and pending suggestions.
- Confirmed transcript labels remain ordinary historical labels after deletion.
- Incompatible model upgrades require reenrollment.
- Production suggestions remain disabled until calibration establishes
  conservative thresholds.
- Enrollment, matching, improvement, deletion, migration, cancellation, Keychain
  failure, and accessibility paths have automated coverage.
