import Foundation
import Testing
@testable import FreeTalker

@MainActor
struct TemplateImportTests {
    @Test func importsArrayOfNewTemplatesWithoutTouchingExisting() throws {
        let store = try makeStore()
        let existing = store.templates

        let incoming = [
            Template(id: "a", name: "Meeting Notes", prompt: "Summarize this meeting."),
            Template(id: "b", name: "Bug Report", prompt: "Format this as a bug report.")
        ]
        let count = try store.importTemplates(from: encode(incoming))

        #expect(count == 2)
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
        let count = try store.importTemplates(from: encode([duplicate]))

        #expect(count == 0)
        #expect(store.templates.filter { $0.name == "Seeded Template" }.count == 1)
    }

    @Test func reassignsFreshIDOnCollisionWithDifferentContent() throws {
        let store = try makeStore()
        let seeded = Template(id: "shared-id", name: "Original", prompt: "Original prompt.")
        try store.upsert(seeded)

        let colliding = Template(id: "shared-id", name: "Imported", prompt: "Imported prompt.")
        let count = try store.importTemplates(from: encode([colliding]))

        #expect(count == 1)
        #expect(store.template(id: "shared-id") == seeded)
        let imported = try #require(store.templates.first { $0.name == "Imported" })
        #expect(imported.id != "shared-id")
        #expect(imported.prompt == "Imported prompt.")
    }

    @Test func renamesReservedNameInsteadOfThrowing() throws {
        let store = try makeStore()
        let reserved = Template(id: "raw", name: "raw transcript", prompt: "Reserved collision.")

        let count = try store.importTemplates(from: encode([reserved]))

        #expect(count == 1)
        let imported = try #require(store.templates.first { $0.prompt == "Reserved collision." })
        #expect(imported.name != "raw transcript")
        #expect(!TemplateStore.isReservedTemplateName(imported.name))
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

        let count = try store.importTemplates(from: encode(single))

        #expect(count == 1)
        #expect(store.templates.contains { $0.name == "Single Import" })
    }

    private func makeStore() throws -> TemplateStore {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("template-import-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileURL = directory.appendingPathComponent("templates.json")
        return TemplateStore(fileURL: fileURL)
    }

    private func encode(_ templates: [Template]) throws -> Data {
        try JSONEncoder().encode(templates)
    }

    private func encode(_ template: Template) throws -> Data {
        try JSONEncoder().encode(template)
    }
}
