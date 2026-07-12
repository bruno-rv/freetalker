# Context settings clarity design

## Summary

FreeTalker's **Local context** settings currently combine two independent
features under one heading: choosing what nearby text the app may read and
allowing the app to choose a template automatically. The labels **Scope** and
**Automatic local style** do not tell users what those controls do, which
permissions they need, or how they interact with **App Rules** and cloud
processing.

This change separates the controls into **On-device text context** and
**Automatic template selection**, renames the controls and scope options, and
adds concise inline descriptions and help tooltips. It changes copy, layout,
and help only. Capture timing, context limits, permission handling, template
resolution, persistence, and processing behavior remain unchanged.

## Goals

- Explain what information each context scope reads.
- Make permission requirements visible before a user selects a scope.
- State when context is captured, where it is processed, and how long it is
  retained.
- Explain automatic template selection and the priority of **App Rules**.
- Keep essential guidance visible without relying on hover behavior.
- Preserve all existing runtime behavior and stored setting values.

## Non-goals

- Changing the context capture pipeline or its character limits.
- Changing when context is captured or adding continuous capture.
- Changing permission requests, fallbacks, or warning behavior.
- Changing template-selection rules, built-in templates, or **App Rules**.
- Sending local context to cloud or BYOK processors.
- Renaming persisted `LocalContextScope` cases or settings keys.
- Redesigning other sections of Settings or the recording HUD.

## User experience

### On-device text context

Replace the **Local context** section with a section titled **On-device text
context**. The section contains a picker labeled **Text context**.

Display the existing `LocalContextScope` cases with these names, without
changing their raw values:

| Existing case | New option name |
| --- | --- |
| `off` | **None** |
| `selectedText` | **Selected text** |
| `focusedField` | **Current text field** |
| `activeWindow` | **Visible text in current window** |
| `windowOCR` | **Current window screenshot (OCR)** |

Show one dynamic description directly below the picker. It changes with the
selected option and is the authoritative explanation of that option:

| Option | Dynamic description and option tooltip |
| --- | --- |
| **None** | Does not read nearby text. The destination app may still be used for App Rules and automatic template selection. |
| **Selected text** | Reads only the selected text in the destination app. Requires Accessibility permission. |
| **Current text field** | Reads the full focused editable field, excluding secure fields. Requires Accessibility permission. |
| **Visible text in current window** | Reads text exposed by the current window's accessibility tree. Secure content is excluded. Requires Accessibility permission. |
| **Current window screenshot (OCR)** | Takes one screenshot of the destination window and reads it with Apple Vision. Requires Screen Recording permission; the image is discarded after OCR. |

Keep the existing permission warning below the dynamic description. The
warning continues to appear only when the selected scope requires a permission
that is not currently available. Existing fallback behavior and warning text
may remain unchanged in this copy-only change.

Show this privacy note after the dynamic description and any permission
warning:

> Context is captured once when dictation stops, kept in memory, and used only
> with Apple's on-device processing. It is never sent to cloud providers.

This note is always visible, including when **None** is selected. It establishes
the privacy boundary without requiring the user to hover.

### Automatic template selection

Place a separate section titled **Automatic template selection** immediately
after **On-device text context**. Replace **Automatic local style** with a
toggle labeled **Automatically choose template**.

Show this inline description below the toggle:

> Selects a built-in template based on the destination app and available
> context. App Rules take priority.

This separation makes clear that reading nearby text and choosing a template
are related but independently configurable. The existing
`automaticStyleEnabled` setting, default, persistence, and resolution logic do
not change.

## Help tooltips

Apply help to the section content and controls with the following exact text:

- **On-device text context section:** "Control what nearby text FreeTalker may
  read when dictation stops. Context stays on this Mac and is used only with
  Apple's on-device processing."
- **Text context picker:** "Choose what FreeTalker may read when dictation
  stops. Context is never sent to cloud providers."
- **Automatically choose template toggle:** "When no App Rule matches,
  FreeTalker chooses Email, Refined Message, Clean Dictation, or Refined
  Prompt. Turn this off to keep the Active Template."
- **Automatic template selection section:** "Let FreeTalker choose a built-in
  template from the destination app and available on-device context. App Rules
  always take priority."

Each scope option uses the exact tooltip text in the dynamic-description table.
SwiftUI and native macOS menu items do not consistently expose per-option
`.help` while a picker menu is open. Implementation may attach help to option
labels where supported, but it must not rely on those tooltips. The visible
dynamic description is authoritative and must update whenever the selection
changes.

## Components

### `LocalContextScope` presentation metadata

Update display names to the approved option names. Add presentation-only
metadata for the dynamic description and option help if that keeps copy out of
`SettingsView`. Do not change enum cases, raw values, `Codable` behavior, or
settings migration.

### `SettingsView`

Replace the combined section with the two approved sections. Bind the picker
and toggle to the existing settings properties. Render the selected scope's
description below the picker, preserve the existing conditional permission
warning, and render the always-visible privacy note. Add the approved `.help`
copy and keep native SwiftUI controls and existing visual conventions.

### Existing runtime services

`AppCoordinator`, `AccessibilityLocalContextProvider`, screenshot capture,
Apple Vision OCR, processors, and template resolution require no behavior
changes. Existing permission status state in `SettingsView` remains the source
for conditional warnings.

## Data flow

1. `AppSettings.localContextScope` supplies the current picker selection.
2. `SettingsView` maps that selection to its new display name and dynamic
   description.
3. Selecting another option writes the same existing enum value through the
   same binding and refreshes the visible description.
4. At the end of dictation, the existing coordinator captures the selected
   context once.
5. Accessibility-backed scopes read selected text, the current field, or
   visible window text. The screenshot scope captures the stopped window once
   and runs Apple Vision OCR.
6. The existing resolver applies a matching **App Rule** first. Only when no
   rule matches may automatic selection choose a built-in template.
7. Local context is supplied only to Apple's on-device processor. Cloud and
   BYOK processing continue to receive no local context.

## Permissions and degraded states

- **None** needs no context permission.
- **Selected text**, **Current text field**, and **Visible text in current
  window** require Accessibility permission.
- **Current window screenshot (OCR)** requires Screen Recording permission.
  Accessibility may improve window metadata but is not required for OCR.
- When a required permission is unavailable, retain the existing inline warning
  and app-identity-only fallback.
- When the stopped window is unavailable or capture fails, retain the existing
  runtime warning and continue without OCR.
- Secure text remains excluded from field and accessibility-tree context.

The copy must not imply that selecting a scope grants permission or guarantees
that text will be available. It explains requirements; existing permission UI
and runtime handling remain responsible for status and recovery.

## Privacy boundary

Context is captured once when dictation stops. Accessibility text, screenshots,
and OCR output remain in memory and are used only by Apple's on-device
Foundation Model path. Screenshot bytes are released after OCR. Context is not
persisted, logged, or included in cloud or BYOK requests. The UI must use
"on-device" and "never sent to cloud providers" consistently; it must not use
"local" as an unexplained substitute for this boundary.

Automatic template selection may still use destination app identity when text
context is **None**. App identity is distinct from nearby text context, which is
why the **None** description explicitly mentions **App Rules** and automatic
template selection.

## Error handling

This feature introduces no new runtime operations and therefore no new runtime
errors. Presentation metadata must cover every `LocalContextScope` case so a
new or existing selection never shows blank or stale guidance. Existing
permission and OCR warnings remain visible and take precedence as actionable
status; the privacy note remains visible as stable explanatory context.

## Testing

Add or update focused tests for presentation behavior:

- Every `LocalContextScope` case has the approved display name.
- Every scope has the exact approved dynamic description.
- Scope presentation metadata is exhaustive and maps persisted enum cases
  without changing raw values.
- The automatic-template tooltip states the four eligible built-in templates,
  **App Rules** priority, and the **Active Template** fallback when disabled.
- Existing settings persistence tests continue to pass without migration.
- Existing context routing, permission fallback, OCR, privacy-boundary, and
  template-priority tests continue to pass unchanged.

Perform a manual Settings check on macOS:

1. Confirm the two section titles and controls match the approved labels.
2. Select each text-context option and confirm its visible description updates
   immediately.
3. Confirm the appropriate permission warning appears below the description
   when Accessibility or Screen Recording is unavailable.
4. Hover the picker, toggle, and section content and confirm supported controls
   show the approved help text.
5. Confirm the layout remains readable at the Settings window's minimum size
   and with increased system text size.
6. Confirm menu-option help is supplemental: all essential information remains
   available in the dynamic description when menu tooltips do not appear.

## Acceptance criteria

- Settings shows separate **On-device text context** and **Automatic template
  selection** sections.
- The picker label, five option names, toggle label, descriptions, and tooltips
  match this specification exactly.
- The selected scope's explanation is always visible and changes with the
  picker selection.
- Users can determine the Accessibility or Screen Recording requirement before
  attempting capture.
- Settings visibly states that context is captured once, stays in memory, uses
  Apple's on-device processing, and is never sent to cloud providers.
- Settings states that **App Rules** take priority and that disabling automatic
  selection keeps the **Active Template**.
- Existing stored selections remain valid, and no setting is reset or migrated.
- Context capture, automatic template resolution, permission fallback, and
  local-versus-cloud behavior are unchanged.
- Automated tests pass, and the manual Settings checks find no clipped,
  contradictory, or tooltip-only essential guidance.
