import Foundation

/// Templates are simple editable records — a JSON file is simpler than a DB table + CRUD SQL
/// for this (PLAN.md step 5 explicitly allows "SQLite or JSON, pick simpler").
@MainActor
final class TemplateStore: ObservableObject {
    static let shared = TemplateStore()

    @Published private(set) var templates: [Template]

    private let fileURL: URL

    private init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = support.appendingPathComponent("FreeTalker", isDirectory: true)
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

        // Upgrade-if-unedited migration (PLAN.md step 7): a never-edited built-in prompt is
        // upgraded to the current default; an edited one, or a built-in the user deleted, is
        // left alone. Only rewrite the file when something actually changed, so an unchanged
        // `templates.json` isn't rewritten on every launch.
        let (upgraded, changed) = Template.upgradingBuiltIns(loadedTemplates)
        templates = upgraded
        if didSeed || changed {
            save()
        }
    }

    func template(id: String) -> Template? {
        templates.first { $0.id == id }
    }

    func upsert(_ template: Template) {
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

    private func save() {
        guard let data = try? JSONEncoder().encode(templates) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
