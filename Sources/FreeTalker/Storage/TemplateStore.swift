import Foundation

@MainActor
final class TemplateStore: ObservableObject {
    static let shared = TemplateStore()

    nonisolated static let rawTranscriptTemplateName = "Raw Transcript"

    enum TemplateStoreError: LocalizedError {
        case reservedName

        var errorDescription: String? {
            "\"\(TemplateStore.rawTranscriptTemplateName)\" is reserved for raw dictations and can't be used as a Template name."
        }
    }

    @Published private(set) var templates: [Template]

    private let fileURL: URL

    private init() {
        let dir = FreeTalkerPaths.applicationSupport
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("templates.json")

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
