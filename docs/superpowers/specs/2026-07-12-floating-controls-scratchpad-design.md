# Floating controls and scratchpad design

## Summary

FreeTalker will add two optional entry points for dictation: an edge-hover
launcher and a persistent scratchpad. The launcher stays hidden until the
pointer reaches a user-selected screen edge and expands into controls for
dictation, the scratchpad, the main app, and dictation language. The scratchpad
provides a focusable rich-text workspace for dictating, formatting, and
optionally rewriting notes with the configured cloud API model.

The temporary recording HUD will also become freely draggable. It will retain
its nonactivating, always-on-top behavior and its ability to appear over another
application in a full-screen Space.

The implementation uses separate window controllers for the launcher,
recording HUD, and scratchpad. This keeps each window's activation and focus
contract explicit: launcher and HUD interactions must not steal the external
dictation target, while the scratchpad must accept keyboard focus.

## Goals

- Offer an optional microphone launcher that appears only on edge hover.
- Let users select the launcher's edge and normalized position along that edge.
- Expose Automatic, English, and Portuguese from both Settings and the
  launcher, backed by one persisted default.
- Make the temporary recording HUD draggable and restore a safe saved position.
- Provide a persistent rich-text scratchpad with dictation and common
  formatting.
- Provide Improve writing, Expand, Condense, and Custom instruction actions
  when the configured cloud API model is eligible.
- Explain unavailable AI actions through hover help and accessibility help.
- Preserve external-app insertion, focus, privacy, and full-screen behavior.

## Non-goals

- Replacing the menu bar menu, hot keys, Library, templates, or App Rules.
- Copying another product's floating-control or scratchpad layout.
- Adding languages beyond Automatic, English, and Portuguese.
- Adding a new AI provider, model configuration, API-key store, or local Apple
  Foundation Model path for scratchpad AI actions.
- Synchronizing scratchpad content between Macs or storing it in the Library.
- Supporting images, tables, attachments, Markdown source editing, or multiple
  scratchpad documents in the first version.
- Letting the launcher or recording HUD become a key or main window.
- Changing the current pasteboard fallback when external insertion is unsafe.

## User experience

### Floating controls

Add a **Floating controls** section to Settings. **Show edge launcher** defaults
to off. When enabled, the section provides:

- **Screen edge:** Left, Right, Top, or Bottom.
- **Position along edge:** A slider representing a normalized value from `0` to
  `1` along the selected edge.
- **Default dictation language:** Automatic, English, or Portuguese.

The launcher presents only a narrow edge-hover target while collapsed. Moving
the pointer into that target reveals a small microphone control. Continuing to
hover expands a compact group containing:

- Start or stop normal dictation.
- Open the scratchpad.
- Open the main app or menu.
- Select Automatic, English, or Portuguese.

The controls collapse after the pointer leaves the complete hover region for a
short grace interval. Moving between controls must not cause flicker. Hovering
alone must never activate FreeTalker, start recording, or change the frontmost
application. The expanded group needs a distinct FreeTalker design and must not
reproduce the reference product's layout.

The language selection updates the existing persisted `languagePin` setting:
`auto`, `en`, or `pt`. It is the default for subsequent recordings. Existing
one-shot HUD selection and App Rule precedence remain unchanged:

1. A recording's one-shot language wins.
2. A matching app language rule wins next.
3. The persisted default language applies last.

### Draggable recording HUD

Users can drag the temporary recording HUD from any non-control area. Dragging
must remain available in every HUD mode without interfering with stop, lock,
language, template, or other existing controls.

The HUD saves its last position after a completed drag and restores it on the
next presentation. It remains a borderless `.nonactivatingPanel`, cannot become
key or main, stays at floating window level, and retains
`.canJoinAllSpaces`, `.stationary`, and `.fullScreenAuxiliary`. Clicking or
dragging it must not steal focus from the external application or invalidate
the insertion target captured by normal dictation.

### Scratchpad

The scratchpad opens as a normal titled, closable, resizable, focusable window.
It contains one persistent rich-text document and an editor toolbar. Closing
the window hides the workspace; it does not clear its contents. Reopening the
window or relaunching FreeTalker restores the document and selection-safe
formatting.

The initial formatting toolbar provides:

- Heading styles.
- Bold.
- Italic.
- Bulleted list.
- Numbered list.
- Clear formatting.

Formatting applies to the current selection. With an empty selection, inline
styles affect subsequently typed or dictated text, and paragraph styles affect
the current paragraph. **Clear formatting** removes supported inline and
paragraph formatting without deleting text.

Scratchpad dictation inserts finalized text at the editor's current insertion
point or replaces its current selection. Live preview is visually temporary and
must not enter the persisted document or undo history until final transcription
completes. Scratchpad dictation never pastes into another application.

### AI text actions

The scratchpad shows these actions:

- **Improve writing** improves clarity and correctness while preserving meaning.
- **Expand** adds useful detail without changing the core meaning.
- **Condense** shortens the text while preserving essential information.
- **Custom instruction** accepts a user instruction for the transformation.

An action uses the selected text, or the entire document when there is no
selection. Empty input keeps all actions disabled. A successful result replaces
only the source range used by the request and becomes one undoable edit.

These are API-only actions. They are enabled only when the current
`AppSettings.cloudLLMSnapshot.eligibility` is
`CloudLLMEligibility.eligible`. The UI must not duplicate URL, model, API-key,
or localhost eligibility rules. In particular, it must preserve the canonical
keyless exception for an OpenAI-compatible provider using HTTP on a loopback
host.

AI controls remain visible when unavailable. Their tooltip and accessibility
help explain the canonical reason:

- Invalid configuration: configure a valid HTTP or HTTPS base URL and model in
  Cloud post-processing settings.
- Missing API key: add an API key for the selected provider. The explanation
  may mention that eligible OpenAI-compatible loopback HTTP endpoints do not
  require one.
- Empty input: select text or add text to the scratchpad.

The custom instruction control additionally explains when an instruction is
required. Tooltips are supplemental; disabled controls must expose the same
reason through an accessibility label, value, or help description.

## Architecture

Use three specialized window surfaces that share existing recording, language,
and cloud-processing services:

- `FloatingControlsController` owns the nonactivating edge-hover panel,
  tracking region, expansion state, geometry, and action callbacks.
- `HUDController` continues to own the recording HUD and gains drag and
  position-restoration behavior.
- `ScratchpadWindowController` owns the normal focusable scratchpad window,
  editor state, persistence, formatting, and AI-action presentation.

`AppCoordinator` remains the orchestration boundary for recording. Add an
explicit recording destination instead of inferring the destination from the
frontmost window after recording begins. The destination is either:

- External insertion, with the current stop-time app, accessibility target,
  context capture, App Rule, and paste-safety behavior.
- Scratchpad insertion, with a stable editor insertion range or replacement
  token managed by the scratchpad controller.

The destination must flow through recording start, live preview, final
transcription, post-processing, success, cancellation, and error paths. Window
focus must never decide where completed text goes.

## Components

### Settings

Extend `AppSettings` only for values that do not already exist:

- Launcher enabled state, default `false`.
- Launcher edge, default Right.
- Launcher normalized edge position, clamped to `0...1`.
- Saved HUD position and display identity.

Reuse `languagePin` for the default language. Do not add a second language
setting. Loading validates enum-like values, finite coordinates, normalized
ranges, and display availability. Invalid or legacy values fall back safely and
are normalized when next saved.

### Launcher panel

Use a borderless nonactivating `NSPanel` whose `canBecomeKey` and
`canBecomeMain` values are false. It accepts pointer events but does not call
application activation for hover or normal dictation. **Open scratchpad** and
**Open main app** may activate FreeTalker because those actions intentionally
open focusable application UI.

The hover target and expanded controls form one logical tracking region. Menu
or popover choices must preserve the captured external target when normal
dictation starts. The launcher observes settings so edge, position, enabled
state, and language changes apply without relaunching.

### Recording HUD

Keep the existing `HUDPanel` focus overrides and collection behavior. Add a
drag handle through event handling that distinguishes background drags from
control clicks. Do not replace the panel with a SwiftUI scene or activating
window.

### Scratchpad editor

Use an AppKit rich-text editor, such as `NSTextView` bridged into SwiftUI, so
selection ranges, attributed-string formatting, undo grouping, insertion-point
attributes, and accessibility follow native macOS behavior. The editor exposes
commands to a toolbar view model rather than placing formatting logic in button
views.

### Scratchpad AI service

Create a narrow scratchpad transformation service around a single
`CloudLLMSettingsSnapshot` captured when the action starts. Construct the
existing `CloudLLMProcessor` or a shared request client from that same snapshot
so gating and request credentials cannot observe different settings. Prompts
must request only transformed text, preserve the input language, and encode the
selected built-in action or custom instruction.

Do not silently fall back to `AppleFMProcessor`. Scratchpad AI is unavailable
when the canonical cloud snapshot is ineligible.

## Data flows

### Normal dictation from the launcher

1. The user hovers over the configured edge and selects dictation.
2. The launcher starts the existing recording flow without activating
   FreeTalker.
3. The coordinator records an external-insertion destination.
4. At stop time, the existing flow snapshots the frontmost app, insertion
   target, and approved local-context target before asynchronous work.
5. Language resolution applies one-shot selection, App Rules, and then
   `languagePin`.
6. Transcription and existing post-processing complete.
7. The insertion layer validates the captured external target. It pastes only
   when safe; otherwise, it leaves text on the pasteboard and reports the
   existing manual-paste fallback.

### Scratchpad dictation

1. The user places the insertion point or selects text in the scratchpad.
2. The scratchpad asks the coordinator to start recording with a scratchpad
   destination and a stable replacement token.
3. Temporary live preview renders outside the stored attributed string.
4. Final transcription uses the selected language and approved processing
   path.
5. The scratchpad resolves the token against the current document. If still
   valid, it performs one undoable replacement and schedules persistence.
6. No pasteboard write, synthetic paste, external context capture, or external
   insertion occurs.

### AI transformation

1. The scratchpad captures the selected range or full-document range, its
   attributed text, and its plain-text input.
2. It captures one `cloudLLMSnapshot` and checks its canonical eligibility.
3. It sends the plain text and selected action to the configured API endpoint.
4. While the request runs, the originating action shows progress and prevents
   a duplicate request.
5. On success, the editor verifies that the source range still contains the
   original text. It replaces that range as one undoable edit and preserves
   surrounding formatting.
6. If the range changed, the app does not overwrite newer edits. It presents
   the result for explicit user application or reports that the source changed.

## Geometry and display changes

Launcher position uses the main screen's `visibleFrame`, not the full frame, so
it avoids the menu bar and Dock. The normalized position defaults to `0.5`. For
left and right edges, the normalized position maps from bottom to top. For top
and bottom edges, it maps from left to right. Clamp the final panel frame so the
complete expanded controls remain visible.

The launcher appears on the current main screen. When the main screen changes,
it repositions on that screen using the same edge and normalized value. Display
reconfiguration must remove stale tracking areas before installing new ones.

Save the HUD position using a display identifier and coordinates normalized to
that display's visible frame. On restoration, denormalize against the matching
display. If that display is missing, use the current main screen. Clamp enough
of the HUD inside the visible frame that users can always drag it again. Reapply
the clamp after HUD content changes size and after screen configuration changes.

## Focus and window ordering

The launcher and recording HUD are nonactivating panels. Both must reject key
and main status while accepting first-click pointer events. Neither hover nor a
dictation control click may activate FreeTalker. These constraints preserve the
frontmost external app and the focused accessibility element used for safe
insertion.

Both panels join all Spaces and use `.fullScreenAuxiliary` so they can appear in
front of another app's full-screen window. The existing recording HUD retains
`.stationary` and floating level. The launcher may use the same behaviors when
needed for consistent edge access.

The scratchpad is intentionally different: opening it activates FreeTalker and
makes its normal window key. Scratchpad dictation routes by explicit
destination, so later focus changes cannot redirect its output to an external
app.

## Persistence

Persist launcher and HUD preferences through `AppSettings` and `UserDefaults`.
Persist scratchpad rich text in FreeTalker's Application Support directory as
an attributed-string archive that retains the supported formatting. Write to a
temporary sibling file and replace the destination atomically after edits are
debounced. Flush pending changes when the window closes and during orderly app
termination.

Load the scratchpad once when its controller initializes. A missing file creates
an empty document. If the file is unreadable or corrupt, keep the source file,
open a safe empty document, and show a non-destructive warning. Do not overwrite
the unreadable file until the user edits or explicitly replaces the document.
Never persist live-preview text, API keys, request headers, or transient errors.

## Privacy and security

Normal external dictation retains the existing local-context privacy boundary.
Scratchpad dictation does not capture external selected text, focused-field
content, accessibility-tree content, or screenshots.

AI actions send only the chosen scratchpad text and transformation instruction
to the cloud endpoint configured by the user. They do not send the rest of the
document when a selection exists. The UI must make the API dependency clear and
must not describe these actions as on-device. API keys remain in the existing
provider-scoped Keychain account and must not enter scratchpad persistence,
logs, tooltips, or errors.

## Error handling

- If launcher geometry is invalid, clamp it to a usable default instead of
  hiding it off-screen.
- If a saved HUD display is unavailable, restore and clamp it on the main
  screen.
- If scratchpad persistence fails, keep the in-memory document, show a
  non-destructive error, and allow a later save attempt.
- If recording fails or is canceled, remove temporary preview and leave the
  scratchpad document unchanged.
- If a scratchpad insertion token becomes invalid, do not insert at an unrelated
  location. Preserve the transcription for explicit recovery.
- If AI eligibility changes before a request starts, disable the action and show
  the current canonical reason.
- If an AI request fails, times out, returns empty output, or is canceled, leave
  the original text and formatting unchanged and show an actionable error.
- If the source text changes during an AI request, never overwrite the newer
  content automatically.

## Testing

Add focused automated tests for:

- Launcher enabled state defaults to off and persists.
- Launcher edge values and normalized positions persist, clamp, and fall back
  from invalid stored values.
- Edge geometry maps all four edges correctly and keeps collapsed and expanded
  frames visible.
- HUD positions round-trip across display geometry and clamp after screen
  removal or content resizing.
- Launcher and HUD presentations remain nonactivating and include
  `.fullScreenAuxiliary`; HUD retains `.stationary` and floating behavior.
- Language selection round-trips `auto`, `en`, and `pt`, and resolution retains
  one-shot, App Rule, and default precedence.
- Explicit destinations route normal dictation to external insertion and
  scratchpad dictation only to the editor.
- Scratchpad live preview never enters persisted content or undo history.
- Rich text round-trips headings, bold, italic, bulleted lists, numbered lists,
  and cleared formatting across relaunch.
- Corrupt persistence data is preserved and produces a safe empty document.
- AI actions use selected text or the whole document as specified.
- AI enablement derives from every `CloudLLMEligibility` case, including the
  keyless OpenAI-compatible loopback exception.
- Disabled AI actions expose the same reason in tooltip and accessibility help.
- AI success replaces one verified range as one undo operation.
- AI failure, empty output, cancellation, and concurrent source edits preserve
  the original text.
- Scratchpad AI uses one settings snapshot for eligibility and request creation.

Run the smallest focused test targets while implementing, then run the full
`make test` suite and assemble the release app.

## Manual verification

1. Merge or update from current `main` before implementation and confirm the
   recently merged context-settings behavior remains unchanged.
2. Confirm the launcher is absent with **Show edge launcher** off.
3. Enable each edge, move the position slider to both ends and the midpoint,
   and confirm the hover target and expanded controls remain reachable.
4. Confirm hover does not activate FreeTalker or change the focused field in
   another application.
5. Start launcher dictation into another app and confirm text reaches the
   captured target or uses the existing manual-paste fallback when focus drifts.
6. Select Automatic, English, and Portuguese from Settings and the launcher;
   confirm both surfaces stay synchronized and new recordings use the selection.
7. Drag the recording HUD around every edge, relaunch FreeTalker, and confirm
   its saved position is restored and usable.
8. Repeat HUD and launcher checks on multiple displays, after disconnecting a
   display, across Spaces, and over another application in full-screen mode.
9. Confirm clicking and dragging the HUD does not activate FreeTalker or move
   the external insertion target.
10. Dictate into the scratchpad at an insertion point and over a selection.
    Confirm no text is pasted into another app and live preview is not saved.
11. Apply every formatting command, close the window, relaunch the app, and
    confirm content and formatting persist.
12. Exercise Improve writing, Expand, Condense, and Custom instruction with a
    valid API model. Confirm selection and whole-document behavior.
13. Remove the model, invalidate the URL, and remove the required API key in
    turn. Confirm AI controls remain visible and their tooltips and
    accessibility help explain the correct reason.
14. Edit source text during an AI request and simulate a request failure.
    Confirm neither path overwrites the newer or original content.
15. Use VoiceOver and keyboard navigation to confirm every launcher, formatting,
    dictation, language, and AI control has an understandable name and state.

## Acceptance criteria

- The edge launcher is optional, defaults to off, and appears only on hover at
  the selected edge and normalized position.
- Launcher actions cover dictation, scratchpad, main app access, and Automatic,
  English, and Portuguese language selection.
- Settings and launcher language controls share the existing persisted default.
- The recording HUD is freely draggable, restores safely, stays nonactivating,
  and remains visible over full-screen applications through
  `.fullScreenAuxiliary`.
- Normal dictation preserves stop-time external target capture and safe
  insertion semantics.
- Scratchpad dictation inserts only into the persistent focusable rich-text
  editor.
- Headings, bold, italic, bulleted lists, numbered lists, and clear formatting
  work and persist across relaunches.
- Improve writing, Expand, Condense, and Custom instruction operate on the
  selection or whole document and never destroy source text on failure.
- AI availability uses canonical `CloudLLMEligibility` without duplicated
  configuration rules, and disabled reasons appear in both tooltip and
  accessibility help.
- Automated and manual verification find no regression in context settings,
  external focus handling, full-screen behavior, privacy boundaries, or
  existing pasteboard fallback behavior.
