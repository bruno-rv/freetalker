# Vocabulary Editor Affordance Design

Date: 2026-07-15
Status: Approved 2026-07-15

## Objective

Make the vocabulary editor visibly editable when it is empty without changing
its storage, normalization, or transcription behavior.

## Background

The settings-card refactor moved the vocabulary `TextEditor` from a grouped
form into a custom card. The editor and card now use effectively the same
background, and the editor has no explicit boundary, inset, placeholder, or
accessibility label. The field still accepts and persists text, but empty space
looks like part of the card rather than an input control.

## User experience

The vocabulary section keeps its existing title and explanatory text. The
editor gains:

- A semantic text-editor background that adapts to light and dark appearances.
- A subtle one-pixel separator-colored rounded border.
- Internal padding between the border and entered text.
- The empty-state placeholder **One term or phrase per line**.
- Example terms beneath the placeholder only when they fit without competing
  with user content.
- The VoiceOver label **Vocabulary terms**.
- A visible keyboard focus treatment that does not resemble an error state.

The placeholder disappears as soon as the user enters text. Existing
vocabulary content appears unchanged.

## Scope

This change modifies only the vocabulary editor's presentation and
accessibility metadata. It does not modify:

- `AppSettings.vocabularyText` persistence.
- Vocabulary normalization or transcription prompt construction.
- Other multiline editors.
- Vocabulary syntax or separators.

## Implementation boundary

The vocabulary section owns a small field wrapper that layers placeholder text
over the existing `TextEditor` and applies semantic fill, border, inset, and
focus styling. The wrapper binds directly to the existing
`settings.vocabularyText` value.

The field must use semantic macOS colors rather than fixed light or dark
values. The border remains neutral while unfocused and becomes more visible
through the app's existing focus treatment.

## Accessibility

VoiceOver announces the editor as **Vocabulary terms** and does not announce
the placeholder as entered content. Keyboard navigation can focus the editor,
and the visible focus treatment meets the surrounding settings contrast.

## Verification

Verify these combinations manually:

- Empty and populated content.
- Light and dark appearances.
- Keyboard focus and tab navigation.
- VoiceOver label and placeholder behavior.
- Relaunch persistence with existing content.

Run the existing settings tests and add a focused persistence and normalization
test only if current automated coverage does not protect the binding's existing
behavior. SwiftUI modifier assertions must not replace visual smoke checks.

## Success criteria

An empty vocabulary editor reads immediately as an editable multiline field,
its expected input format is clear, and all existing vocabulary values continue
to persist and affect transcription exactly as before.
