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
            // ponytail: init can't throw here without changing every call site (this predates
            // throwing save()); a failed initial-seed write just means it retries on next
            // mutation, same as before this change. Upgrade path: surface via a published error.
            try? save()
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
        let incoming: [Template]
        if let array = try? JSONDecoder().decode([Template].self, from: data) {
            incoming = array
        } else if let single = try? JSONDecoder().decode(Template.self, from: data) {
            incoming = [single]
        } else {
            throw TemplateStoreError.invalidImportData
        }
        return try importTemplates(incoming)
    }

    /// Merges already-decoded `incoming` templates into the existing library. Never deletes or
    /// modifies existing templates; fresh IDs for appended rows whose incoming ID is empty or
    /// collides with an existing one. Returns a complete old→new ID map — see `ImportResult`.
    /// Used directly by Backup Bundle restore, which validates+bounds-checks the array before
    /// this ever runs (PLAN.md F1.4/F1.5), so this method itself does no bounds checking.
    func importTemplates(_ incoming: [Template]) throws -> ImportResult {
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

        for var template in incoming {
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
            toImport.append(template)
        }

        let skippedCount = incoming.count - toImport.count
        guard !toImport.isEmpty else {
            return ImportResult(idMap: idMap, importedCount: 0, skippedCount: skippedCount)
        }

        let (renamed, _) = Self.renamingReservedNameCollisions(toImport)
        try mutateAndSave { templates in
            templates.append(contentsOf: renamed)
        }
        return ImportResult(idMap: idMap, importedCount: renamed.count, skippedCount: skippedCount)
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
