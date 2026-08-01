# Duck system output while dictating — design, 2026-08-01

Music playing through the speakers keeps playing while you dictate. It bleeds into the microphone
and it competes with your own voice for your attention. FreeTalker should drop the system output
volume for the duration of a recording and put it back afterwards.

## Decisions

| Question | Answer | Why |
|---|---|---|
| Pause playback or lower volume? | **Lower volume** | Pause means the system play/pause media key, which is a blind toggle — guess wrong about what was playing and you *start* audio that wasn't. Volume is exact and always reversible. |
| How far down? | **10% of the current volume** (−20 dB) | Full mute leaves a silent Mac with no visible cause if it ever gets stuck. Ducked-and-stuck is audible and one volume-key press fixes it. |
| Absolute 0.10 or relative? | **Relative** (`original * 0.10`) | An absolute floor would make it *louder* for anyone already below 10%. |
| Skip when headphones are connected? | **No, always duck** | One code path, always matches what was asked. Transport-type classification is a guess anyway — a USB DAC feeding desk speakers looks identical to a USB headset. |
| Settings toggle? | **No** | Requested as behaviour, not as a preference. |
| Persist restoration across launches? | **No** | See "Ownership and recovery" — every in-process path is covered instead, which is where the real exposure was. |

## Feasibility, verified on the target machine

```
default output device id=74  name=MacBook Pro Speakers  uid=BuiltInSpeakerDevice  transport=bltn
  VolumeScalar element=0: has=true settable=true value=0.43749997
  VolumeScalar element=1/2: has=false
  Mute        element=0: has=true settable=true value=0.0
```

`kAudioDevicePropertyVolumeScalar` on the main element is present and settable, so the approach
works here. It is not universal: HDMI/DisplayPort outputs and some aggregate devices expose no
settable software volume, and some USB DACs expose per-channel elements (1, 2) but no main element.
The implementation tries main first, falls back to channels 1 and 2, and degrades to doing nothing.

## Component

`Sources/FreeTalker/Core/OutputAudioDucker.swift` — one class owning a restoration ledger.

```
duck()     resolve the default output device, then for each controllable element:
             read original -> append to ledger -> write original * 0.10 -> read back -> record
restore()  drain the ledger: for each entry still owned, write the original back
```

The unit of state is a **ledger entry**, not a single saved value:

```
DuckedElement { deviceUID: String, element: UInt32, original: Float, readback: Float? }
```

Policy lives in `nonisolated static` helpers so it is testable without a sound card, matching the
shape already used for `AppCoordinator.decoderBiasVocabulary` and
`WhisperKitEngine.predeterminedLanguage`:

- `duckTarget(original:)` → `original * 0.10`
- `shouldRestore(entry:current:tolerance:)` → whether this element is still ours to restore

CoreAudio access follows the existing idiom in `Core/AudioInputDevices.swift`
(`AudioObjectPropertyAddress` + `AudioObjectGetPropertyData`), and reuses its `stringProperty`
helper for the device UID.

## Ownership and recovery

The governing rule: **never mutate a volume that is not already recorded in the ledger, and never
drop a ledger entry that has not been successfully restored.** Everything below follows from it.

**Record before you write.** Read the original, append the entry, *then* write. The reverse order —
the obvious one — loses the original if the process dies or the read-back fails between write and
save, and there is then nothing to undo with.

**Read-back is a refinement, not a precondition.** After writing, read the value back and store it
so `restore()` can tell "still what we set" from "the user changed it". If the read-back itself
fails, the entry keeps `readback: nil` and restore treats it as unconditionally ours — we know we
wrote it, we just cannot verify it later. Failing to read is not a reason to abandon a mutation we
made.

**Partial duck rolls back.** With the channel-1/2 fallback, `duck()` performs more than one write.
If any element fails after another has succeeded, restore the ones that succeeded and abandon the
attempt: half-ducked stereo is worse than not ducking.

**Restore keeps what it could not finish.** An entry is removed from the ledger only after its write
succeeds. If the device is absent — display asleep, headphones unplugged — the entry stays and is
retried on the next `duck()`, the next `stop()`, and at termination. Without this, a device that
disappears mid-recording and reappears later comes back at 10% with the only record of its original
already discarded. Device volume is persistent hardware state; forgetting it is not free.

**Restore runs on termination.** `App.swift:230`'s Quit button calls `NSApplication.shared.terminate`
directly, with no capture teardown, so quitting mid-dictation would otherwise leave the volume down.
An `applicationWillTerminate` hook drains the ledger synchronously. This is in-process only — it
does not make the design persist anything across launches.

**One lock, whole transition.** `AudioCapture` is `@unchecked Sendable` and calls in from several
threads. The ledger's check-record-write and check-write-drop sequences are each taken under a
single `NSLock` that also covers the CoreAudio calls, so two concurrent `duck()` calls cannot both
observe an empty ledger and compound the attenuation. Sequential duplicate-call tests cannot catch
this; the isolation has to be stated, not inferred.

## Where it hooks

Inside `AudioCapture.start()` (Core/AudioCapture.swift:486) and `AudioCapture.stop()` (:713), not at
the call sites. `start()` has 2 callers and `stop()` has 8; one guard in the shared function beats
eight guards in callers, and every recording path — dictation, voice-edit instruction capture,
hands-free, cancel — is covered without touching any of them.

Two placement details that decide whether it actually holds:

- `start()` restores before rethrowing, so a failed capture never leaves the volume down.
- `stop()` calls `restore()` **outside** the `wasCapturing` branch. `restartAfterCorroboratedFault`
  sets `isCapturing = false` before propagating a restart failure, and the failure teardown then
  calls `stop()` — with `wasCapturing == false`. Put the restore inside that branch and the exact
  restart-failure path this design is supposed to survive leaves the output ducked.

Live-preview ticks are not a concern: they read from the existing capture buffer
(`snapshotSuffix`) and never call `start()`/`stop()`.

## Error handling

Every CoreAudio call can fail and none of them are fatal. Failures never block or delay a recording.
If no element on the device has a settable volume, `duck()` records nothing and `restore()` has
nothing to drain. One `notice`-level log line per transition (`ducked BuiltInSpeakerDevice 0.44 ->
0.04`, `restored BuiltInSpeakerDevice 0.44`, `restore deferred, device absent`), consistent with the
diagnostics convention in `docs/perf-decoder-prompt-2026-08-01.md`.

## Testing

A fake volume device behind a small protocol, so the whole state machine runs without hardware:

- duck then restore returns the original value
- the target is relative to the starting volume, not an absolute floor
- a second duck while ducked does not overwrite the saved original
- a second restore is a no-op
- a volume the user changed mid-recording is left alone
- read-back failure still leaves a restorable entry
- a second-element write failure rolls back the first
- a device absent at restore keeps its entry, and a later attempt restores it
- termination drains the ledger
- `stop()` restores even when `wasCapturing` is false
- interleaved duck/restore calls do not compound the attenuation
- a device with no settable volume degrades to doing nothing, and recording still starts

## Accepted limitations

- **Playback keeps advancing.** A 5 s dictation over a podcast still loses 5 s of it. That is the
  cost of ducking rather than pausing, chosen deliberately.
- **Switching the default output mid-recording leaves the rest of that dictation unducked.** The
  ledger is keyed by device UID, so the device that was ducked is still restored correctly at stop —
  nothing is stranded. The new device simply is not ducked for the remainder. Fixing it means a
  `kAudioHardwarePropertyDefaultOutputDevice` listener and duck-on-switch, which is real complexity
  for a case that lasts seconds. Revisit if it ever happens in practice.
- **A crash or `SIGKILL` mid-recording leaves the volume at 10%.** Graceful quit is covered above;
  an unhandled crash is not. Recovering it would mean persisting audio state across launches, which
  buys a stale-restore failure mode to solve something one volume-key press fixes.
- **System-wide, not per-application.** This moves the output device's volume, not any individual
  app's.
