# Media Import and Diarization Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Import audio/video, transcribe with the selected WhisperKit model, separate speakers locally, rename them, and export labeled transcripts.

**Architecture:** AVFoundation writes a disk-backed 16 kHz mono job WAV, an additive timestamped Whisper adapter preserves segment timing, and a FluidAudio adapter performs offline diarization. Pure timeline join/export units remain independent of frameworks.

**Tech Stack:** AVFoundation, WhisperKit 0.18+, FluidAudio 0.12.4+, Core ML, SwiftUI.

## Global Constraints

- Supported inputs: WAV, M4A, MP3, MP4, MOV.
- Source files are never modified or deleted.
- All processing and model inference stays local.
- Diarization failure preserves the transcript.
- Renamed speakers propagate to TXT, Markdown, SRT, and VTT.

---

### Task 1: Add FluidAudio and pure transcript types

**Files:**
- Modify: `Package.swift`
- Create: `Sources/FreeTalker/Models/TimestampedTranscript.swift`
- Create: `Sources/FreeTalker/Workflows/Media/TimelineJoiner.swift`
- Create: `Sources/FreeTalker/Workflows/Media/TranscriptExporter.swift`
- Test: `Tests/FreeTalkerTests/TimelineAndExportTests.swift`

- [ ] **Step 1: Write failing tests** for temporal overlap, ties/overlap ambiguity, dynamic names, escaping, monotonic subtitle cues, and all four formats.
- [ ] **Step 2: Verify RED.**
- [ ] **Step 3: Add `.package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.12.4")` and implement pure types/functions:**

```swift
struct TranscriptSegment: Sendable { let start: TimeInterval; let end: TimeInterval; let text: String }
struct SpeakerTurn: Sendable { let speakerID: String; let start: TimeInterval; let end: TimeInterval }
struct TimelineJoiner { func join(transcript: [TranscriptSegment], speakers: [SpeakerTurn]) -> [AttributedTranscriptSegment] }
enum TranscriptFormat { case plainText, markdown, srt, vtt }
```

- [ ] **Step 4: Run focused tests GREEN and resolve dependencies.**
- [ ] **Step 5: Commit `feat: add local diarization primitives`.**

### Task 2: Decode audio/video and preserve bookmarks

**Files:**
- Create: `Sources/FreeTalker/Workflows/Media/MediaImportService.swift`
- Create: `Sources/FreeTalker/Workflows/Media/AVAudioDecoder.swift`
- Test: `Tests/FreeTalkerTests/MediaImportServiceTests.swift`
- Test assets: `Tests/FreeTalkerTests/Fixtures/tone.wav`, `two-tone.m4a`, `silent-video.mov`

- [ ] **Step 1: Add small generated fixtures and failing tests** for UTType allowlist, bookmark resolution, balanced start/stop access, disk-backed decode, cancellation cleanup, and source preservation.
- [ ] **Step 2: Verify RED.**
- [ ] **Step 3: Implement:**

```swift
struct MediaImportService { func createJob(for sourceURL: URL) async throws -> UUID }
struct AVAudioDecoder { func decode(source: URL, destination: URL, progress: @Sendable (Double) -> Void, cancellation: CancellationToken) async throws }
```

Use `AVAssetReader` and `AVAudioConverter`; never materialize the full media file in memory.
- [ ] **Step 4: Run focused tests GREEN.**
- [ ] **Step 5: Commit `feat: import local audio and video`.**

### Task 3: Timestamped Whisper and FluidAudio adapters

**Files:**
- Create: `Sources/FreeTalker/Workflows/Media/TimestampedWhisperTranscriber.swift`
- Create: `Sources/FreeTalker/Workflows/Media/FluidAudioDiarizer.swift`
- Modify: `Sources/FreeTalker/Engines/WhisperKitEngine.swift`
- Test: `Tests/FreeTalkerTests/MediaAdapterTests.swift`

- [ ] **Step 1: Write failing adapter tests** using fake Whisper results and fake diarizer, including model download progress, timestamps, cancellation, and error mapping.
- [ ] **Step 2: Verify RED.**
- [ ] **Step 3: Add an additive protocol without breaking live dictation:**

```swift
protocol TimestampedTranscribing: Sendable { func transcribeFile(at url: URL, language: String?, model: String) async throws -> [TranscriptSegment] }
protocol SpeakerDiarizing: Sendable { func diarizeFile(at url: URL, progress: @Sendable (Double) -> Void) async throws -> [SpeakerTurn] }
```

FluidAudio adapter owns `OfflineDiarizerManager` task-locally and uses its disk-backed API.
- [ ] **Step 4: Run focused tests and release build GREEN.**
- [ ] **Step 5: Commit `feat: add offline speaker diarization`.**

### Task 4: Media job pipeline and persistence

**Files:**
- Create: `Sources/FreeTalker/Workflows/Media/MediaImportPipeline.swift`
- Modify: `Sources/FreeTalker/Storage/TranscriptionJobStore.swift`
- Test: `Tests/FreeTalkerTests/MediaImportPipelineTests.swift`

- [ ] **Step 1: Write failing stage tests** for decode/transcribe/diarize/finalize progress, resume, cancellation, transcript preservation on diarization failure, exact derived-file deletion, and source non-deletion.
- [ ] **Step 2: Verify RED.**
- [ ] **Step 3: Implement pipeline through `LocalJobRunner`; persist segments and speaker turns transactionally; resolve names only at read/export time.**
- [ ] **Step 4: Run focused tests GREEN.**
- [ ] **Step 5: Commit `feat: process imported media locally`.**

### Task 5: Imports UI, speaker naming, and exports

**Files:**
- Modify: `Sources/FreeTalker/UI/LibraryView.swift`
- Create: `Sources/FreeTalker/UI/ImportsView.swift`
- Create: `Sources/FreeTalker/UI/ImportDetailView.swift`
- Create: `Sources/FreeTalker/UI/SpeakerRenameView.swift`
- Modify: `Sources/FreeTalker/App.swift`
- Modify: `README.md`
- Test: `Tests/FreeTalkerTests/MediaImportPresentationTests.swift`

- [ ] **Step 1: Write failing presentation tests** for drop validation, per-stage progress, retry/cancel/delete eligibility, speaker rename propagation, export availability, and local-only copy.
- [ ] **Step 2: Verify RED.**
- [ ] **Step 3: Add picker/drop UI, progress rows, detail transcript, rename sheet, export panel, and on-demand diarization model progress.**
- [ ] **Step 4: Run `swift test && make app && git diff --check`; manually import one audio and one video fixture.**
- [ ] **Step 5: Commit `feat: ship media import and speaker separation`.**

