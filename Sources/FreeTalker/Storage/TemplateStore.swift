import Foundation

@MainActor
final class TemplateStore: ObservableObject {
    static let shared = TemplateStore()

    nonisolated static let rawTranscriptTemplateName = "Raw Transcript"

    enum TemplateStoreError: LocalizedError, Equatable, Sendable {
        case reservedName
        case invalidImportData
        case fileTooLarge(maxBytes: Int)
        case tooManyTemplates(max: Int)
        case stringTooLong(field: String, maxBytes: Int)

        var errorDescription: String? {
            switch self {
            case .reservedName:
                return "\"\(TemplateStore.rawTranscriptTemplateName)\" is reserved for raw dictations and can't be used as a Template name."
            case .invalidImportData:
                return "This file doesn't contain valid FreeTalker templates."
            case .fileTooLarge(let maxBytes):
                return "This template file is larger than the \(maxBytes / (1024 * 1024)) MB limit."
            case .tooManyTemplates(let max):
                return "This file has more than \(max) templates."
            case .stringTooLong(let field, let maxBytes):
                return "A \(field) in the template file exceeds the \(maxBytes)-byte limit."
            }
        }
    }

    nonisolated private static let maxImportFileBytes = BackupBundleBounds.maxFileBytes
    nonisolated private static let maxImportTemplates = BackupBundleBounds.maxTemplates
    nonisolated private static let maxImportTemplateIDBytes = BackupBundleBounds.maxTemplateNameBytes
    nonisolated private static let maxImportTemplateNameBytes = BackupBundleBounds.maxTemplateNameBytes
    nonisolated private static let maxImportTemplatePromptBytes = BackupBundleBounds.maxTemplatePromptBytes

    private static let promptEngineerMigrationKey = "TemplateStore.migrations.promptEngineer.v1"
    private static let promptEngineerMigrationVersion = 1

    /// Mirrors `promptEngineerMigrationKey` above, for the three model-specific Prompt Engineer
    /// built-ins (`Template.modelPromptEngineerIDs`) added in the same release.
    private static let modelPromptEngineersMigrationKey = "TemplateStore.migrations.modelPromptEngineers.v1"
    private static let modelPromptEngineersMigrationVersion = 1

    /// PLAN.md PR A, item 5 — version-bumped migration key (mirrors `promptEngineerMigrationKey`
    /// above) gating `Template.migratingSpokenCommandRules`, run once per install.
    private static let spokenCommandRulesMigrationKey = "TemplateStore.migrations.spokenCommandRules.v1"
    private static let spokenCommandRulesMigrationVersion = 1
    private static let legacyCommandRuleWarningKey = "TemplateStore.spokenCommandRules.unrecognizedTemplateIDs"
    /// Codex round-7 finding 9 — see `importTemplates(_:)`. A precommit landing zone for warning
    /// IDs discovered mid-import: written before `mutateAndSave`, promoted into
    /// `legacyCommandRuleWarningKey` only after the save lands, and reconciled against the loaded
    /// `templates.json` at every `init` so a hard kill anywhere in that sequence self-corrects
    /// instead of leaving a permanent false warning.
    private static let pendingLegacyCommandRuleWarningKey = "TemplateStore.spokenCommandRules.pendingUnrecognizedTemplateIDs"

    /// Built-in-ID templates flagged during the spoken-command-rules migration as containing an
    /// unrecognized variant of the legacy section (PLAN.md PR A, item 5) — surfaced as a one-time
    /// warning in Settings ("legacy rules still active despite the toggle being off"). Persisted
    /// so the warning survives relaunch until explicitly dismissed via
    /// `dismissLegacyCommandRuleWarning()`.
    @Published private(set) var unrecognizedLegacyCommandRuleTemplateIDs: [String]

    func dismissLegacyCommandRuleWarning() {
        unrecognizedLegacyCommandRuleTemplateIDs = []
        defaults.set([String](), forKey: Self.legacyCommandRuleWarningKey)
    }

    /// Merges newly-discovered unrecognized-legacy-variant built-in IDs into the persisted,
    /// one-time Settings warning set. Shared by `init` (local migration) and `importTemplates`
    /// (PLAN.md PR A, item 5 — restoring a pre-feature backup can reintroduce the legacy section
    /// under a built-in ID; that must surface the same warning as the local migration does).
    private func recordUnrecognizedLegacyCommandRuleIDs(_ newIDs: [String]) {
        guard !newIDs.isEmpty else { return }
        let merged = Array(Set(unrecognizedLegacyCommandRuleTemplateIDs + newIDs)).sorted()
        unrecognizedLegacyCommandRuleTemplateIDs = merged
        defaults.set(merged, forKey: Self.legacyCommandRuleWarningKey)
    }

    /// Complete old→new ID map covering EVERY template `importTemplates` was asked to import:
    /// appended-with-fresh-ID → new ID, appended-keeping-ID → same ID, and skipped-as-duplicate
    /// → the matching EXISTING template's ID. Callers (e.g. Backup Bundle restore) use this to
    /// rewrite `activeTemplateID`/`appRules` references so they never dangle. See PLAN.md F1.5.
    struct ImportResult: Equatable, Sendable {
        let idMap: [String: String]
        let importedCount: Int
        let skippedCount: Int
    }

    @Published private(set) var templates: [Template]

    private let fileURL: URL
    private let defaults: UserDefaults

    private convenience init() {
        let dir = FreeTalkerPaths.applicationSupport
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.init(fileURL: dir.appendingPathComponent("templates.json"), defaults: .standard)
    }

    // Internal (not private) so tests can point the store at an isolated file — see
    // Tests/FreeTalkerTests/TemplateImportTests.swift.
    convenience init(fileURL: URL) {
        self.init(fileURL: fileURL, defaults: .standard)
    }

    init(fileURL: URL, defaults: UserDefaults) {
        self.fileURL = fileURL
        self.defaults = defaults
        unrecognizedLegacyCommandRuleTemplateIDs = defaults.stringArray(forKey: Self.legacyCommandRuleWarningKey) ?? []

        let loadedTemplates: [Template]
        let didSeed: Bool
        if let data = try? Data(contentsOf: fileURL),
           let loaded = try? JSONDecoder().decode([Template].self, from: data) {
            loadedTemplates = loaded
            didSeed = false
        } else {
            loadedTemplates = Template.builtIns
            didSeed = true
        }

        let (upgraded, changed) = Template.upgradingBuiltIns(loadedTemplates)
        let (renamedTemplates, renameChanged) = Self.renamingReservedNameCollisions(upgraded)
        var renamed = renamedTemplates
        let migrationComplete = defaults.integer(forKey: Self.promptEngineerMigrationKey)
            >= Self.promptEngineerMigrationVersion
        let migrationNeeded = !migrationComplete
        let hasPromptEngineer = renamed.contains { $0.id == "prompt-engineer" }
        var addedPromptEngineer = false
        var migrationReady = true
        if migrationNeeded && !loadedTemplates.isEmpty && !hasPromptEngineer {
            if let promptEngineer = Template.builtIns.first(where: { $0.id == "prompt-engineer" }) {
                renamed.append(promptEngineer)
                addedPromptEngineer = true
            } else {
                migrationReady = false
            }
        }

        let modelPromptEngineersMigrationComplete = defaults.integer(forKey: Self.modelPromptEngineersMigrationKey)
            >= Self.modelPromptEngineersMigrationVersion
        let modelPromptEngineersMigrationNeeded = !modelPromptEngineersMigrationComplete
        var modelPromptEngineersMigrationReady = true
        if modelPromptEngineersMigrationNeeded && !loadedTemplates.isEmpty {
            let existingIDs = Set(renamed.map(\.id))
            let missingIDs = Template.modelPromptEngineerIDs.filter { !existingIDs.contains($0) }
            for id in missingIDs {
                guard let template = Template.builtIns.first(where: { $0.id == id }) else {
                    modelPromptEngineersMigrationReady = false
                    continue
                }
                renamed.append(template)
            }
        }

        let spokenCommandMigrationComplete = defaults.integer(forKey: Self.spokenCommandRulesMigrationKey)
            >= Self.spokenCommandRulesMigrationVersion
        let spokenCommandMigrationNeeded = !spokenCommandMigrationComplete
        var newlyUnrecognizedIDs: [String] = []
        if spokenCommandMigrationNeeded {
            let (migrated, _, unrecognizedIDs) = Template.migratingSpokenCommandRules(renamed)
            renamed = migrated
            newlyUnrecognizedIDs = unrecognizedIDs
        }
        templates = renamed

        // Codex round-7 finding 9: reconcile any warning IDs left pending by a prior
        // `importTemplates(_:)` call that was interrupted between precommitting them and
        // promoting them into `legacyCommandRuleWarningKey`. Only promote an ID whose loaded
        // template ACTUALLY still carries the unrecognized variant — if the matching
        // `mutateAndSave` never landed (or landed differently), the loaded content won't match
        // and the stale pending entry is silently dropped, never surfaced as a false warning.
        if let pendingIDs = defaults.stringArray(forKey: Self.pendingLegacyCommandRuleWarningKey),
           !pendingIDs.isEmpty {
            let stillUnrecognized = pendingIDs.filter { id in
                guard let template = templates.first(where: { $0.id == id }) else { return false }
                return Template.containsUnrecognizedLegacyCommandRuleVariant(template.prompt)
            }
            if !stillUnrecognized.isEmpty {
                recordUnrecognizedLegacyCommandRuleIDs(stillUnrecognized)
            }
            defaults.removeObject(forKey: Self.pendingLegacyCommandRuleWarningKey)
        }

        let needsSave = migrationNeeded || didSeed || changed || renameChanged || addedPromptEngineer
            || spokenCommandMigrationNeeded || modelPromptEngineersMigrationNeeded
        if needsSave {
            // ponytail: init can't throw here without changing every call site (this predates
            // throwing save()); a failed initial-seed write just means it retries on next
            // mutation, same as before this change. Upgrade path: surface via a published error.
            do {
                try save()
                if migrationNeeded && migrationReady {
                    defaults.set(Self.promptEngineerMigrationVersion, forKey: Self.promptEngineerMigrationKey)
                }
                if modelPromptEngineersMigrationNeeded && modelPromptEngineersMigrationReady {
                    defaults.set(
                        Self.modelPromptEngineersMigrationVersion,
                        forKey: Self.modelPromptEngineersMigrationKey
                    )
                }
                // Marker (and the unrecognized-template warning it gates) is only persisted once
                // `save()` has actually landed the stripped text on disk — mirrors promptEngineer's
                // migrationReady gate above. A failed save leaves the marker unset so init retries
                // the whole migration (strip + re-scan for unrecognized variants) on next launch,
                // instead of silently stranding legacy text with the marker claiming "done".
                if spokenCommandMigrationNeeded {
                    // Codex round-7 finding 10: warning IDs must be durable BEFORE the completion
                    // marker, not after — the previous order left a kill window where the marker
                    // landed (so the migration never reruns) but the matching warning was lost
                    // forever. This order's own kill window (warning lands, marker doesn't) is
                    // safe: the whole migration is a cheap, idempotent re-strip + re-scan that
                    // simply reruns and completes properly on the next launch.
                    recordUnrecognizedLegacyCommandRuleIDs(newlyUnrecognizedIDs)
                    defaults.set(Self.spokenCommandRulesMigrationVersion, forKey: Self.spokenCommandRulesMigrationKey)
                }
            } catch {
                // A failed migration save leaves its marker unset, so initialization retries it
                // on the next launch without claiming that the on-disk library was updated.
            }
        }
    }

    func template(id: String) -> Template? {
        templates.first { $0.id == id }
    }

    func upsert(_ template: Template) throws {
        guard !Self.isReservedTemplateName(template.name) else {
            throw TemplateStoreError.reservedName
        }
        try mutateAndSave { templates in
            if let index = templates.firstIndex(where: { $0.id == template.id }) {
                templates[index] = template
            } else {
                templates.append(template)
            }
        }
    }

    func delete(id: String) throws {
        try mutateAndSave { templates in
            templates.removeAll { $0.id == id }
        }
    }

    /// Merges templates decoded from `data` (either a `[Template]` array, the same shape as
    /// templates.json, or a single `Template` object) into the existing library. Thin wrapper
    /// over `importTemplates(_:)` that preserves the historical Data-based entry point (Templates
    /// tab's file importer, `TemplateImportTests`).
    @discardableResult
    func importTemplates(from data: Data) throws -> ImportResult {
        let incoming = try Self.decodeTemplates(from: data)
        return try importTemplates(incoming)
    }

    /// Decodes and validates a template import without touching MainActor state. Callers that
    /// read an external file can run this helper off-main, then pass the validated templates to
    /// `importTemplates(_:)` on the main actor.
    nonisolated static func decodeTemplates(from data: Data) throws -> [Template] {
        guard data.count <= maxImportFileBytes else {
            throw TemplateStoreError.fileTooLarge(maxBytes: maxImportFileBytes)
        }

        let incoming: [Template]
        if let array = try? JSONDecoder().decode([Template].self, from: data) {
            incoming = array
        } else if let single = try? JSONDecoder().decode(Template.self, from: data) {
            incoming = [single]
        } else {
            throw TemplateStoreError.invalidImportData
        }

        guard incoming.count <= maxImportTemplates else {
            throw TemplateStoreError.tooManyTemplates(max: maxImportTemplates)
        }
        for template in incoming {
            guard template.id.utf8.count <= maxImportTemplateIDBytes else {
                throw TemplateStoreError.stringTooLong(field: "template id", maxBytes: maxImportTemplateIDBytes)
            }
            guard template.name.utf8.count <= maxImportTemplateNameBytes else {
                throw TemplateStoreError.stringTooLong(field: "template name", maxBytes: maxImportTemplateNameBytes)
            }
            guard template.prompt.utf8.count <= maxImportTemplatePromptBytes else {
                throw TemplateStoreError.stringTooLong(field: "template prompt", maxBytes: maxImportTemplatePromptBytes)
            }
        }
        return incoming
    }

    /// Reads at most one byte beyond the import limit before delegating to the pure decoder, so
    /// external files can be rejected without allocating an unbounded `Data` value.
    nonisolated static func loadTemplates(from url: URL) throws -> [Template] {
        let maxRead = maxImportFileBytes + 1
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var data = Data()
        while data.count < maxRead {
            guard let chunk = try handle.read(upToCount: maxRead - data.count), !chunk.isEmpty else {
                break
            }
            data.append(chunk)
        }
        return try decodeTemplates(from: data)
    }

    /// Merges already-decoded `incoming` templates into the existing library. Never deletes or
    /// modifies existing templates; fresh IDs for appended rows whose incoming ID is empty or
    /// collides with an existing one. Returns a complete old→new ID map — see `ImportResult`.
    /// Used directly by Backup Bundle restore, which validates+bounds-checks the array before
    /// this ever runs (PLAN.md F1.4/F1.5), so this method itself does no bounds checking.
    func importTemplates(_ incoming: [Template]) throws -> ImportResult {
        // Reconcile recognized historical built-in IDs BEFORE dedup/remapping (PLAN.md PR A, item
        // 5 / finding 3): a pre-feature backup can carry a built-in-ID prompt still ending in the
        // legacy spoken-command suffix. Left unstripped, that prompt no longer matches the
        // library's current (migrated) built-in text, so dedupe treats it as new content and
        // remaps it onto a fresh UUID id — silently reactivating the legacy command rules (which
        // apply regardless of the toggle) under a template that's no longer recognized as a
        // built-in. Stripping first lets a pristine legacy built-in dedupe cleanly against the
        // current one, exactly like the local migration does; unrecognized variants are left
        // intact and flagged via the same one-time Settings warning.
        let (reconciled, _, unrecognizedIDs) = Template.migratingSpokenCommandRules(incoming)
        let unrecognizedIDSet = Set(unrecognizedIDs)

        var existingIDs = Set(templates.map(\.id))
        // `templates` can itself already contain two entries with the same (name, prompt) —
        // e.g. clicking "+" twice creates two "New Template"/empty-prompt rows — so
        // `uniqueKeysWithValues:` (which traps on a duplicate key) is unsafe here. Keep the
        // FIRST occurrence deterministically: it's the earliest-created of the colliding
        // templates, so it's the one dedupe/remap logic below treats as canonical. See P1 crash
        // finding.
        var existingIDByDedupeKey = Dictionary(templates.map { (Self.dedupeKey($0), $0.id) }, uniquingKeysWith: { first, _ in first })
        var idMap: [String: String] = [:]
        var toImport: [Template] = []
        var importedUnrecognizedIDs: [String] = []

        for var template in reconciled {
            let key = Self.dedupeKey(template)
            if let existingID = existingIDByDedupeKey[key] {
                // Skipped as a duplicate of existing content — map its old id (if it had one) to
                // the EXISTING template's id, so a restored `activeTemplateID`/`appRules`
                // reference that pointed at this incoming template still resolves. See F1.5.
                if !template.id.isEmpty { idMap[template.id] = existingID }
                continue
            }

            let originalID = template.id
            if template.id.isEmpty || existingIDs.contains(template.id) {
                template.id = UUID().uuidString
            }
            existingIDs.insert(template.id)
            existingIDByDedupeKey[key] = template.id
            if !originalID.isEmpty { idMap[originalID] = template.id }
            // Codex round-8 finding 4: append the FINAL `template.id` (post-remap), not
            // `originalID` — a colliding unrecognized-variant built-in gets remapped to a fresh
            // UUID just above, so the pending/committed warning key must reference the id the
            // content actually lands under in `templates`/`templates.json`. Keying on
            // `originalID` here left both the pending-key reconciliation at `init` (which looks up
            // `templates.first(where: { $0.id == id })`) and any direct lookup unable to find the
            // remapped entry — silently dropping the warning while the remapped legacy-rule
            // template survived un-warned.
            if unrecognizedIDSet.contains(originalID) { importedUnrecognizedIDs.append(template.id) }
            toImport.append(template)
        }

        let skippedCount = incoming.count - toImport.count
        guard !toImport.isEmpty else {
            return ImportResult(idMap: idMap, importedCount: 0, skippedCount: skippedCount)
        }

        let (renamed, _) = Self.renamingReservedNameCollisions(toImport)
        // Codex round-7 finding 9: round-6's fix (precommit the warning to the COMMITTED key,
        // roll back on catch) still has a crash window an ordinary `catch` can't close — a hard
        // kill between the precommit and `mutateAndSave` landing left a permanent false warning
        // with no matching import, since nothing ever revisited it. Precommitting to a separate
        // PENDING key instead, and only promoting it into the committed key once `mutateAndSave`
        // actually lands, means a hard kill anywhere in this sequence leaves at most a stale
        // pending entry — reconciled against the loaded templates.json the next time the store
        // is initialized (see `init`), never surfaced as a warning unless the corresponding
        // template content is actually on disk.
        if !importedUnrecognizedIDs.isEmpty {
            defaults.set(importedUnrecognizedIDs, forKey: Self.pendingLegacyCommandRuleWarningKey)
        }
        try mutateAndSave { templates in
            templates.append(contentsOf: renamed)
        }
        if !importedUnrecognizedIDs.isEmpty {
            recordUnrecognizedLegacyCommandRuleIDs(importedUnrecognizedIDs)
            defaults.removeObject(forKey: Self.pendingLegacyCommandRuleWarningKey)
        }
        return ImportResult(idMap: idMap, importedCount: renamed.count, skippedCount: skippedCount)
    }

    /// Encodes only the template library as stable, human-readable JSON suitable for sharing or
    /// importing back through `importTemplates(from:)`.
    func exportTemplatesJSON() throws -> Data {
        try Self.encodeTemplates(templates)
    }

    nonisolated static func encodeTemplates(_ templates: [Template]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(templates)
    }

    private static func dedupeKey(_ template: Template) -> String {
        "\(template.name)\u{0}\(template.prompt)"
    }

    nonisolated static func isReservedTemplateName(_ name: String) -> Bool {
        name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == rawTranscriptTemplateName.lowercased()
    }

    nonisolated static func renamingReservedNameCollisions(_ templates: [Template]) -> (templates: [Template], changed: Bool) {
        var changed = false
        let renamed = templates.map { template -> Template in
            guard isReservedTemplateName(template.name) else { return template }
            changed = true
            var updated = template
            updated.name = "\(rawTranscriptTemplateName) (Template)"
            return updated
        }
        return (renamed, changed)
    }

    /// Applies `mutate` to `templates` and persists, rolling the in-memory array back to its
    /// pre-mutation state (and rethrowing) if the save fails — so a failed write is observable
    /// (see `save()`) AND never leaves `templates` claiming a change that isn't on disk. See
    /// PLAN.md F1.5.
    private func mutateAndSave(_ mutate: (inout [Template]) -> Void) throws {
        let previous = templates
        mutate(&templates)
        do {
            try save()
        } catch {
            templates = previous
            throw error
        }
    }

    /// Throwing: encode/filesystem failures are surfaced to the caller rather than swallowed, so
    /// e.g. Backup Bundle restore can observe and report a failed templates stage. See PLAN.md
    /// F1.5.
    private func save() throws {
        let data = try JSONEncoder().encode(templates)
        try data.write(to: fileURL, options: .atomic)
    }
}
