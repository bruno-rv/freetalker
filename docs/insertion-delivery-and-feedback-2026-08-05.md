# Transcribed text not appearing, and no completion signal — 2026-08-05

Reported symptom, two halves:

> after transcription, the generated text often does not appear in the tool, even though the tool
> is open and ready for input. No feedback is provided when processing finishes, so I must manually
> verify completion and then paste the text myself.

Both halves reproduce as **designed behaviour** in the current code. The second half ("I paste it
myself") is the tell: the text *is* on the clipboard, which means the pipeline succeeded and the
delivery step declined to act.

This is a code-reading investigation. Every line reference below is verified; the claims about
*how often* each branch fires at runtime are inference, and are labelled as such. Nothing here was
executed — the app is macOS-only and there is no Swift toolchain in this environment.

## The delivery step

There is exactly one insertion strategy: a synthetic ⌘V.

```
processDictation → external: { insert(refined, target) }   AppCoordinator.swift:4083-4088
  └─ Insertion.insertTrackingCorrection                    Insertion.swift:569
       └─ Insertion.insert                                 Insertion.swift:117
            └─ postCommandV()  — CGEvent ⌘V                Insertion.swift:890
```

`AXUIElement` is used only for *reads*. Nothing ever calls `AXUIElementSetAttributeValue`, so there
is no AX-write fallback and no type-it-out fallback. The decision is not "which strategy" — it is
**paste, or don't**.

`Insertion.insert` (`Insertion.swift:117-161`) writes the text to the pasteboard *first*
(`:124-126`), then runs a pre-flight identity check, and returns without posting anything if that
check fails (`:139-153`).

## Half one: why the paste is skipped

`shouldSynthesizePaste` (`Insertion.swift:229-265`) refuses on any of: no snapshot bundle id, a
changed frontmost bundle id, a changed pid, or `elementComparison == .mismatch`.

That last one is the prime suspect. `compareElements` (`Insertion.swift:789-801`):

```swift
if let snapshotElement = snapshot.focusedElement {
    guard let currentElement else { return .mismatch }
    // AXUIElement is CFEqual-comparable for identity — see AXUIElement.h.
    return CFEqual(snapshotElement, currentElement) ? .match : .mismatch
}
```

It compares an `AXUIElement` captured at **stop time** (`AppCoordinator.swift:2430`) against one
re-read immediately before the paste. Between those two reads sits the entire pipeline. Per
`docs/perf-dictation-latency-2026-07-29.md`, that is **18.5 s of local decode plus a post-processing
call measured between 1.9 s and 33.3 s** — a window of roughly 20 to 70 seconds.

Two things make `.mismatch` likely across such a window, and both are consistent with "the tool is
open and ready for input":

- **Pointer identity is not field identity.** Apps that rebuild their accessibility tree — anything
  Chromium/Electron-based, and web areas generally — can vend a fresh, non-`CFEqual` `AXUIElement`
  for the same visually-focused field after any re-render. The field never lost focus; the handle
  did.
- **Anything at all taking focus is unrecoverable.** There is no focus restore anywhere in the
  codebase. `insert` never activates the target app, never re-asserts `kAXFocusedUIElement`, never
  raises the window. It only observes whether focus happens to still be where it was and gives up
  if not. (The HUD itself is not the culprit — every panel is `.nonactivatingPanel` with
  `canBecomeKey == false`, `HUDPanel.swift:575`, `:832`.)

Note the asymmetry this creates: `.unavailable` — an app that exposes *no* usable AX identity — is
treated **permissively** for ordinary dictation (`case .unavailable: return !strict`,
`Insertion.swift:263`), while `.mismatch` is refused unconditionally, even when the bundle id and
pid both still match and the current focused element is editable. An app that reports partial
information is punished harder than one that reports none.

### A second, independent way the text fails to appear

Even when the paste *is* posted, `Insertion.swift:182-194` restores the user's previous clipboard
1.0 s later:

```swift
DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
    guard pasteboard.changeCount == changeCountAfterWrite else { return }
    restore(savedItems, to: pasteboard)
}
```

The `changeCount` guard protects against another *writer*, not against a slow *reader*. An app that
reads the pasteboard more than a second after receiving the synthetic ⌘V pastes the user's old
clipboard content instead. The code comment acknowledges this ("residual race accepted for personal
use"). It is a distinct failure mode from the drift skip, and it also presents as "the text didn't
appear".

### And a third: success is never verified

`postCommandV` (`Insertion.swift:890-905`) returns `true` once `keyDown.post` / `keyUp.post` have
been called. It cannot know whether the target app consumed the event. A ⌘V swallowed by a modal, a
focus race, an IME, or Secure Input is reported upward as a successful insertion.

## Half two: why there is no feedback

`runPipeline`'s terminal handler (`AppCoordinator.swift:3614-3641`):

```swift
} else if !result.posted {
    hud.flash(skipPostProcessing ? "Copied (raw) — paste manually" : "Copied — paste manually")  // :3629
...
} else {
    hud.hide()                                                                                   // :3639
}
```

- **On success: nothing.** Line `:3639` hides the HUD. The only signal that a dictation finished is
  the "Processing…" pill *vanishing*. `README.md:667`'s own manual checklist treats the
  disappearing pill as the success indicator. So "pasted" and "posted a ⌘V that went nowhere" look
  identical.
- **On the skipped paste: a 2.5 s flash.** `hud.flash`'s default duration is 2.5 s
  (`HUDPanel.swift:358-368`). After a 20–70 s wait the user is, reasonably, looking somewhere else.
  The one message that requires the user to *act* is the most transient thing the app draws.
- **The reason is computed and then discarded.** `InsertionFailureReason` distinguishes
  `.targetDrift` / `.noFocusedElement` / `.axDenied` / `.pasteFailed`
  (`Insertion.swift:41-49`, classified at `:199-227`) — but `insertTrackingCorrection` returns a
  bare `Bool` (`Insertion.swift:569-578`), so the main dictation path collapses all four into
  `posted == false`. Other call sites do use it: `insertLastDictation`
  (`AppCoordinator.swift:5074`) refreshes Permission Diagnosis on a permission-class failure. The
  primary path does not.
- **Nothing is logged.** `Insertion.swift` has no `Logger` at all. A skipped paste leaves no trace
  in Console, which is why this has been hard to pin down from the outside.
- **`lastError` is dead.** `AppCoordinator.lastError` is assigned at seventeen sites and read by no
  UI in `Sources/` (the menu bar binds `engineStatusText`, `recoveryHealth`, `hotKeyStatusText`,
  `permissionDiagnosis` — `App.swift:182-199`).
- **There is no sound and no notification.** `NSSound`, `AudioServices`, `NSBeep`,
  `UNUserNotification` appear zero times in `Sources/`. Feedback is 100 % the HUD, and the HUD may
  be on another display or behind a fullscreen window.

### One outright bug

`AppCoordinator.swift:3614-3618`:

```swift
guard await completeForegroundRecovery(recovery) else {
    hud.flash("Dictation saved — recovery cleanup failed")
    return                                    // ← returns before any `posted` check
}
```

If recovery cleanup fails, this returns before the `!result.posted` branches ever run. The user is
told about cleanup and told *nothing* about the fact that their text was never pasted and is
sitting on the clipboard.

## Ranked causes

| # | Cause | Evidence | Confidence |
|---|---|---|---|
| 1 | `.mismatch` → `.targetDrift`, silently, over a 20–70 s window | `Insertion.swift:794` → `:252` → `:217` → `:152` | high — matches the symptom exactly, including "I paste it myself" |
| 2 | No completion signal on the happy path | `AppCoordinator.swift:3639` | certain (code) |
| 3 | Failure notice is a 2.5 s flash with no reason | `AppCoordinator.swift:3629`, `HUDPanel.swift:360` | certain (code) |
| 4 | 1.0 s pasteboard restore beats a slow reader | `Insertion.swift:189` | medium — app-dependent |
| 5 | `postCommandV` reports posting, not landing | `Insertion.swift:904` | certain (code); frequency unknown |
| 6 | Recovery-cleanup early return hides the insertion result | `AppCoordinator.swift:3617` | certain (code); rare |
| 7 | No focus restore, ever | absence of `activate` before any insert | certain (code) |

## Status

| Fix | State |
|---|---|
| 1. Soften the drift rule | done — `ElementComparison.rebuilt`; **unverified against a real app** |
| 2. Surface the failure reason | done — `AppCoordinator.notPastedMessage` |
| 3. Persist the actionable notice | done — `actionableNoticeDuration`, 10 s |
| 4. Completion signal | done — HUD "Pasted" always; opt-in sound (`completionSoundEnabled`) |
| 5. Log skipped pastes | done — `Insertion.logger`, category `insertion` |
| 6. Fix the `:3617` early return | done — cleanup failure now appends to the delivery message |
| 7. Verify the paste landed | not done |

### How item 1 was narrowed

The blunt version of "soften the drift rule" — paste whenever bundle id, pid and window agree,
whatever the element says — would have re-opened exactly the mis-delivery the rule was built to
prevent: switching Slack channel or Mail draft mid-dictation also keeps the window and changes the
element.

What separates the two cases is not the *new* element but the *old* one:

- **User moved focus** — the snapshotted element still exists, it just isn't focused. Still
  `.mismatch`, still refused.
- **App rebuilt its AX tree** — the snapshotted element is *gone*, and the current one is a fresh
  handle for the same place. That is `.rebuilt`, and ordinary dictation now pastes on it.

`compareElements` probes `kAXRoleAttribute` on the snapshotted element and requires an affirmative
`.invalidUIElement` — every other `AXError` means "couldn't tell" and fails closed to `.mismatch`.
The window must still match too, and an unobtainable window on either side also fails closed.

Two properties worth keeping in mind when reviewing it:

- **It can only add pastes in that one provable case.** An app whose stale element stays valid
  lands on `.mismatch` and behaves exactly as before, so the worst case for the change is that it
  does nothing.
- **`strict` callers are untouched.** `.rebuilt` returns `!strict`, so the History panel, streaming
  live-typing (`streamingSafeElement`) and the two-phase anchor all still demand a real `.match`.

The residual risk is narrow but real: if the focused element is destroyed and focus lands on a
*different* editable field in the same window (a modal closing, say), this pastes into that field.
`isEditableFocusedElement` still gates it, so it can only ever be an editable target.

**This is the part that needs real dictation to verify, not a unit test** — the policy is covered
by `PermissionAndCapturePresentationTests`, but whether Chromium/Electron actually invalidates the
old element on re-render (rather than keeping it alive) decides whether the fix does anything at
all. Verify against Slack, VS Code, a browser text area, and a native `NSTextView`.

Note what item 4 does and does not buy: the HUD now distinguishes "pasted" from "copied", so a
dictation that silently went nowhere is visible. It still cannot distinguish "pasted" from "posted
a ⌘V the target app swallowed" — that needs item 7.

## Recommended fixes, in order of value

1. **Soften the drift rule instead of failing closed on pointer inequality.** When bundle id and
   pid still match, the window still matches, and the current focused element is editable, a
   `.mismatch` on element identity alone should paste. Element identity is the least reliable of
   the four signals and currently the only one that can veto on its own. This is the change most
   likely to make the reported symptom go away.
2. **Say why.** Thread `InsertionFailureReason` through `insertTrackingCorrection` and map it into
   the HUD text — "Focus changed in Slack — copied, paste manually" instead of "Copied — paste
   manually". The classification already exists; only the plumbing is missing.
3. **Make the actionable message persistent.** The clipboard-fallback notice is the one case where
   the user must do something. It should stay until dismissed or until the next dictation, not
   disappear after 2.5 s.
4. **Add a completion signal.** There is no sound and no notification today. An opt-in one is the
   direct answer to "I must manually verify completion" — and it costs nothing on the paths that
   already work.
5. **Log skipped pastes.** One `Logger` line in `Insertion.insert`'s failure branch, with the
   reason, would have made this a five-minute diagnosis instead of a code audit.
6. **Fix `AppCoordinator.swift:3617`** so a recovery-cleanup failure still reports the insertion
   outcome.
7. **Consider verifying the paste landed** (compare the focused element's value/length against the
   pre-paste baseline, which `captureCorrectionAnchor` already reads for the Correction Loop) and
   fall back to the clipboard notice when it did not.

Items 2–6 are additive and low-risk. Item 1 changes a deliberate safety rule that exists to stop
text landing in the wrong field, and should be weighed as such: today's rule trades a frequent,
silent non-delivery for a rare mis-delivery. The reported symptom suggests that trade is currently
set too conservatively, but loosening it needs real-app verification (Slack, VS Code, a browser, a
native field) rather than a unit test — `docs/perf-dictation-latency-2026-07-29.md:142-145` makes
the same point about the two-phase path being unverifiable at the AX layer.

## Related, already known

- Two-phase insertion (raw first, refined replaces it) narrows the drift window for the
  cloud-post-processed path, but it is gated to that path only
  (`AppCoordinator.shouldUseTwoPhaseInsertion`, `AppCoordinator.swift:3926`) and was never verified
  at the AX layer (`docs/perf-dictation-latency-2026-07-29.md:115-145`). Raw stops, local Apple FM,
  translation and streaming all still insert exactly once, at the end of the full wait.
- `README.md:287-290` documents "Insert Last Dictation" as being "handy when a paste got dismissed
  or overwritten" — the workaround for this issue already ships.
