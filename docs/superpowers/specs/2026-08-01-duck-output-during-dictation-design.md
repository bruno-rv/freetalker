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
| Persist restoration across launches? | **No** | Two sequences can strand a device at 10% as a result; both are enumerated under "Accepted limitations" rather than hidden. |

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
             read original -> record entry -> write target -> read back -> mark written
restore()  drain the ledger: for each entry, decide restore / relinquish / defer
```

### Ledger entry and its states

```
DuckedElement {
    deviceUID: String       // not AudioDeviceID — those are recycled
    element:   UInt32
    original:  Float        // what to put back
    target:    Float        // what we asked for
    readback:  Float?       // what the device reported after the write, if we could read it
}
```

An entry exists in exactly one state:

| State | Meaning | Next |
|---|---|---|
| **pending** | recorded, write not yet attempted | write succeeds → *written*; write fails → **removed** |
| **written** | we changed this element | restore succeeds → **removed**; ownership lost → **removed**; device unreachable → stays *written* |

The two removals that are easy to get wrong:

- **A failed write removes the entry.** `duck()` records before it writes, so that a crash between
  the two does not lose the original. But if the write itself returns an error, FreeTalker never
  changed anything, and keeping the entry would let a later restore overwrite a volume the user
  chose afterwards. Confirmed-unwritten is confirmed-not-ours.
- **Ownership loss removes the entry without writing.** See below.

### The ownership check

`ownedValue = readback ?? target`. A device may quantize (`0.10` in, `0.09803922` out), so the
read-back is preferred; when the read-back failed, the requested target is the best evidence we
have that the element is still as we left it. It is *not* a licence to write unconditionally — a
failed read-back must not turn into "overwrite whatever the user has since chosen".

On restore, per entry:

| Current value | Action |
|---|---|
| unreadable | **defer** — keep the entry, retry later |
| ≈ `ownedValue` (±0.01) | **restore** — write `original`; remove on success, keep on write failure |
| anything else | **relinquish** — the user moved it; remove the entry, write nothing |

Relinquish must be a definitive transition, not a skip: leaving a mismatched entry in the ledger
means a later duck/stop could rediscover it the moment the user happens to land back on the old
ducked value, and overwrite a deliberate choice with a stale original.

### Partial duck rolls back

With the channel-1/2 fallback, `duck()` writes more than once. If any element fails after another
succeeded, the successful ones are restored through the ordinary restore path and the attempt is
abandoned — half-ducked stereo is worse than not ducking. If a *rollback* write fails, that entry
stays *written* and is retried like any other deferred entry.

### Retry and termination

Deferred entries are retried on the next `duck()`, the next `stop()`, and at termination.
`App.swift:230`'s Quit button calls `NSApplication.shared.terminate` directly with no capture
teardown, so quitting mid-dictation would otherwise leave the volume down; an
`applicationWillTerminate` hook drains the ledger synchronously. All in-process — nothing is
written to disk.

### Isolation

`AudioCapture` is `@unchecked Sendable` and is called from several threads. Each of
check-record-write and check-decide-remove is taken under a single `NSLock` that also covers the
CoreAudio calls, so two concurrent `duck()` calls cannot both observe an empty ledger and compound
the attenuation. Sequential duplicate-call tests cannot catch this; the isolation has to be stated,
not inferred.

### Resolving the device

Keying by UID is only useful with a resolver that can find the device again. `AudioInputDevices`
cannot be reused for this: `stringProperty` is private (AudioInputDevices.swift:56) and
`resolveID(forUID:)` goes through `enumerate()`, which filters to `inputChannelCount > 0` (:38, :42)
— an output-only USB DAC is invisible to it. The ducker therefore carries its own resolver that
enumerates every CoreAudio device and matches the stored UID, independent of input capability and
of which device is currently default.

Policy helpers stay `nonisolated static` so they test without a sound card, matching
`AppCoordinator.decoderBiasVocabulary` and `WhisperKitEngine.predeterminedLanguage`:

- `duckTarget(original:)` → `original * 0.10`
- `restoreDecision(entry:current:tolerance:)` → `.restore` / `.relinquish` / `.defer`

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

Live-preview ticks are not a concern: they read the existing capture buffer (`snapshotSuffix`) and
never call `start()`/`stop()`.

## Error handling

Every CoreAudio call can fail and none of them are fatal. Failures never block or delay a recording.
If no element on the device has a settable volume, `duck()` records nothing and `restore()` has
nothing to drain. One `notice`-level log line per transition (`ducked BuiltInSpeakerDevice 0.44 ->
0.04`, `restored BuiltInSpeakerDevice 0.44`, `relinquished, user changed volume`, `restore deferred,
device absent`), consistent with the diagnostics convention in
`docs/perf-decoder-prompt-2026-08-01.md`.

## Testing

A fake volume device behind a small protocol, so the whole state machine runs without hardware:

- duck then restore returns the original value
- the target is relative to the starting volume, not an absolute floor
- a second duck while ducked does not overwrite the saved original
- a second restore is a no-op
- a volume the user changed mid-recording is left alone **and its entry is dropped**, so the next
  duck records the new value as its original
- a user change after a *failed* read-back is still left alone
- a failed duck write leaves no entry, so a later restore cannot overwrite the user's value
- a second-element write failure rolls back the first
- a failed rollback write keeps the entry for retry
- a device absent at restore keeps its entry, and a later attempt restores it
- termination drains the ledger
- `stop()` restores even when `wasCapturing` is false
- interleaved duck/restore calls do not compound the attenuation
- the UID resolver finds an output-only device (no input channels) and one that is not the current
  default
- a device with no settable volume degrades to doing nothing, and recording still starts

## Accepted limitations

- **Playback keeps advancing.** A 5 s dictation over a podcast still loses 5 s of it. That is the
  cost of ducking rather than pausing, chosen deliberately.
- **Switching the default output mid-recording leaves the rest of that dictation unducked.** The
  ledger is UID-keyed, so the device that was ducked is still restored at stop provided it is still
  connected. Ducking the new device too would need a
  `kAudioHardwarePropertyDefaultOutputDevice` listener — real complexity for a case that lasts
  seconds. Revisit if it happens in practice.
- **A device that is unplugged and never comes back before FreeTalker exits stays at 10%.** Duck the
  speakers, unplug or sleep the device so output moves elsewhere, then stop and quit while it is
  still absent: every restore attempt defers, and termination discards the ledger. The device's
  volume is persistent hardware state, so it comes back quiet. This is the same failure class as the
  crash case below and has the same one-keypress fix; closing it properly would mean writing the
  ledger to disk and reconciling it on the next launch.
- **A crash or `SIGKILL` mid-recording leaves the volume at 10%.** Graceful quit is covered;
  an unhandled crash is not.
- **System-wide, not per-application.** This moves the output device's volume, not any individual
  app's.
