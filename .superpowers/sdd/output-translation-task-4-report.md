# Output Translation Task 4 Report

## Outcome

Implemented Library output metadata and translation-variant persistence on base
`3108c80` without changing existing Library row identity or original transcript
fields.

## TDD evidence

- RED: the focused migration/store command initially failed because the typed
  insert request, migration 10, metadata projections, and variant operations did
  not exist.
- RED (concurrency): the two-connection parent-delete race reproduced
  `database is locked`; adding a bounded SQLite busy timeout made the race
  deterministic while the foreign key prevents orphan variants.
- GREEN:
  `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter 'DatabaseMigrationTests|LibraryTranslationStoreTests'`
  passed 24 tests in 2 suites.
- Database/Library gate:
  `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter 'Database|Library'`
  passed before the final concurrency hardening; the final focused gate above
  covers the changed database paths.
- Full suite:
  `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test`
  exited 0 after the final production change.

## Implementation

- Migration 10 adds `requested_output_language` with the data-preserving
  `same` default and creates the parent/target-keyed translation table with an
  `ON DELETE CASCADE` foreign key.
- Direct `Database` initialization enables foreign keys and invokes the shared
  migration ledger, removing Library startup-order dependence.
- `SourceLanguage`, `OutputLanguage`, and `DictationInsertRequest` replace the
  ambiguous positional String insert interface. All list/latest/search/single
  projections use the same metadata ordering.
- Translation reads, transactional upserts, and transactional deletes are
  exposed through both `Database` and `LibraryStore`. Upsert verifies the
  parent while holding an immediate write transaction; conflict replacement
  changes only variant text and update time.
- Existing `Int64` Library identities remain intact. The migration uses the
  brief's `TEXT` child column, which SQLite validates against the existing
  integer parent key by parent affinity.
- `TranslationTarget` remains unable to represent `same`.

## Migration and integrity coverage

- Populated v9 row preservation and default output metadata.
- Contiguous/idempotent ledger behavior and complete v10 rollback.
- Exact parent/target uniqueness, FK declaration, cascade deletion, and
  missing-parent rejection.
- Two-connection parent deletion race cannot leave an orphan variant.
- Repeated upsert atomically replaces one variant and never mutates the raw or
  refined original.

## Self-review

- Corrected the first preservation test because it originally inserted after a
  completed migration; it now constructs a populated v9 Library schema and
  migrates that row to v10.
- Corrected the first deletion-race test because it was sequential; the final
  test uses two live Database connections and exposed the missing busy timeout.
- Reviewed every changed SELECT projection/index and the parent-key bind/read
  affinity together.
- `git diff --check` is clean. Unrelated pre-existing task report edits were
  left untouched and are not included in the commit.

## Review-finding fixes

- Added a populated legacy-v9 migration fixture containing source row `41` and
  reprocessed child `99`. Migration 10 now atomically rebuilds only a
  `dictations` table whose `source_id` still has the legacy self-foreign-key,
  preserving every row, explicit ID, provenance value, metadata field, FTS
  index, trigger behavior, and search result. Deleting source `41` succeeds and
  child `99` remains with `source_id = 41`.
- The fresh Library base schema now includes
  `requested_output_language`; after the shared migrator, Database ensures the
  translation table exists. A shared-migrator-first file can therefore be
  opened later as a Library, inserted into, and used for variant upsert without
  relying on store startup order. Existing non-Library migration suites remain
  green.
- Added typed `DatabaseError.translationParentMissing(Int64)`. The
  two-connection race test captures the upsert result and accepts only success,
  that exact typed parent race, or SQLite's FK constraint race. It explicitly
  rejects busy/locked errors and verifies no orphan remains.

### Review-fix verification

- RED: legacy migration retained the self-FK and source deletion failed with
  `FOREIGN KEY constraint failed`.
- RED: shared-migrator-first Library insertion failed with
  `table dictations has no column named requested_output_language`.
- GREEN focused gate: 26 tests in `DatabaseMigrationTests` and
  `LibraryTranslationStoreTests` passed.
- GREEN Database/Library gate: 27 tests in 3 suites passed.
- GREEN full suite: `swift test` exited 0 after the final changes.
