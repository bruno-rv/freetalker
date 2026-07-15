import Foundation
import Testing
@testable import FreeTalker

@Suite struct RecoveryActionTests {
    @Test @MainActor func refreshProjectsLedgerOnlyAndLegacyRecoveries() async throws {
        let fixture = try RecoveryActionFixture()
        let silentID = try await fixture.silentCapture()
        let damagedID = try await fixture.damagedCapture()
        let legacy = try await fixture.failedRecovery()
        let library = JobLibraryStore(store: fixture.store, recoveryDirectory: fixture.root)

        try await library.refresh()

        #expect(Set(library.recoveryItems.map(\.id)) == [silentID, damagedID, legacy.id])
        #expect(library.recoveryItems.first { $0.id == silentID }?.availableActions == [.startNewRecording, .delete])
        #expect(library.recoveryItems.first { $0.id == damagedID }?.availableActions == [.exportArtifact, .delete])
        #expect(library.recoveryItems.first { $0.id == legacy.id }?.availableActions == [.retryProcessing, .exportAudio, .delete])
    }

    @Test @MainActor func exportCopiesWithoutChangingOwnedSource() async throws {
        let fixture = try RecoveryActionFixture()
        let job = try await fixture.failedRecovery()
        let library = JobLibraryStore(store: fixture.store, recoveryDirectory: fixture.root)
        try await library.refresh()
        let destination = fixture.temp.url.appendingPathComponent("export.wav")
        let source = URL(fileURLWithPath: job.source.reference)
        let original = try Data(contentsOf: source)

        try library.export(id: job.id, to: destination)

        #expect(try Data(contentsOf: destination) == original)
        #expect(try Data(contentsOf: source) == original)
        #expect(try await fixture.store.job(id: job.id) != nil)
    }

    @Test @MainActor func damagedArtifactExportIsCopyOnly() async throws {
        let fixture = try RecoveryActionFixture()
        let id = try await fixture.damagedCapture()
        let source = fixture.root.appendingPathComponent(id.uuidString)
            .appendingPathComponent("capture-failure.marker")
        let library = JobLibraryStore(store: fixture.store, recoveryDirectory: fixture.root)
        try await library.refresh()
        let destination = fixture.temp.url.appendingPathComponent("exported.marker")

        try library.export(id: id, to: destination)

        #expect(try Data(contentsOf: destination) == Data("fault".utf8))
        #expect(try Data(contentsOf: source) == Data("fault".utf8))
        #expect(try await fixture.store.session(id: id)?.state == .damaged)
    }

    @Test @MainActor func deletingSilentCapturePersistsDispositionAndDoesNotCreateJob() async throws {
        let fixture = try RecoveryActionFixture()
        let id = try await fixture.silentCapture()
        let library = JobLibraryStore(store: fixture.store, recoveryDirectory: fixture.root)
        try await library.refresh()

        try await library.delete(id: id)

        let reopened = try TranscriptionJobStore(databaseURL: fixture.database, clock: SystemJobClock())
        #expect(try await reopened.session(id: id) == nil)
        #expect(try await reopened.job(id: id) == nil)
        #expect(!FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent(id.uuidString).path))
        #expect(try RecoveryImportDispositionStore(directory: fixture.root).descriptor(id: id) != nil)
    }

    @Test @MainActor func startNewRecordingUsesConfiguredAdmission() async throws {
        let fixture = try RecoveryActionFixture()
        let id = try await fixture.silentCapture()
        let library = JobLibraryStore(store: fixture.store, recoveryDirectory: fixture.root)
        try await library.refresh()
        var calls = 0
        library.configureStartNewRecording { calls += 1; return true }

        #expect(library.startNewRecording(id: id))
        #expect(calls == 1)
    }
}

private final class RecoveryActionFixture: @unchecked Sendable {
    let temp: RecoveryActionTemporaryDirectory
    let root: URL
    let database: URL
    let store: TranscriptionJobStore

    init() throws {
        temp = try RecoveryActionTemporaryDirectory()
        root = temp.url.appendingPathComponent("failed-dictations", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        database = temp.url.appendingPathComponent("jobs.sqlite")
        store = try TranscriptionJobStore(databaseURL: database, clock: SystemJobClock())
    }

    func silentCapture() async throws -> UUID {
        let id = UUID()
        let directory = root.appendingPathComponent(id.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        try Data("diagnostic".utf8).write(to: directory.appendingPathComponent("capture-diagnostics.json"))
        _ = try await store.createCapture(.init(
            id: id, directory: directory, capturedAt: Date(), sampleRate: 16_000,
            channelCount: 1, inputDeviceUID: nil, destination: "external"
        ))
        try await store.transition(
            id: id, from: .capturing, to: .silent, recoveryJobID: nil,
            libraryDictationID: nil, assetKind: .silent,
            failureMessage: SilentCapturePresentation.message, contentHash: nil
        )
        return id
    }

    func damagedCapture() async throws -> UUID {
        let id = UUID()
        let directory = root.appendingPathComponent(id.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        try Data("fault".utf8).write(to: directory.appendingPathComponent("capture-failure.marker"))
        _ = try await store.createCapture(.init(
            id: id, directory: directory, capturedAt: Date(), sampleRate: 16_000,
            channelCount: 1, inputDeviceUID: nil, destination: "external"
        ))
        try await store.transition(
            id: id, from: .capturing, to: .damaged, recoveryJobID: nil,
            libraryDictationID: nil, assetKind: .damaged,
            failureMessage: "Capture journal failed", contentHash: nil
        )
        return id
    }

    func failedRecovery() async throws -> TranscriptionJob {
        let source = root.appendingPathComponent("\(UUID().uuidString).wav")
        try WAVEncoder.encode(samples: [0.2, -0.1], sampleRate: 16_000).write(to: source)
        return try await store.createRecovery(
            source: .init(reference: source.path),
            metadata: .init(capturedAt: Date(), failure: .init(stage: .transcribing, message: "Offline"))
        )
    }
}

private final class RecoveryActionTemporaryDirectory {
    let url: URL
    init() throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
    }
    deinit { try? FileManager.default.removeItem(at: url) }
}
