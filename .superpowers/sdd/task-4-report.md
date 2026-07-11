# Task 4 report — lifecycle, Settings UI, and README integration

## RED

`make selfcheck` failed before production implementation with missing
`AppCoordinator.routeSpeechModelSelection`, `SpeechModelRowPresentation`, and app-owned
speech-model lifecycle properties. After the first implementation compiled, SelfCheck also
caught a policy error: a downloaded row marked **Selected — pending reload** still exposed
Delete.

## GREEN

- `AppCoordinator` owns one shared download coordinator, one store, and one engine wired to
  that store's event receiver.
- App launch starts the local rescan and the store's guarded one-shot remote support refresh
  before engine preload events arrive.
- Settings routes every user selection through `setWhisperModelFromUser(_:)` and engine
  reload in one integration API.
- The native SwiftUI preference list covers active, pending, download progress, downloaded,
  failed, busy, unsupported, waiting, first-launch, selection, download, and confirmed delete
  presentation. Active, selected reload-target, and busy rows stay undeletable.
- README documents all seven multilingual choices, model management and storage, plus the
  existing zero-code Ollama Desktop path.

## Verification

- `make selfcheck` — passed after the final changes.
- `git diff --check` — passed with no output.
- `make test` — failed in unchanged `Tests/FreeTalkerTests/FreeTalkerTests.swift` lines 66
  and 80: its existing `insert` closures accept one argument, while the current production
  closure type expects `(String, InsertionTarget?)`. No Task 4 file causes this compile error,
  and the task's allowed file scope excludes unrelated test-target repair.

## Self-review

- Changes stay within the Task 4 allowlist and this required report.
- Settings never assigns `settings.whisperModel` directly.
- No second model store, engine, or download coordinator is created for the app run.
- No local LLM runtime code or dependency was added.

## Review follow-up

### RED

Focused SelfCheck additions first failed because the row presentation had no combined
selected/busy state, no model-specific accessibility label, no surfaced delete failure, and
the store exposed no automatic-selection lifecycle callback. A second RED check referenced
the missing automatic preload-then-reload route needed to converge even when an older preload
was already in flight.

### GREEN

- A selected reload target now retains **Selected — pending reload** while also naming its
  current **Loading** state.
- Remote support correction updates the non-user setting, clears presumptive active flags,
  and notifies `AppCoordinator`; the coordinator waits for any preload and then reloads the
  corrected target, so the engine's `.active` event remains the only post-correction activation.
- The radio's VoiceOver label and value include the catalog display name and selection state.
- Delete errors are no longer discarded; Settings presents an accessible alert with the model
  name and localized failure hint.

Fresh follow-up verification: `make selfcheck` passed and `git diff --check` passed.

## Lifecycle review follow-up

### RED

Focused SelfCheck calls first failed because automatic lifecycle routing had no loaded/local
engine inputs. The initialization check also documented the semantic regression: the shared
automatic-default helper cleared active state for both synchronous fallback correction and
later remote correction.

### GREEN

- Synchronous fallback correction now marks its corrected desired row active, preserving the
  first-launch **Active — downloads on first use** presentation.
- Remote support correction clears presumptive active state and waits for the engine's install
  event before marking the corrected target active.
- Lifecycle routing now reloads an already-loaded local kit, preloads then convergence-checks
  an unloaded kit only when WhisperKit is selected, and performs no local model work while
  Cloud STT remains selected.

Fresh lifecycle follow-up verification: `make selfcheck` passed and `git diff --check` passed.

## Model hover-tip addendum

### RED

Catalog invariants first failed to compile because `SpeechModelCatalogEntry` had no
`quickTip` metadata. The first UI compile then confirmed this SDK does not expose a SwiftUI
`accessibilityHelp` modifier.

### GREEN

- Every catalog entry now owns a concise, distinct quick tip covering its specific
  speed/accuracy/resource tradeoff, best-fit use case, and exact searchable model ID.
- Every complete Settings row uses the same catalog text for native macOS hover help and an
  equivalent VoiceOver accessibility hint. No tooltip content is duplicated in the view.
- SelfCheck requires non-empty, distinct tips and verifies that each includes its exact ID.

Fresh addendum verification: `make selfcheck` passed and `git diff --check` passed.
