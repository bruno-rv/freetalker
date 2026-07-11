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
