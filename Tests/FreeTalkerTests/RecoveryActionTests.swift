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

        try await library.export(id: job.id, to: destination)

        #expect(try Data(contentsOf: destination) == original)
        #expect(try Data(contentsOf: source) == original)
        #expect(try await fixture.store.job(id: job.id) != nil)
        try FileManager.default.removeItem(at: source)
        #expect(try Data(contentsOf: destination) == original)
        let values = try destination.resourceValues(
            forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
        )
        #expect(values.isRegularFile == true)
        #expect(values.isSymbolicLink != true)
    }

    @Test @MainActor func damagedArtifactExportIsCopyOnly() async throws {
        let fixture = try RecoveryActionFixture()
        let id = try await fixture.damagedCapture()
        let source = fixture.root.appendingPathComponent(id.uuidString)
            .appendingPathComponent("capture-failure.marker")
        let library = JobLibraryStore(store: fixture.store, recoveryDirectory: fixture.root)
        try await library.refresh()
        let destination = fixture.temp.url.appendingPathComponent("exported.marker")

        try await library.export(id: id, to: destination)

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

    @Test @MainActor func crossIdentityJobSourceCannotExportOrDeleteAnotherRecoveryAudio() async throws {
        let fixture = try RecoveryActionFixture()
        let first = try await fixture.failedRecovery(samples: [0.15])
        let second = try await fixture.failedRecovery(samples: [0.15])
        try await fixture.store.updateRecoverySource(
            id: first.id, expectedSourceReference: first.source.reference,
            source: second.source
        )
        let library = JobLibraryStore(store: fixture.store, recoveryDirectory: fixture.root)
        try await library.refresh()

        let corrupted = try #require(library.recoveryItems.first { $0.id == first.id })
        #expect(corrupted.audioURL == nil)
        #expect(corrupted.availableActions.isEmpty)
        await #expect(throws: Error.self) {
            try await library.delete(id: first.id)
        }
        #expect(FileManager.default.fileExists(atPath: second.source.reference))
        #expect(try await fixture.store.job(id: second.id) != nil)
    }

    @Test @MainActor func markerlessCurrentRecoveryBackfillsOwnershipIdempotentlyAndDeletesAcrossReopen() async throws {
        let fixture = try RecoveryActionFixture()
        let job = try await fixture.markerlessFailedRecovery()
        let source = URL(fileURLWithPath: job.source.reference)
        let library = JobLibraryStore(store: fixture.store, recoveryDirectory: fixture.root)

        try await library.refresh()

        #expect(library.recoveryItems.first { $0.id == job.id }?.availableActions
            == [.retryProcessing, .exportAudio, .delete])
        let dispositions = RecoveryImportDispositionStore(directory: fixture.root)
        #expect(try dispositions.ownsSource(id: job.id, source: source))
        let marker = fixture.root.appendingPathComponent(
            ".recovery-ownership-\(job.id.uuidString).marker"
        )
        let firstMarker = try Data(contentsOf: marker)

        try await library.refresh()

        #expect(try Data(contentsOf: marker) == firstMarker)
        try await library.delete(id: job.id)
        let reopened = try TranscriptionJobStore(databaseURL: fixture.database, clock: SystemJobClock())
        let reopenedLibrary = JobLibraryStore(store: reopened, recoveryDirectory: fixture.root)
        try await reopenedLibrary.refresh()
        #expect(try await reopened.job(id: job.id) == nil)
        #expect(!FileManager.default.fileExists(atPath: source.path))
        #expect(!reopenedLibrary.recoveryItems.contains { $0.id == job.id })
    }

    @Test @MainActor func markerlessCrossLinkToAnotherOwnedRecoveryIsNeverBackfilled() async throws {
        let fixture = try RecoveryActionFixture()
        let markerless = try await fixture.markerlessFailedRecovery()
        let owned = try await fixture.failedRecovery()
        try await fixture.store.updateRecoverySource(
            id: markerless.id, expectedSourceReference: markerless.source.reference,
            source: owned.source
        )
        let library = JobLibraryStore(store: fixture.store, recoveryDirectory: fixture.root)

        try await library.refresh()

        #expect(try !RecoveryImportDispositionStore(directory: fixture.root)
            .ownsSource(id: markerless.id, source: URL(fileURLWithPath: owned.source.reference)))
        #expect(library.recoveryItems.first { $0.id == markerless.id }?.availableActions.isEmpty == true)
        #expect(FileManager.default.fileExists(atPath: owned.source.reference))
    }

    @Test @MainActor func exportRevalidatesChangedBytesAndLeavesNoDestination() async throws {
        let fixture = try RecoveryActionFixture()
        let job = try await fixture.failedRecovery()
        let library = JobLibraryStore(store: fixture.store, recoveryDirectory: fixture.root)
        try await library.refresh()
        let source = URL(fileURLWithPath: job.source.reference)
        try WAVEncoder.encode(samples: [0.9], sampleRate: 16_000).write(to: source)
        let destination = fixture.temp.url.appendingPathComponent("changed.wav")

        await #expect(throws: Error.self) {
            try await library.export(id: job.id, to: destination)
        }

        #expect(!FileManager.default.fileExists(atPath: destination.path))
        #expect(FileManager.default.fileExists(atPath: source.path))
    }

    @Test @MainActor func exportRevalidatesSymlinkAndLeavesNoDestination() async throws {
        let fixture = try RecoveryActionFixture()
        let job = try await fixture.failedRecovery()
        let other = try await fixture.failedRecovery()
        let library = JobLibraryStore(store: fixture.store, recoveryDirectory: fixture.root)
        try await library.refresh()
        let source = URL(fileURLWithPath: job.source.reference)
        try FileManager.default.removeItem(at: source)
        try FileManager.default.createSymbolicLink(
            at: source, withDestinationURL: URL(fileURLWithPath: other.source.reference)
        )
        let destination = fixture.temp.url.appendingPathComponent("symlink.wav")

        await #expect(throws: Error.self) {
            try await library.export(id: job.id, to: destination)
        }

        #expect(!FileManager.default.fileExists(atPath: destination.path))
        #expect(FileManager.default.fileExists(atPath: source.path))
    }

    @Test @MainActor func descriptorExportRejectsIdenticalContentSymlinkSwapAtOpenBoundary() async throws {
        let fixture = try RecoveryActionFixture()
        let job = try await fixture.failedRecovery(samples: [0.2])
        let other = try await fixture.failedRecovery(samples: [0.2])
        let source = URL(fileURLWithPath: job.source.reference)
        let exporter = RecoveryArtifactExporter(beforeSourceOpen: { opened in
            try FileManager.default.removeItem(at: opened)
            try FileManager.default.createSymbolicLink(
                at: opened, withDestinationURL: URL(fileURLWithPath: other.source.reference)
            )
        })
        let library = JobLibraryStore(
            store: fixture.store, recoveryDirectory: fixture.root,
            artifactExporter: exporter
        )
        try await library.refresh()
        let destination = fixture.temp.url.appendingPathComponent("swapped.wav")

        await #expect(throws: Error.self) {
            try await library.export(id: job.id, to: destination)
        }

        #expect(!FileManager.default.fileExists(atPath: destination.path))
        #expect(try source.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true)
        #expect(FileManager.default.fileExists(atPath: other.source.reference))
    }

    @Test @MainActor func descriptorExportNeverFollowsOrDeletesPrecreatedTemporarySymlink() async throws {
        let fixture = try RecoveryActionFixture()
        let job = try await fixture.failedRecovery()
        let outside = fixture.temp.url.appendingPathComponent("outside.txt")
        try Data("keep".utf8).write(to: outside)
        let attackedTemp = fixture.temp.url.appendingPathComponent("attacked.exporting")
        try FileManager.default.createSymbolicLink(at: attackedTemp, withDestinationURL: outside)
        let exporter = RecoveryArtifactExporter(
            temporaryURL: { _ in attackedTemp }
        )
        let library = JobLibraryStore(
            store: fixture.store, recoveryDirectory: fixture.root,
            artifactExporter: exporter
        )
        try await library.refresh()
        let destination = fixture.temp.url.appendingPathComponent("attacked.wav")

        await #expect(throws: Error.self) {
            try await library.export(id: job.id, to: destination)
        }

        #expect(!FileManager.default.fileExists(atPath: destination.path))
        #expect(try attackedTemp.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true)
        #expect(try Data(contentsOf: outside) == Data("keep".utf8))
    }

    @Test @MainActor func descriptorExportNeverReplacesOrFollowsDestinationSymlink() async throws {
        let fixture = try RecoveryActionFixture()
        let job = try await fixture.failedRecovery()
        let outside = fixture.temp.url.appendingPathComponent("destination-outside.txt")
        try Data("keep".utf8).write(to: outside)
        let destination = fixture.temp.url.appendingPathComponent("destination-link.wav")
        try FileManager.default.createSymbolicLink(at: destination, withDestinationURL: outside)
        let library = JobLibraryStore(store: fixture.store, recoveryDirectory: fixture.root)
        try await library.refresh()

        await #expect(throws: Error.self) {
            try await library.export(id: job.id, to: destination)
        }

        #expect(try destination.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true)
        #expect(try Data(contentsOf: outside) == Data("keep".utf8))
    }

    @Test @MainActor func exportRevalidatesCurrentJobSourceAndLeavesNoDestination() async throws {
        let fixture = try RecoveryActionFixture()
        let job = try await fixture.failedRecovery()
        let other = try await fixture.failedRecovery()
        let library = JobLibraryStore(store: fixture.store, recoveryDirectory: fixture.root)
        try await library.refresh()
        try await fixture.store.updateRecoverySource(
            id: job.id, expectedSourceReference: job.source.reference, source: other.source
        )
        let destination = fixture.temp.url.appendingPathComponent("cross-id.wav")

        await #expect(throws: Error.self) {
            try await library.export(id: job.id, to: destination)
        }

        #expect(!FileManager.default.fileExists(atPath: destination.path))
        #expect(FileManager.default.fileExists(atPath: job.source.reference))
    }

    @Test @MainActor func nestedNoncanonicalAudioNeverOffersRetryOrAudioExport() async throws {
        let fixture = try RecoveryActionFixture()
        let segment = try await fixture.failedNestedRecovery(filename: "segment-00000000.wav")
        let arbitrary = try await fixture.failedNestedRecovery(filename: "other.wav")
        let canonical = try await fixture.failedNestedRecovery(filename: nil)
        let library = JobLibraryStore(store: fixture.store, recoveryDirectory: fixture.root)

        try await library.refresh()

        #expect(library.recoveryItems.first { $0.id == segment.id }?.availableActions.isEmpty == true)
        #expect(library.recoveryItems.first { $0.id == arbitrary.id }?.availableActions.isEmpty == true)
        #expect(library.recoveryItems.first { $0.id == canonical.id }?.availableActions
            == [.retryProcessing, .exportAudio, .delete])
    }

    @Test @MainActor func libraryCommittedSessionIdentitySuppressesFallbackJobProjection() async throws {
        let fixture = try RecoveryActionFixture()
        let job = try await fixture.failedRecovery()
        let directory = fixture.root.appendingPathComponent(job.id.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        _ = try await fixture.store.createCapture(.init(
            id: job.id, directory: directory, capturedAt: Date(), sampleRate: 16_000,
            channelCount: 1, inputDeviceUID: nil, destination: "external"
        ))
        try await fixture.store.transition(
            id: job.id, from: .capturing, to: .libraryCommitted,
            recoveryJobID: job.id, libraryDictationID: 42, assetKind: .audio,
            failureMessage: nil, contentHash: nil
        )
        let library = JobLibraryStore(store: fixture.store, recoveryDirectory: fixture.root)

        try await library.refresh()

        #expect(!library.recoveryItems.contains { $0.id == job.id })
    }

    @Test @MainActor func stagedLedgerOnlyAudioCanExportAndDeleteAcrossReopen() async throws {
        let fixture = try RecoveryActionFixture()
        let id = try await fixture.stagedCapture()
        let library = JobLibraryStore(store: fixture.store, recoveryDirectory: fixture.root)
        try await library.refresh()
        let item = try #require(library.recoveryItems.first { $0.id == id })
        #expect(item.availableActions == [.exportAudio, .delete])

        try await library.delete(id: id)

        let reopened = try TranscriptionJobStore(databaseURL: fixture.database, clock: SystemJobClock())
        #expect(try await reopened.session(id: id) == nil)
        #expect(!FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent(id.uuidString).path))
    }

    @Test @MainActor func directDeleteIsNotBlockedByUnrelatedMalformedCommittedSession() async throws {
        let fixture = try RecoveryActionFixture()
        let target = try await fixture.failedRecovery()
        let targetSource = target.source.reference
        let malformedID = UUID()
        let outside = fixture.temp.url.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
        _ = try await fixture.store.createCapture(.init(
            id: malformedID, directory: outside, capturedAt: Date(), sampleRate: 16_000,
            channelCount: 1, inputDeviceUID: nil, destination: "external"
        ))
        try await fixture.store.transition(
            id: malformedID, from: .capturing, to: .libraryCommitted,
            recoveryJobID: nil, libraryDictationID: 4, assetKind: .audio,
            failureMessage: nil, contentHash: nil
        )
        let library = JobLibraryStore(store: fixture.store, recoveryDirectory: fixture.root)
        try await library.refresh()

        try await library.delete(id: target.id)

        #expect(try await fixture.store.job(id: target.id) == nil)
        #expect(!FileManager.default.fileExists(atPath: targetSource))
        #expect(try await fixture.store.session(id: malformedID)?.state == .libraryCommitted)
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

    func stagedCapture() async throws -> UUID {
        let id = UUID()
        let directory = root.appendingPathComponent(id.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let canonical = directory.appendingPathComponent("\(id.uuidString).wav")
        try WAVEncoder.encode(samples: [0.2], sampleRate: 16_000).write(to: canonical)
        _ = try await store.createCapture(.init(
            id: id, directory: directory, capturedAt: Date(), sampleRate: 16_000,
            channelCount: 1, inputDeviceUID: nil, destination: "external"
        ))
        try await store.transition(
            id: id, from: .capturing, to: .staged, recoveryJobID: nil,
            libraryDictationID: nil, assetKind: .audio,
            failureMessage: nil, contentHash: nil
        )
        return id
    }

    func failedRecovery(samples: [Float] = [0.2, -0.1]) async throws -> TranscriptionJob {
        let source = root.appendingPathComponent("\(UUID().uuidString).wav")
        try WAVEncoder.encode(samples: samples, sampleRate: 16_000).write(to: source)
        let job = try await store.createRecovery(
            source: .init(reference: source.path),
            metadata: .init(capturedAt: Date(), failure: .init(stage: .transcribing, message: "Offline"))
        )
        try RecoveryImportDispositionStore(directory: root)
            .registerOwnedSource(id: job.id, source: source)
        return job
    }

    func markerlessFailedRecovery() async throws -> TranscriptionJob {
        let source = root.appendingPathComponent("\(UUID().uuidString).wav")
        try WAVEncoder.encode(samples: [0.2], sampleRate: 16_000).write(to: source)
        return try await store.createRecovery(
            source: .init(reference: source.path),
            metadata: .init(capturedAt: Date(), failure: .init(stage: .transcribing, message: "Offline"))
        )
    }

    func failedNestedRecovery(filename: String?) async throws -> TranscriptionJob {
        let id = UUID()
        let directory = root.appendingPathComponent(id.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let source = directory.appendingPathComponent(filename ?? "\(id.uuidString).wav")
        try WAVEncoder.encode(samples: [0.2], sampleRate: 16_000).write(to: source)
        let job = try await store.createProvisionalRecovery(
            id: id, source: .init(reference: source.path), capturedAt: Date()
        )
        try await store.failProvisionalRecovery(
            id: id, failure: .init(stage: .transcribing, message: "Offline")
        )
        return job
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
