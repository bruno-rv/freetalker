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

`AudioCapture.startCaptureAttempt` (`Sources/FreeTalker/Core/AudioCapture.swift:386`
at `a8446a8`) read the input format once and passed it to `installTap`:

```swift
let inputFormat = attemptInput.outputFormat(forBus: 0)
...
attemptInput.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { ... }
```

A non-nil tap format is a request to *apply* that format to the tapped output bus.
The app therefore forces a client format while the graph is still reconfiguring —
`setVoiceProcessingEnabled` and the `kAudioOutputUnitProperty_CurrentDevice` switch
both renegotiate it asynchronously — and the forced 48 kHz value is rejected
against the 16 kHz hardware input scope. (Which component picked 16 kHz, the
webcam's active mode or VPIO policy, is not established from these logs; VPIO is
allowed to expose differing hardware-input and client-output formats, so the two
scopes disagreeing is not by itself proof of a stale read.) Consequences:

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
3. **The process continues after a foreign exception unwound Swift frames.**
   `swift_task_isCurrentExecutorWithFlags` then reaches
   `SerialExecutorRef::isMainExecutor()` with an executor pointer that is not a valid
   object, and `objc_msgSend`es a low address → `SIGSEGV` at an arbitrary later moment
   (a SwiftUI timer tick, a view body, a `mouseEntered`). **This is symptom 2.**

   *Confidence:* steps 1 and 2 are proven by the logs and the code. Step 3's exact
   mechanism is **not proven** — the specific claim that a stack-allocated
   `ExecutorTrackingInfo` is stranded in thread-local storage is the best-fitting
   hypothesis, not a measurement (Objective-C exceptions do participate in native
   unwinding, so "no cleanup ran" cannot be assumed). Adjacent current-task TLS, or
   unrelated memory corrupted during the unwind, fit the same stack. What is
   established: the crash is not an ordinary isolation violation (that traps, it does
   not `objc_msgSend` through an invalid pointer), and it starts only after the
   exception. Proving the exact record requires breaking on `objc_exception_throw`,
   sampling `swift_task_getCurrent()` and the executor-tracking TLS pointer before the
   throw and again inside `-[NSApplication reportException:]`, and showing the retained
   pointer is the invalid executor used later. 07-30's "null at launch, non-null after
   the first key press" is suggestive but not sufficient: a non-null current task while
   a MainActor task runs is normal.

The event-tap callback's `MainActor.assumeIsolated`
(`Sources/FreeTalker/Core/HotKeyManager.swift:249`) is a read site, not the cause. It
performs an isolation check without establishing a task or pushing an executor-tracking
context, and it returns before capture starts — the tap callback only enqueues
`Task { @MainActor … }`, so the AVFoundation exception cannot unwind through its frame.

## The fix

| Change | Why |
|---|---|
| `installTap(format: nil)`, converter built from each buffer's own format and rebuilt when the bus renegotiates | Stops forcing a client format onto a reconfiguring graph — the exception and the silent no-op both disappear |
| `FTInstallTapCatchingException` — an Objective-C wrapper that calls `installTapOnBus:` itself, inside `@try` | A raise is contained with no Swift frame between it and the `@catch`. The engine that raised is then discarded untouched (no `stop()`, no `removeTap`) and the next attempt starts from a fresh one |
| First-buffer deadline (`starvedCaptureAction`, 2 s), counting tap callbacks per attempt before any conversion work | `MicrophoneSignalWatchdog` only ever observes buffers that *arrive*, so "the tap never fired" was invisible to it — and it must not be confused with "buffers arrived but failed to convert" |
| Unusable-audio deadline (`unusableAudioDeadline`, 2 input seconds, per attempt) | Buffers that arrive and never convert satisfy the deadline above while the journal stays empty — the same live-looking dead capture by another route |
| One decision per attempt (`resolveFault`), restart twice, then `abortForRouteFailure` | A configuration change is posted *after* the engine has stopped, so having heard audio a moment ago is no reason to ignore the fault — that path left a live-looking HUD over a dead engine. Two faults for one attempt must not each spend a restart |
| The abort finalizes like a duration cap, keeping its own reason | The healthy journal writer drains (partial audio survives), `recoveryHealth` is untouched — it was never a storage fault — and the terminal message says the microphone route died rather than "no speech was detected" |
| Per-dictation stage timings | The only way to attribute the latency on the other Mac (see below) |
| Makefile resolves `.codesign-identity` from the git common dir | Stops worktree builds silently ad-hoc signing and orphaning TCC grants |

Reviewed by Codex. Round 1 (`REVISE`) downgraded the step-3 claim above from
mechanism to hypothesis, rejected a proposed `inputFormat` vs `outputFormat` equality
gate (the two are legitimately different under VPIO, so the gate would have forced
raw-capture fallback and silently disabled noise suppression), and asked for the
containment shim. Round 2 (`REVISE`) caught that the first shim took a Swift closure —
which puts a Swift frame between the raise and the `@catch`, defeating the whole
point — that the deadline keyed off a capture-wide counter the fault report itself
incremented, so a restarted attempt could never be found starved, that a route fault
arriving *after* signal had been heard was ignored even though the engine had already
stopped, and that the `catch` called `stop()` on a graph its own contract says must
not be touched.

## Symptom 3 — "slow even for small dictations" on another Mac

Not reproducible on this machine and not part of the chain above. `docs/perf-dictation-latency-2026-07-29.md`
already measured the local pipeline: `large-v3-turbo` at RTF 0.20 (19 s for 92 s of
audio), cloud post-processing LLM 1.9–33.3 s for the identical payload, and **~19–50 s
that existing logs cannot attribute at all** because no stage duration is recorded
anywhere. On a fresh install the first run additionally pays WhisperKit model
download plus per-model ANE compilation.

Closing this needs per-stage timings captured *on the affected machine*, which the app
had no way to produce. It does now — one `notice` per dictation:

```
log show --predicate 'subsystem == "org.freetalker.app" AND category == "capture"' \
  --last 1h --info | grep 'stage timings'
stage timings: engine=WhisperKit audio=12.40s transcribe=2.61s refine=1.88s total=4.52s
```

`audio` is the recording's length, so `transcribe`/`audio` is the effective RTF on that
machine, and `total − transcribe − refine` is what remains unaccounted for. That
splits the three candidates — a slow model on slow silicon, the cloud LLM's tail, or
the still-unattributed remainder — which cannot be told apart from the outside.

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
