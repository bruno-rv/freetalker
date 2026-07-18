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

        #expect(store.templates.count == prePromptTemplates.count + 1)
        #expect(Set(store.templates.map(\.id)) == Set(["clean-dictation", "email", "custom", "prompt-engineer"]))
        #expect(store.template(id: "clean-dictation")?.prompt == Template.builtIns.first { $0.id == "clean-dictation" }?.prompt)
        #expect(store.template(id: "email") == customizedEmail)
        #expect(store.template(id: "custom") == custom)
        #expect(store.template(id: "prompt-engineer") == Template.builtIns.first { $0.id == "prompt-engineer" })
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
        #expect(store.templates == [customized])

        try store.delete(id: "prompt-engineer")
        let reloaded = TemplateStore(fileURL: fileURL, defaults: defaults)
        #expect(reloaded.template(id: "prompt-engineer") == nil)
        #expect(reloaded.templates.isEmpty)
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
