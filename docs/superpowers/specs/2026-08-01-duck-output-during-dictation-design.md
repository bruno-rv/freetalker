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
| Survive a crash mid-recording? | **No** | Persisting audio state across launches buys a stale-restore failure mode to solve a problem you can hear. |

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

`Sources/FreeTalker/Core/OutputAudioDucker.swift` — one class, two methods.

```
duck()     read the default output device's UID and volume, write original * 0.10,
           read the value back, remember (uid, elements, original, readback)
restore()  re-resolve the device by UID, write the original back, forget
```

Policy lives in `nonisolated static` helpers so it is testable without a sound card, matching the
shape already used for `AppCoordinator.decoderBiasVocabulary` and
`WhisperKitEngine.predeterminedLanguage`:

- `duckTarget(original:)` → `original * 0.10`
- `shouldRestore(savedReadback:current:tolerance:)` → whether the value we wrote is still the value
  on the device

CoreAudio access follows the existing idiom in `Core/AudioInputDevices.swift`
(`AudioObjectPropertyAddress` + `AudioObjectGetPropertyData`), and reuses its `stringProperty`
helper for the device UID.

## Where it hooks

Inside `AudioCapture.start()` (Core/AudioCapture.swift:486) and `AudioCapture.stop()` (:713), not at
the call sites. `start()` has 2 callers and `stop()` has 8; one guard in the shared function beats
eight guards in callers, and every recording path — dictation, voice-edit instruction capture,
hands-free — is covered without touching any of them.

`start()`'s throwing path restores before rethrowing, so a failed capture never leaves the volume
down.

## Three failure modes that define the implementation

**Read-back, not request.** Devices quantize: write `0.10`, read `0.09803922`. The "did the user
change the volume mid-recording?" check compares the device's current value against the value read
back after writing, with a ~0.01 tolerance. Comparing against the *requested* value fails every
time, and restore would never fire.

**Idempotence guards the save, not the write.** A second `duck()` while already ducked must not
re-capture "original" — it would save `0.04` as the original and pin the user at 4% for good. The
same on the other side: `stop()` is reachable twice (`AppCoordinator.swift:2413` does
`stoppedCapture?.samples ?? audioCapture.stop()`), so `restore()` no-ops unless currently ducked.
`restartAfterCorroboratedFault` restarts capture through `startCaptureAttempt` rather than
`start()`, so it should not re-enter — the guard holds either way.

**Device identity is the UID, not the ID.** `AudioDeviceID` values are recycled. Store the UID
string and re-resolve on restore; if the device is gone (headphones unplugged, display asleep),
skip the restore rather than writing an unrelated device's volume.

## Error handling

Every CoreAudio call can fail and none of them are fatal. A failure to read or write volume is
recorded and ignored — it never blocks or delays a recording. If the property is not settable,
`duck()` remembers nothing and `restore()` has nothing to undo. One `notice`-level log line per
transition (`ducked output 0.44 -> 0.04`, `restored output 0.44`), consistent with the diagnostics
convention established in `docs/perf-decoder-prompt-2026-08-01.md`.

## Testing

A fake volume device behind a small protocol, so the whole state machine runs without hardware:

- duck then restore returns the original value
- the target is relative to the starting volume, not an absolute floor
- a second duck while ducked does not overwrite the saved original
- a second restore is a no-op
- a volume the user changed mid-recording is left alone
- a device that disappeared before restore is skipped
- a device with no settable volume degrades to doing nothing, and recording still starts

## What this does not do

- Does not pause playback — a 5 s dictation over a podcast still advances 5 s.
- Does not touch per-application volume; this is the system output device.
- Does not restore after a crash or forced quit. You are left at 10% until you press volume-up.
