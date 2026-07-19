import Foundation
import Testing
@testable import FreeTalker

@Suite struct RecoveryStorageTests {
    @Test func stopStagesDurableAudioBeforeLaunchingAsyncRegistration() throws {
        let fixture = try RecoveryFixture()
        let service = RecoveryCaptureService(directory: fixture.directory, store: fixture.store)
        var events: [String] = []
        var launchedCapture: StagedRecoveryCapture?

        try AppCoordinator.stageCaptureBeforeLaunching(
            samples: [0.25],
            stage: { samples in
                events.append("stage")
                return try service.stageProvisional(samples: samples, capturedAt: Date())
            },
            launch: { capture in
                events.append("launch")
                #expect(FileManager.default.fileExists(atPath: capture.source.reference))
                launchedCapture = capture
            }
        )

        #expect(events == ["stage", "launch"])
        #expect(launchedCapture != nil)
    }

    @Test func launchReconcilesAudioStagedBeforeRegistration() async throws {
        let fixture = try RecoveryFixture()
        let service = RecoveryCaptureService(directory: fixture.directory, store: fixture.store)
        let staged = try service.stageProvisional(
            samples: [0.25],
            capturedAt: Date(timeIntervalSince1970: 8_000)
        )

        let captures = try await service.reconcileStagedProvisionalCaptures()

        #expect(captures.map(\.source) == [staged.source])
        let job = try #require(try await fixture.store.job(id: captures[0].id))
        #expect(job.state == .processing(stage: .preparing))
        #expect(FileManager.default.fileExists(atPath: staged.source.reference))
    }

    @Test func launchIgnoresUnmarkedOrphanWAV() async throws {
        let fixture = try RecoveryFixture()
        let orphan = fixture.directory.appendingPathComponent("\(UUID().uuidString).wav")
        try Data("orphan".utf8).write(to: orphan)
        let service = RecoveryCaptureService(directory: fixture.directory, store: fixture.store)

        #expect(try await service.reconcileStagedProvisionalCaptures().isEmpty)
        #expect(try await fixture.store.jobs(kind: .recovery).isEmpty)
        #expect(FileManager.default.fileExists(atPath: orphan.path))
    }

    @Test func provisionalRegistrationFailureKeepsStagedAudioForLaunchReconciliation() async throws {
        let directory = try TemporaryDirectory()
        let service = RecoveryCaptureService(directory: directory.url, store: FailingRecoveryStore())
        let staged = try service.stageProvisional(samples: [0.25], capturedAt: Date())

        await #expect(throws: RecoveryTestError.databaseFailure) {
            try await service.registerProvisional(staged)
        }

        #expect(FileManager.default.fileExists(atPath: staged.source.reference))
    }

    @Test func provisionalCaptureAtomicallyWritesWAVAndCreatesLiveProcessingJob() async throws {
        let fixture = try RecoveryFixture()
        let now = Date(timeIntervalSince1970: 9_000)
        let service = RecoveryCaptureService(directory: fixture.directory, store: fixture.store)

        let capture = try await service.preserveProvisional(samples: [0, 0.5, -0.5], capturedAt: now)

        let job = try #require(try await fixture.store.job(id: capture.id))
        #expect(job.state == .processing(stage: .preparing))
        #expect(job.createdAt == now)
        #expect(job.source.reference == capture.source.reference)
        #expect(FileManager.default.fileExists(atPath: capture.source.reference))
    }

    @Test func provisionalFailureLeavesSameAudioRecoverableAndRetryable() async throws {
        let fixture = try RecoveryFixture()
        let service = RecoveryCaptureService(directory: fixture.directory, store: fixture.store)
        let capture = try await service.preserveProvisional(samples: [0.25], capturedAt: Date())
        let failure = JobFailure(stage: .transcribing, message: "cancelled")

        try await service.failProvisional(capture, failure: failure)

        let job = try #require(try await fixture.store.job(id: capture.id))
        #expect(job.state == .failed(failure))
        #expect(FileManager.default.fileExists(atPath: capture.source.reference))
    }

    @Test func journalCompletionKeepsRecoveryUntilLibraryOwnershipThenDeletesMediaJobAndLedgerInOrder() async throws {
        let fixture = try await JournalCompletionFixture()
        let libraryID = fixture.libraryID
        let service = fixture.service(libraryID: libraryID)

        try await service.completeJournalCapture(
            fixture.capture,
            captureID: fixture.captureID
        )

        #expect(fixture.events.values == [
            "lookup:\(fixture.captureID.uuidString)",
            "ledger-commit:\(fixture.captureID.uuidString)",
            "sync:\(fixture.temp.url.path)",
            "sync:\(fixture.temp.url.path)",
            "remove:\(fixture.canonical.path)",
            "remove:\(fixture.segment.path)",
            "sync:\(fixture.sessionDirectory.path)",
            // Codex round-5 finding 5: no marker exists in this fixture, so the marker-removal
            // step is a no-op, but the now-empty per-capture directory is still removed and its
            // parent (the recovery root) re-synced — additive cleanup after the unchanged steps
            // above, before the job/ledger rows are deleted.
            "remove:\(fixture.sessionDirectory.path)",
            "sync:\(fixture.temp.url.path)",
            "delete-job:\(fixture.captureID.uuidString)",
            "delete-ledger:\(fixture.captureID.uuidString)"
        ])
        #expect(try await fixture.store.job(id: fixture.captureID) == nil)
        #expect(try await fixture.store.session(id: fixture.captureID) == nil)
        #expect(!FileManager.default.fileExists(atPath: fixture.sessionDirectory.path))
    }

    @Test("cleanup removes the orphan voice-command intent marker and the now-empty capture directory before deleting the ledger row (Codex round-5 finding 5)")
    func journalCompletionRemovesTheOrphanVoiceCommandMarkerAndNowEmptyDirectory() async throws {
        let fixture = try await JournalCompletionFixture(writesVoiceCommandMarker: true)
        let marker = VoiceCommandFinalizationIntent.markerURL(in: fixture.sessionDirectory)
        #expect(FileManager.default.fileExists(atPath: marker.path))
        let service = fixture.service(libraryID: fixture.libraryID)

        try await service.completeJournalCapture(
            fixture.capture, captureID: fixture.captureID
        )

        #expect(!FileManager.default.fileExists(atPath: marker.path))
        #expect(!FileManager.default.fileExists(atPath: fixture.sessionDirectory.path))
        #expect(try await fixture.store.job(id: fixture.captureID) == nil)
        #expect(try await fixture.store.session(id: fixture.captureID) == nil)
    }

    @Test("cleanup refuses to delete a session directory outside <recoveryRoot>/<captureID> (Codex round-6 finding 1)")
    func cleanupRefusesSessionDirectoryOutsideRecoveryRoot() async throws {
        let temp = try TemporaryDirectory()
        let recoveryRoot = temp.url.appendingPathComponent("recovery", isDirectory: true)
        try FileManager.default.createDirectory(at: recoveryRoot, withIntermediateDirectories: true)
        let outside = temp.url.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let sentinel = outside.appendingPathComponent("do-not-delete.txt")
        try Data("keep".utf8).write(to: sentinel)
        let marker = VoiceCommandFinalizationIntent.markerURL(in: outside)
        try JSONEncoder().encode(VoiceCommandFinalizationIntent(enabled: true, keywords: ["comando"]))
            .write(to: marker)

        let captureID = UUID()
        let store = try TranscriptionJobStore(
            databaseURL: temp.url.appendingPathComponent("jobs.sqlite"), clock: SystemJobClock()
        )
        // A corrupted/migrated ledger row pointing outside `<recoveryRoot>/<captureID>` — cleanup
        // must never trust `session.directory` blindly for deletion.
        _ = try await store.createCapture(.init(
            id: captureID, directory: outside, capturedAt: Date(timeIntervalSince1970: 1),
            sampleRate: 16_000, channelCount: 1, inputDeviceUID: nil, destination: "external"
        ))
        try await store.transition(
            id: captureID, from: .capturing, to: .libraryCommitted,
            recoveryJobID: nil, libraryDictationID: 42, assetKind: .audio,
            failureMessage: nil, contentHash: nil
        )

        let service = RecoveryCaptureService(
            directory: recoveryRoot, store: store, ledger: store,
            libraryDictationID: { _ in 42 }
        )

        await #expect(throws: RecoveryFinalizationError.captureIdentityMismatch) {
            try await service.resumeLibraryCommittedCapture(captureID: captureID)
        }
        #expect(FileManager.default.fileExists(atPath: sentinel.path))
        #expect(FileManager.default.fileExists(atPath: marker.path))
        #expect(try await store.session(id: captureID)?.state == .libraryCommitted)
    }

    @Test("cleanup keeps the ledger row when the capture directory still has unexpected contents after marker removal (Codex round-6 finding 4)")
    func cleanupRetainsOwnershipWhenDirectoryHasUnexpectedContents() async throws {
        let fixture = try await JournalCompletionFixture()
        let stray = fixture.sessionDirectory.appendingPathComponent("unexpected.tmp")
        try Data("stray".utf8).write(to: stray)
        let service = fixture.service(libraryID: fixture.libraryID)

        await #expect(throws: CaptureJournalError.self) {
            try await service.completeJournalCapture(fixture.capture, captureID: fixture.captureID)
        }

        // The unexpected file (and therefore the directory itself) must survive — deleting the
        // job/ledger rows anyway would strand it with nothing left to revisit it.
        #expect(FileManager.default.fileExists(atPath: stray.path))
        #expect(FileManager.default.fileExists(atPath: fixture.sessionDirectory.path))
        #expect(try await fixture.store.session(id: fixture.captureID) != nil)
        #expect(try await fixture.store.job(id: fixture.captureID) != nil)
    }

    @Test("cleanup durably removes recognized app-owned temporary residue before the emptiness check, instead of wedging on legitimate crash leftovers (Codex round-7 finding 4)")
    func cleanupSweepsRecognizedTemporaryResidueBeforeEmptinessCheck() async throws {
        let fixture = try await JournalCompletionFixture()
        // Every temporary file this subsystem writes into a session directory
        // (`DurableArtifactWriter.commit`'s `temporary:` argument — segment, canonical-audio,
        // marker, and diagnostics writes) uses this exact `.<name>.<uuid>.tmp` naming. This
        // simulates a crash between one such write and its rename — legitimate app-owned residue,
        // not evidence of unexpected content, unlike `unexpected.tmp` in the round-6 finding-4 test
        // above (no leading dot — genuinely unrecognized).
        let residue = fixture.sessionDirectory.appendingPathComponent(
            ".capture-voice-command-intent.\(UUID().uuidString).tmp"
        )
        try Data("partial write".utf8).write(to: residue)
        let service = fixture.service(libraryID: fixture.libraryID)

        try await service.completeJournalCapture(fixture.capture, captureID: fixture.captureID)

        #expect(!FileManager.default.fileExists(atPath: residue.path))
        #expect(!FileManager.default.fileExists(atPath: fixture.sessionDirectory.path))
        #expect(try await fixture.store.job(id: fixture.captureID) == nil)
        #expect(try await fixture.store.session(id: fixture.captureID) == nil)
    }

    @Test("cleanup rejects an unrecognized hidden .tmp file instead of sweeping it as app-owned residue (Codex round-8 finding 1)")
    func cleanupRejectsUnrecognizedHiddenTemporaryFile() async throws {
        let fixture = try await JournalCompletionFixture()
        // Looks like the recognized `.<stem>.<uuid>.tmp` residue shape at a glance (leading dot,
        // `.tmp` suffix) but has no embedded UUID and isn't one of this subsystem's known
        // artifact stems — must NOT be swept as legitimate crash leftovers.
        let evil = fixture.sessionDirectory.appendingPathComponent(".evil.tmp")
        try Data("not app-owned".utf8).write(to: evil)
        let service = fixture.service(libraryID: fixture.libraryID)

        await #expect(throws: CaptureJournalError.self) {
            try await service.completeJournalCapture(fixture.capture, captureID: fixture.captureID)
        }

        #expect(FileManager.default.fileExists(atPath: evil.path))
        #expect(FileManager.default.fileExists(atPath: fixture.sessionDirectory.path))
        #expect(try await fixture.store.session(id: fixture.captureID) != nil)
        #expect(try await fixture.store.job(id: fixture.captureID) != nil)
    }

    @Test("cleanup refuses to remove a directory planted at the final intent-marker path (Codex round-9 finding 5)")
    func cleanupRejectsDirectoryPlantedAtIntentMarkerPath() async throws {
        let fixture = try await JournalCompletionFixture()
        // The final marker-removal step previously checked only name and existence —
        // `FileManager.removeItem` recursively deletes whatever is planted there, so a directory
        // (with real content inside) would be destroyed instead of hitting the unexpected-content
        // guard.
        let marker = VoiceCommandFinalizationIntent.markerURL(in: fixture.sessionDirectory)
        try FileManager.default.createDirectory(at: marker, withIntermediateDirectories: true)
        let sentinel = marker.appendingPathComponent("do-not-delete.txt")
        try Data("keep".utf8).write(to: sentinel)
        let service = fixture.service(libraryID: fixture.libraryID)

        await #expect(throws: CaptureJournalError.self) {
            try await service.completeJournalCapture(fixture.capture, captureID: fixture.captureID)
        }

        #expect(FileManager.default.fileExists(atPath: sentinel.path))
        #expect(try await fixture.store.session(id: fixture.captureID) != nil)
        #expect(try await fixture.store.job(id: fixture.captureID) != nil)
    }

    @Test("cleanup accepts a lowercase-UUID nested session directory the reconciler can legitimately create (Codex round-7 finding 5)")
    func cleanupAcceptsLowercaseUUIDDirectoryName() async throws {
        let temp = try TemporaryDirectory()
        let recoveryRoot = temp.url.appendingPathComponent("recovery", isDirectory: true)
        try FileManager.default.createDirectory(at: recoveryRoot, withIntermediateDirectories: true)
        let captureID = UUID()
        // `RecoveryReconciler.directoryCaptureID` parses the leaf via the case-insensitive
        // `UUID(uuidString:)` and persists whatever casing was actually on disk — a lowercase leaf
        // is a legitimate directory name this subsystem itself creates, not evidence of corruption.
        let sessionDirectory = recoveryRoot.appendingPathComponent(
            captureID.uuidString.lowercased(), isDirectory: true
        )
        try FileManager.default.createDirectory(at: sessionDirectory, withIntermediateDirectories: true)
        let canonical = sessionDirectory.appendingPathComponent("\(captureID.uuidString).wav")
        try Data([1]).write(to: canonical)
        let store = try TranscriptionJobStore(
            databaseURL: temp.url.appendingPathComponent("jobs.sqlite"), clock: SystemJobClock()
        )
        _ = try await store.createCapture(.init(
            id: captureID, directory: sessionDirectory, capturedAt: Date(timeIntervalSince1970: 1),
            sampleRate: 16_000, channelCount: 1, inputDeviceUID: nil, destination: "external"
        ))
        try await store.transition(
            id: captureID, from: .capturing, to: .libraryCommitted,
            recoveryJobID: nil, libraryDictationID: 42, assetKind: .audio,
            failureMessage: nil, contentHash: nil
        )
        let service = RecoveryCaptureService(
            directory: recoveryRoot, store: store, ledger: store,
            libraryDictationID: { _ in 42 }
        )

        try await service.resumeLibraryCommittedCapture(captureID: captureID)

        #expect(!FileManager.default.fileExists(atPath: sessionDirectory.path))
        #expect(try await store.session(id: captureID) == nil)
    }

    @Test("cleanup fsyncs the recovery root even when a retry finds the child directory already removed (Codex round-7 minor finding 2)")
    func cleanupFsyncsRecoveryRootOnRetryWhenChildAlreadyRemoved() async throws {
        let fixture = try await JournalCompletionFixture()
        // Simulates a prior pass that already durably removed the session directory (this exact
        // method's own directory-removal step, on an earlier attempt) but crashed before its
        // parent fsync landed — a retry must still fsync the recovery root before releasing
        // ownership (the job/ledger deletes) below.
        try FileManager.default.removeItem(at: fixture.sessionDirectory)
        let spy = SynchronizeDirectorySpyFileSystem()
        let service = RecoveryCaptureService(
            directory: fixture.temp.url, store: fixture.store, ledger: fixture.store,
            journalFileSystem: spy, libraryDictationID: { _ in fixture.libraryID }
        )

        try await service.completeJournalCapture(fixture.capture, captureID: fixture.captureID)

        #expect(spy.synchronizedDirectories.contains(fixture.temp.url.standardizedFileURL.path))
        #expect(try await fixture.store.job(id: fixture.captureID) == nil)
        #expect(try await fixture.store.session(id: fixture.captureID) == nil)
    }

    @Test func journalCompletionRefusesCleanupBeforeObservableLibraryCommit() async throws {
        let fixture = try await JournalCompletionFixture()
        let service = fixture.service(libraryID: nil)

        await #expect(throws: RecoveryFinalizationError.libraryOwnershipMissing(fixture.captureID)) {
            try await service.completeJournalCapture(
                fixture.capture,
                captureID: fixture.captureID
            )
        }

        #expect(try await fixture.store.job(id: fixture.captureID) != nil)
        #expect(try await fixture.store.session(id: fixture.captureID) != nil)
    }

    @Test func journalCompletionRetriesEveryInterruptedBoundaryWithoutLosingOwnership() async throws {
        let boundaries = [
            "lookup", "ledger-commit", "canonical", "segment", "sync", "delete-job", "delete-ledger"
        ]
        var fixtures: [JournalCompletionFixture] = []
        for _ in boundaries { fixtures.append(try await JournalCompletionFixture()) }
        for (boundary, fixture) in zip(boundaries, fixtures) {
            fixture.events.armFailure(boundary)
            let service = fixture.service(libraryID: fixture.libraryID)

            do {
                try await service.completeJournalCapture(
                    fixture.capture, captureID: fixture.captureID
                )
                Issue.record("expected injected failure at \(boundary)")
            } catch is InjectedRecoveryFinalizationFailure {
            }
            let libraryOwnsCapture = fixture.events.values.contains(
                "lookup:\(fixture.captureID.uuidString)"
            )
            let recoveryJobExists = try await fixture.store.job(id: fixture.captureID) != nil
            let recoveryLedgerExists = try await fixture.store.session(id: fixture.captureID) != nil
            #expect(libraryOwnsCapture || recoveryJobExists || recoveryLedgerExists)

            let reopened = try TranscriptionJobStore(
                databaseURL: fixture.databaseURL, clock: SystemJobClock()
            )
            let resumed = RecoveryCaptureService(
                directory: fixture.temp.url, store: reopened, ledger: reopened,
                journalFileSystem: LocalJournalFileSystem(),
                libraryDictationID: { id in try fixture.library.lookup(captureID: id) }
            )
            let reopenedSession = try await reopened.session(id: fixture.captureID)
            if reopenedSession == nil {
                // The final ledger delete committed before the injected throw.
            } else if reopenedSession?.state == .libraryCommitted {
                try await resumed.resumeLibraryCommittedCaptures()
            } else {
                try await resumed.completeJournalCapture(
                    fixture.capture, captureID: fixture.captureID
                )
            }
            #expect(try await reopened.job(id: fixture.captureID) == nil)
            #expect(try await reopened.session(id: fixture.captureID) == nil)
            #expect(try fixture.library.count(captureID: fixture.captureID) == 1)
        }
    }

    @Test func startupResumesLedgerOnlyCleanupAfterRecoveryJobDeleteCommittedThenThrew() async throws {
        let fixture = try await JournalCompletionFixture()
        try await fixture.store.transition(
            fixture.captureID, from: .processing,
            to: .failed(.init(stage: .persisting, message: "stale lease"))
        )
        try await fixture.store.transition(fixture.captureID, from: .failed, to: .queued)
        _ = try await fixture.store.claimQueuedJob(
            fixture.captureID, kind: .recovery, owner: UUID(), leaseDuration: 300
        )
        fixture.events.armFailure("delete-job")
        let service = fixture.service(libraryID: fixture.libraryID)

        await #expect(throws: InjectedRecoveryFinalizationFailure.self) {
            try await service.completeJournalCapture(
                fixture.capture, captureID: fixture.captureID
            )
        }
        #expect(try await fixture.store.job(id: fixture.captureID) == nil)
        #expect(try await fixture.store.session(id: fixture.captureID)?.state == .libraryCommitted)

        let reopened = try TranscriptionJobStore(
            databaseURL: fixture.databaseURL, clock: SystemJobClock()
        )
        let resumed = RecoveryCaptureService(
            directory: fixture.temp.url,
            store: reopened,
            ledger: reopened,
            journalFileSystem: LocalJournalFileSystem(),
            libraryDictationID: { id in try fixture.library.lookup(captureID: id) }
        )
        try await resumed.resumeLibraryCommittedCaptures()

        #expect(try await reopened.job(id: fixture.captureID) == nil)
        #expect(try await reopened.session(id: fixture.captureID) == nil)
    }

    @Test func captureAtomicallyWritesWAVAndCreatesFailedJob() async throws {
        let fixture = try RecoveryFixture()
        let now = Date(timeIntervalSince1970: 10_000)
        let service = RecoveryCaptureService(directory: fixture.directory, store: fixture.store)

        let id = try await service.preserve(
            samples: [0, 0.5, -0.5],
            metadata: RecoveryMetadata(capturedAt: now, failure: .init(stage: .transcribing, message: "no speech"))
        )

        let job = try #require(try await fixture.store.job(id: id))
        #expect(job.kind == .recovery)
        #expect(job.state == .failed(.init(stage: .transcribing, message: "no speech")))
        #expect(FileManager.default.fileExists(atPath: job.source.reference))
        let files = try FileManager.default.contentsOfDirectory(at: fixture.directory, includingPropertiesForKeys: nil)
        let audioFiles = files.filter { $0.pathExtension == "wav" }
        #expect(audioFiles.count == 1)
        #expect(try Data(contentsOf: URL(fileURLWithPath: job.source.reference)).prefix(4) == Data("RIFF".utf8))
    }

    @Test func captureRemovesFinalAndTemporaryFilesWhenJobCreationFails() async throws {
        let directory = try TemporaryDirectory()
        let service = RecoveryCaptureService(directory: directory.url, store: FailingRecoveryStore())

        await #expect(throws: RecoveryTestError.databaseFailure) {
            try await service.preserve(samples: [0.25], metadata: .init(
                capturedAt: Date(timeIntervalSince1970: 20_000),
                failure: .init(stage: .persisting, message: "database failed")
            ))
        }

        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.url.path).isEmpty)
    }

    @Test func captureExposesPersistenceAndRollbackErrorsWhenFinalRemovalFails() async throws {
        let directory = try TemporaryDirectory()
        let service = RecoveryCaptureService(
            directory: directory.url,
            store: FailingRecoveryStore(),
            fileRemover: AlwaysFailingRemover()
        )

        do {
            _ = try await service.preserve(samples: [0.25], metadata: .init(
                capturedAt: Date(), failure: .init(stage: .persisting, message: "database failed")
            ))
            Issue.record("Expected compound capture failure")
        } catch let error as RecoveryCaptureRollbackError {
            #expect(error.persistenceError is RecoveryTestError)
            #expect(error.rollbackError is CocoaError)
        }
    }

    @Test(arguments: RecoveryRetention.allCases.filter { $0 != .never })
    func automaticRetentionNeverDeletesFailedRecovery(retention: RecoveryRetention) async throws {
        let fixture = try RecoveryFixture()
        let createdAt = Date(timeIntervalSince1970: 100_000)
        let id = try await fixture.failedRecovery(createdAt: createdAt)
        let service = RecoveryRetentionService(directory: fixture.directory, store: fixture.store)

        let path = try #require(try await fixture.store.job(id: id)).source.reference
        #expect(try await service.purgeExpired(now: .distantFuture, retention: retention) == PurgeResult(deletedJobIDs: []))
        #expect(FileManager.default.fileExists(atPath: path))
        #expect(try await fixture.store.job(id: id) != nil)
    }

    @Test func libraryDebugPurgeNeverTraversesRecoveryRoot() throws {
        let temp = try TemporaryDirectory()
        let recovery = temp.url.appendingPathComponent("failed-dictations", isDirectory: true)
        let nested = recovery.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let retryable = recovery.appendingPathComponent("\(UUID().uuidString).wav")
        let damaged = nested.appendingPathComponent("capture-failure.marker")
        let silent = nested.appendingPathComponent("capture-diagnostics.json")
        try Data("retryable".utf8).write(to: retryable)
        try Data("damaged".utf8).write(to: damaged)
        try Data("silent".utf8).write(to: silent)
        let debug = temp.url.appendingPathComponent("last-dictation.wav")
        try Data("debug".utf8).write(to: debug)

        try LibraryStore.purgeDebugAudio(in: temp.url)

        #expect(!FileManager.default.fileExists(atPath: debug.path))
        #expect(try Data(contentsOf: retryable) == Data("retryable".utf8))
        #expect(try Data(contentsOf: damaged) == Data("damaged".utf8))
        #expect(try Data(contentsOf: silent) == Data("silent".utf8))
    }

    @Test func automaticRetentionFinishesOnlyLibraryCommittedCleanup() async throws {
        let fixture = try RecoveryFixture()
        let failedID = try await fixture.failedRecovery(createdAt: .distantPast)
        let failedSource = try #require(try await fixture.store.job(id: failedID))
            .source.reference
        let committedID = UUID()
        let committedDirectory = fixture.directory.appendingPathComponent(
            committedID.uuidString, isDirectory: true
        )
        try FileManager.default.createDirectory(at: committedDirectory, withIntermediateDirectories: false)
        try Data("committed".utf8).write(
            to: committedDirectory.appendingPathComponent("\(committedID.uuidString).wav")
        )
        _ = try await fixture.store.createCapture(.init(
            id: committedID, directory: committedDirectory, capturedAt: .distantPast,
            sampleRate: 16_000, channelCount: 1, inputDeviceUID: nil,
            destination: "external"
        ))
        try await fixture.store.transition(
            id: committedID, from: .capturing, to: .libraryCommitted,
            recoveryJobID: nil, libraryDictationID: 42, assetKind: .audio,
            failureMessage: nil, contentHash: nil
        )

        _ = try await RecoveryRetentionService(
            directory: fixture.directory, store: fixture.store, ledger: fixture.store
        ).purgeExpired(now: .distantFuture, retention: .oneDay)

        #expect(try await fixture.store.session(id: committedID) == nil)
        #expect(!FileManager.default.fileExists(atPath: committedDirectory.path))
        #expect(try await fixture.store.job(id: failedID) != nil)
        #expect(FileManager.default.fileExists(atPath: failedSource))
    }

    @Test func claimedDeletesConvergeBeforeUnrelatedMalformedCommittedCleanupFailure() async throws {
        let fixture = try RecoveryFixture()
        let first = try await fixture.failedRecovery(createdAt: .distantPast)
        let second = try await fixture.failedRecovery(createdAt: .distantPast)
        let firstSource = try #require(try await fixture.store.job(id: first)).source.reference
        let secondSource = try #require(try await fixture.store.job(id: second)).source.reference
        #expect(try await fixture.store.claimRecoveryForDeletion(id: first, claimedAt: Date()))
        #expect(try await fixture.store.claimRecoveryForDeletion(id: second, claimedAt: Date()))
        let malformedID = UUID()
        let malformedDirectory = fixture.temp.url.appendingPathComponent("malformed", isDirectory: true)
        try FileManager.default.createDirectory(at: malformedDirectory, withIntermediateDirectories: false)
        _ = try await fixture.store.createCapture(.init(
            id: malformedID, directory: malformedDirectory, capturedAt: Date(),
            sampleRate: 16_000, channelCount: 1, inputDeviceUID: nil,
            destination: "external"
        ))
        try await fixture.store.transition(
            id: malformedID, from: .capturing, to: .libraryCommitted,
            recoveryJobID: nil, libraryDictationID: 7, assetKind: .audio,
            failureMessage: nil, contentHash: nil
        )

        await #expect(throws: RecoveryFinalizationError.captureIdentityMismatch) {
            _ = try await RecoveryRetentionService(
                directory: fixture.directory, store: fixture.store, ledger: fixture.store
            ).purgeExpired(now: Date(), retention: .never)
        }

        let reopened = try TranscriptionJobStore(
            databaseURL: fixture.temp.url.appendingPathComponent("jobs.sqlite"),
            clock: SystemJobClock()
        )
        #expect(try await reopened.job(id: first) == nil)
        #expect(try await reopened.job(id: second) == nil)
        #expect(try await reopened.claimedRecoveries().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: firstSource))
        #expect(!FileManager.default.fileExists(atPath: secondSource))
        #expect(try await reopened.session(id: malformedID)?.state == .libraryCommitted)
        #expect(FileManager.default.fileExists(atPath: malformedDirectory.path))
    }

    @Test func neverRetentionDoesNothing() async throws {
        let fixture = try RecoveryFixture()
        let id = try await fixture.failedRecovery(createdAt: .distantPast)
        let result = try await RecoveryRetentionService(directory: fixture.directory, store: fixture.store)
            .purgeExpired(now: .distantFuture, retention: .never)
        #expect(result.deletedJobIDs.isEmpty)
        #expect(try await fixture.store.job(id: id) != nil)
        let path = try #require(try await fixture.store.job(id: id)).source.reference
        #expect(FileManager.default.fileExists(atPath: path))
    }

    @Test func purgeDeletesOnlyExactOwnedPath() async throws {
        let fixture = try RecoveryFixture()
        let id = try await fixture.failedRecovery(createdAt: .distantPast)
        let source = try #require(try await fixture.store.job(id: id)).source.reference
        let sibling = URL(fileURLWithPath: source + ".backup")
        try Data("keep".utf8).write(to: sibling)
        #expect(try await fixture.store.claimRecoveryForDeletion(id: id, claimedAt: Date()))

        _ = try await RecoveryRetentionService(directory: fixture.directory, store: fixture.store)
            .purgeExpired(now: .distantFuture, retention: .oneDay)

        #expect(FileManager.default.fileExists(atPath: sibling.path))
        #expect(!FileManager.default.fileExists(atPath: source))
    }

    @Test func purgeExcludesQueuedProcessingReadyCancelledAndNonRecoveryJobs() async throws {
        let fixture = try RecoveryFixture()
        let old = Date(timeIntervalSince1970: 1)
        let states: [JobState] = [.queued, .processing(stage: .transcribing), .ready, .cancelled]
        var ids: [UUID] = []
        for state in states { ids.append(try await fixture.job(kind: .recovery, state: state, createdAt: old)) }
        ids.append(try await fixture.job(kind: .mediaImport, state: .failed(.init(stage: .transcribing, message: "x")), createdAt: old))

        let result = try await RecoveryRetentionService(directory: fixture.directory, store: fixture.store)
            .purgeExpired(now: .distantFuture, retention: .oneDay)

        #expect(result.deletedJobIDs.isEmpty)
        for id in ids { #expect(try await fixture.store.job(id: id) != nil) }
    }

    @Test func databaseClaimRejectsAJobThatBecameActiveAfterDiscovery() async throws {
        let fixture = try RecoveryFixture()
        let id = try await fixture.failedRecovery(createdAt: .distantPast)
        try await fixture.store.transition(id, from: .failed, to: .queued)

        #expect(try await fixture.store.claimExpiredRecoveries(cutoff: .distantFuture, claimedAt: Date()) == [])
        #expect(try await fixture.store.job(id: id)?.state == .queued)
    }

    @Test func claimedRecoveryCannotBeRetriedOrActivated() async throws {
        let fixture = try RecoveryFixture()
        let id = try await fixture.failedRecovery(createdAt: .distantPast)
        #expect(try await fixture.store.claimExpiredRecoveries(cutoff: .distantFuture, claimedAt: Date()).map(\.id) == [id])

        await #expect(throws: JobStoreError.invalidTransition) {
            try await fixture.store.transition(id, from: .failed, to: .queued)
        }
        await #expect(throws: JobStoreError.purgeClaimed) {
            _ = try await fixture.store.beginAttempt(jobID: id, configuration: .init())
        }
    }

    @Test func purgeClaimAndAttemptHaveExactlyOneWinnerAcrossConnectionsInBothOrderings() async throws {
        for claimFirst in [true, false] {
            let temp = try TemporaryDirectory()
            let databaseURL = temp.url.appendingPathComponent("jobs.sqlite")
            let first = try TranscriptionJobStore(databaseURL: databaseURL, clock: SystemJobClock())
            let second = try TranscriptionJobStore(databaseURL: databaseURL, clock: SystemJobClock())
            let source = temp.url.appendingPathComponent("\(UUID().uuidString).wav")
            try Data("audio".utf8).write(to: source)
            let job = try await first.createRecovery(
                source: .init(reference: source.path),
                metadata: .init(
                    capturedAt: .distantPast,
                    failure: .init(stage: .transcribing, message: "failed")
                )
            )

            if claimFirst {
                #expect(try await first.claimExpiredRecoveries(cutoff: .distantFuture, claimedAt: Date()).map(\.id) == [job.id])
                await #expect(throws: JobStoreError.purgeClaimed) {
                    _ = try await second.beginAttempt(jobID: job.id, configuration: .init())
                }
                #expect(try await second.attempts(jobID: job.id).isEmpty)
            } else {
                let attempt = try await first.beginAttempt(jobID: job.id, configuration: .init())
                #expect(attempt.number == 1)
                #expect(try await second.claimExpiredRecoveries(cutoff: .distantFuture, claimedAt: Date()).isEmpty)
                #expect(try await second.claimedRecoveries().isEmpty)
            }
        }
    }

    @Test func purgeReconcilesClaimedJobWithExistingFileAfterCrash() async throws {
        let fixture = try RecoveryFixture()
        let id = try await fixture.failedRecovery(createdAt: .distantPast)
        let source = try #require(try await fixture.store.job(id: id)).source.reference
        _ = try await fixture.store.claimExpiredRecoveries(cutoff: .distantFuture, claimedAt: Date())
        let restarted = try TranscriptionJobStore(
            databaseURL: fixture.temp.url.appendingPathComponent("jobs.sqlite"),
            clock: SystemJobClock()
        )

        let result = try await RecoveryRetentionService(directory: fixture.directory, store: restarted)
            .purgeExpired(now: Date(), retention: .never)

        #expect(result.deletedJobIDs == [id])
        #expect(!FileManager.default.fileExists(atPath: source))
        #expect(try await restarted.job(id: id) == nil)
    }

    @Test func purgeReconcilesClaimedJobWithMissingFileAfterCrash() async throws {
        let fixture = try RecoveryFixture()
        let id = try await fixture.failedRecovery(createdAt: .distantPast)
        let source = try #require(try await fixture.store.job(id: id)).source.reference
        _ = try await fixture.store.claimExpiredRecoveries(cutoff: .distantFuture, claimedAt: Date())
        try FileManager.default.removeItem(atPath: source)

        let result = try await RecoveryRetentionService(directory: fixture.directory, store: fixture.store)
            .purgeExpired(now: Date(), retention: .never)

        #expect(result.deletedJobIDs == [id])
        #expect(try await fixture.store.job(id: id) == nil)
    }

    @Test func removalFailureKeepsClaimAndVisibleCleanupError() async throws {
        let fixture = try RecoveryFixture()
        let job = try await fixture.failedRecovery(createdAt: .distantPast)
        #expect(try await fixture.store.claimRecoveryForDeletion(id: job, claimedAt: Date()))

        await #expect(throws: Error.self) {
            _ = try await RecoveryRetentionService(
                directory: fixture.directory,
                store: fixture.store,
                fileRemover: AlwaysFailingRemover()
            )
                .purgeExpired(now: .distantFuture, retention: .oneDay)
        }

        let claim = try #require(try await fixture.store.claimedRecoveries().first { $0.id == job })
        #expect(claim.cleanupError != nil)
        #expect(try await fixture.store.job(id: job) != nil)
    }

    @Test func unsafeDotDotNestedAndSymlinkSourcesNeverDeleteOutsideFiles() async throws {
        let fixture = try RecoveryFixture()
        let outside = fixture.temp.url.appendingPathComponent("outside.wav")
        try Data("outside".utf8).write(to: outside)
        let nestedDirectory = fixture.directory.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nestedDirectory, withIntermediateDirectories: false)
        let nested = nestedDirectory.appendingPathComponent("\(UUID().uuidString).wav")
        try Data("nested".utf8).write(to: nested)
        let symlink = fixture.directory.appendingPathComponent("\(UUID().uuidString).wav")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: outside)
        let references = [
            fixture.directory.appendingPathComponent("../outside.wav").path,
            nested.path,
            symlink.path
        ]
        for reference in references {
            let id = try await fixture.failedRecovery(createdAt: .distantPast, sourceReference: reference)
            #expect(try await fixture.store.claimRecoveryForDeletion(id: id, claimedAt: Date()))
        }

        _ = try? await RecoveryRetentionService(directory: fixture.directory, store: fixture.store)
            .purgeExpired(now: .distantFuture, retention: .oneDay)

        #expect(try Data(contentsOf: outside) == Data("outside".utf8))
        #expect(FileManager.default.fileExists(atPath: nested.path))
        #expect(FileManager.default.fileExists(atPath: symlink.path))
        #expect(try await fixture.store.claimedRecoveries().count == 3)
    }

    @Test func symlinkRootAllowsOwnedChildButNeverOutsideSymlinkTarget() async throws {
        let temp = try TemporaryDirectory()
        let realRoot = temp.url.appendingPathComponent("real", isDirectory: true)
        let linkedRoot = temp.url.appendingPathComponent("linked", isDirectory: true)
        try FileManager.default.createDirectory(at: realRoot, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(at: linkedRoot, withDestinationURL: realRoot)
        let store = try TranscriptionJobStore(databaseURL: temp.url.appendingPathComponent("jobs.sqlite"), clock: SystemJobClock())
        let owned = linkedRoot.appendingPathComponent("\(UUID().uuidString).wav")
        try Data("owned".utf8).write(to: owned)
        let job = try await store.createRecovery(source: .init(reference: owned.path), metadata: .init(capturedAt: .distantPast, failure: .init(stage: .transcribing, message: "x")))
        try RecoveryImportDispositionStore(directory: linkedRoot)
            .registerOwnedSource(id: job.id, source: owned)
        #expect(try await store.claimRecoveryForDeletion(id: job.id, claimedAt: Date()))

        _ = try await RecoveryRetentionService(directory: linkedRoot, store: store)
            .purgeExpired(now: .distantFuture, retention: .oneDay)

        #expect(!FileManager.default.fileExists(atPath: owned.path))
        #expect(try await store.job(id: job.id) == nil)
    }
}

private enum RecoveryTestError: Error { case databaseFailure }

private actor FailingRecoveryStore: RecoveryJobStoring {
    func job(id: UUID) throws -> TranscriptionJob? { throw RecoveryTestError.databaseFailure }
    func createProvisionalRecovery(source: JobSource, capturedAt: Date) throws -> TranscriptionJob { throw RecoveryTestError.databaseFailure }
    func createProvisionalRecovery(id: UUID, source: JobSource, capturedAt: Date, voiceCommandsEnabled: Bool?, commandKeywords: [String]?) throws -> TranscriptionJob { throw RecoveryTestError.databaseFailure }
    func failProvisionalRecovery(id: UUID, failure: JobFailure) throws { throw RecoveryTestError.databaseFailure }
    func deleteProvisionalRecovery(id: UUID, expectedSourceReference: String) throws -> Bool { throw RecoveryTestError.databaseFailure }
    func deleteCommittedRecovery(id: UUID, expectedSourceReference: String) throws -> Bool { throw RecoveryTestError.databaseFailure }
    func createRecovery(source: JobSource, metadata: RecoveryMetadata) throws -> TranscriptionJob { throw RecoveryTestError.databaseFailure }
    func claimExpiredRecoveries(cutoff: Date, claimedAt: Date) throws -> [RecoveryPurgeClaim] { [] }
    func claimedRecoveries() throws -> [RecoveryPurgeClaim] { [] }
    func recordPurgeError(id: UUID, message: String) throws {}
    func deleteClaimedRecovery(id: UUID, expectedSourceReference: String) throws -> Bool { false }
}

private struct AlwaysFailingRemover: RecoveryFileRemoving {
    func removeItem(at url: URL) throws {
        throw CocoaError(.fileWriteNoPermission)
    }
}

private final class LockedRecoveryEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []
    private var failureEvent: String?
    private var didFail = false
    init(failureEvent: String? = nil) { self.failureEvent = failureEvent }
    var values: [String] { lock.withLock { storage } }
    func append(_ value: String) { lock.withLock { storage.append(value) } }
    func armFailure(_ boundary: String) {
        lock.withLock {
            failureEvent = boundary
            didFail = false
        }
    }
    func record(_ value: String, boundary: String) throws {
        let fails = lock.withLock { () -> Bool in
            storage.append(value)
            guard !didFail, failureEvent == boundary else { return false }
            didFail = true
            return true
        }
        if fails { throw InjectedRecoveryFinalizationFailure(boundary: boundary) }
    }
}

private struct InjectedRecoveryFinalizationFailure: Error {
    let boundary: String
}

/// Records every `synchronizeDirectory` call while delegating to a real filesystem, so a test can
/// assert a specific directory was durably fsynced without depending on that fsync's (unobservable
/// from userspace) actual disk effect (Codex round-7 minor finding 2).
private final class SynchronizeDirectorySpyFileSystem: JournalFileSystem, @unchecked Sendable {
    private let base = LocalJournalFileSystem()
    private let lock = NSLock()
    private var storage: [String] = []
    var synchronizedDirectories: [String] { lock.withLock { storage } }
    func createDirectory(_ url: URL) throws { try base.createDirectory(url) }
    func write(_ data: Data, to url: URL) throws { try base.write(data, to: url) }
    func append(_ data: Data, to url: URL) throws { try base.append(data, to: url) }
    func synchronizeFile(_ url: URL) throws { try base.synchronizeFile(url) }
    func rename(_ source: URL, to destination: URL) throws { try base.rename(source, to: destination) }
    func synchronizeDirectory(_ url: URL) throws {
        try base.synchronizeDirectory(url)
        lock.withLock { storage.append(url.standardizedFileURL.path) }
    }
    func contents(_ url: URL) throws -> [URL] { try base.contents(url) }
    func read(_ url: URL) throws -> Data { try base.read(url) }
    func remove(_ url: URL) throws { try base.remove(url) }
    func removeEmptyDirectory(_ url: URL) throws { try base.removeEmptyDirectory(url) }
    func removeRegularFile(_ url: URL) throws { try base.removeRegularFile(url) }
    func exists(_ url: URL) -> Bool { base.exists(url) }
}

private struct RecordingRecoveryFileSystem: JournalFileSystem {
    let base = LocalJournalFileSystem()
    let events: LockedRecoveryEvents

    func createDirectory(_ url: URL) throws { try base.createDirectory(url) }
    func write(_ data: Data, to url: URL) throws { try base.write(data, to: url) }
    func append(_ data: Data, to url: URL) throws { try base.append(data, to: url) }
    func synchronizeFile(_ url: URL) throws { try base.synchronizeFile(url) }
    func rename(_ source: URL, to destination: URL) throws { try base.rename(source, to: destination) }
    func synchronizeDirectory(_ url: URL) throws {
        try base.synchronizeDirectory(url)
        try events.record("sync:\(url.path)", boundary: "sync")
    }
    func contents(_ url: URL) throws -> [URL] { try base.contents(url) }
    func read(_ url: URL) throws -> Data { try base.read(url) }
    func remove(_ url: URL) throws {
        let boundary = url.lastPathComponent.hasPrefix("segment-") ? "segment" : "canonical"
        try base.remove(url)
        try events.record("remove:\(url.path)", boundary: boundary)
    }
    func removeEmptyDirectory(_ url: URL) throws { try base.removeEmptyDirectory(url) }
    func removeRegularFile(_ url: URL) throws { try base.removeRegularFile(url) }
    func exists(_ url: URL) -> Bool { base.exists(url) }
}

private struct JournalCompletionFixture {
    let temp: TemporaryDirectory
    let store: TranscriptionJobStore
    let databaseURL: URL
    let library: PersistentCaptureLibrary
    let libraryID: Int64
    let captureID: UUID
    let sessionDirectory: URL
    let canonical: URL
    let segment: URL
    let capture: ProvisionalRecoveryCapture
    let events: LockedRecoveryEvents

    init(removeCanonical: Bool = false, writesVoiceCommandMarker: Bool = false, failureEvent: String? = nil) async throws {
        events = LockedRecoveryEvents(failureEvent: failureEvent)
        temp = try TemporaryDirectory()
        captureID = UUID()
        sessionDirectory = temp.url.appendingPathComponent(captureID.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: sessionDirectory, withIntermediateDirectories: true)
        canonical = sessionDirectory.appendingPathComponent("\(captureID.uuidString).wav")
        segment = sessionDirectory.appendingPathComponent("segment-00000000.wav")
        try Data([1]).write(to: canonical)
        try Data([2]).write(to: segment)
        if writesVoiceCommandMarker {
            try JSONEncoder().encode(VoiceCommandFinalizationIntent(enabled: true, keywords: ["comando"]))
                .write(to: VoiceCommandFinalizationIntent.markerURL(in: sessionDirectory))
        }
        databaseURL = temp.url.appendingPathComponent("jobs.sqlite")
        library = try PersistentCaptureLibrary(
            url: temp.url.appendingPathComponent("library.sqlite")
        )
        libraryID = try library.insert(captureID: captureID)
        store = try TranscriptionJobStore(
            databaseURL: databaseURL,
            clock: SystemJobClock()
        )
        let capturedAt = Date(timeIntervalSince1970: 12_345)
        _ = try await store.createCapture(.init(
            id: captureID, directory: sessionDirectory, capturedAt: capturedAt,
            sampleRate: 16_000, channelCount: 1, inputDeviceUID: nil,
            destination: "external"
        ))
        try await store.recordCommittedSegment(.init(
            captureID: captureID, ordinal: 0, url: segment,
            sampleCount: 1, contentHash: "hash"
        ))
        try await store.transition(
            id: captureID, from: .capturing, to: .staged,
            recoveryJobID: nil, libraryDictationID: nil, assetKind: .audio,
            failureMessage: nil, contentHash: "canonical"
        )
        let job = try await store.createProvisionalRecovery(
            id: captureID,
            source: .init(reference: canonical.path), capturedAt: capturedAt
        )
        try await store.transition(
            id: captureID, from: .staged, to: .processing,
            recoveryJobID: job.id, libraryDictationID: nil, assetKind: .audio,
            failureMessage: nil, contentHash: "canonical"
        )
        capture = .init(id: job.id, source: job.source)
        if removeCanonical { try FileManager.default.removeItem(at: canonical) }
    }

    func service(libraryID: Int64?) -> RecoveryCaptureService {
        RecoveryCaptureService(
            directory: temp.url,
            store: EventingRecoveryStore(base: store, events: events),
            ledger: EventingCaptureLedger(base: store, events: events),
            journalFileSystem: RecordingRecoveryFileSystem(events: events),
            libraryDictationID: { id in
                try events.record("lookup:\(id.uuidString)", boundary: "lookup")
                guard libraryID != nil else { return nil }
                return try library.lookup(captureID: id)
            }
        )
    }
}

private final class PersistentCaptureLibrary: @unchecked Sendable {
    let url: URL
    init(url: URL) throws {
        self.url = url
        _ = try Database(path: url)
    }

    func insert(captureID: UUID) throws -> Int64 {
        let db = try Database(path: url)
        return try db.insertDictation(.init(
            timestamp: Date(timeIntervalSince1970: 12_345),
            sourceLanguage: SourceLanguage("en"),
            requestedOutputLanguage: .sameAsSpoken,
            template: "Clean", transcript: "raw", refined: "refined",
            engine: "local", sourceID: nil
        ), captureID: captureID).id
    }

    func lookup(captureID: UUID) throws -> Int64? {
        try Database(path: url).dictations(captureID: captureID).first?.id
    }

    func count(captureID: UUID) throws -> Int {
        try Database(path: url).dictations(captureID: captureID).count
    }
}

private struct EventingRecoveryStore: RecoveryJobStoring {
    let base: TranscriptionJobStore
    let events: LockedRecoveryEvents
    func job(id: UUID) async throws -> TranscriptionJob? { try await base.job(id: id) }
    func createProvisionalRecovery(source: JobSource, capturedAt: Date) async throws -> TranscriptionJob { try await base.createProvisionalRecovery(source: source, capturedAt: capturedAt) }
    func createProvisionalRecovery(id: UUID, source: JobSource, capturedAt: Date, voiceCommandsEnabled: Bool?, commandKeywords: [String]?) async throws -> TranscriptionJob { try await base.createProvisionalRecovery(id: id, source: source, capturedAt: capturedAt, voiceCommandsEnabled: voiceCommandsEnabled, commandKeywords: commandKeywords) }
    func failProvisionalRecovery(id: UUID, failure: JobFailure) async throws { try await base.failProvisionalRecovery(id: id, failure: failure) }
    func deleteProvisionalRecovery(id: UUID, expectedSourceReference: String) async throws -> Bool { try await base.deleteProvisionalRecovery(id: id, expectedSourceReference: expectedSourceReference) }
    func deleteCommittedRecovery(id: UUID, expectedSourceReference: String) async throws -> Bool {
        let removed = try await base.deleteCommittedRecovery(
            id: id, expectedSourceReference: expectedSourceReference
        )
        try events.record("delete-job:\(id.uuidString)", boundary: "delete-job")
        return removed
    }
    func createRecovery(source: JobSource, metadata: RecoveryMetadata) async throws -> TranscriptionJob { try await base.createRecovery(source: source, metadata: metadata) }
    func claimExpiredRecoveries(cutoff: Date, claimedAt: Date) async throws -> [RecoveryPurgeClaim] { try await base.claimExpiredRecoveries(cutoff: cutoff, claimedAt: claimedAt) }
    func claimedRecoveries() async throws -> [RecoveryPurgeClaim] { try await base.claimedRecoveries() }
    func recordPurgeError(id: UUID, message: String) async throws { try await base.recordPurgeError(id: id, message: message) }
    func deleteClaimedRecovery(id: UUID, expectedSourceReference: String) async throws -> Bool { try await base.deleteClaimedRecovery(id: id, expectedSourceReference: expectedSourceReference) }
}

private struct EventingCaptureLedger: CaptureLedgerStoring {
    let base: TranscriptionJobStore
    let events: LockedRecoveryEvents
    func createCapture(_ request: CaptureStartRequest) async throws -> CaptureSession { try await base.createCapture(request) }
    func recordCommittedSegment(_ segment: CaptureSegment) async throws { try await base.recordCommittedSegment(segment) }
    func transition(id: UUID, from: CaptureSessionState, to: CaptureSessionState, recoveryJobID: UUID?, libraryDictationID: Int64?, assetKind: RecoveryAssetKind, failureMessage: String?, contentHash: String?) async throws {
        try await base.transition(id: id, from: from, to: to, recoveryJobID: recoveryJobID, libraryDictationID: libraryDictationID, assetKind: assetKind, failureMessage: failureMessage, contentHash: contentHash)
        if to == .libraryCommitted {
            try events.record("ledger-commit:\(id.uuidString)", boundary: "ledger-commit")
        }
    }
    func session(id: UUID) async throws -> CaptureSession? { try await base.session(id: id) }
    func unfinishedSessions() async throws -> [CaptureSession] { try await base.unfinishedSessions() }
    func committedSegments(captureID: UUID) async throws -> [CaptureSegment] { try await base.committedSegments(captureID: captureID) }
    func removeCommittedSegments(captureID: UUID) async throws { try await base.removeCommittedSegments(captureID: captureID) }
    func removeCleanedSession(id: UUID) async throws {
        try await base.removeCleanedSession(id: id)
        try events.record("delete-ledger:\(id.uuidString)", boundary: "delete-ledger")
    }
}

private final class RecoveryFixture: @unchecked Sendable {
    let temp: TemporaryDirectory
    let directory: URL
    let store: TranscriptionJobStore

    init() throws {
        temp = try TemporaryDirectory()
        directory = temp.url.appendingPathComponent("recoveries", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        store = try TranscriptionJobStore(databaseURL: temp.url.appendingPathComponent("jobs.sqlite"), clock: SystemJobClock())
    }

    func failedRecovery(createdAt: Date) async throws -> UUID {
        try await job(kind: .recovery, state: .failed(.init(stage: .transcribing, message: "failed")), createdAt: createdAt)
    }

    func failedRecovery(createdAt: Date, source: URL) async throws -> UUID {
        try await failedRecovery(createdAt: createdAt, sourceReference: source.path)
    }

    func failedRecovery(createdAt: Date, sourceReference: String) async throws -> UUID {
        let created = try await store.create(kind: .recovery, source: .init(reference: sourceReference), now: createdAt)
        try await store.transition(created.id, from: .queued, to: .processing(stage: .preparing))
        try await store.transition(created.id, from: .processing, to: .failed(.init(stage: .transcribing, message: "failed")))
        let source = URL(fileURLWithPath: sourceReference)
        let values = try? source.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        if source.deletingLastPathComponent().standardizedFileURL == directory.standardizedFileURL,
           values?.isRegularFile == true, values?.isSymbolicLink != true,
           (try? CaptureSegmentCodec(fileSystem: LocalJournalFileSystem()).hashFile(source)) != nil {
            try RecoveryImportDispositionStore(directory: directory)
                .registerOwnedSource(id: created.id, source: source)
        }
        return created.id
    }

    func job(kind: JobKind, state: JobState, createdAt: Date) async throws -> UUID {
        let source = directory.appendingPathComponent("\(UUID().uuidString).wav")
        let path = source.path
        try Data("audio".utf8).write(to: source)
        let created = try await store.create(kind: kind, source: .init(reference: path), now: createdAt)
        if state != .queued {
            if state.kind == .cancelled { try await store.transition(created.id, from: .queued, to: state) }
            else {
                try await store.transition(created.id, from: .queued, to: .processing(stage: .preparing))
                try await store.transition(created.id, from: .processing, to: state)
            }
        }
        if kind == .recovery {
            try RecoveryImportDispositionStore(directory: directory)
                .registerOwnedSource(id: created.id, source: source)
        }
        return created.id
    }
}

private final class TemporaryDirectory: @unchecked Sendable {
    let url: URL
    init() throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
    deinit { try? FileManager.default.removeItem(at: url) }
}
