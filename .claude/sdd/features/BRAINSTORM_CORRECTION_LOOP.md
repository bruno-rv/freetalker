# BRAINSTORM: Correction Loop

**Phase:** 0 — Brainstorm
**Date:** 2026-07-24
**Status:** Ready for `/define`
**Feature slug:** `CORRECTION_LOOP`

---

## Problem

When a dictation mishears a name or a piece of jargon, the user retypes it by hand and the
app never finds out. The most reliable correction signal in the entire product — a human
deliberately fixing a word — is thrown away.

The app already mines vocabulary, but only by comparing its own raw transcript against its own
post-processed output (`VocabularyMiner.candidates(transcript:refined:)`,
`VocabularyMiner.swift:47`). It learns from what the language model changed, never from what
the user changed.

Confirmed gaps:
- After pasting, the app immediately forgets **what** it inserted and **where**
  (`Insertion.swift:91-150` posts ⌘V and discards the range).
- Voice Edit can replace text in place, but only within a selection captured fresh at hotkey
  press; it has no notion of a recent dictation and no link to `LibraryStore`
  (`VoiceEditCoordinator.swift`, wired at `AppCoordinator.swift:718-789`).
- No alternate transcriptions exist to offer. WhisperKit computes per-decode quality scores
  internally, but the engine collapses everything to one string
  (`WhisperKitEngine.performTranscribe:524-614`).

---

## Decisions (from discovery)

| # | Question | Decision |
|---|----------|----------|
| 1 | What actually goes wrong? | **A misheard name / jargon word.** Not template problems, not lost text, not whole misheard phrases |
| 2 | How does the app learn the right spelling? | **All three ways** — a key press, a spoken correction, and noticing an edit |
| 3 | Sequencing? | **All three in one feature**, watching included, behind its own switch |
| 4 | Does it also fix the text? | **Yes — repair in place *and* learn** |
| 5 | Where does the corrected word go? | **Into effect immediately**; if the vocabulary budget is full, offer to drop the least-used term |
| 6 | Test set? | **The vocabulary system's own history** — terms already approved and dismissed |

---

## Shared core

All three signals capture the same thing: a **wrong → right** pair tied to a specific
dictation. Two pieces of shared machinery serve all of them:

### 1. Remember what was inserted, and where
`Insertion` must retain, for a bounded window: the inserted text, its range, the insertion
target, and the dictation it came from. This is the single genuine gap under every variant.

**Shared with `BRAINSTORM_STREAMING_ASR`**, which needs the same ledger to replace its typed
partials with refined output. These two features should agree on one mechanism, not build two.

### 2. Record corrections as vocabulary evidence
`VocabStore.recordEvidence(dictationID:candidates:)` (`VocabStore.swift:117`) already takes a
plain `{normalizedTerm, surfaceTerm}` pair and is fully decoupled from the miner's diffing.
A user correction can be fed straight in — validated by `AppSettings.validatedVocabularyTerm`,
the same rule manual terms pass — without touching the mining logic at all.

Corrections must be marked as **user-supplied**, not mined, because they are stronger evidence
and are treated differently on approval (below).

---

## The three signals

### A. Press a key after a bad dictation
A panel shows what was heard; the user fixes the word. The text is repaired where it already
sits, and the pair is recorded.

### B. Speak the correction
The cheapest of the three: Voice Edit already transcribes an instruction locally, previews the
result, replaces in place, and refuses when the window or selection has drifted
(`VoiceEditCoordinator.swift:214`; refusal cases `:15-38`). What is missing is that it doesn't
know the last dictation exists and doesn't teach the vocabulary anything. Both are additions
to an existing, working flow — not new machinery.

Voice Edit stays pinned to the on-device engine even when dictation uses cloud STT
(`AppCoordinator.swift:702-704`); corrections inherit that.

### C. Notice the user editing what was just inserted
For a bounded window after insertion, watch the inserted range. If it changes into something
that reads as a single-word substitution, offer to remember it.

This is the expensive one and the only one that reads text the user did not explicitly hand
over. It gets **its own switch, off by default**, and is confined to the range the app itself
inserted — never the rest of the field, never anything typed before or after the window.
It is also the least reliable: applications that expose text badly (Electron, most web views)
will simply not support it, and that must degrade silently to signals A and B rather than
appearing broken.

---

## Approval and the vocabulary budget

Vocabulary terms compete for a fixed budget that biases the speech model, which is why the
existing suggestion flow is fit-gated. A deliberate correction takes effect **immediately** —
the user has already decided.

If the budget is full, the app says so and offers to drop the term gone longest without use.
The trade is presented, not made silently: a word the user added months ago must never vanish
without them knowing, or the next mishearing becomes inexplicable.

---

## In scope / out of scope

**In:** single misheard words and names; correcting the most recent dictation; the three
signals above; immediate vocabulary effect with an explicit swap when full.

**Out:**

| Cut | Why |
|-----|-----|
| Re-running a dictation through a different template | Different failure mode. `reprocess(dictation:with:)` (`AppCoordinator.swift:3958`) already exists for this and is reachable from the Library |
| Re-recording a misheard phrase | Failure mode explicitly not selected |
| Recovering text that landed in the wrong place | Different feature |
| "Did you mean…" alternate transcriptions | The engine surfaces only a single best string today (`WhisperKitEngine:609`). Exposing n-best is its own piece of work with its own value question |
| Correcting dictations older than the most recent one | The Library already allows re-processing; correcting arbitrary history is a settings-shaped task, not an in-the-moment one |

---

## Validation

The vocabulary system has been mining real dictations for weeks and already holds terms the
user approved and terms they dismissed — a labelled set of genuine mistakes, in the user's own
voice, at no cost.

Two checks fall out of it:
1. Corrections captured through the new signals agree with terms already approved (the paths
   don't contradict each other).
2. Words that were dismissed as suggestions do not re-enter the vocabulary through a
   correction path without the user saying so.

The runnable check the feature must leave behind: replay that stored evidence through the
correction path and assert both properties hold.

---

## Draft requirements for `/define`

1. Text insertion retains what was inserted, where, and which dictation it came from, for a
   bounded window. This mechanism is shared with the streaming feature, not duplicated.
2. A hotkey opens a correction panel for the most recent dictation, showing what was heard and
   allowing a word to be corrected.
3. A spoken correction can target the most recent dictation without requiring the user to
   select text first, reusing the existing Voice Edit preview, confirm and drift-refusal
   behaviour.
4. Optionally — behind a switch that is off by default — the app notices when the user edits
   the text it inserted and offers to remember the correction.
5. The watching signal reads only the range the app itself inserted, only within the window,
   and degrades silently where the application does not support it.
6. Any correction repairs the text in place, refusing when the target has drifted, and never
   silently editing the wrong thing.
7. A correction records a user-supplied wrong → right pair against the dictation, validated by
   the same rule manual vocabulary terms pass, and distinguishable from mined evidence.
8. A corrected term takes effect immediately rather than waiting in the suggestions queue.
9. When the vocabulary budget is full, the app offers to drop the least-used term; it never
   evicts silently.
10. A previously dismissed suggestion does not silently return through a correction path.

---

**Next:** `/define .claude/sdd/features/BRAINSTORM_CORRECTION_LOOP.md`
