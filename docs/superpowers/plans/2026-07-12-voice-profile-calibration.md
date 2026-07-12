# Voice profile calibration implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> superpowers:subagent-driven-development (recommended) or
> superpowers:executing-plans to implement this plan task-by-task. Steps use
> checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a local, non-production calibration harness that measures
FluidAudio speaker-embedding behavior and produces evidence for conservative
voice-profile matching parameters.

**Architecture:** Add a Foundation-only `VoiceProfileCore` target for validated
embeddings, matching, assignment, and metrics. Add a `VoiceProfileFluidAudio`
target so the app and calibration executable use the same offline extraction
code. Extend the existing adapter without persisting or using representations in
the app. The calibration executable consumes an explicit consent manifest and
writes aggregate reports without copying audio or enabling production identity
suggestions.

**Tech stack:** Swift 6.2, Swift Testing, Foundation, FluidAudio 0.15.5,
ArgumentParser-free command-line parsing, JSON and Markdown reports.

## Global constraints

- All samples, embeddings, matching, metrics, and reports remain local.
- Never commit calibration audio, manifests containing real paths, raw
  embeddings, or identifiable participant names.
- Use user-approved pseudonymous participant IDs in calibration manifests and
  reports.
- Do not retain or copy input audio; read it from the explicit manifest path.
- Validate exactly 256 finite values, reject near-zero vectors, and L2-normalize
  every embedding in FreeTalker code.
- Do not use FluidAudio's `rho128` value or its `0.65` clustering threshold as an
  identity representation or acceptance threshold.
- Do not add profile persistence, Keychain storage, identity UI, or production
  suggestions in this plan.
- Keep production matching disabled until a human approves the calibration
  report and a separate product implementation plan records exact constants and
  the model fingerprint.
- Preserve existing diarization behavior, cancellation semantics, local-only
  guarantees, and the signed app build.

---

### Task 1: Add validated voice-embedding primitives

**Files:**

- Modify: `Package.swift`
- Create: `Sources/VoiceProfileCore/VoiceEmbedding.swift`
- Create: `Sources/VoiceProfileCore/EmbeddingModelFingerprint.swift`
- Create: `Sources/VoiceProfileCore/SpeakerRepresentation.swift`
- Create: `Tests/VoiceProfileCoreTests/VoiceEmbeddingTests.swift`

**Interfaces:**

- Consumes: Plain `[Float]` model output and model metadata.
- Produces: `VoiceEmbedding`, `EmbeddingModelFingerprint`,
  `SpeakerEmbeddingSample`, and `SpeakerRepresentation` for all later tasks.

- [ ] **Step 1: Add the core target and failing normalization tests**

Add `VoiceProfileCore` as a library product, make `FreeTalker` depend on it, and
add a dedicated `VoiceProfileCoreTests` target:

```swift
.library(name: "VoiceProfileCore", targets: ["VoiceProfileCore"]),
.target(name: "VoiceProfileCore"),
.testTarget(
    name: "VoiceProfileCoreTests",
    dependencies: ["VoiceProfileCore"]
)
```

Write tests that require:

```swift
@Test func validatesAndNormalizesExactly256FiniteValues() throws {
    var raw = Array(repeating: Float(0), count: 256)
    raw[0] = 3
    raw[1] = 4
    let embedding = try VoiceEmbedding(validating: raw)
    #expect(abs(embedding.values[0] - 0.6) < 0.000_001)
    #expect(abs(embedding.values[1] - 0.8) < 0.000_001)
}

@Test(arguments: [255, 257])
func rejectsWrongDimensions(_ count: Int) {
    #expect(throws: VoiceEmbeddingError.invalidDimension(count)) {
        try VoiceEmbedding(validating: Array(repeating: 1, count: count))
    }
}
```

Also test NaN, positive and negative infinity, all-zero vectors, values whose
norm is below `1e-12`, equality, and stable `Float32` values.

- [ ] **Step 2: Run the focused tests and verify RED**

Run:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --filter VoiceEmbeddingTests
```

Expected: compilation fails because `VoiceEmbedding` and related types do not
exist.

- [ ] **Step 3: Implement the minimal validated value types**

Define the public core boundary:

```swift
public enum VoiceEmbeddingError: Error, Equatable, Sendable {
    case invalidDimension(Int)
    case nonFiniteValue(index: Int)
    case zeroNorm
}

public struct VoiceEmbedding: Equatable, Sendable {
    public static let dimension = 256
    public let values: [Float]

    public init(validating raw: [Float]) throws
    public func cosineDistance(to other: VoiceEmbedding) -> Double
}

public struct EmbeddingModelFingerprint: Codable, Equatable, Hashable, Sendable {
    public let provider: String
    public let modelID: String
    public let modelRevision: String
    public let preprocessingRevision: String
    public let dimension: Int
}

public struct SpeakerEmbeddingSample: Equatable, Sendable {
    public let embedding: VoiceEmbedding
    public let start: TimeInterval
    public let end: TimeInterval
    public let quality: Double?
}

public struct SpeakerRepresentation: Equatable, Sendable {
    public let speakerID: String
    public let samples: [SpeakerEmbeddingSample]
    public let cleanSpeechSeconds: TimeInterval
}
```

Compute the norm in `Double`, reject a squared norm below `1e-24`, normalize
once, and clamp cosine similarity to `-1...1` before returning `1 - similarity`.

- [ ] **Step 4: Run focused and package tests**

Run:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --filter VoiceEmbeddingTests
make test
```

Expected: the focused suite and all existing suites pass.

- [ ] **Step 5: Commit the core types**

```bash
git add Package.swift Sources/VoiceProfileCore Tests/VoiceProfileCoreTests
git commit -m "feat: add validated voice embeddings"
```

---

### Task 2: Expose offline FluidAudio speaker representations

**Files:**

- Modify: `Package.swift`
- Modify: `Sources/FreeTalker/Workflows/Media/FluidAudioDiarizer.swift`
- Modify: `Sources/FreeTalker/Workflows/Media/MediaImportPipeline.swift`
- Create:
  `Sources/VoiceProfileFluidAudio/OfflineSpeakerRepresentationExtractor.swift`
- Create:
  `Tests/VoiceProfileFluidAudioTests/OfflineSpeakerRepresentationExtractorTests.swift`
- Modify: `Tests/FreeTalkerTests/MediaAdapterTests.swift`
- Test: `Tests/FreeTalkerTests/MediaImportPipelineTests.swift`

**Interfaces:**

- Consumes: `VoiceEmbedding`, `SpeakerEmbeddingSample`, and
  `EmbeddingModelFingerprint` from Task 1.
- Produces: A shared `OfflineSpeakerRepresentationExtractor` and
  `SpeakerDiarizationResult` from `SpeakerDiarizing` while the media pipeline
  continues to persist only its `turns` field during calibration.

- [ ] **Step 1: Write failing adapter-boundary tests**

Replace fake backend results with this explicit boundary:

```swift
struct RawSpeakerRepresentation: Sendable, Equatable {
    let speakerID: String
    let samples: [RawSpeakerEmbeddingSample]
}

struct RawSpeakerEmbeddingSample: Sendable, Equatable {
    let values: [Float]
    let start: TimeInterval
    let end: TimeInterval
    let quality: Double?
}

struct SpeakerDiarizationResult: Sendable, Equatable {
    let turns: [SpeakerTurn]
    let speakers: [SpeakerRepresentation]
    let fingerprint: EmbeddingModelFingerprint
}
```

Tests must prove that the adapter:

- Preserves existing turn ordering and validation.
- Groups valid chunk embeddings by the final cluster-aligned speaker ID.
- Defensively normalizes raw vectors.
- Rejects only malformed representation samples while preserving valid turns.
- Produces deterministic speaker and sample ordering.
- Computes clean duration from the union of sample intervals, not their sum.
- Preserves cancellation and suppresses post-cancel publication.
- Returns a stable, nonempty fingerprint for the pinned model path.

- [ ] **Step 2: Run focused tests and verify RED**

Run:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --filter MediaAdapterTests
```

Expected: compilation fails because `SpeakerDiarizationResult` and raw
representation types are missing.

- [ ] **Step 3: Configure FluidAudio and map its public result**

Add a shared target that both the app and calibration executable can import:

```swift
.target(
    name: "VoiceProfileFluidAudio",
    dependencies: [
        "VoiceProfileCore",
        .product(name: "FluidAudio", package: "FluidAudio")
    ]
),
.testTarget(
    name: "VoiceProfileFluidAudioTests",
    dependencies: ["VoiceProfileFluidAudio"]
)
```

Make `FreeTalker` depend on `VoiceProfileFluidAudio`. Define the shared extractor:

```swift
public struct OfflineVoiceRepresentationResult: Sendable, Equatable {
    public let turns: [OfflineSpeakerTurn]
    public let speakers: [SpeakerRepresentation]
    public let fingerprint: EmbeddingModelFingerprint
}

public struct OfflineSpeakerRepresentationExtractor: Sendable {
    public init(modelsDirectory: URL)
    public func process(
        _ url: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> OfflineVoiceRepresentationResult
}
```

Change the protocols to return the richer result:

```swift
protocol SpeakerDiarizing: Sendable {
    func diarizeFile(
        at url: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> SpeakerDiarizationResult
}

protocol SpeakerDiarizationBackend: Sendable {
    func diarizeFile(
        at url: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> RawSpeakerDiarizationResult
}
```

Inside the shared extractor, construct the offline manager with chunk exposure
enabled:

```swift
let config = OfflineDiarizerConfig(exposeChunkEmbeddings: true)
let manager = OfflineDiarizerManager(config: config)
```

Map `result.segments` to turns and `result.chunkEmbeddings` to cluster-aligned
samples using `embedding256`. Do not use `rho128`. Treat unavailable chunk
embeddings as an empty representation list, not a diarization failure. Document
the exact FluidAudio model and preprocessing identifiers used in the fingerprint.
Keep model preparation coordinated per cache directory and preserve the existing
drain-before-cancellation behavior. The FreeTalker backend delegates to this
extractor instead of maintaining a second mapping implementation.

- [ ] **Step 4: Preserve current app behavior explicitly**

Update `MediaImportPipeline` to use:

```swift
let diarization = try await diarizer.diarizeFile(at: decodedURL, progress: sink)
try await store.persistSpeakerTurns(
    jobID: job.id,
    owner: owner,
    turns: diarization.turns,
    progress: 0.75
)
```

Do not persist `speakers` or `fingerprint` in this calibration plan. Add a
pipeline regression proving no new identity or embedding rows exist and imports
behave exactly as before.

- [ ] **Step 5: Run focused, full, and release verification**

Run:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --filter 'MediaAdapterTests|MediaImportPipelineTests'
make test
make app
git diff --check
```

Expected: all tests pass, the app builds and signs, and the diff check is clean.

- [ ] **Step 6: Commit the richer adapter boundary**

```bash
git add Package.swift Sources/VoiceProfileFluidAudio \
  Tests/VoiceProfileFluidAudioTests Sources/FreeTalker/Workflows/Media \
  Tests/FreeTalkerTests/MediaAdapterTests.swift \
  Tests/FreeTalkerTests/MediaImportPipelineTests.swift
git commit -m "feat: expose local speaker representations"
```

---

### Task 3: Add deterministic matching and calibration metrics

**Files:**

- Create: `Sources/VoiceProfileCore/VoiceProfileMatcher.swift`
- Create: `Sources/VoiceProfileCore/CalibrationMetrics.swift`
- Create: `Tests/VoiceProfileCoreTests/VoiceProfileMatcherTests.swift`
- Create: `Tests/VoiceProfileCoreTests/CalibrationMetricsTests.swift`

**Interfaces:**

- Consumes: Validated embeddings and speaker representations from Task 1.
- Produces: Candidate-distance matrices, deterministic one-to-one assignments,
  and threshold evaluation summaries for the executable in Task 4.

- [ ] **Step 1: Write failing cosine and assignment tests**

Define tests around these core types:

```swift
public struct EnrollmentPrototype: Equatable, Sendable {
    public let participantID: String
    public let embedding: VoiceEmbedding
}

public struct SpeakerMatchCandidate: Equatable, Sendable {
    public let speakerID: String
    public let participantID: String
    public let distance: Double
    public let runnerUpMargin: Double
}

public struct MatchingParameters: Codable, Equatable, Sendable {
    public let maximumDistance: Double
    public let minimumRunnerUpMargin: Double
    public let minimumCleanSpeechSeconds: Double
}
```

Test exact-match acceptance, threshold rejection, runner-up ambiguity, model
compatibility rejection, insufficient duration, stable tie-breaking, input-order
independence, and a global assignment where greedy row-by-row matching would map
two speakers to one participant.

- [ ] **Step 2: Write failing metric tests**

Require:

```swift
public struct LabeledDistance: Codable, Equatable, Sendable {
    public let expectedSamePerson: Bool
    public let distance: Double
    public let cleanSpeechSeconds: Double
    public let quality: Double?
}

public struct ThresholdMetrics: Codable, Equatable, Sendable {
    public let threshold: Double
    public let falseMatchCount: Int
    public let missedMatchCount: Int
    public let trueMatchCount: Int
    public let trueRejectCount: Int
}
```

Test threshold equality boundaries, empty cohorts, deterministic sorting, duration
bins, division-by-zero-safe rates, and JSON round trips.

- [ ] **Step 3: Run core tests and verify RED**

Run:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --filter 'VoiceProfileMatcherTests|CalibrationMetricsTests'
```

Expected: compilation fails because matcher and metric types do not exist.

- [ ] **Step 4: Implement deterministic minimum-cost assignment**

Implement a polynomial-time minimum-cost bipartite assignment with explicit
unknown dummy nodes:

```swift
public struct VoiceProfileMatcher: Sendable {
    public init(parameters: MatchingParameters)
    public func candidates(
        speakers: [SpeakerRepresentation],
        prototypes: [EnrollmentPrototype]
    ) -> [SpeakerMatchCandidate]
}
```

Group prototypes by participant, score a speaker against every participant, and
solve the complete cost matrix while allowing unknown speakers. Apply duration,
maximum-distance, and runner-up-margin rules after computing the matrix. Break
exact ties by stable participant and speaker IDs. Keep this implementation
Foundation-only, reject non-finite parameters, and cover rectangular matrices,
empty sides, and more speakers than profiles. Do not use factorial enumeration;
the same core must remain safe when the eventual product has many global profiles.

- [ ] **Step 5: Implement threshold metrics**

Add pure functions that evaluate an explicit threshold grid and produce counts
and rates. The report layer must be able to ask for thresholds from `0.00` through
`1.00` in `0.01` increments without hidden defaults.

- [ ] **Step 6: Run core and full tests**

Run:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --filter VoiceProfileCoreTests
make test
```

Expected: all core tests and the full app suite pass.

- [ ] **Step 7: Commit matching and metrics**

```bash
git add Sources/VoiceProfileCore Tests/VoiceProfileCoreTests
git commit -m "feat: add voice calibration metrics"
```

---

### Task 4: Build the consent-manifest calibration executable

**Files:**

- Modify: `Package.swift`
- Modify: `Makefile`
- Create: `Sources/VoiceProfileCalibration/main.swift`
- Create: `Sources/VoiceProfileCalibration/CalibrationManifest.swift`
- Create: `Sources/VoiceProfileCalibration/CalibrationRunner.swift`
- Create: `Sources/VoiceProfileCalibration/CalibrationReport.swift`
- Create: `Tests/VoiceProfileCalibrationTests/CalibrationManifestTests.swift`
- Create: `Tests/VoiceProfileCalibrationTests/CalibrationRunnerTests.swift`
- Create: `docs/voice-profile-calibration.md`
- Modify: `.gitignore`

**Interfaces:**

- Consumes: FluidAudio representations from Task 2 and core metrics from Task 3.
- Produces: Deterministic aggregate JSON and Markdown reports containing no raw
  embeddings, audio, real names, or source paths.

- [ ] **Step 1: Add failing manifest-validation tests**

Use this versioned manifest contract:

```swift
struct CalibrationManifest: Codable, Equatable, Sendable {
    let version: Int
    let samples: [CalibrationSample]
}

struct CalibrationSample: Codable, Equatable, Sendable {
    let sampleID: String
    let participantID: String
    let sessionID: String
    let mediaPath: String
    let microphone: String
    let environment: String
    let expectedSpeakerID: String
    let consentConfirmed: Bool
}
```

Reject versions other than `1`, duplicate IDs, blank pseudonyms, relative paths,
missing files, `consentConfirmed == false`, and manifests with fewer than two
participants or fewer than two sessions for each participant. Error descriptions
must contain IDs only, never media paths.

- [ ] **Step 2: Add failing report-privacy and determinism tests**

Inject a fake representation extractor and assert that reports contain:

- The model fingerprint and aggregate cohort counts.
- Same-person and different-person distance distributions.
- Duration and available-quality bins.
- Explicit threshold-grid metrics and runner-up-margin observations.
- Warnings for insufficient cohorts and rejected samples.

Assert that JSON and Markdown contain no media path, raw embedding value,
microphone serial number, or source participant name. Run the same shuffled input
twice and require byte-identical JSON.

- [ ] **Step 3: Run calibration tests and verify RED**

Run:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --filter VoiceProfileCalibrationTests
```

Expected: compilation fails because the calibration target and manifest types do
not exist.

- [ ] **Step 4: Add the non-bundled executable and tests**

Add:

```swift
.executable(name: "VoiceProfileCalibration", targets: ["VoiceProfileCalibration"])
```

The target depends on `VoiceProfileCore` and `VoiceProfileFluidAudio`. It imports
the shared extractor from Task 2 and does not implement a second FluidAudio path.
It is a SwiftPM tool only; do not copy it into `FreeTalker.app`.

Parse exactly these arguments without adding a dependency:

```text
VoiceProfileCalibration --manifest /absolute/manifest.json \
  --output-directory /absolute/report-directory
```

Reject missing, duplicate, or unknown arguments. Create reports atomically with
mode `0600`. Do not create a cache of source audio or embeddings.

- [ ] **Step 5: Implement local extraction and aggregate-only reports**

For each manifest sample, run the same richer FluidAudio adapter configuration
from Task 2. Select `expectedSpeakerID`, validate its representation, and keep
vectors in memory only for the duration of the run. Build enrollment prototypes
from a different session than each query sample so the report never evaluates a
sample against itself.

Before writing, reduce all data to counts, quantiles, threshold metrics, and model
metadata. Explicitly clear large in-memory arrays when a sample and the final
report calculation finish. Never serialize a vector.

- [ ] **Step 6: Add the Make target, ignore rules, and operator guide**

Add:

```make
.PHONY: calibrate-voice-profiles

calibrate-voice-profiles: test-preflight
	@test -n "$(MANIFEST)" || \
		( echo "error: MANIFEST=/absolute/path.json is required" >&2; exit 1 )
	DEVELOPER_DIR="$(XCODE_DEVELOPER_DIR)" swift run VoiceProfileCalibration \
		--manifest "$(MANIFEST)" \
		--output-directory ".codex/sdd/reports/voice-profile-calibration"
```

Ignore `calibration-data/` and generated calibration report directories. The
guide must explain consent, pseudonyms, minimum cohort shape, local-only handling,
how to run the tool, report limitations, and how to delete samples and reports.

- [ ] **Step 7: Run focused, full, privacy, and bundle verification**

Run:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --filter VoiceProfileCalibrationTests
make test
make app
codesign --verify --deep --strict FreeTalker.app
git diff --check
```

Inspect the assembled bundle:

```bash
test ! -e FreeTalker.app/Contents/MacOS/VoiceProfileCalibration
```

Expected: tests pass, the signed app excludes the tool, and no calibration data
or report is staged.

- [ ] **Step 8: Commit the calibration tool**

```bash
git add Package.swift Makefile .gitignore Sources/VoiceProfileCalibration \
  Tests/VoiceProfileCalibrationTests docs/voice-profile-calibration.md
git commit -m "feat: add local voice calibration harness"
```

---

### Task 5: Run the calibration gate and record the decision

**Files:**

- Runtime input outside Git: `/absolute/path/to/consented-manifest.json`
- Generated and ignored:
  `.codex/sdd/reports/voice-profile-calibration/`
- Create after human approval:
  `docs/superpowers/specs/2026-07-12-voice-profile-calibration-decision.md`

**Interfaces:**

- Consumes: The harness from Task 4 and user-approved local samples.
- Produces: A committed human decision with exact approved parameters or a
  committed decision to stop without enabling production matching.

- [ ] **Step 1: Validate consent and cohort shape before execution**

Confirm that every sample has explicit participant consent, uses a pseudonymous
ID, exists outside Git, and includes no speech that the participant did not agree
to use. Stop if any requirement fails.

- [ ] **Step 2: Run calibration twice for determinism**

Run:

```bash
make calibrate-voice-profiles MANIFEST=/absolute/path/to/consented-manifest.json
```

Move the first aggregate report outside the output directory, rerun the command,
and compare JSON with `cmp`. Expected: byte-identical aggregate reports for the
same tool, model fingerprint, manifest, and files.

- [ ] **Step 3: Review false matches before missed matches**

Reject the production phase if no parameter set demonstrates an acceptably
conservative false-match result across participants, sessions, and environments.
Do not choose a threshold solely because it minimizes total error.

- [ ] **Step 4: Write the exact decision document**

If approved, record exact values for:

- Model and preprocessing fingerprint.
- Maximum cosine distance.
- Minimum runner-up margin.
- Minimum clean-speech duration.
- Available quality floor or an explicit decision not to use quality.
- Maximum prototype count.
- Cohort size, sessions, environments, and measured limitations.

If rejected, record why the evidence is insufficient and keep production matching
disabled. Do not include participant IDs, media paths, raw embeddings, or audio.

- [ ] **Step 5: Self-review and commit only the aggregate decision**

Verify no sample, manifest, generated report, path, or raw vector is staged:

```bash
git status --short
git diff --cached --check
```

Then commit:

```bash
git add docs/superpowers/specs/2026-07-12-voice-profile-calibration-decision.md
git commit -m "docs: record voice profile calibration decision"
```

The production implementation plan is written only after this decision is
approved, using its exact fingerprint and constants. Until then, FreeTalker has
no production voice-profile storage, matching, or identity UI.
