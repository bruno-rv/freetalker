import Foundation
import Testing
@testable import FreeTalker

@Suite struct LibraryTranslationStoreTests {
    @Test func directLibraryOpenRunsLedgerAndEnablesForeignKeys() throws {
        let fixture = try Fixture()

        #expect(try fixture.db.migrationVersions() == Array(1...DatabaseMigrator.latestVersion))
        #expect(try fixture.db.foreignKeysEnabled())
    }

    @Test func insertionRoundTripsTypedMetadataAcrossEveryProjection() throws {
        let fixture = try Fixture()
        _ = try fixture.insert(
            sourceLanguage: SourceLanguage("pt-BR"),
            requestedOutputLanguage: .german,
            refined: "Guten Tag"
        )

        let all = try #require(fixture.db.allDictations().first)
        let latestResult = try fixture.db.latestDictation()
        let latest = try #require(latestResult)
        let searched = try #require(fixture.db.searchDictations(query: "Guten").first)
        for row in [all, latest, searched] {
            #expect(row.sourceLanguage == SourceLanguage("pt-BR"))
            #expect(row.requestedOutputLanguage == .german)
        }
    }

    @Test func variantUpsertNeverChangesOriginalAndAtomicallyReplacesText() throws {
        let fixture = try Fixture()
        let id = try fixture.insert(refined: "Hello")

        try fixture.db.upsertTranslation(parentID: id, target: .portuguese, text: "Olá")
        try fixture.db.upsertTranslation(parentID: id, target: .portuguese, text: "Bom dia")

        let variants = try fixture.db.translationVariants(parentID: id)
        #expect(variants.count == 1)
        #expect(variants.first?.target == .portuguese)
        #expect(variants.first?.text == "Bom dia")
        #expect(try fixture.db.dictation(id: id)?.refined == "Hello")
        #expect(try fixture.db.dictation(id: id)?.transcript == "raw")
    }

    @Test func variantsAreUniquePerParentAndTarget() throws {
        let fixture = try Fixture()
        let first = try fixture.insert(refined: "one")
        let second = try fixture.insert(refined: "two")
        try fixture.db.upsertTranslation(parentID: first, target: .spanish, text: "uno")
        try fixture.db.upsertTranslation(parentID: second, target: .spanish, text: "dos")

        #expect(try fixture.db.translationVariants(parentID: first).map(\.text) == ["uno"])
        #expect(try fixture.db.translationVariants(parentID: second).map(\.text) == ["dos"])
    }

    @Test func deletingVariantLeavesOriginalAndDeletingParentCascadesVariants() throws {
        let fixture = try Fixture()
        let id = try fixture.insert(refined: "original")
        try fixture.db.upsertTranslation(parentID: id, target: .french, text: "traduit")

        try fixture.db.deleteTranslation(parentID: id, target: .french)
        #expect(try fixture.db.translationVariants(parentID: id).isEmpty)
        #expect(try fixture.db.dictation(id: id)?.refined == "original")

        try fixture.db.upsertTranslation(parentID: id, target: .french, text: "traduit")
        try fixture.db.deleteRow(id: id)
        #expect(try fixture.db.translationVariants(parentID: id).isEmpty)
    }

    @Test func upsertRejectsMissingParent() throws {
        let fixture = try Fixture()
        let id = try fixture.insert()
        try fixture.db.deleteRow(id: id)

        #expect(throws: DatabaseError.translationParentMissing(id)) {
            try fixture.db.upsertTranslation(parentID: id, target: .hindi, text: "अनुवाद")
        }
        #expect(try fixture.db.translationVariants(parentID: id).isEmpty)
    }

    @Test func concurrentParentDeletionCannotLeaveAnOrphanVariant() async throws {
        let fixture = try Fixture()
        let id = try fixture.insert()
        let secondConnection = SendableDatabase(try Database(path: fixture.url))

        async let upsert: Result<Void, DatabaseError> = Task.detached {
            do {
                try secondConnection.value.upsertTranslation(
                    parentID: id, target: .german, text: "Übersetzung"
                )
                return .success(())
            } catch let error as DatabaseError {
                return .failure(error)
            } catch {
                Issue.record("Unexpected upsert error: \(error)")
                return .failure(.sqlFailed("unexpected error"))
            }
        }.value
        async let deletion: Void = Task.detached {
            try fixture.sendableDatabase.value.deleteRow(id: id)
        }.value

        switch await upsert {
        case .success:
            break
        case .failure(.translationParentMissing(let missingID)):
            #expect(missingID == id)
        case .failure(.sqlFailed(let message)):
            #expect(message.contains("FOREIGN KEY constraint failed"))
            #expect(!message.localizedCaseInsensitiveContains("busy"))
            #expect(!message.localizedCaseInsensitiveContains("locked"))
        case .failure(let error):
            Issue.record("Unexpected upsert outcome: \(error)")
        }
        try await deletion
        #expect(try secondConnection.value.translationVariants(parentID: id).isEmpty)
    }

    @Test func unknownPersistedTargetIsNotReturnedAsSame() throws {
        #expect(TranslationTarget(rawValue: OutputLanguage.sameAsSpoken.rawValue) == nil)
    }

    @Test func conditionalInsertNeverOverwritesAConcurrentVariant() throws {
        let fixture = try Fixture()
        let id = try fixture.insert()
        let first = try fixture.db.conditionalUpsertTranslation(
            parentID: id, target: .french, text: "un", expected: .absent
        )
        let secondConnection = try Database(path: fixture.url)
        let second = try secondConnection.conditionalUpsertTranslation(
            parentID: id, target: .french, text: "deux", expected: .absent
        )

        guard case .committed(let committed) = first else { Issue.record("Expected commit"); return }
        #expect(committed.text == "un")
        guard case .replacementConfirmationRequired(let current) = second else { Issue.record("Expected confirmation"); return }
        #expect(current.text == "un")
        #expect(try fixture.db.translationVariants(parentID: id).map(\.text) == ["un"])
    }

    @Test func confirmedReplacementRequiresTheExactCurrentVersion() throws {
        let fixture = try Fixture()
        let id = try fixture.insert()
        guard case .committed(let first) = try fixture.db.conditionalUpsertTranslation(
            parentID: id, target: .german, text: "eins", expected: .absent
        ) else { Issue.record("Expected first commit"); return }
        guard case .committed(let second) = try fixture.db.conditionalUpsertTranslation(
            parentID: id, target: .german, text: "zwei", expected: .version(first.updatedAt)
        ) else { Issue.record("Expected confirmed commit"); return }

        let stale = try fixture.db.conditionalUpsertTranslation(
            parentID: id, target: .german, text: "drei", expected: .version(first.updatedAt)
        )
        guard case .replacementConfirmationRequired(let current) = stale else { Issue.record("Expected reconfirmation"); return }
        #expect(current == second)
    }
}

private final class Fixture {
    let url: URL
    let db: Database
    var sendableDatabase: SendableDatabase { SendableDatabase(db) }

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("freetalker-library-\(UUID().uuidString).sqlite")
        db = try Database(path: url)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.removeItem(atPath: url.path + "-wal")
        try? FileManager.default.removeItem(atPath: url.path + "-shm")
    }

    @discardableResult
    func insert(
        sourceLanguage: SourceLanguage = SourceLanguage("en"),
        requestedOutputLanguage: OutputLanguage = .sameAsSpoken,
        refined: String = "refined"
    ) throws -> Int64 {
        try db.insertDictation(.init(
            timestamp: Date(),
            sourceLanguage: sourceLanguage,
            requestedOutputLanguage: requestedOutputLanguage,
            template: "Clean",
            transcript: "raw",
            refined: refined,
            engine: "local"
        ))
    }
}

private final class SendableDatabase: @unchecked Sendable {
    let value: Database

    init(_ value: Database) {
        self.value = value
    }
}
