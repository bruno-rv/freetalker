# Zero-audio dictation + crash-on-record — 2026-07-31

Two reported symptoms, one root cause. Reproduced on `/Applications/FreeTalker.app`
(app_version `50867f1`, i.e. current `main`), device = HD Webcam C615, voice
processing (noise suppression) enabled.

## Evidence

Unified log, first instance (pid 76360), single F13 press at 11:22:48.969:

```
11:22:49.168 [avae] Format mismatch: input hw <1 ch, 16000 Hz, Float32>, client format <1 ch, 48000 Hz, Float32>
11:22:49.168 [avae] Failed to create tap, config change pending!          <-- non-fatal: NO TAP INSTALLED
11:22:49.171 [avae] Engine@0x1064507d0: start, was running 0
11:22:49.271 [avae] Engine@0x1064507d0: iounit configuration changed > posting notification
11:22:49.271 [avae] Engine@0x1064507d0: stop, was running 1               <-- configuration observer restarts capture
11:22:49.276 [avae] Format mismatch: input hw <1 ch, 16000 Hz>, client format <1 ch, 48000 Hz>
11:22:49.283 [AppKit] Failed to create tap due to format mismatch, <AVAudioFormat 1 ch, 48000 Hz, Float32>
11:22:49.293 [HIExceptions] FAULT: com.apple.coreaudio.avfaudio           <-- ObjC exception raised + caught by AppKit
11:22:50.100 kernel: FreeTalker[76360] Corpse allowed 1 of 5
```

Second instance (pid 41431), second F13 press at 11:22:58.558: byte-identical
sequence, including `Voice isolation DSP is available for client ... org.freetalker.app`
just before the mismatch.

Both instances died `EXC_BAD_ACCESS` (`SIGSEGV`) with the same stack shape
(`/tmp/ft-evidence-2026-07-31/*.ips`, also 07-30's reports):

```
objc_msgSend / objc_opt_class            <- KERN_INVALID_ADDRESS at 0x60 / 0x1e
swift_getObjectType
swift_task_isMainExecutorImpl
swift::SerialExecutorRef::isMainExecutor() const
swift_task_isCurrentExecutorWithFlagsImpl
<any MainActor isolation check>          <- GeneralSettingsView 1 s timer tick; DesignLibrary HStack.init
```

Persisted state, same window:

| Artifact | Value |
|---|---|
| `capture_sessions.state` | `damaged`, `failure_message = "Interrupted capture has no committed audio"` |
| session WAV | 42 bytes — header only, zero audio frames |
| `transcription_jobs` | `kind=recovery`, `state=failed`, `progress=0.0`, `failure_stage=preparing` |
| `key down: micAuthorizationStatus` | `3` (`.authorized`) — mic TCC was **not** the problem |

Every `recovery` job in `jobs.db` since 07-30 18:57 has the identical
`preparing` / progress `0.0` signature.

## Root cause

`AudioCapture.startCaptureAttempt` (`Sources/FreeTalker/Core/AudioCapture.swift:386`)
reads the input format once and passes it to `installTap`:

```swift
let inputFormat = attemptInput.outputFormat(forBus: 0)
...
attemptInput.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { ... }
```

With voice processing enabled, the VPIO unit renegotiates the input bus to 16 kHz
asynchronously. `outputFormat(forBus:)` still reports the pre-negotiation
48 kHz, so the format handed to `installTap` does not match the hardware format:

1. **First call → silent no-op.** AVAudioEngine logs `Failed to create tap, config
   change pending!` and installs nothing. `engine.start()` then succeeds, so the app
   believes it is recording — but no tap callback ever fires. Zero frames reach the
   journal, hence the 42-byte WAV, the `damaged` session, and the recovery job stuck
   at `preparing` / progress `0.0`. **This is symptom 1.**
2. **Second call (from the configuration-change observer) → ObjC exception.** Same
   mismatch, but not during a pending config change, so AVAudioEngine raises
   `NSInternalInconsistencyException` ("Failed to create tap due to format
   mismatch"). AppKit catches it at the run-loop boundary and the process keeps
   running.
3. **The exception unwinds Swift frames without running their cleanup.** The main
   thread's `ExecutorTrackingInfo` (stack-allocated, pushed/popped by the MainActor
   executor around each job) is left dangling in thread-local storage. From that
   moment every MainActor isolation check calls
   `swift_task_isCurrentExecutorWithFlags`, which dereferences the stale record's
   active executor and does `objc_msgSend` on freed stack memory → `SIGSEGV` at an
   arbitrary later moment (a SwiftUI timer tick, a view body, a `mouseEntered`).
   **This is symptom 2**, and it explains 07-30's findings verbatim: `swift_task_getCurrent()`
   null at launch, non-null after the first key press, crash sites unrelated to each other.

The event-tap callback's `MainActor.assumeIsolated`
(`Sources/FreeTalker/Core/HotKeyManager.swift:249`) is where the corrupted TLS was
first observed, not where it is created; it is a read site like every other
isolation check.

## Symptom 3 — "slow even for small dictations" on another Mac

Not reproducible on this machine and not part of the chain above. `docs/perf-dictation-latency-2026-07-29.md`
already measured the local pipeline: `large-v3-turbo` at RTF 0.20 (19 s for 92 s of
audio), cloud post-processing LLM 1.9–33.3 s for the identical payload, and **~19–50 s
that existing logs cannot attribute at all** because no stage duration is recorded
anywhere. On a fresh install the first run additionally pays WhisperKit model
download plus per-model ANE compilation.

Closing this needs per-stage timings captured *on the affected machine*, which the
app does not currently emit.

## Non-issue found on the way

`/Applications/FreeTalker.app` is **ad-hoc signed** (`Signature=adhoc`,
`TeamIdentifier=not set`) even though `/Users/bruno/Dev/freetalker/.codesign-identity`
says `FreeTalker Dev`. That file is gitignored, and 4 of 6 worktrees do not have it,
so a `make app` run from one of those silently ad-hoc signs and orphans the
Accessibility/Input-Monitoring grants. It did **not** cause the zero-audio bug (mic
status was `.authorized`), but it is why hotkey grants keep evaporating after a
rebuild.

Also observed: `GeneralSettingsView`'s 1 s refresh timer
(`Sources/FreeTalker/UI/SettingsView.swift:358`) issues 3 `TCCAccessRequest` IPCs per
tick for as long as the Settings window stays open (45 min continuous in this
session's log). Wasteful, not a latency cause.

## Evidence bundle

`/tmp/ft-evidence-2026-07-31/` — both `.ips` reports, both failed-dictation
directories (incl. the 42-byte WAV), and a `jobs.db` snapshot.
