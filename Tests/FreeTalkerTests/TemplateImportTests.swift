import Foundation
import Testing
@testable import FreeTalker

@MainActor
struct TemplateImportTests {
    // `importTemplates` now returns `TemplateStore.ImportResult` (idMap + counts) instead of a
    // bare `Int` — Backup Bundle restore needs the old→new ID map to rewrite `activeTemplateID`/
    // `appRules` references (PLAN.md F1.5). Every existing case below is preserved unchanged;
    // each is extended with an `idMap` assertion for the case it already covers.
    @Test func importsArrayOfNewTemplatesWithoutTouchingExisting() throws {
        let store = try makeStore()
        let existing = store.templates

        let incoming = [
            Template(id: "a", name: "Meeting Notes", prompt: "Summarize this meeting."),
            Template(id: "b", name: "Bug Report", prompt: "Format this as a bug report.")
        ]
        let result = try store.importTemplates(from: encode(incoming))

        #expect(result.importedCount == 2)
        #expect(result.skippedCount == 0)
        // Appended-keeping-ID: ids "a"/"b" didn't collide, so the map is identity.
        #expect(result.idMap == ["a": "a", "b": "b"])
        #expect(store.templates.contains { $0.name == "Meeting Notes" && $0.prompt == "Summarize this meeting." })
        #expect(store.templates.contains { $0.name == "Bug Report" && $0.prompt == "Format this as a bug report." })
        for template in existing {
            #expect(store.template(id: template.id) == template)
        }
    }

    @Test func skipsExactDuplicateOfExistingNameAndPrompt() throws {
        let store = try makeStore()
        let seeded = Template(id: "seed", name: "Seeded Template", prompt: "Seeded prompt.")
        try store.upsert(seeded)

        let duplicate = Template(id: "different-id", name: "Seeded Template", prompt: "Seeded prompt.")
        let result = try store.importTemplates(from: encode([duplicate]))

        #expect(result.importedCount == 0)
        #expect(result.skippedCount == 1)
        // Skipped-as-duplicate: maps the incoming id to the matching EXISTING template's id.
        #expect(result.idMap == ["different-id": "seed"])
        #expect(store.templates.filter { $0.name == "Seeded Template" }.count == 1)
    }

    @Test func reassignsFreshIDOnCollisionWithDifferentContent() throws {
        let store = try makeStore()
        let seeded = Template(id: "shared-id", name: "Original", prompt: "Original prompt.")
        try store.upsert(seeded)

        let colliding = Template(id: "shared-id", name: "Imported", prompt: "Imported prompt.")
        let result = try store.importTemplates(from: encode([colliding]))

        #expect(result.importedCount == 1)
        #expect(store.template(id: "shared-id") == seeded)
        let imported = try #require(store.templates.first { $0.name == "Imported" })
        #expect(imported.id != "shared-id")
        #expect(imported.prompt == "Imported prompt.")
        // Appended-with-fresh-ID: maps the incoming (colliding) id to the freshly-minted id.
        #expect(result.idMap["shared-id"] == imported.id)
    }

    @Test func renamesReservedNameInsteadOfThrowing() throws {
        let store = try makeStore()
        let reserved = Template(id: "raw", name: "raw transcript", prompt: "Reserved collision.")

        let result = try store.importTemplates(from: encode([reserved]))

        #expect(result.importedCount == 1)
        let imported = try #require(store.templates.first { $0.prompt == "Reserved collision." })
        #expect(imported.name != "raw transcript")
        #expect(!TemplateStore.isReservedTemplateName(imported.name))
        #expect(result.idMap == ["raw": "raw"])
    }

    @Test func doesNotTrapWhenExistingLibraryAlreadyHasDuplicateContent() throws {
        // Reachable via "+" clicked twice (two "New Template"/empty-prompt rows) before this
        // fix shipped. `Dictionary(uniqueKeysWithValues:)` would trap building the dedupe index
        // from `templates` itself; must instead dedupe against the first of the two.
        let store = try makeStore()
        let first = Template(id: "dup-1", name: "New Template", prompt: "")
        let second = Template(id: "dup-2", name: "New Template", prompt: "")
        try store.upsert(first)
        try store.upsert(second)

        let incoming = Template(id: "incoming", name: "New Template", prompt: "")
        let result = try store.importTemplates(from: encode([incoming]))

        #expect(result.importedCount == 0)
        #expect(result.skippedCount == 1)
        // Deduped against the FIRST existing colliding template, not the second.
        #expect(result.idMap == ["incoming": "dup-1"])
        #expect(store.templates.filter { $0.name == "New Template" && $0.prompt == "" }.count == 2)
    }

    @Test func malformedJSONThrows() throws {
        let store = try makeStore()
        let malformed = Data("{ not valid json".utf8)

        #expect(throws: (any Error).self) {
            try store.importTemplates(from: malformed)
        }
    }

    @Test func importsSingleTemplateObjectShape() throws {
        let store = try makeStore()
        let single = Template(id: "single", name: "Single Import", prompt: "A single template object.")

        let result = try store.importTemplates(from: encode(single))

        #expect(result.importedCount == 1)
        #expect(store.templates.contains { $0.name == "Single Import" })
    }

    @Test func exportsTemplatesAsStableJSONThatRoundTripsUserTemplates() throws {
        let store = try makeStore()
        let custom = Template(id: "custom-id", name: "Meeting Notes", prompt: "Summarize this meeting.")
        try store.upsert(custom)

        let data = try store.exportTemplatesJSON()
        let repeatedData = try store.exportTemplatesJSON()
        let decoded = try JSONDecoder().decode([Template].self, from: data)
        let jsonArray = try #require(JSONSerialization.jsonObject(with: data) as? [[String: Any]])

        #expect(decoded == store.templates)
        #expect(data == repeatedData)
        #expect(jsonArray.allSatisfy { Set($0.keys) == ["id", "name", "prompt"] })
        #expect(String(decoding: data, as: UTF8.self).contains("\n"))

        let roundTripStore = try makeStore()
        let result = try roundTripStore.importTemplates(from: data)
        #expect(result.importedCount == 1)
        #expect(roundTripStore.template(id: custom.id) == custom)
    }

    @Test func seedsPromptEngineerAsABuiltIn() throws {
        let store = try makeStore()

        #expect(Template.builtIns.contains { $0.id == "prompt-engineer" && $0.name == "Prompt Engineer" })
        #expect(store.templates.contains { $0.id == "prompt-engineer" && $0.name == "Prompt Engineer" })
    }

    @Test func migratesPromptEngineerIntoAnExistingPrePromptLibraryOnlyOnce() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("template-migration-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileURL = directory.appendingPathComponent("templates.json")
        let legacyClean = Template(
            id: "clean-dictation", name: "Clean Dictation",
            prompt: try #require(Template.legacyPrompts["clean-dictation"]?.first)
        )
        let customizedEmail = Template(id: "email", name: "Email", prompt: "My customized email prompt")
        let custom = Template(id: "custom", name: "My Template", prompt: "My prompt")
        let prePromptTemplates = [legacyClean, customizedEmail, custom]
        try encode(prePromptTemplates).write(to: fileURL)

        let defaults = try isolatedDefaults()
        let store = TemplateStore(fileURL: fileURL, defaults: defaults)

        // A pre-existing library also predates the three model-specific Prompt Engineer
        // built-ins, so their own migration appends those alongside `prompt-engineer`.
        #expect(store.templates.count == prePromptTemplates.count + 1 + Template.modelPromptEngineerIDs.count)
        #expect(Set(store.templates.map(\.id)) == Set(
            ["clean-dictation", "email", "custom", "prompt-engineer"] + Template.modelPromptEngineerIDs
        ))
        #expect(store.template(id: "clean-dictation")?.prompt == Template.builtIns.first { $0.id == "clean-dictation" }?.prompt)
        #expect(store.template(id: "email") == customizedEmail)
        #expect(store.template(id: "custom") == custom)
        #expect(store.template(id: "prompt-engineer") == Template.builtIns.first { $0.id == "prompt-engineer" })
        for id in Template.modelPromptEngineerIDs {
            #expect(store.template(id: id) == Template.builtIns.first { $0.id == id })
        }
        #expect(store.template(id: "refined-prompt") == nil)

        try store.delete(id: "prompt-engineer")
        let reloaded = TemplateStore(fileURL: fileURL, defaults: defaults)
        #expect(reloaded.template(id: "prompt-engineer") == nil)
        #expect(reloaded.templates == store.templates.filter { $0.id != "prompt-engineer" })
    }

    @Test func preservesAnExistingCustomizedPromptEngineerAndDoesNotReaddIt() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("template-migration-custom-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileURL = directory.appendingPathComponent("templates.json")
        let customized = Template(id: "prompt-engineer", name: "Prompt Engineer", prompt: "My custom prompt")
        try encode([customized]).write(to: fileURL)
        let defaults = try isolatedDefaults()

        let store = TemplateStore(fileURL: fileURL, defaults: defaults)
        // The customized `prompt-engineer` is preserved verbatim; the library still lacks the
        // three model-specific Prompt Engineer built-ins, so their own migration appends those.
        #expect(store.template(id: "prompt-engineer") == customized)
        #expect(store.templates.count == 1 + Template.modelPromptEngineerIDs.count)
        for id in Template.modelPromptEngineerIDs {
            #expect(store.template(id: id) == Template.builtIns.first { $0.id == id })
        }

        try store.delete(id: "prompt-engineer")
        for id in Template.modelPromptEngineerIDs {
            try store.delete(id: id)
        }
        let reloaded = TemplateStore(fileURL: fileURL, defaults: defaults)
        #expect(reloaded.template(id: "prompt-engineer") == nil)
        #expect(reloaded.templates.isEmpty)
    }

    @Test func seedsModelPromptEngineersAsBuiltIns() throws {
        let store = try makeStore()

        for id in Template.modelPromptEngineerIDs {
            #expect(Template.builtIns.contains { $0.id == id })
            #expect(store.templates.contains { $0.id == id })
        }
        #expect(store.templates.contains { $0.id == "prompt-engineer-fable-5" && $0.name == "Prompt Engineer (Fable 5)" })
        #expect(store.templates.contains { $0.id == "prompt-engineer-opus-4-8" && $0.name == "Prompt Engineer (Opus 4.8)" })
        #expect(store.templates.contains { $0.id == "prompt-engineer-sonnet-5" && $0.name == "Prompt Engineer (Sonnet 5)" })
    }

    @Test func migratesModelPromptEngineersIntoAnExistingLibraryOnlyOnce() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("template-migration-model-pe-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileURL = directory.appendingPathComponent("templates.json")
        let cleanDictation = try #require(Template.builtIns.first { $0.id == "clean-dictation" })
        // Includes `prompt-engineer` already, so only the model-specific migration fires here —
        // its own migration is covered separately above.
        let promptEngineer = try #require(Template.builtIns.first { $0.id == "prompt-engineer" })
        let custom = Template(id: "custom", name: "My Template", prompt: "My prompt")
        let preTemplates = [cleanDictation, promptEngineer, custom]
        try encode(preTemplates).write(to: fileURL)

        let defaults = try isolatedDefaults()
        let store = TemplateStore(fileURL: fileURL, defaults: defaults)

        #expect(store.templates.count == preTemplates.count + Template.modelPromptEngineerIDs.count)
        for id in Template.modelPromptEngineerIDs {
            #expect(store.template(id: id) == Template.builtIns.first { $0.id == id })
        }

        // Deleting one and reloading must NOT re-add it.
        try store.delete(id: "prompt-engineer-fable-5")
        let reloaded = TemplateStore(fileURL: fileURL, defaults: defaults)
        #expect(reloaded.template(id: "prompt-engineer-fable-5") == nil)
        #expect(reloaded.templates == store.templates.filter { $0.id != "prompt-engineer-fable-5" })
    }

    @Test func preservesAnExistingCustomizedModelPromptEngineerAndDoesNotOverwriteIt() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("template-migration-model-pe-custom-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileURL = directory.appendingPathComponent("templates.json")
        let cleanDictation = try #require(Template.builtIns.first { $0.id == "clean-dictation" })
        let promptEngineer = try #require(Template.builtIns.first { $0.id == "prompt-engineer" })
        let customizedSonnet = Template(
            id: "prompt-engineer-sonnet-5", name: "Prompt Engineer (Sonnet 5)", prompt: "My custom sonnet prompt"
        )
        try encode([cleanDictation, promptEngineer, customizedSonnet]).write(to: fileURL)
        let defaults = try isolatedDefaults()

        let store = TemplateStore(fileURL: fileURL, defaults: defaults)

        #expect(store.template(id: "prompt-engineer-sonnet-5") == customizedSonnet)
        // The two IDs still missing get appended, the customized one is left untouched.
        #expect(store.template(id: "prompt-engineer-fable-5") == Template.builtIns.first { $0.id == "prompt-engineer-fable-5" })
        #expect(store.template(id: "prompt-engineer-opus-4-8") == Template.builtIns.first { $0.id == "prompt-engineer-opus-4-8" })
    }

    @Test func preservesAValidEmptyLibraryInsteadOfReseedingBuiltIns() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("template-migration-empty-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileURL = directory.appendingPathComponent("templates.json")
        try encode([]).write(to: fileURL)
        let defaults = try isolatedDefaults()

        let store = TemplateStore(fileURL: fileURL, defaults: defaults)
        #expect(store.templates.isEmpty)

        let reloaded = TemplateStore(fileURL: fileURL, defaults: defaults)
        #expect(reloaded.templates.isEmpty)
    }

    @Test func rejectsOversizedImportData() throws {
        let store = try makeStore()
        let oversized = Data(repeating: 0, count: 5 * 1024 * 1024 + 1)

        #expect(throws: TemplateStore.TemplateStoreError.fileTooLarge(maxBytes: 5 * 1024 * 1024)) {
            try store.importTemplates(from: oversized)
        }
    }

    @Test func boundedFileLoaderRejectsOversizedImportBeforeDecoding() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("template-import-file-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileURL = directory.appendingPathComponent("oversized.json")
        try Data(repeating: 0, count: 5 * 1024 * 1024 + 1).write(to: fileURL)

        #expect(throws: TemplateStore.TemplateStoreError.fileTooLarge(maxBytes: 5 * 1024 * 1024)) {
            try TemplateStore.loadTemplates(from: fileURL)
        }
    }

    @Test func rejectsTooManyImportedTemplates() throws {
        let store = try makeStore()
        let incoming = (0..<501).map { index in
            Template(id: "template-\(index)", name: "Template \(index)", prompt: "Prompt \(index)")
        }

        #expect(throws: TemplateStore.TemplateStoreError.tooManyTemplates(max: 500)) {
            try store.importTemplates(from: encode(incoming))
        }
    }

    @Test func rejectsOversizedImportedTemplateFields() throws {
        let store = try makeStore()
        let oversizedID = Template(id: String(repeating: "i", count: 501), name: "Name", prompt: "Prompt")
        let oversizedName = Template(id: "long-name", name: String(repeating: "n", count: 501), prompt: "Prompt")
        let oversizedPrompt = Template(id: "long-prompt", name: "Name", prompt: String(repeating: "p", count: 50_001))

        #expect(throws: TemplateStore.TemplateStoreError.stringTooLong(field: "template id", maxBytes: 500)) {
            try store.importTemplates(from: encode(oversizedID))
        }
        #expect(throws: TemplateStore.TemplateStoreError.stringTooLong(field: "template name", maxBytes: 500)) {
            try store.importTemplates(from: encode(oversizedName))
        }
        #expect(throws: TemplateStore.TemplateStoreError.stringTooLong(field: "template prompt", maxBytes: 50_000)) {
            try store.importTemplates(from: encode(oversizedPrompt))
        }
    }

    // MARK: - Spoken-command-rules migration (PLAN.md PR A, item 5)

    @Test func pristineBuiltInHasTheExactLegacySuffixStrippedAndMatchesTheCurrentBuiltIn() throws {
        let directory = try Self.migrationDirectory()
        let fileURL = directory.appendingPathComponent("templates.json")
        let currentClean = try #require(Template.builtIns.first { $0.id == "clean-dictation" })
        var pristine = currentClean
        pristine.prompt += Template.legacySpokenCommandsSuffix
        try encode([pristine]).write(to: fileURL)
        let defaults = try isolatedDefaults()

        let store = TemplateStore(fileURL: fileURL, defaults: defaults)

        #expect(store.template(id: "clean-dictation") == currentClean)
        #expect(store.unrecognizedLegacyCommandRuleTemplateIDs.isEmpty)
    }

    @Test func editedBuiltInKeepsItsOwnEditsWithOnlyTheExactLegacySuffixRemoved() throws {
        let directory = try Self.migrationDirectory()
        let fileURL = directory.appendingPathComponent("templates.json")
        let currentClean = try #require(Template.builtIns.first { $0.id == "clean-dictation" })
        let ownEdit = "Custom prefix I added. " + currentClean.prompt
        let edited = Template(id: "clean-dictation", name: "My Clean Dictation", prompt: ownEdit + Template.legacySpokenCommandsSuffix)
        try encode([edited]).write(to: fileURL)
        let defaults = try isolatedDefaults()

        let store = TemplateStore(fileURL: fileURL, defaults: defaults)

        let migrated = try #require(store.template(id: "clean-dictation"))
        #expect(migrated.prompt == ownEdit)
        #expect(migrated.name == "My Clean Dictation")
        #expect(store.unrecognizedLegacyCommandRuleTemplateIDs.isEmpty)
    }

    @Test func unrecognizedLegacyVariantIsLeftIntactAndFlaggedForAOneTimeWarning() throws {
        let directory = try Self.migrationDirectory()
        let fileURL = directory.appendingPathComponent("templates.json")
        let currentClean = try #require(Template.builtIns.first { $0.id == "clean-dictation" })
        // Doesn't end with the exact known suffix, but still plausibly carries legacy
        // spoken-command wording — must be left untouched, not silently dropped.
        let reworded = currentClean.prompt + " Also, follow any spoken commands like 'scratch that' you hear."
        let unrecognized = Template(id: "clean-dictation", name: "Clean Dictation", prompt: reworded)
        try encode([unrecognized]).write(to: fileURL)
        let defaults = try isolatedDefaults()

        let store = TemplateStore(fileURL: fileURL, defaults: defaults)

        #expect(store.template(id: "clean-dictation")?.prompt == reworded)
        #expect(store.unrecognizedLegacyCommandRuleTemplateIDs == ["clean-dictation"])

        store.dismissLegacyCommandRuleWarning()
        #expect(store.unrecognizedLegacyCommandRuleTemplateIDs.isEmpty)
    }

    /// Regression for finding 5: an edited legacy section that renames the heading and drops
    /// "scratch that" — but keeps paragraph/line/list/quote/caps instructions — must still be
    /// flagged, not silently missed.
    @Test func editedVariantDroppingBothOriginalMarkersButKeepingOtherLegacyRulesIsStillFlagged() throws {
        let directory = try Self.migrationDirectory()
        let fileURL = directory.appendingPathComponent("templates.json")
        let currentClean = try #require(Template.builtIns.first { $0.id == "clean-dictation" })
        // Renames the "Spoken Commands" heading and removes "scratch that" entirely, but keeps
        // the paragraph/line/list/quote/caps instructions verbatim — neither marker the old
        // heuristic checked ("spoken command", "scratch that") is present here.
        let reworded = currentClean.prompt + " Also apply these dictation shortcuts: \"new paragraph\" "
            + "starts a new paragraph; \"new line\" breaks to a new line; \"bullet point\" starts a "
            + "bulleted list item; \"numbered list\" starts a numbered list item; \"quote\" ... "
            + "\"unquote\" wraps the enclosed words in quotation marks; \"all caps\" ... \"end caps\" "
            + "uppercases the enclosed words."
        let unrecognized = Template(id: "clean-dictation", name: "Clean Dictation", prompt: reworded)
        try encode([unrecognized]).write(to: fileURL)
        let defaults = try isolatedDefaults()

        let store = TemplateStore(fileURL: fileURL, defaults: defaults)

        #expect(store.template(id: "clean-dictation")?.prompt == reworded)
        #expect(store.unrecognizedLegacyCommandRuleTemplateIDs == ["clean-dictation"])
    }

    /// Regression for Codex round-2 finding 3: ISOLATED per-convention evasion — an edited
    /// built-in that keeps only ONE convention's clause (every other legacy marker, including the
    /// "Spoken Commands" heading and "scratch that", is gone) must still be flagged. Each case
    /// below drops every marker except the one under test, so a marker-list gap for any single
    /// convention shows up as its own failing case instead of being masked by the others. The
    /// quote case uses the legacy "quote"/"end quote" pairing (not "unquote") — the exact variant
    /// the marker list missed before this fix.
    @Test(
        "isolated legacy convention clause is still flagged",
        arguments: [
            ("paragraph", "\"new paragraph\" starts a new paragraph."),
            ("line", "\"new line\" breaks to a new line."),
            ("bulleted list", "\"bullet point\" starts a bulleted list item."),
            ("numbered list", "\"numbered list\" starts a numbered list item."),
            ("caps", "\"all caps\" ... \"end caps\" uppercases the enclosed words."),
            ("scratch that", "\"scratch that\" removes the most recent sentence or clause."),
            ("quote (legacy \"quote\"/\"end quote\" variant)",
             "\"quote\" ... \"end quote\" wraps the enclosed words in quotation marks.")
        ]
    )
    func isolatedLegacyConventionClauseIsStillFlagged(label: String, clause: String) throws {
        let directory = try Self.migrationDirectory()
        let fileURL = directory.appendingPathComponent("templates.json")
        let currentClean = try #require(Template.builtIns.first { $0.id == "clean-dictation" })
        let reworded = currentClean.prompt + " Also: " + clause
        let unrecognized = Template(id: "clean-dictation", name: "Clean Dictation", prompt: reworded)
        try encode([unrecognized]).write(to: fileURL)
        let defaults = try isolatedDefaults()

        let store = TemplateStore(fileURL: fileURL, defaults: defaults)

        #expect(
            store.unrecognizedLegacyCommandRuleTemplateIDs == ["clean-dictation"],
            Comment(rawValue: label)
        )
    }

    @Test func userCreatedTemplatesAreNeverScannedOrTouchedByTheMigration() throws {
        let directory = try Self.migrationDirectory()
        let fileURL = directory.appendingPathComponent("templates.json")
        // A user-created id (not in `Template.builtIns`) carrying text that would trigger both
        // the suffix-strip and the unrecognized-variant heuristic if it were a built-in id — proves
        // the migration only ever looks at built-in-ID rows.
        let userTemplate = Template(
            id: "my-custom-template", name: "My Template",
            prompt: "Follow spoken commands and scratch that if needed." + Template.legacySpokenCommandsSuffix
        )
        try encode([userTemplate]).write(to: fileURL)
        let defaults = try isolatedDefaults()

        let store = TemplateStore(fileURL: fileURL, defaults: defaults)

        #expect(store.template(id: "my-custom-template") == userTemplate)
        #expect(store.unrecognizedLegacyCommandRuleTemplateIDs.isEmpty)
    }

    @Test func migrationRunsOnlyOnceEvenIfLegacyTextReappearsOnDisk() throws {
        let directory = try Self.migrationDirectory()
        let fileURL = directory.appendingPathComponent("templates.json")
        let currentClean = try #require(Template.builtIns.first { $0.id == "clean-dictation" })
        var pristine = currentClean
        pristine.prompt += Template.legacySpokenCommandsSuffix
        try encode([pristine]).write(to: fileURL)
        let defaults = try isolatedDefaults()

        _ = TemplateStore(fileURL: fileURL, defaults: defaults)
        // Simulates a stale/rolled-back file reappearing with the legacy suffix after the
        // migration marker is already set — the version-gated migration must not re-run and
        // silently strip content the user may have since customized back in.
        try encode([pristine]).write(to: fileURL)

        let reloaded = TemplateStore(fileURL: fileURL, defaults: defaults)

        #expect(reloaded.template(id: "clean-dictation") == pristine)
    }

    /// Codex round-7 finding 10: a kill between the two `defaults.set` calls in the migration's
    /// completion block must never leave the completion marker durable without its matching
    /// warning IDs — the marker being set makes the migration (the only thing that recomputes
    /// those IDs) never rerun, permanently stranding the warning. A raw process kill can't be
    /// simulated deterministically for two back-to-back non-throwing `UserDefaults.set` calls, so
    /// this asserts the property that actually guarantees crash safety here: the warning IDs are
    /// written strictly BEFORE the completion marker, so any interruption between them leaves the
    /// marker unset (migration safely reruns) rather than the warning lost.
    @Test func warningIDsArePersistedBeforeTheMigrationCompletionMarker() throws {
        let directory = try Self.migrationDirectory()
        let fileURL = directory.appendingPathComponent("templates.json")
        let currentClean = try #require(Template.builtIns.first { $0.id == "clean-dictation" })
        let reworded = currentClean.prompt + " Also, follow any spoken commands like 'scratch that' you hear."
        let unrecognized = Template(id: "clean-dictation", name: "Clean Dictation", prompt: reworded)
        try encode([unrecognized]).write(to: fileURL)
        let spy = try #require(UserDefaultsSetOrderSpy(suiteName: "TemplateImportTests.\(UUID().uuidString)"))

        _ = TemplateStore(fileURL: fileURL, defaults: spy)

        let warningIndex = try #require(spy.setOrder.firstIndex(
            of: "TemplateStore.spokenCommandRules.unrecognizedTemplateIDs"
        ))
        let markerIndex = try #require(spy.setOrder.firstIndex(
            of: "TemplateStore.migrations.spokenCommandRules.v1"
        ))
        #expect(warningIndex < markerIndex)
        #expect(spy.stringArray(forKey: "TemplateStore.spokenCommandRules.unrecognizedTemplateIDs")
            == ["clean-dictation"])
    }

    // MARK: - Import-time reconciliation of legacy built-ins (PLAN.md PR A, item 5 / finding 3)

    /// Regression test for restoring a pre-feature (v2) backup: its built-in-ID prompts still
    /// carry the legacy spoken-command suffix. Without reconciling that suffix before dedup, each
    /// pristine legacy built-in fails to match the library's current (already-migrated) prompt,
    /// gets remapped onto a fresh UUID id, and reactivates the legacy command rules regardless of
    /// the (default-off) toggle. Reconciling first must make every pristine legacy built-in dedupe
    /// cleanly against the current one instead.
    @Test func restoringAPreFeatureBackupDedupesPristineLegacyBuiltInsInsteadOfReactivatingThem() throws {
        let store = try makeStore()
        let existingCount = store.templates.count
        let legacyBackup = Template.builtIns.map { template -> Template in
            var legacy = template
            legacy.prompt += Template.legacySpokenCommandsSuffix
            return legacy
        }

        let result = try store.importTemplates(legacyBackup)

        #expect(result.importedCount == 0)
        #expect(result.skippedCount == legacyBackup.count)
        for template in Template.builtIns {
            #expect(result.idMap[template.id] == template.id)
        }
        #expect(store.templates.count == existingCount)
        #expect(store.templates.allSatisfy { !$0.prompt.contains(Template.spokenCommandsSection) })
        #expect(store.unrecognizedLegacyCommandRuleTemplateIDs.isEmpty)
    }

    /// An edited pre-feature built-in (own edits + the legacy suffix) must still have only the
    /// exact legacy suffix stripped before import — the user's edits land as a new row (since the
    /// built-in id already exists locally), but never carrying the reactivated legacy commands.
    @Test func restoringAPreFeatureBackupStripsTheLegacySuffixFromAnEditedBuiltInBeforeImport() throws {
        let store = try makeStore()
        let currentEmail = try #require(Template.builtIns.first { $0.id == "email" })
        let ownEdit = "My customized opening line. " + currentEmail.prompt
        let editedLegacyBackup = Template(
            id: "email", name: "My Email",
            prompt: ownEdit + Template.legacySpokenCommandsSuffix
        )

        let result = try store.importTemplates([editedLegacyBackup])

        #expect(result.importedCount == 1)
        #expect(result.skippedCount == 0)
        let imported = try #require(store.templates.first { $0.name == "My Email" })
        #expect(imported.id != "email")
        #expect(imported.prompt == ownEdit)
        #expect(!imported.prompt.contains(Template.spokenCommandsSection))
        #expect(store.unrecognizedLegacyCommandRuleTemplateIDs.isEmpty)
    }

    /// An unrecognized legacy variant under a built-in id is imported untouched (never silently
    /// dropped) and flagged via the same one-time Settings warning the local migration uses.
    @Test func restoringABackupWithAnUnrecognizedLegacyVariantFlagsItInsteadOfSilentlyDropping() throws {
        let store = try makeStore()
        let currentClean = try #require(Template.builtIns.first { $0.id == "clean-dictation" })
        let reworded = currentClean.prompt + " Also, follow any spoken commands like 'scratch that' you hear."
        let unrecognizedBackup = Template(id: "clean-dictation", name: "Clean Dictation", prompt: reworded)

        let result = try store.importTemplates([unrecognizedBackup])

        #expect(result.importedCount == 1)
        let imported = try #require(store.templates.first { $0.prompt == reworded })
        #expect(imported.id != "clean-dictation")
        // Codex round-8 finding 4: keyed to the FINAL, post-remap id — the incoming template's
        // original "clean-dictation" id collided with the existing clean built-in and was remapped.
        #expect(store.unrecognizedLegacyCommandRuleTemplateIDs == [imported.id])

        store.dismissLegacyCommandRuleWarning()
        #expect(store.unrecognizedLegacyCommandRuleTemplateIDs.isEmpty)
    }

    /// Codex round-8 finding 4: the colliding incoming template's id ("clean-dictation") gets
    /// remapped to a fresh UUID at import time (see the `existingIDs.contains` branch above) since
    /// the local library already holds a CLEAN "clean-dictation" built-in — the reworded content
    /// doesn't dedupe-match it. The warning must be keyed to that FINAL, post-remap id (where the
    /// unrecognized content actually lives), not the original colliding id, which still resolves
    /// to the untouched clean built-in and would silently drop the warning (and, at the next
    /// launch, the same original-id pending entry would find nothing unrecognized under it and be
    /// discarded — permanently losing the warning while the remapped legacy-rule template survives
    /// unflagged).
    @Test func collidingUnrecognizedLegacyVariantWarningIsKeyedToTheRemappedIDNotTheOriginalID() throws {
        let store = try makeStore()
        let currentClean = try #require(Template.builtIns.first { $0.id == "clean-dictation" })
        let reworded = currentClean.prompt + " Also, follow any spoken commands like 'scratch that' you hear."
        let collidingBackup = Template(id: "clean-dictation", name: "Clean Dictation", prompt: reworded)

        let result = try store.importTemplates([collidingBackup])

        let remappedID = try #require(result.idMap["clean-dictation"])
        #expect(remappedID != "clean-dictation")
        #expect(store.unrecognizedLegacyCommandRuleTemplateIDs == [remappedID])
        #expect(store.template(id: remappedID)?.prompt == reworded)
        #expect(store.template(id: "clean-dictation")?.prompt == currentClean.prompt)
    }

    /// Codex round-5 finding 6: the legacy-rules warning must only be recorded once the templates
    /// it describes are durably saved — recording it before `mutateAndSave` left a false warning
    /// behind a rolled-back save (`mutateAndSave` restores `templates` on failure, but the warning
    /// flag wasn't part of that rollback), while Backup Bundle reported zero applied templates.
    @Test func failedSaveDuringImportDoesNotPersistTheLegacyWarning() throws {
        let directory = try Self.migrationDirectory()
        let fileURL = directory.appendingPathComponent("templates.json")
        let defaults = try isolatedDefaults()
        let store = TemplateStore(fileURL: fileURL, defaults: defaults)
        let currentClean = try #require(Template.builtIns.first { $0.id == "clean-dictation" })
        let reworded = currentClean.prompt + " Also, follow any spoken commands like 'scratch that' you hear."
        let unrecognizedBackup = Template(id: "clean-dictation", name: "Clean Dictation", prompt: reworded)
        // Remove the store's directory so the subsequent save() write fails.
        try FileManager.default.removeItem(at: directory)

        #expect(throws: (any Error).self) {
            _ = try store.importTemplates([unrecognizedBackup])
        }

        #expect(store.unrecognizedLegacyCommandRuleTemplateIDs.isEmpty)
        #expect(!store.templates.contains { $0.name == "Clean Dictation" && $0.prompt == reworded })
    }

    /// Codex round-6 finding 5: the warning is now precommitted BEFORE the templates.json save
    /// (closing the crash window between a durable save and a post-save warning write) and rolled
    /// back on an ordinary save failure. This must roll back to the exact PRE-import snapshot —
    /// not an empty array — so an already-legitimate warning from an earlier, successful import
    /// survives a later import whose save fails.
    @Test func failedSaveDuringImportRollsBackToThePriorWarningNotToEmpty() throws {
        let directory = try Self.migrationDirectory()
        let fileURL = directory.appendingPathComponent("templates.json")
        let defaults = try isolatedDefaults()
        let store = TemplateStore(fileURL: fileURL, defaults: defaults)
        let currentClean = try #require(Template.builtIns.first { $0.id == "clean-dictation" })
        let firstReworded = currentClean.prompt + " Also, follow any spoken commands like 'scratch that' you hear."
        let firstResult = try store.importTemplates([
            Template(id: "clean-dictation", name: "Clean Dictation", prompt: firstReworded)
        ])
        // Codex round-8 finding 4: keyed to the FINAL, post-remap id — "clean-dictation" collided
        // with the existing clean built-in and was remapped to a fresh UUID.
        let firstRemappedID = try #require(firstResult.idMap["clean-dictation"])
        #expect(store.unrecognizedLegacyCommandRuleTemplateIDs == [firstRemappedID])

        let currentRefined = try #require(Template.builtIns.first { $0.id == "refined-message" })
        let secondReworded = currentRefined.prompt + " Also, follow any spoken commands like 'scratch that' you hear."
        // Remove the store's directory so the second import's save() write fails.
        try FileManager.default.removeItem(at: directory)

        #expect(throws: (any Error).self) {
            _ = try store.importTemplates([
                Template(id: "refined-message", name: "Refined Message", prompt: secondReworded)
            ])
        }

        #expect(store.unrecognizedLegacyCommandRuleTemplateIDs == [firstRemappedID])
        #expect(defaults.stringArray(forKey: "TemplateStore.spokenCommandRules.unrecognizedTemplateIDs") == [firstRemappedID])
    }

    // MARK: - Pending-warning reconciliation at init (Codex round-7 finding 9)

    /// Round-6's fix (precommit the warning, roll back via `catch`) still had a crash window an
    /// ordinary `catch` can't close — a hard kill between the precommit and `mutateAndSave` landing
    /// left a permanent false warning with no matching import. The new fix precommits to a SEPARATE
    /// pending key and only promotes it once the save actually lands, reconciling the pending key
    /// against the loaded `templates.json` on every subsequent `init`. Simulates that exact crash
    /// directly: a pending entry with no matching unrecognized content on disk must be dropped, not
    /// surfaced. The migration-completion marker is pre-set so the LOCAL migration (a separate
    /// mechanism) can't independently produce the same result and mask a broken fix.
    @Test func pendingWarningIsDroppedAtInitWhenTheMatchingImportNeverLanded() throws {
        let directory = try Self.migrationDirectory()
        let fileURL = directory.appendingPathComponent("templates.json")
        try encode(Template.builtIns).write(to: fileURL)
        let defaults = try isolatedDefaults()
        defaults.set(1, forKey: "TemplateStore.migrations.spokenCommandRules.v1")
        defaults.set(
            ["clean-dictation"],
            forKey: "TemplateStore.spokenCommandRules.pendingUnrecognizedTemplateIDs"
        )

        let store = TemplateStore(fileURL: fileURL, defaults: defaults)

        #expect(store.unrecognizedLegacyCommandRuleTemplateIDs.isEmpty)
        #expect(defaults.stringArray(
            forKey: "TemplateStore.spokenCommandRules.pendingUnrecognizedTemplateIDs"
        ) == nil)
    }

    /// The opposite crash window: `mutateAndSave` DID land (the unrecognized content is durably on
    /// disk) but the process died before promoting the pending warning into the committed key — the
    /// warning must still surface, recovered from the loaded template content itself, never lost.
    @Test func pendingWarningIsPromotedAtInitWhenTheMatchingImportDidLand() throws {
        let directory = try Self.migrationDirectory()
        let fileURL = directory.appendingPathComponent("templates.json")
        let currentClean = try #require(Template.builtIns.first { $0.id == "clean-dictation" })
        let reworded = currentClean.prompt + " Also, follow any spoken commands like 'scratch that' you hear."
        var seeded = Template.builtIns
        let index = try #require(seeded.firstIndex { $0.id == "clean-dictation" })
        seeded[index].prompt = reworded
        try encode(seeded).write(to: fileURL)
        let defaults = try isolatedDefaults()
        defaults.set(1, forKey: "TemplateStore.migrations.spokenCommandRules.v1")
        defaults.set(
            ["clean-dictation"],
            forKey: "TemplateStore.spokenCommandRules.pendingUnrecognizedTemplateIDs"
        )

        let store = TemplateStore(fileURL: fileURL, defaults: defaults)

        #expect(store.unrecognizedLegacyCommandRuleTemplateIDs == ["clean-dictation"])
        #expect(defaults.stringArray(
            forKey: "TemplateStore.spokenCommandRules.pendingUnrecognizedTemplateIDs"
        ) == nil)
    }

    private static func migrationDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("template-command-migration-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func makeStore() throws -> TemplateStore {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("template-import-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileURL = directory.appendingPathComponent("templates.json")
        return TemplateStore(fileURL: fileURL, defaults: try isolatedDefaults())
    }

    private func isolatedDefaults() throws -> UserDefaults {
        try #require(UserDefaults(suiteName: "TemplateImportTests.\(UUID().uuidString)"))
    }

    private func encode(_ templates: [Template]) throws -> Data {
        try JSONEncoder().encode(templates)
    }

    private func encode(_ template: Template) throws -> Data {
        try JSONEncoder().encode(template)
    }
}

/// Records the order of every `UserDefaults.set(_:forKey:)` call while still durably persisting
/// through the real `UserDefaults` superclass — used to assert write ORDERING (the actual property
/// that makes a two-step durable-write sequence crash-safe) without needing to simulate a raw
/// process kill between two non-throwing calls (Codex round-7 finding 10).
private final class UserDefaultsSetOrderSpy: UserDefaults {
    private(set) var setOrder: [String] = []

    override func set(_ value: Any?, forKey defaultName: String) {
        setOrder.append(defaultName)
        super.set(value, forKey: defaultName)
    }
}
