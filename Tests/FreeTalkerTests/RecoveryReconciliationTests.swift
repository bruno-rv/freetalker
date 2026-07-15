import Foundation
import Testing
@testable import FreeTalker

@Suite struct RecoveryReconciliationTests {
    @Test("corrupt artifacts are quarantined without blocking later valid audio")
    func corruptThenValidIsIsolatedAndDurable() async throws {
        let fixture = try ReconciliationFixture()
        let corrupt = fixture.root.appendingPathComponent("failed-000-corrupt.wav")
        let valid = fixture.root.appendingPathComponent("failed-999-valid.wav")
        try Data("not wav".utf8).write(to: corrupt)
        try WAVEncoder.encode(samples: [0.3, -0.1], sampleRate: 16_000).write(to: valid)

        let report = await fixture.reconciler().reconcile()
        #expect(report.quarantined == 1)
        #expect(report.imported == 1)
        #expect(report.failed == 0)
        #expect(FileManager.default.fileExists(atPath: corrupt.path))
        #expect(FileManager.default.fileExists(atPath: valid.path))
        #expect(try await fixture.store.jobs(kind: .recovery).count == 2)
    }

    @Test("orphan canonical UUID audio is registered by capture identity")
    func orphanCanonicalUsesCaptureIdentity() async throws {
        let fixture = try ReconciliationFixture()
        let captureID = UUID()
        let audio = fixture.root.appendingPathComponent("\(captureID.uuidString).wav")
        try WAVEncoder.encode(samples: [0.2], sampleRate: 16_000).write(to: audio)

        let report = await fixture.reconciler().reconcile()
        #expect(report.failures.isEmpty, Comment(rawValue: String(describing: report.failures)))
        #expect(report.imported == 1)
        #expect(try await fixture.store.session(id: captureID) == nil)
        let jobs = try await fixture.store.jobs(kind: .recovery)
        #expect(jobs.map(\.id) == [captureID])
        let storedSource = try #require(try await fixture.store.job(id: captureID)?.source.reference)
        #expect(
            URL(fileURLWithPath: storedSource).resolvingSymlinksInPath()
                == audio.resolvingSymlinksInPath()
        )

        let rerun = await fixture.reconciler().reconcile()
        #expect(rerun.imported == 0)
        #expect(rerun.duplicates == 1)
    }

    @Test("pending marker registers capture identity before marker removal")
    func pendingMarkerUsesCaptureIdentity() async throws {
        let fixture = try ReconciliationFixture()
        let captureID = UUID()
        let audio = fixture.root.appendingPathComponent("\(captureID.uuidString).wav")
        let marker = fixture.root.appendingPathComponent("\(captureID.uuidString).pending")
        try WAVEncoder.encode(samples: [0.4], sampleRate: 16_000).write(to: audio)
        try Data("0".utf8).write(to: marker)

        let report = await fixture.reconciler().reconcile()
        #expect(report.imported == 1)
        #expect(report.duplicates == 1) // the subsequent WAV inventory sees durable ownership
        #expect(try await fixture.store.job(id: captureID) != nil)
        #expect(!FileManager.default.fileExists(atPath: marker.path))
    }

    @Test("preparation evidence becomes durable damaged ownership and reruns idempotently")
    func preparationMarkerIsDurablyQuarantined() async throws {
        let fixture = try ReconciliationFixture()
        let captureID = UUID()
        let marker = fixture.root.appendingPathComponent(
            ".capture-preparation-\(captureID.uuidString).marker"
        )
        try Data("interrupted".utf8).write(to: marker)

        let first = await fixture.reconciler().reconcile()
        #expect(first.failures.isEmpty, Comment(rawValue: String(describing: first.failures)))
        #expect(first.quarantined == 1)
        #expect(try await fixture.store.session(id: captureID)?.assetKind == .quarantined)
        #expect(try await fixture.store.job(id: captureID) != nil)
        #expect(FileManager.default.fileExists(atPath: marker.path))

        let second = await fixture.reconciler().reconcile()
        #expect(second.duplicates == 1)
        #expect(try await fixture.store.jobs(kind: .recovery).count == 1)
    }

    @Test("Library capture identity wins and resumes cleanup without transcription")
    func libraryCommittedCaptureResumesCleanup() async throws {
        let fixture = try ReconciliationFixture()
        let captureID = UUID()
        let captureDirectory = fixture.root.appendingPathComponent(captureID.uuidString, isDirectory: true)
        try fixture.fileSystem.createDirectory(captureDirectory)
        let audio = captureDirectory.appendingPathComponent("\(captureID.uuidString).wav")
        let codec = CaptureSegmentCodec(fileSystem: fixture.fileSystem)
        try codec.encode([0.3]).write(to: audio)
        let request = CaptureStartRequest(
            id: captureID, directory: captureDirectory, capturedAt: Date(),
            sampleRate: 16_000, channelCount: 1, inputDeviceUID: nil,
            destination: "external"
        )
        _ = try await fixture.store.createCapture(request)
        try await fixture.store.transition(
            id: captureID, from: .capturing, to: .staged,
            recoveryJobID: nil, libraryDictationID: nil, assetKind: .audio,
            failureMessage: nil, contentHash: try codec.hashFile(audio)
        )
        _ = try await fixture.store.createProvisionalRecovery(
            id: captureID, source: JobSource(reference: audio.path), capturedAt: Date()
        )
        try await fixture.store.transition(
            id: captureID, from: .staged, to: .processing,
            recoveryJobID: captureID, libraryDictationID: nil, assetKind: .audio,
            failureMessage: nil, contentHash: try codec.hashFile(audio)
        )

        let report = await fixture.reconciler(libraryDictationID: { _ in 42 }).reconcile()
        #expect(report.failed == 0)
        #expect(try await fixture.store.session(id: captureID) == nil)
        #expect(try await fixture.store.job(id: captureID) == nil)
        #expect(!FileManager.default.fileExists(atPath: audio.path))
    }

    @Test("concurrent launch calls share one reconciliation")
    func concurrentReconciliationIsSingleFlight() async throws {
        let fixture = try ReconciliationFixture()
        let audio = fixture.root.appendingPathComponent("failed-concurrent.wav")
        try CaptureSegmentCodec(fileSystem: fixture.fileSystem).encode([0.2]).write(to: audio)
        let reconciler = fixture.reconciler()
        async let first = reconciler.reconcile()
        async let second = reconciler.reconcile()
        let reports = await [first, second]
        #expect(reports[0] == reports[1])
        #expect(try await fixture.store.jobs(kind: .recovery).count == 1)
    }

    @Test("store-wide inventory failure is distinct from item failures")
    func inventoryFailureHasHealthSignal() async throws {
        let fixture = try ReconciliationFixture()
        let reconciler = RecoveryReconciler(
            directory: fixture.root, store: fixture.store, ledger: fixture.store,
            fileSystem: InventoryFailingFileSystem(base: fixture.fileSystem),
            libraryDictationID: { _ in nil }
        )
        let report = await reconciler.reconcile()
        #expect(report.storeFailure != nil)
        #expect(report.failed == 0)
        #expect(report.failures.isEmpty)
    }
}

private struct InventoryFailingFileSystem: JournalFileSystem {
    let base: LocalJournalFileSystem
    func createDirectory(_ url: URL) throws { try base.createDirectory(url) }
    func write(_ data: Data, to url: URL) throws { try base.write(data, to: url) }
    func append(_ data: Data, to url: URL) throws { try base.append(data, to: url) }
    func synchronizeFile(_ url: URL) throws { try base.synchronizeFile(url) }
    func rename(_ source: URL, to destination: URL) throws { try base.rename(source, to: destination) }
    func synchronizeDirectory(_ url: URL) throws { try base.synchronizeDirectory(url) }
    func contents(_ url: URL) throws -> [URL] {
        throw JournalPersistenceError.read(path: url.path, code: EIO)
    }
    func read(_ url: URL) throws -> Data { try base.read(url) }
    func remove(_ url: URL) throws { try base.remove(url) }
    func exists(_ url: URL) -> Bool { base.exists(url) }
}

final class ReconciliationFixture: @unchecked Sendable {
    let temp: ReconciliationTemporaryDirectory
    let root: URL
    let database: URL
    let fileSystem = LocalJournalFileSystem()
    let store: TranscriptionJobStore

    init(temp: ReconciliationTemporaryDirectory = try! ReconciliationTemporaryDirectory()) throws {
        self.temp = temp
        root = temp.url.appendingPathComponent("failed-dictations", isDirectory: true)
        database = temp.url.appendingPathComponent("jobs.sqlite")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        store = try TranscriptionJobStore(databaseURL: database, clock: SystemJobClock())
    }

    private init(temp: ReconciliationTemporaryDirectory, root: URL, database: URL) throws {
        self.temp = temp
        self.root = root
        self.database = database
        store = try TranscriptionJobStore(databaseURL: database, clock: SystemJobClock())
    }

    func reopen() throws -> ReconciliationFixture {
        try ReconciliationFixture(temp: temp, root: root, database: database)
    }

    func reconciler(
        libraryDictationID: @escaping @Sendable (UUID) async throws -> Int64? = { _ in nil }
    ) -> RecoveryReconciler {
        RecoveryReconciler(
            directory: root, store: store, ledger: store, fileSystem: fileSystem,
            libraryDictationID: libraryDictationID
        )
    }
}

final class ReconciliationTemporaryDirectory: @unchecked Sendable {
    let url: URL
    init() throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "reconciliation-\(UUID().uuidString)", isDirectory: true
        )
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
    deinit { try? FileManager.default.removeItem(at: url) }
}
