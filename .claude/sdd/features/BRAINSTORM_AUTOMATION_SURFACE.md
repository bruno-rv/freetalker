# BRAINSTORM: Automation Surface

**Phase:** 0 — Brainstorm
**Date:** 2026-07-24
**Status:** Ready for `/define` (one spike required first — see Open Question)
**Feature slug:** `AUTOMATION_SURFACE`

---

## Problem

FreeTalker only ever acts when the user presses its hotkey. Nothing else on the Mac can ask
it for anything. Every capability the app has — transcription, speaker separation, template
post-processing, translation — is locked behind a human pressing a key.

`PLAN.md:51` records this as a deliberate deferral: *"Automation surface deferred; builder
shaped as the reusable entry point."* `PLAN.md:63` lists *"Automation endpoints (design-for
only)"* as out of scope. This feature collects that debt.

Verified: there is **no external input surface today** — no XPC, no distributed
notifications, no sockets, no local HTTP, no URL types registered
(`Info.plist` has no `CFBundleURLTypes`; grep across `Sources/` for XPC/socket/listener APIs
returns nothing).

---

## Decisions (from discovery)

| # | Question | Decision |
|---|----------|----------|
| 1 | Which direction? | **Inbound** — other tools ask FreeTalker to do work. (Outbound post-dictation hooks explicitly deferred.) |
| 2 | Which transport? | **Apple's Shortcuts system**, because everything else on the Mac can run a Shortcut — Finder, Spotlight, Raycast, Stream Deck, `shortcuts run` in a shell |
| 3 | Toolchain problem (see below)? | **Spike the metadata processor; fall back to Cocoa Scripting (`.sdef`)** |
| 4 | Which capabilities in v1? | **Transcribe a file**, and **clean up text I already have**. Nothing else. |
| 5 | Open by default? | **No — off until switched on in Settings** |
| 6 | Long jobs? | **The caller waits**; the job is visible and cancellable in the Imports window |

---

## The toolchain obstacle (must be resolved before `/define` lands)

App Intents — the modern, native way to expose Shortcuts actions — are discovered by macOS
through a `Metadata.appintents` payload inside the app bundle. That payload is produced by
Xcode's `appintentsmetadataprocessor`, which runs as an **Xcode build phase**. This project
has no `.xcodeproj` on purpose (`Makefile:25` — *"Assembles FreeTalker.app from the built
executable — no .xcodeproj available (CLT only)"*), builds with `swift build -c release`, and
copies the bundle together by hand (`Makefile:26-38`).

A plain SwiftPM build will happily *compile* App Intent types, and Shortcuts will never see
them.

**Plan:** timeboxed spike. Xcode is installed on this machine, so invoke
`appintentsmetadataprocessor` directly from the `app` target after `swift build`, before
`codesign`. Success criterion: the actions appear in the Shortcuts app and in
`shortcuts list`.

**Fallback if the spike fails:** Cocoa Scripting via an `.sdef` and `NSScriptCommand`
subclasses. Two decades old, needs no Xcode, and is reachable from Shortcuts (Run AppleScript),
`osascript` in any shell, Raycast, Alfred and Keyboard Maestro. Worse discoverability, same
capability, including return values.

Rejected: adopting an Xcode project (via xcodegen or otherwise) purely to unlock App Intents.
It would rewrite the build, signing and self-update story that `Makefile` and
`scripts/self-update.sh` currently own — too much collateral for one feature.

---

## Spike result: Cocoa Scripting (fallback taken)

**Timeboxed spike performed 2026-07-25.** `appintentsmetadataprocessor` is at
`/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/`.
A throwaway `FreeTalkerSpikeIntent`/`AppShortcutsProvider` pair was added to the module and the
pipeline was reconstructed by hand:

1. `swift-frontend` accepts `-const-gather-protocols-file <protocols.json>` (the exact protocol
   list Xcode itself ships at
   `.../XcodeDefault.xctoolchain/usr/share/swift/SwiftConstantValues/AppIntents.json`, format
   corrected from the shipped object-wrapped JSON to the plain array the flag actually expects)
   and `-emit-const-values-path <out>` to extract per-declaration App Intents metadata.
2. **This mechanically works** — proven first on an isolated single-file compile, then at real
   scale against all 142 `Sources/FreeTalker/*.swift` files. Feeding the result to
   `appintentsmetadataprocessor` produced a valid `Metadata.appintents/{version.json,
   extract.actionsdata}` bundle whose `extract.actionsdata` correctly listed
   `FreeTalkerSpikeIntent`, its title, description, and the auto-generated Shortcut phrase — at
   the exact path Xcode's own build spec uses (`$(ProductResourcesDir)/Metadata.appintents`,
   confirmed against `AppIntentsMetadata.xcspec`).
3. **But getting there required exploiting an undocumented SwiftPM/swift-frontend quirk.**
   `swift build -c release` silently drops `-emit-const-values-path` for any module compiled
   with whole-module optimization once it has more than ~2 source files (confirmed by binary
   search: 2 files → works, 3 files → silently produces nothing, no error). Root cause: SwiftPM's
   driver auto-generates its own `-supplementary-output-file-map` once a WMO compile crosses that
   file-count threshold, and that auto-generated map has no `"const-values"` key — which silently
   overrides the command-line flag with no diagnostic. The only way to make it work is to
   reconstruct SwiftPM's own compile invocation by parsing `swift build -v` output, then replace
   it with a hand-built `-supplementary-output-file-map` that adds the missing key for every
   source file, forced in via a second `-Xfrontend` pass.
4. **Shortcuts-side discovery could not be confirmed in this environment.** The built app was
   registered with Launch Services (`lsregister -f`) and relaunched; `log stream` confirmed
   `linkd` (`com.apple.appintents:Registry`, the system App Intents registry daemon) does react to
   the launch, but the outcome logged was the ambiguous `"<private> is not link enabled"` with the
   informative fields redacted, and this is a headless agent session with no way to reliably drive
   the Shortcuts.app GUI (AppleScript/System Events UI scripting requires an interactive
   Accessibility grant that isn't available here) to do the actual "search the action library"
   check the brainstorm's own success criterion calls for. `shortcuts list` — the other half of
   that criterion — was verified via `shortcuts list --help` to only ever list saved shortcuts,
   never an app's available actions, so it can never satisfy this criterion regardless of path.

**Decision: fall back to Cocoa Scripting**, per the plan above. The mechanical proof-of-concept
shows App Intents is *possible* here, but the only route to it is a hand-rolled Makefile step
that reverse-engineers and depends on an undocumented, silently-failing compiler/build-system
interaction — a permanent piece of build infrastructure whose failure mode on a future Xcode or
Swift toolchain update is "zero intents exported, no error, no signal" rather than a build
failure. That is an unacceptable maintenance risk for what this feature needs, and end-to-end
discoverability was never actually confirmed. Cocoa Scripting is 20+ years stable, needs no
Xcode, has no analogous silent-failure mode, and reaches the exact same callers (Shortcuts' Run
AppleScript action, `osascript`, Raycast, Alfred) with the same return-value capability, matching
what this document already flagged as the fallback plan.

---

## Capabilities in v1

### 1. Transcribe a file → text

Point at an audio or video file, get the transcript back. Output shape selectable: plain
text, subtitles (SRT/VTT), Markdown, with or without speaker labels — the import pipeline
already produces all of these (`Workflows/Media/TranscriptExporter.swift`).

Runs entirely on the existing background job machinery: `MediaImportService.createJob(for:)`
then `LocalJobRunner.enqueue(_:)`. `LocalJobRunner` is a plain `actor`, **not** `@MainActor`
(`Workflows/LocalJobRunner.swift:81,143`), so this path never touches the UI singleton and
works with the app sitting quietly in the menu bar.

Unlocks: right-click a recording in Finder; run a folder of recordings unattended overnight.

### 2. Clean up text → text

Hand over any text plus a template name, get the post-processed version back. No microphone,
no recording, no permissions. A direct call into `PostProcessor.process(_:)` with a
`PostProcessingRequest` (`Engines/PostProcessor.swift:3-24`) after resolving the named
template from `TemplateStore`.

Turns the user's templates into something the whole system can use — clipboard, notes, email
drafts, anything.

### Cut from v1 (YAGNI)

| Cut | Why | Revisit when |
|-----|-----|--------------|
| Start / stop a dictation on command | Fire-and-forget; text lands at the cursor and never returns to the caller. Also the only capability needing a `@MainActor` hop into `AppCoordinator`. | A Stream Deck / Raycast use case actually shows up |
| Hand back recent dictations | Journaling nice-to-have, not a workflow unblocker | Someone wants dictations auto-filed |
| Outbound post-dictation hooks | Opposite direction; separate feature with its own security model (executing user-supplied code) | Separate brainstorm |
| URL scheme (`freetalker://…`) | Any visited web page can fire it, and it can't return values. Shortcuts covers the same ground safely. | Never, probably |
| Standalone CLI binary + IPC | `shortcuts run` already gives shell access to every action, for free | Only if the Shortcuts route dies entirely |

---

## Security model

Automation is **off by default**, behind a single switch in Settings. This matches how every
other privacy-touching capability in the app already behaves — local context capture, voice
commands and the edge launcher all ship off.

The reason is concrete: once "clean up text" exists and a cloud provider is configured, an
arbitrary Shortcut — including one a stranger sends you — can push text through the user's own
API key and off the machine. The switch is the consent gate for that.

Secondary rules:
- No API keys, provider URLs or model names are readable through automation.
- Automation reuses whatever provider settings already exist; it cannot change them.
- Template resolution is by name against the user's own templates; an unknown name is an
  error, never a silently-substituted default.
- `CommandInstructionBuilder` (`Engines/CommandInstructionBuilder.swift:24`) remains the single
  hardened entry point for building processor instructions — automation calls the same layer,
  exactly as `PLAN.md:21` intended, rather than assembling prompts of its own.

---

## Behaviour on long and failing jobs

The caller waits for its result, like any other slow step in a Shortcut. In parallel the job
appears in the Imports window with progress, so it can be watched or cancelled there. One
story, one mental model: you asked for text, you get text.

Failures surface as errors the calling app can see and branch on — unsupported file type,
missing speech model, unknown template name, automation switched off.

---

## Grounding / validation

The runnable check this feature must leave behind: a Shortcut (or `osascript` one-liner, if
the fallback path is taken) that transcribes a known short recording already in the repo's
test fixtures and asserts the returned text matches the transcript the app produces through
the normal Imports window. If the two paths ever diverge, the automation layer has started
reimplementing the pipeline instead of calling it.

---

## Draft requirements for `/define`

1. A spike determines whether App Intents can be produced from the existing SwiftPM +
   Makefile build; the fallback is Cocoa Scripting via `.sdef`. Everything below is
   transport-agnostic.
2. Automation exposes exactly two capabilities: transcribe a file, and post-process supplied
   text with a named template.
3. File transcription accepts the formats the Imports window already accepts, and can return
   plain text, SRT, VTT or Markdown, with optional speaker labels.
4. File transcription runs on the existing background job queue and does not require the UI
   singleton or a visible window.
5. Text post-processing resolves the template by name from the user's own templates; unknown
   names are an error.
6. Both capabilities are refused unless automation is enabled in Settings; the setting is off
   on first run.
7. No provider credentials, endpoints or model identifiers are readable or writable through
   automation.
8. Callers block until the result is ready; the job is simultaneously visible and cancellable
   in the Imports window.
9. Failures are returned as errors the calling app can branch on.
10. Automation calls the same pipelines as the UI — no parallel implementation.

---

**Next:** `/define .claude/sdd/features/BRAINSTORM_AUTOMATION_SURFACE.md`
