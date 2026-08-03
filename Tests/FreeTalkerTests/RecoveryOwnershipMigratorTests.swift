import Foundation
import Testing
@testable import FreeTalker

/// The Library's recovery-health banner renders whatever these issues say verbatim, so the message
/// is the feature: it has to name the file and the actual reason, not report every refusal as an
/// ownership ambiguity.
@Suite struct RecoveryOwnershipMigratorTests {
    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ownership-migrator-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func makeJob(id: UUID, source: URL) -> TranscriptionJob {
        let now = Date()
        return TranscriptionJob(
            id: id, kind: .recovery, source: JobSource(reference: source.path),
            state: .failed(JobFailure(stage: .transcribing, message: "Empty transcript")),
            progress: 0, createdAt: now, updatedAt: now, startedAt: nil, completedAt: nil,
            expiresAt: nil, result: nil, needsSourceCleanup: false, sourceCleanupError: nil
        )
    }

    @Test func missingAudioIsReportedAsMissingRatherThanAmbiguous() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        // Legacy layout: the file is named after a *different* UUID than the job that references
        // it — the only shape this migrator acts on — and the file itself is gone.
        let filenameID = UUID()
        let source = root.appendingPathComponent("\(filenameID.uuidString).wav")
        let job = makeJob(id: UUID(), source: source)

        let result = RecoveryOwnershipMigrator(root: root).migrate(jobs: [job], sessions: [])

        let issue = try #require(result.issues.first)
        #expect(result.issues.count == 1)
        #expect(issue.source.standardizedFileURL == source.standardizedFileURL)
        #expect(issue.message.contains(source.lastPathComponent))
        #expect(issue.message.contains("missing"))
        #expect(!issue.message.contains("ambiguous"))
        // The path stays protected either way — reconciliation must not reinterpret it as an
        // unowned orphan just because the upgrade was refused.
        #expect(result.protectedPaths.contains(source.standardizedFileURL.path))
    }

    @Test func twoJobsClaimingOneFileAreReportedAsContested() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let filenameID = UUID()
        let source = root.appendingPathComponent("\(filenameID.uuidString).wav")
        try Data([0x52, 0x49, 0x46, 0x46]).write(to: source)
        let jobs = [makeJob(id: UUID(), source: source), makeJob(id: UUID(), source: source)]

        let result = RecoveryOwnershipMigrator(root: root).migrate(jobs: jobs, sessions: [])

        #expect(result.issues.count == 2)
        for issue in result.issues {
            #expect(issue.message.contains(source.lastPathComponent))
            #expect(issue.message.contains("more than one job"))
        }
    }

    /// Codex round 2, finding 3: `references` is grouped over every job kind, so the other
    /// claimant need not be a recovery — the message must not promise that it is.
    @Test func aMediaImportSharingThePathIsCountedButNotCalledARecovery() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let filenameID = UUID()
        let source = root.appendingPathComponent("\(filenameID.uuidString).wav")
        try Data([0x52, 0x49, 0x46, 0x46]).write(to: source)
        var importJob = makeJob(id: UUID(), source: source)
        importJob = TranscriptionJob(
            id: importJob.id, kind: .mediaImport, source: importJob.source, state: importJob.state,
            progress: 0, createdAt: importJob.createdAt, updatedAt: importJob.updatedAt,
            startedAt: nil, completedAt: nil, expiresAt: nil, result: nil,
            needsSourceCleanup: false, sourceCleanupError: nil
        )

        let result = RecoveryOwnershipMigrator(root: root).migrate(
            jobs: [makeJob(id: UUID(), source: source), importJob], sessions: []
        )

        let issue = try #require(result.issues.first)
        #expect(result.issues.count == 1)
        #expect(issue.message.contains("more than one job"))
        #expect(!issue.message.contains("recovery entr"))
    }

    @Test func unreadableAudioIsReportedAsUnreadable() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let filenameID = UUID()
        let source = root.appendingPathComponent("\(filenameID.uuidString).wav")
        try Data("not a wav".utf8).write(to: source)
        let job = makeJob(id: UUID(), source: source)

        let result = RecoveryOwnershipMigrator(root: root).migrate(jobs: [job], sessions: [])

        let issue = try #require(result.issues.first)
        #expect(issue.message.contains(source.lastPathComponent))
        #expect(issue.message.contains("not readable recovery audio"))
    }

    /// The canonical layout — file named after the job that owns it — was never this migrator's
    /// business, and must stay silent rather than adding a permanent banner.
    @Test func filenameMatchingItsOwnJobIsLeftAlone() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let id = UUID()
        let source = root.appendingPathComponent("\(id.uuidString).wav")
        try Data([0x52, 0x49, 0x46, 0x46]).write(to: source)

        let result = RecoveryOwnershipMigrator(root: root).migrate(
            jobs: [makeJob(id: id, source: source)], sessions: []
        )

        #expect(result.issues.isEmpty)
        #expect(result.protectedPaths.isEmpty)
    }
}
