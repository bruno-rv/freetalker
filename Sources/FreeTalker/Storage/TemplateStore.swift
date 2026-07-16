import Foundation

@MainActor
final class TemplateStore: ObservableObject {
    static let shared = TemplateStore()

    nonisolated static let rawTranscriptTemplateName = "Raw Transcript"

    enum TemplateStoreError: LocalizedError {
        case reservedName
        case invalidImportData

        var errorDescription: String? {
            switch self {
            case .reservedName:
                return "\"\(TemplateStore.rawTranscriptTemplateName)\" is reserved for raw dictations and can't be used as a Template name."
            case .invalidImportData:
                return "This file doesn't contain valid FreeTalker templates."
            }
        }
    }

    @Published private(set) var templates: [Template]

    private let fileURL: URL

    private convenience init() {
        let dir = FreeTalkerPaths.applicationSupport
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.init(fileURL: dir.appendingPathComponent("templates.json"))
    }

    // Internal (not private) so tests can point the store at an isolated file — see
    // Tests/FreeTalkerTests/TemplateImportTests.swift.
    init(fileURL: URL) {
        self.fileURL = fileURL

        let loadedTemplates: [Template]
        let didSeed: Bool
        if let data = try? Data(contentsOf: fileURL),
           let loaded = try? JSONDecoder().decode([Template].self, from: data),
           !loaded.isEmpty {
            loadedTemplates = loaded
            didSeed = false
        } else {
            loadedTemplates = Template.builtIns
            didSeed = true
        }

        let (upgraded, changed) = Template.upgradingBuiltIns(loadedTemplates)
        let (renamed, renameChanged) = Self.renamingReservedNameCollisions(upgraded)
        templates = renamed
        if didSeed || changed || renameChanged {
            save()
        }
    }

    func template(id: String) -> Template? {
        templates.first { $0.id == id }
    }

    func upsert(_ template: Template) throws {
        guard !Self.isReservedTemplateName(template.name) else {
            throw TemplateStoreError.reservedName
        }
        if let index = templates.firstIndex(where: { $0.id == template.id }) {
            templates[index] = template
        } else {
            templates.append(template)
        }
        save()
    }

    func delete(id: String) {
        templates.removeAll { $0.id == id }
        save()
    }

    /// Merges templates decoded from `data` (either a `[Template]` array, the same shape as
    /// templates.json, or a single `Template` object) into the existing library. Never deletes
    /// or modifies existing templates. Returns the number of templates actually imported.
    @discardableResult
    func importTemplates(from data: Data) throws -> Int {
        let incoming: [Template]
        if let array = try? JSONDecoder().decode([Template].self, from: data) {
            incoming = array
        } else if let single = try? JSONDecoder().decode(Template.self, from: data) {
            incoming = [single]
        } else {
            throw TemplateStoreError.invalidImportData
        }

        var existingIDs = Set(templates.map(\.id))
        var existingNamePromptKeys = Set(templates.map(Self.dedupeKey))
        var toImport: [Template] = []

        for var template in incoming {
            let key = Self.dedupeKey(template)
            guard !existingNamePromptKeys.contains(key) else { continue }

            if template.id.isEmpty || existingIDs.contains(template.id) {
                template.id = UUID().uuidString
            }
            existingIDs.insert(template.id)
            existingNamePromptKeys.insert(key)
            toImport.append(template)
        }

        guard !toImport.isEmpty else { return 0 }

        let (renamed, _) = Self.renamingReservedNameCollisions(toImport)
        templates.append(contentsOf: renamed)
        save()
        return renamed.count
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

    private func save() {
        guard let data = try? JSONEncoder().encode(templates) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
