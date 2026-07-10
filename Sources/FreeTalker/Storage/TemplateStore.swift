import Foundation

/// Templates are simple editable records — a JSON file is simpler than a DB table + CRUD SQL
/// for this (PLAN.md step 5 explicitly allows "SQLite or JSON, pick simpler").
@MainActor
final class TemplateStore: ObservableObject {
    static let shared = TemplateStore()

    /// Reserved display name for Raw-path Library rows (CONTEXT.md/PLAN.md step 11) — NOT a
    /// real, storable Template. `upsert` rejects creating/renaming a Template to this name
    /// (case-insensitive, trimmed); `init` renames any pre-existing user template already using
    /// it, so the sentinel is unambiguous from the very first launch after this upgrade.
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
        // Reserved-name migration (PLAN.md step 11): a template that predates the "Raw
        // Transcript" sentinel and happens to already be named that is renamed once, on load, so
        // the sentinel is unambiguous going forward.
        let (renamed, renameChanged) = Self.renamingReservedNameCollisions(upgraded)
        templates = renamed
        if didSeed || changed || renameChanged {
            save()
        }
    }

    func template(id: String) -> Template? {
        templates.first { $0.id == id }
    }

    /// Throws `TemplateStoreError.reservedName` (case-insensitive, trimmed) rather than creating
    /// or renaming a Template to the reserved "Raw Transcript" sentinel. See PLAN.md step 11.
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

    /// Pure "is this the reserved Raw Transcript sentinel" check (trimmed, case-insensitive) —
    /// extracted so SelfCheck can exercise the rejection rule without touching the real
    /// singleton's file-backed storage. `upsert` uses this same function. See PLAN.md step 11.
    nonisolated static func isReservedTemplateName(_ name: String) -> Bool {
        name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == rawTranscriptTemplateName.lowercased()
    }

    /// Renames any template whose name collides with the reserved sentinel (case-insensitive,
    /// trimmed) to "Raw Transcript (Template)" — pure so SelfCheck can drive it directly. See
    /// PLAN.md step 11.
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
