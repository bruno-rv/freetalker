# Task 5 report — local Ollama without an API key

## Result

- Added one pure `CloudLLMSettingsSnapshot.eligibility` rule shared by UI/config routing and
  `CloudLLMProcessor`.
- Empty keys are eligible only for the OpenAI-compatible provider over loopback HTTP at
  `localhost`, `127.0.0.1`, or `::1`.
- Remote HTTP/HTTPS endpoints and unrelated providers still require a non-empty key.
- Eligibility rejects malformed URLs and blank models.
- OpenAI-compatible request construction uses a pure header helper. It omits `Authorization`
  for an allowed empty-key local request and retains `Bearer <key>` when a key is supplied.
- README and Settings help text describe the exception accurately.

## TDD evidence

### RED — eligibility matrix

`make selfcheck` failed with the expected six assertions before the shared rule existed:

- localhost, 127.0.0.1, and IPv6 loopback empty-key requests were rejected.
- `not a URL`, `http://`, and `://localhost:11434/v1` were incorrectly accepted by routing.

### RED — request headers

After adding header expectations, `swift build -c release` failed because
`CloudLLMProcessor.openAICompatibleHeaders(apiKey:)` did not exist. This established the pure
request-header seam before implementation.

### GREEN

`make selfcheck` passed after implementing the shared eligibility rule and header helper. The
new runnable checks cover:

- empty key at localhost, IPv4 loopback, and IPv6 loopback;
- empty key at remote HTTP and HTTPS endpoints;
- malformed URLs;
- a supplied local key;
- no localhost exception for Anthropic;
- Authorization omission with no key and bearer retention with a supplied key.

## Full verification

- `make selfcheck` — passed; runnable SelfCheck completed with no failures.
- `make test` — passed; all application and test targets compiled and linked. The test target
  had two pre-existing one-argument insertion closures that no longer matched the production
  two-argument signature; they were updated mechanically to `{ _, _ in true }`.
- `git diff --check` — passed with exit code 0 and no output.

## Whole-branch final fix wave

### Result

- Added one lock-backed `EngineStatusComposer` that gives an active reload lifecycle precedence
  over concurrent status writes from a transcription using the previously captured kit.
- Reload checking, download, loading, success, and failure now share a tokenized lifecycle.
  Matching terminal completion exposes the new Ready or failure text; superseded tokens cannot
  overwrite a newer lifecycle.
- Replaced the sequential guarded-kit identity assertion with an async production-seam fake
  operation: it captures the old kit, signals, suspends, swaps the stored kit concurrently,
  resumes, and proves the operation retained the old identity while storage exposes the new one.
- Moved compact row tradeoff text into `SpeechModelCatalogEntry` beside `quickTip`; Settings no
  longer switches on catalog IDs.
- A selected pending row is no longer selectable, preventing redundant reload tasks.

### Focused RED

`make selfcheck` failed at compile time before production changes, specifically because:

- `SpeechModelCatalogEntry` had no `compactTradeoff` member;
- `EngineStatusComposer` did not exist;
- `GuardedKitState` had no async `withCapturedKit` production seam.

The pending-row expectation was also changed first from selectable to nonselectable, making the
existing row presentation behavior fail once compilation reached the runnable assertions.

### GREEN and full verification

- `make selfcheck` — passed; concurrent reload-precedence, success/failure terminal exposure,
  suspended old-kit identity, catalog metadata, and pending-row checks all completed without a
  failure.
- `make test` — passed; application and test targets compiled and linked.
- `git diff --check` — passed with exit code 0 and no output.

Follow-up commit: `0c8730e` — `Validate local Ollama port syntax`

## Commit

`d0108e6` — `Allow keyless local Ollama post-processing`

## Important-finding follow-up — port validation

The shared eligibility rule now inspects the original URL authority so an absent port remains
valid while an explicit empty port is rejected. A parsed explicit port must be in `1...65535`.
This keeps routing/UI gating and `CloudLLMProcessor` aligned because both still consume the same
`CloudLLMSettingsSnapshot.eligibility` result.

### RED

`make selfcheck` failed on the new assertions for:

- `http://localhost:/v1`
- `http://localhost:0/v1`
- `http://localhost:65536/v1`
- `http://localhost:99999/v1`

The nonnumeric-port assertion already passed because `URLComponents` rejects that URL entirely.

### GREEN and full verification

- Valid `:11434`, default `:80`, and no-port localhost URLs remain eligible without a key.
- Explicit empty, zero, over-65535, and nonnumeric ports are ineligible.
- `make selfcheck` — passed.
- `make test` — passed; application and test targets compiled and linked.
- `git diff --check` — passed with exit code 0 and no output.
