import Foundation
import Testing
@testable import FreeTalker

@Suite struct RecoveryReconciliationTests {
    @Test("launch reconciliation upgrades a markerless current-format job before orphan import")
    func launchUpgradesMarkerlessCurrentRecovery() async throws {
        let fixture = try ReconciliationFixture()
        let filenameID = UUID()
        let source = fixture.root.appendingPathComponent("\(filenameID.uuidString).wav")
        try WAVEncoder.encode(samples: [0.2], sampleRate: 16_000).write(to: source)
        let job = try await fixture.store.createRecovery(
            source: .init(reference: source.path),
            metadata: .init(
                capturedAt: Date(),
                failure: .init(stage: .transcribing, message: "Offline")
            )
        )

        let report = await fixture.reconciler().reconcile()

        #expect(report.failed == 0)
        #expect(try await fixture.store.jobs(kind: .recovery).map(\.id) == [job.id])
        #expect(try await fixture.store.job(id: filenameID) == nil)
        #expect(try await fixture.store.session(id: filenameID) == nil)
        #expect(try RecoveryImportDispositionStore(directory: fixture.root)
            .ownsSource(id: job.id, source: source))

        let reopened = try fixture.reopen()
        let second = await reopened.reconciler().reconcile()
        #expect(second.failed == 0)
        #expect(try await reopened.store.jobs(kind: .recovery).map(\.id) == [job.id])
    }

    @Test(
        "silent cleanup rejects every unowned segment path without partial deletion",
        arguments: UnsafeSilentSegmentCase.allCases
    )
    func silentCleanupRejectsUnownedSegments(candidate: UnsafeSilentSegmentCase) async throws {
        let fixture = try ReconciliationFixture()
        let id = UUID()
        let expectedDirectory = fixture.root.appendingPathComponent(id.uuidString, isDirectory: true)
        let sessionDirectory = candidate == .sessionOutsideRoot
            ? fixture.temp.url.appendingPathComponent("outside-session", isDirectory: true)
            : expectedDirectory
        try fixture.fileSystem.createDirectory(sessionDirectory)
        _ = try await fixture.store.createCapture(.init(
            id: id, directory: sessionDirectory, capturedAt: Date(), sampleRate: 16_000,
            channelCount: 1, inputDeviceUID: "mic", destination: "external"
        ))
        let codec = CaptureSegmentCodec(fileSystem: fixture.fileSystem)
        let valid = sessionDirectory.appendingPathComponent("segment-00000000.wav")
        let validData = codec.encode([0])
        try validData.write(to: valid)
        try await fixture.store.recordCommittedSegment(.init(
            captureID: id, ordinal: 0, url: valid, sampleCount: 1,
            contentHash: codec.hash(validData)
        ))

        let outside = fixture.temp.url.appendingPathComponent("outside-segment.wav")
        try Data("outside-must-survive".utf8).write(to: outside)
        let unsafe: URL = switch candidate {
        case .outsideRoot:
            outside
        case .pathTraversal:
            sessionDirectory.appendingPathComponent("../segment-00000001.wav")
        case .symlink:
            sessionDirectory.appendingPathComponent("segment-00000001.wav")
        case .ordinalMismatch:
            sessionDirectory.appendingPathComponent("segment-00000002.wav")
        case .sessionOutsideRoot:
            sessionDirectory.appendingPathComponent("segment-00000001.wav")
        }
        if candidate == .symlink {
            try FileManager.default.createSymbolicLink(at: unsafe, withDestinationURL: outside)
        } else if unsafe.standardizedFileURL != outside.standardizedFileURL {
            try codec.encode([0]).write(to: unsafe.standardizedFileURL)
        }
        try await fixture.store.recordCommittedSegment(.init(
            captureID: id, ordinal: 1, url: unsafe, sampleCount: 1,
            contentHash: codec.hash(codec.encode([0]))
        ))
        let diagnostics = CaptureDiagnostics(
            peak: 0, rms: 0, inputDeviceUID: "mic", routeFailure: nil
        )
        try DurableArtifactWriter(fileSystem: fixture.fileSystem).commit(
            try JSONEncoder().encode(diagnostics),
            temporary: sessionDirectory.appendingPathComponent("diagnostics.tmp"),
            destination: sessionDirectory.appendingPathComponent("capture-diagnostics.json")
        )
        try await fixture.store.transition(
            id: id, from: .capturing, to: .silent, recoveryJobID: nil,
            libraryDictationID: nil, assetKind: .silent,
            failureMessage: SilentCapturePresentation.message, contentHash: nil
        )

        let report = await fixture.reconciler().reconcile()

        #expect(report.failed == 1)
        #expect(report.failures.first?.message.contains("Silent capture") == true)
        #expect(FileManager.default.fileExists(atPath: valid.path))
        #expect(FileManager.default.fileExists(atPath: unsafe.path))
        #expect(try Data(contentsOf: outside) == Data("outside-must-survive".utf8))
        #expect(try await fixture.store.committedSegments(captureID: id).count == 2)
        #expect(try await fixture.store.session(id: id)?.state == .silent)
        #expect(try await fixture.store.session(id: id)?.failureMessage == SilentCapturePresentation.message)
        #expect(try CaptureJournalService(
            fileSystem: fixture.fileSystem, ledger: fixture.store
        ).loadSilentDiagnostics(try #require(try await fixture.store.session(id: id))) == diagnostics)
        #expect(try await fixture.store.jobs(kind: .recovery).isEmpty)
    }

    @Test(
        "silent segment cleanup converges after every durable boundary failure",
        arguments: SilentCleanupBoundary.allCases
    )
    func silentSegmentCleanupConverges(boundary: SilentCleanupBoundary) async throws {
        let fixture = try ReconciliationFixture()
        let id = UUID()
        let directory = fixture.root.appendingPathComponent(id.uuidString, isDirectory: true)
        let fileSystem = SilentCleanupFaultFileSystem(boundary: boundary)
        let ledger = SilentCleanupFaultLedger(base: fixture.store, boundary: boundary)
        let service = CaptureJournalService(
            fileSystem: fileSystem, ledger: ledger,
            configuration: .init(segmentFrames: 4, maximumQueuedFrames: 16),
            recoveryRoot: fixture.root
        )
        let active = try await service.prepare(.init(
            id: id, directory: directory, capturedAt: Date(), sampleRate: 16_000,
            channelCount: 1, inputDeviceUID: "mic", destination: "external"
        ))
        #expect(active.writer.enqueue(Array(repeating: 0, count: 8)) == .accepted)
        #expect(await active.writer.committedSnapshot().count == 2)

        await #expect(throws: (any Error).self) {
            try await service.recordSilent(
                active,
                diagnostics: .init(peak: 0, rms: 0, inputDeviceUID: "mic", routeFailure: nil)
            )
        }
        #expect(try await fixture.store.session(id: id)?.state == .silent)
        #expect(try await fixture.store.session(id: id)?.failureMessage == SilentCapturePresentation.message)
        #expect(try await fixture.store.committedSegments(captureID: id).count == 2)

        let reopened = try fixture.reopen()
        let report = await reopened.reconciler().reconcile()

        #expect(report.failed == 0)
        #expect(try await reopened.store.session(id: id)?.state == .silent)
        #expect(try await reopened.store.session(id: id)?.failureMessage == SilentCapturePresentation.message)
        #expect(try await reopened.store.committedSegments(captureID: id).isEmpty)
        #expect(try reopened.fileSystem.contents(directory).allSatisfy {
            CaptureSegmentCodec.ordinal(from: $0) == nil
        })
        #expect(try await reopened.store.jobs(kind: .recovery).isEmpty)
    }

    @Test("silent diagnostics resume an interrupted silent ledger transition")
    func silentDiagnosticsResumeTransition() async throws {
        let fixture = try ReconciliationFixture()
        let id = UUID()
        let directory = fixture.root.appendingPathComponent(id.uuidString, isDirectory: true)
        try fixture.fileSystem.createDirectory(directory)
        _ = try await fixture.store.createCapture(.init(
            id: id, directory: directory, capturedAt: Date(), sampleRate: 16_000,
            channelCount: 1, inputDeviceUID: "mic", destination: "external"
        ))
        let diagnostics = CaptureDiagnostics(
            peak: 0, rms: 0, inputDeviceUID: "mic", routeFailure: "route unavailable"
        )
        let target = directory.appendingPathComponent("capture-diagnostics.json")
        try DurableArtifactWriter(fileSystem: fixture.fileSystem).commit(
            try JSONEncoder().encode(diagnostics),
            temporary: directory.appendingPathComponent("diagnostics.tmp"),
            destination: target
        )

        let report = await fixture.reconciler().reconcile()

        #expect(report.failed == 0)
        #expect(try await fixture.store.session(id: id)?.state == .silent)
        #expect(try await fixture.store.session(id: id)?.failureMessage == SilentCapturePresentation.message)
        #expect(try CaptureJournalService(
            fileSystem: fixture.fileSystem, ledger: fixture.store
        ).loadSilentDiagnostics(try #require(try await fixture.store.session(id: id))) == diagnostics)
    }

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
        #expect(second.duplicates == 1) // historical marker; owned audio stays within its ledger directory
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

    @Test("crash-recreated recovery job inherits the session's durable voice-command snapshot (PLAN.md PR A, item 1b)")
    func reconciliationInheritsVoiceCommandSnapshotIntoRecreatedJob() async throws {
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
        // Simulates `CaptureJournalService.finish(active, voiceCommands:)` durably recording the
        // snapshot onto the session before its `.capturing -> .staged` transition, then a crash
        // before `RecoveryCaptureService.registerJournalCapture` ever ran to create the
        // provisional job — reconciliation must recreate that job from the canonical audio and
        // inherit the already-durable session snapshot, not silently drop it (nil/nil).
        try await fixture.store.recordVoiceCommandSnapshot(
            id: captureID, enabled: true, keywords: ["command", "comando"]
        )
        let postRecordSession = try await fixture.store.session(id: captureID)
        #expect(postRecordSession?.voiceCommandsEnabled == true)
        #expect(postRecordSession?.commandKeywords == ["command", "comando"])
        try await fixture.store.transition(
            id: captureID, from: .capturing, to: .staged,
            recoveryJobID: nil, libraryDictationID: nil, assetKind: .audio,
            failureMessage: nil, contentHash: try codec.hashFile(audio)
        )

        let preReconcileSession = try await fixture.store.session(id: captureID)
        #expect(preReconcileSession?.voiceCommandsEnabled == true)
        #expect(preReconcileSession?.commandKeywords == ["command", "comando"])

        let report = await fixture.reconciler().reconcile()

        #expect(report.failed == 0)
        let job = try #require(try await fixture.store.job(id: captureID))
        #expect(job.voiceCommandsEnabled == true)
        #expect(job.commandKeywords == ["command", "comando"])
    }

    @Test("a quarantine-created recovery job inherits the session's durable voice-command snapshot instead of defaulting to nil (Codex round-8 finding 3)")
    func quarantineCreatedJobInheritsVoiceCommandSnapshot() async throws {
        let fixture = try ReconciliationFixture()
        let captureID = UUID()
        let captureDirectory = fixture.root.appendingPathComponent(captureID.uuidString, isDirectory: true)
        try fixture.fileSystem.createDirectory(captureDirectory)
        let request = CaptureStartRequest(
            id: captureID, directory: captureDirectory, capturedAt: Date(),
            sampleRate: 16_000, channelCount: 1, inputDeviceUID: nil,
            destination: "external"
        )
        _ = try await fixture.store.createCapture(request)
        // A durable, already-persisted stop-time snapshot on the session — reconciliation must
        // route it through the quarantine job it (re)creates below, not silently discard it via
        // `LegacyRecoveryImporter.importAudio`'s defaulted `nil`/`nil` parameters.
        try await fixture.store.recordVoiceCommandSnapshot(
            id: captureID, enabled: true, keywords: ["command", "comando"]
        )
        // No committed segments and no canonical audio — reconciliation's `.capturing` branch
        // falls through to the "no committed audio" quarantine path, which calls
        // `LegacyRecoveryImporter.importAudio(..., preferredID: captureID, forceQuarantine: true)`
        // with the session (and its snapshot) already durable in the ledger.
        let failureMarker = captureDirectory.appendingPathComponent("capture-failure.marker")
        try Data("Capture journal failed before recoverable audio was committed".utf8).write(to: failureMarker)

        let report = await fixture.reconciler().reconcile()

        #expect(report.failed == 0, Comment(rawValue: String(describing: report.failures)))
        #expect(try await fixture.store.session(id: captureID)?.state == .damaged)
        let job = try #require(try await fixture.store.job(id: captureID))
        #expect(job.voiceCommandsEnabled == true)
        #expect(job.commandKeywords == ["command", "comando"])
    }

    @Test("committed segments assembled after a failed voice-command snapshot write still carry the stop-time policy (Codex round-2 finding 1)")
    func interruptedSegmentsHydrateVoiceCommandSnapshotFromFinalizationIntent() async throws {
        let fixture = try ReconciliationFixture()
        let id = UUID()
        let sessionDirectory = fixture.root.appendingPathComponent(id.uuidString, isDirectory: true)
        let faultyLedger = SnapshotFailingLedger(base: fixture.store)
        let service = CaptureJournalService(
            fileSystem: fixture.fileSystem, ledger: faultyLedger,
            configuration: .init(segmentFrames: 4, maximumQueuedFrames: 16)
        )
        let request = CaptureStartRequest(
            id: id, directory: sessionDirectory, capturedAt: Date(), sampleRate: 16_000,
            channelCount: 1, inputDeviceUID: nil, destination: "external"
        )
        let active = try await service.prepare(request)
        #expect(active.writer.enqueue([0, 1, 2, 3]) == .accepted)
        #expect(await active.writer.committedSnapshot().count == 1)

        // Simulates Stop: the finalization intent marker lands durably, then the ledger write of
        // the snapshot itself fails (e.g. a transient SQLite error) — `finish` must still refuse
        // to commit the canonical WAV, leaving already-committed segments as the only recoverable
        // artifact.
        await #expect(throws: TestLedgerError.injected) {
            _ = try await service.finish(
                active,
                voiceCommands: VoiceCommandSnapshot(enabled: true, keywords: ["command", "comando"])
            )
        }

        let preReconcileSession = try await fixture.store.session(id: id)
        #expect(preReconcileSession?.state == .capturing)
        #expect(preReconcileSession?.voiceCommandsEnabled == nil)
        #expect(!FileManager.default.fileExists(
            atPath: sessionDirectory.appendingPathComponent("\(id.uuidString).wav").path
        ))

        let reopened = try fixture.reopen()
        let report = await reopened.reconciler().reconcile()

        #expect(report.failed == 0, Comment(rawValue: String(describing: report.failures)))
        let job = try #require(try await reopened.store.job(id: id))
        #expect(job.voiceCommandsEnabled == true)
        #expect(job.commandKeywords == ["command", "comando"])
    }

    @Test("transient hydration failure during reconciliation reports and retries instead of quarantining healthy multi-segment audio (Codex round-3 finding 1)")
    func hydrationFailureDuringReconciliationDoesNotQuarantineHealthySegments() async throws {
        let fixture = try ReconciliationFixture()
        let id = UUID()
        let sessionDirectory = fixture.root.appendingPathComponent(id.uuidString, isDirectory: true)
        try fixture.fileSystem.createDirectory(sessionDirectory)
        _ = try await fixture.store.createCapture(.init(
            id: id, directory: sessionDirectory, capturedAt: Date(), sampleRate: 16_000,
            channelCount: 1, inputDeviceUID: nil, destination: "external"
        ))
        let codec = CaptureSegmentCodec(fileSystem: fixture.fileSystem)
        var segmentURLs: [URL] = []
        for (ordinal, samples) in [[Float(0.2), 0.1], [0.3, 0.4]].enumerated() {
            let url = sessionDirectory.appendingPathComponent(String(format: "segment-%08d.wav", ordinal))
            let data = codec.encode(samples)
            try data.write(to: url)
            try await fixture.store.recordCommittedSegment(.init(
                captureID: id, ordinal: ordinal, url: url, sampleCount: samples.count,
                contentHash: codec.hash(data)
            ))
            segmentURLs.append(url)
        }
        // Durable stop-time intent marker present (as `finish` would have written before a
        // transient ledger failure), session snapshot columns still NULL — reconciliation must
        // attempt hydration on this pass.
        try DurableArtifactWriter(fileSystem: fixture.fileSystem).commit(
            try JSONEncoder().encode(VoiceCommandFinalizationIntent(
                enabled: true, keywords: ["command", "comando"]
            )),
            temporary: sessionDirectory.appendingPathComponent(".intent.tmp"),
            destination: VoiceCommandFinalizationIntent.markerURL(in: sessionDirectory)
        )

        let faultyLedger = SnapshotFailingLedger(base: fixture.store)
        let firstReport = await RecoveryReconciler(
            directory: fixture.root, store: fixture.store, ledger: faultyLedger,
            fileSystem: fixture.fileSystem, libraryDictationID: { _ in nil }
        ).reconcile()

        // A transient hydration failure (metadata/storage) must be reported for retry, not folded
        // into "segments are damaged" — the healthy two-segment recording stays intact, and is NOT
        // quarantined down to a single non-retryable fallback file.
        #expect(firstReport.failed == 1)
        #expect(firstReport.quarantined == 0)
        #expect(try await fixture.store.session(id: id)?.state == .capturing)
        #expect(try await fixture.store.committedSegments(captureID: id).count == 2)
        for url in segmentURLs {
            #expect(FileManager.default.fileExists(atPath: url.path))
        }

        let reopened = try fixture.reopen()
        let secondReport = await reopened.reconciler().reconcile()

        #expect(secondReport.failed == 0, Comment(rawValue: String(describing: secondReport.failures)))
        #expect(try await reopened.store.session(id: id)?.state == .processing)
        let job = try #require(try await reopened.store.job(id: id))
        #expect(job.voiceCommandsEnabled == true)
        #expect(job.commandKeywords == ["command", "comando"])
        #expect(FileManager.default.fileExists(
            atPath: sessionDirectory.appendingPathComponent("\(id.uuidString).wav").path
        ))
    }

    @Test("a segment durably written to disk but not yet ledger-committed before a crash is still assembled, not silently dropped (Codex round-5 finding 1)")
    func diskOrphanSegmentIsAdoptedBeforeAssemblingAKnownCapturingSession() async throws {
        let fixture = try ReconciliationFixture()
        let id = UUID()
        let sessionDirectory = fixture.root.appendingPathComponent(id.uuidString, isDirectory: true)
        try fixture.fileSystem.createDirectory(sessionDirectory)
        _ = try await fixture.store.createCapture(.init(
            id: id, directory: sessionDirectory, capturedAt: Date(), sampleRate: 16_000,
            channelCount: 1, inputDeviceUID: nil, destination: "external"
        ))
        let codec = CaptureSegmentCodec(fileSystem: fixture.fileSystem)
        let samples: [[Float]] = [[0.2, 0.1], [0.3, 0.4]]
        var segmentURLs: [URL] = []
        for (ordinal, sample) in samples.enumerated() {
            let url = sessionDirectory.appendingPathComponent(String(format: "segment-%08d.wav", ordinal))
            let data = codec.encode(sample)
            try data.write(to: url)
            segmentURLs.append(url)
        }
        // Simulates a crash between the durable rename of the SECOND segment's file
        // (`CaptureJournalWriter.commit`) and the matching `ledger.recordCommittedSegment` call —
        // the file exists, durably, on disk, but the ledger only knows about the first segment.
        try await fixture.store.recordCommittedSegment(.init(
            captureID: id, ordinal: 0, url: segmentURLs[0], sampleCount: samples[0].count,
            contentHash: codec.hash(codec.encode(samples[0]))
        ))
        #expect(try await fixture.store.committedSegments(captureID: id).count == 1)

        let reopened = try fixture.reopen()
        let report = await reopened.reconciler().reconcile()

        #expect(report.failed == 0, Comment(rawValue: String(describing: report.failures)))
        #expect(report.quarantined == 0)
        #expect(try await reopened.store.session(id: id)?.state == .processing)
        #expect(try await reopened.store.committedSegments(captureID: id).count == 2)
        // Not truncated down to the first segment's 2 samples — both segments' 4 samples total.
        let assembled = try codec.decode(sessionDirectory.appendingPathComponent("\(id.uuidString).wav"))
        #expect(assembled.count == 4)
    }

    @Test("a non-contiguous orphan segment file during disk re-inventory fails loudly instead of silently adopting a gap (Codex round-5 finding 1)")
    func diskInventoryGapFailsInsteadOfSkippingMissingOrdinal() async throws {
        let fixture = try ReconciliationFixture()
        let id = UUID()
        let sessionDirectory = fixture.root.appendingPathComponent(id.uuidString, isDirectory: true)
        try fixture.fileSystem.createDirectory(sessionDirectory)
        _ = try await fixture.store.createCapture(.init(
            id: id, directory: sessionDirectory, capturedAt: Date(), sampleRate: 16_000,
            channelCount: 1, inputDeviceUID: nil, destination: "external"
        ))
        let codec = CaptureSegmentCodec(fileSystem: fixture.fileSystem)
        // Ordinal 0 is both on disk and ledger-committed (the healthy baseline). Ordinal 2's file
        // is an orphan on disk (durably renamed, never ledger-recorded — the finding-1 crash
        // window), but ordinal 1's file is genuinely missing entirely — a real gap, not the
        // crash-window case. Adopting ordinal 2 as if it were the next contiguous segment would
        // silently drop the missing middle segment from assembled audio.
        let firstURL = sessionDirectory.appendingPathComponent("segment-00000000.wav")
        let firstData = codec.encode([0.1, 0.2])
        try firstData.write(to: firstURL)
        try await fixture.store.recordCommittedSegment(.init(
            captureID: id, ordinal: 0, url: firstURL, sampleCount: 2, contentHash: codec.hash(firstData)
        ))
        let gapURL = sessionDirectory.appendingPathComponent("segment-00000002.wav")
        try codec.encode([0.5, 0.6]).write(to: gapURL)

        let report = await fixture.reconciler().reconcile()

        #expect(report.failed == 1)
        #expect(report.quarantined == 0)
        #expect(try await fixture.store.session(id: id)?.state == .capturing)
        #expect(try await fixture.store.committedSegments(captureID: id).count == 1)
    }

    @Test("an orphan directory with a non-contiguous segment gap fails loudly without partially committing ownership (Codex round-7 finding 8)")
    func orphanDirectoryGapFailsLoudlyInsteadOfPartiallyCommitting() async throws {
        let fixture = try ReconciliationFixture()
        let id = UUID()
        let sessionDirectory = fixture.root.appendingPathComponent(id.uuidString, isDirectory: true)
        try fixture.fileSystem.createDirectory(sessionDirectory)
        let codec = CaptureSegmentCodec(fileSystem: fixture.fileSystem)
        // Ordinal 0 and 2 exist on disk; ordinal 1 is genuinely missing (not yet written). No
        // ledger row exists at all yet — this directory is discovered as a totally unowned orphan.
        try codec.encode([0.1, 0.2]).write(to: sessionDirectory.appendingPathComponent("segment-00000000.wav"))
        try codec.encode([0.5, 0.6]).write(to: sessionDirectory.appendingPathComponent("segment-00000002.wav"))

        let report = await fixture.reconciler().reconcile()

        #expect(report.failed == 1)
        #expect(report.quarantined == 0)
        #expect(report.imported == 0)
        // Must not durably commit partial ownership of the gapped inventory — the old bug recorded
        // ordinals 0 and 2 to the ledger before attempting assembly, so even though assembly then
        // failed, the ledger row and its two committed segments survived the failure, and a later
        // pass could never observe ordinal 1 as a still-pending orphan again.
        #expect(try await fixture.store.session(id: id) == nil)
        #expect(try await fixture.store.committedSegments(captureID: id).isEmpty)

        // Ordinal 1 finally shows up (the delayed write lands) — reconciliation must still be able
        // to assemble the full, contiguous 3-segment recording from scratch.
        try codec.encode([0.3, 0.4]).write(to: sessionDirectory.appendingPathComponent("segment-00000001.wav"))
        let secondReport = await fixture.reconciler().reconcile()

        #expect(secondReport.failed == 0, Comment(rawValue: String(describing: secondReport.failures)))
        #expect(secondReport.imported == 1)
        let assembled = try codec.decode(sessionDirectory.appendingPathComponent("\(id.uuidString).wav"))
        #expect(assembled.count == 6)
    }

    @Test("a transient rename failure while assembling healthy segments reports and retries instead of quarantining (Codex round-5 finding 2)")
    func transientAssembleIOFailureDoesNotQuarantineHealthySegments() async throws {
        let fixture = try ReconciliationFixture()
        let id = UUID()
        let sessionDirectory = fixture.root.appendingPathComponent(id.uuidString, isDirectory: true)
        try fixture.fileSystem.createDirectory(sessionDirectory)
        _ = try await fixture.store.createCapture(.init(
            id: id, directory: sessionDirectory, capturedAt: Date(), sampleRate: 16_000,
            channelCount: 1, inputDeviceUID: nil, destination: "external"
        ))
        let codec = CaptureSegmentCodec(fileSystem: fixture.fileSystem)
        var segmentURLs: [URL] = []
        for (ordinal, samples) in [[Float(0.2), 0.1], [0.3, 0.4]].enumerated() {
            let url = sessionDirectory.appendingPathComponent(String(format: "segment-%08d.wav", ordinal))
            let data = codec.encode(samples)
            try data.write(to: url)
            try await fixture.store.recordCommittedSegment(.init(
                captureID: id, ordinal: ordinal, url: url, sampleCount: samples.count,
                contentHash: codec.hash(data)
            ))
            segmentURLs.append(url)
        }

        let faultFileSystem = AssembleRenameFaultFileSystem()
        let firstReport = await RecoveryReconciler(
            directory: fixture.root, store: fixture.store, ledger: fixture.store,
            fileSystem: faultFileSystem, libraryDictationID: { _ in nil }
        ).reconcile()

        // A transient rename failure during assembly (disk full, sandbox hiccup) must report for
        // retry, not quarantine a healthy two-segment recording down to its first segment.
        #expect(firstReport.failed == 1)
        #expect(firstReport.quarantined == 0)
        #expect(try await fixture.store.session(id: id)?.state == .capturing)
        #expect(try await fixture.store.committedSegments(captureID: id).count == 2)
        for url in segmentURLs {
            #expect(FileManager.default.fileExists(atPath: url.path))
        }

        let reopened = try fixture.reopen()
        let secondReport = await reopened.reconciler().reconcile()

        #expect(secondReport.failed == 0, Comment(rawValue: String(describing: secondReport.failures)))
        #expect(try await reopened.store.session(id: id)?.state == .processing)
        _ = try #require(try await reopened.store.job(id: id))
        let assembled = try codec.decode(sessionDirectory.appendingPathComponent("\(id.uuidString).wav"))
        #expect(assembled.count == 4)
    }

    @Test("a genuinely corrupted committed segment still quarantines down to a single fallback file (Codex round-5 finding 2)")
    func corruptedCommittedSegmentStillQuarantines() async throws {
        let fixture = try ReconciliationFixture()
        let id = UUID()
        let sessionDirectory = fixture.root.appendingPathComponent(id.uuidString, isDirectory: true)
        try fixture.fileSystem.createDirectory(sessionDirectory)
        _ = try await fixture.store.createCapture(.init(
            id: id, directory: sessionDirectory, capturedAt: Date(), sampleRate: 16_000,
            channelCount: 1, inputDeviceUID: nil, destination: "external"
        ))
        let codec = CaptureSegmentCodec(fileSystem: fixture.fileSystem)
        let firstURL = sessionDirectory.appendingPathComponent("segment-00000000.wav")
        let firstData = codec.encode([0.2, 0.1])
        try firstData.write(to: firstURL)
        try await fixture.store.recordCommittedSegment(.init(
            captureID: id, ordinal: 0, url: firstURL, sampleCount: 2, contentHash: codec.hash(firstData)
        ))
        let secondURL = sessionDirectory.appendingPathComponent("segment-00000001.wav")
        try codec.encode([0.3, 0.4]).write(to: secondURL)
        // A deliberately WRONG content hash for the second segment — genuine, deterministic
        // corruption evidence, unlike the transient-I/O case above.
        try await fixture.store.recordCommittedSegment(.init(
            captureID: id, ordinal: 1, url: secondURL, sampleCount: 2, contentHash: "corrupt-hash"
        ))

        let report = await fixture.reconciler().reconcile()

        // Known-session quarantines (unlike orphan-directory/loose-file quarantines) don't bump
        // `report.quarantined` — asserting the resulting ledger state is the correct signal here,
        // matching this file's other known-session quarantine tests (e.g. `state == .damaged`
        // above already established elsewhere in this suite).
        #expect(report.failed == 0)
        #expect(try await fixture.store.session(id: id)?.state == .damaged)
        #expect(try await fixture.store.session(id: id)?.assetKind == .quarantined)
    }

    @Test("quarantine fallback selects the first validated surviving segment instead of an unvalidated corrupted one (Codex round-7 finding 6)")
    func quarantineFallbackSkipsAnUnvalidatedCorruptedFirstSegment() async throws {
        let fixture = try ReconciliationFixture()
        let id = UUID()
        let sessionDirectory = fixture.root.appendingPathComponent(id.uuidString, isDirectory: true)
        try fixture.fileSystem.createDirectory(sessionDirectory)
        _ = try await fixture.store.createCapture(.init(
            id: id, directory: sessionDirectory, capturedAt: Date(), sampleRate: 16_000,
            channelCount: 1, inputDeviceUID: nil, destination: "external"
        ))
        let codec = CaptureSegmentCodec(fileSystem: fixture.fileSystem)
        // Segment 0 is the CORRUPTED one — a malformed WAV header, deterministically undecodable,
        // not merely a hash mismatch. The old fallback (`segments.first?.url`, unvalidated) would
        // have picked this exact corrupted file as "recovered" audio, discarding the genuinely
        // healthy segment 1 entirely.
        let firstURL = sessionDirectory.appendingPathComponent("segment-00000000.wav")
        let firstData = Data("not a wav file".utf8)
        try firstData.write(to: firstURL)
        try await fixture.store.recordCommittedSegment(.init(
            captureID: id, ordinal: 0, url: firstURL, sampleCount: 0, contentHash: codec.hash(firstData)
        ))
        // Segment 1 is genuinely healthy and must be the one recovered instead.
        let secondURL = sessionDirectory.appendingPathComponent("segment-00000001.wav")
        let secondData = codec.encode([0.3, 0.4])
        try secondData.write(to: secondURL)
        try await fixture.store.recordCommittedSegment(.init(
            captureID: id, ordinal: 1, url: secondURL, sampleCount: 2, contentHash: codec.hash(secondData)
        ))

        let report = await fixture.reconciler().reconcile()

        #expect(report.failed == 0, Comment(rawValue: String(describing: report.failures)))
        #expect(try await fixture.store.session(id: id)?.state == .damaged)
        #expect(try await fixture.store.session(id: id)?.assetKind == .quarantined)
        let job = try #require(try await fixture.store.job(id: id))
        let recovered = try codec.decode(URL(fileURLWithPath: job.source.reference))
        #expect(recovered == [0.3, 0.4])
    }

    @Test("a permanently missing committed segment quarantines instead of retrying forever (Codex round-6 finding 2)")
    func missingCommittedSegmentFileQuarantinesInsteadOfRetryingForever() async throws {
        let fixture = try ReconciliationFixture()
        let id = UUID()
        let sessionDirectory = fixture.root.appendingPathComponent(id.uuidString, isDirectory: true)
        try fixture.fileSystem.createDirectory(sessionDirectory)
        _ = try await fixture.store.createCapture(.init(
            id: id, directory: sessionDirectory, capturedAt: Date(), sampleRate: 16_000,
            channelCount: 1, inputDeviceUID: nil, destination: "external"
        ))
        let codec = CaptureSegmentCodec(fileSystem: fixture.fileSystem)
        let firstURL = sessionDirectory.appendingPathComponent("segment-00000000.wav")
        let firstData = codec.encode([0.2, 0.1])
        try firstData.write(to: firstURL)
        try await fixture.store.recordCommittedSegment(.init(
            captureID: id, ordinal: 0, url: firstURL, sampleCount: 2, contentHash: codec.hash(firstData)
        ))
        let secondURL = sessionDirectory.appendingPathComponent("segment-00000001.wav")
        let secondData = codec.encode([0.3, 0.4])
        try secondData.write(to: secondURL)
        try await fixture.store.recordCommittedSegment(.init(
            captureID: id, ordinal: 1, url: secondURL, sampleCount: 2, contentHash: codec.hash(secondData)
        ))
        // The ledger still knows about this segment, but its file is gone — a permanent,
        // structural condition (ENOENT), not a transient I/O hiccup like the rename fault above.
        try FileManager.default.removeItem(at: secondURL)

        let report = await fixture.reconciler().reconcile()

        #expect(report.failed == 0, Comment(rawValue: String(describing: report.failures)))
        #expect(try await fixture.store.session(id: id)?.state == .damaged)
        #expect(try await fixture.store.session(id: id)?.assetKind == .quarantined)
    }

    @Test("a healthy committed segment survives quarantine when a later orphan is malformed (Codex round-8 finding 2)")
    func healthyCommittedSegmentSurvivesQuarantineWhenLaterOrphanIsMalformed() async throws {
        let fixture = try ReconciliationFixture()
        let id = UUID()
        let sessionDirectory = fixture.root.appendingPathComponent(id.uuidString, isDirectory: true)
        try fixture.fileSystem.createDirectory(sessionDirectory)
        _ = try await fixture.store.createCapture(.init(
            id: id, directory: sessionDirectory, capturedAt: Date(), sampleRate: 16_000,
            channelCount: 1, inputDeviceUID: nil, destination: "external"
        ))
        let codec = CaptureSegmentCodec(fileSystem: fixture.fileSystem)
        // Segment 0 is already ledger-committed AND healthy — this is the surviving audio the
        // fix must preserve.
        let firstURL = sessionDirectory.appendingPathComponent("segment-00000000.wav")
        let firstData = codec.encode([0.3, 0.4])
        try firstData.write(to: firstURL)
        try await fixture.store.recordCommittedSegment(.init(
            captureID: id, ordinal: 0, url: firstURL, sampleCount: 2, contentHash: codec.hash(firstData)
        ))
        // Segment 1 is a genuine orphan (never ledger-committed) with a malformed WAV header —
        // `reconcileSegmentInventory` throws before recording it, taking the malformed-orphan
        // catch. Before the fix, that catch passed `fallback: nil`, discarding segment 0 (already
        // proven healthy) and replacing it with a bare, non-recoverable failure marker.
        let secondURL = sessionDirectory.appendingPathComponent("segment-00000001.wav")
        try Data("not a wav file".utf8).write(to: secondURL)

        let report = await fixture.reconciler().reconcile()

        #expect(report.failed == 0, Comment(rawValue: String(describing: report.failures)))
        #expect(try await fixture.store.session(id: id)?.state == .damaged)
        #expect(try await fixture.store.session(id: id)?.assetKind == .quarantined)
        let job = try #require(try await fixture.store.job(id: id))
        let recovered = try codec.decode(URL(fileURLWithPath: job.source.reference))
        #expect(recovered == [0.3, 0.4])
    }

    @Test("a malformed orphan segment file during disk re-inventory quarantines instead of retrying forever (Codex round-6 finding 3)")
    func malformedOrphanSegmentQuarantinesInsteadOfRetryingForever() async throws {
        let fixture = try ReconciliationFixture()
        let id = UUID()
        let sessionDirectory = fixture.root.appendingPathComponent(id.uuidString, isDirectory: true)
        try fixture.fileSystem.createDirectory(sessionDirectory)
        _ = try await fixture.store.createCapture(.init(
            id: id, directory: sessionDirectory, capturedAt: Date(), sampleRate: 16_000,
            channelCount: 1, inputDeviceUID: nil, destination: "external"
        ))
        // A genuine orphan on disk (never ledger-committed — the round-5 finding-1 crash window)
        // but its WAV header is malformed: deterministic corruption evidence, unlike a gap or
        // transient I/O.
        let url = sessionDirectory.appendingPathComponent("segment-00000000.wav")
        try Data("not a wav file".utf8).write(to: url)

        let report = await fixture.reconciler().reconcile()

        #expect(report.failed == 0, Comment(rawValue: String(describing: report.failures)))
        #expect(try await fixture.store.session(id: id)?.state == .damaged)
        #expect(try await fixture.store.session(id: id)?.assetKind == .quarantined)
    }

    @Test("a malformed orphan segment is durably cleared before quarantine registers the fallback recovery (Codex round-9 finding 4)")
    func malformedOrphanIsClearedBeforeQuarantineRegistersFallback() async throws {
        let fixture = try ReconciliationFixture()
        let id = UUID()
        let sessionDirectory = fixture.root.appendingPathComponent(id.uuidString, isDirectory: true)
        try fixture.fileSystem.createDirectory(sessionDirectory)
        _ = try await fixture.store.createCapture(.init(
            id: id, directory: sessionDirectory, capturedAt: Date(), sampleRate: 16_000,
            channelCount: 1, inputDeviceUID: nil, destination: "external"
        ))
        let url = sessionDirectory.appendingPathComponent("segment-00000000.wav")
        try Data("not a wav file".utf8).write(to: url)

        let report = await fixture.reconciler().reconcile()

        #expect(report.failed == 0, Comment(rawValue: String(describing: report.failures)))
        #expect(try await fixture.store.session(id: id)?.state == .damaged)
        // Codex round-9 finding 4: this orphan was never ledger-committed, so no later cleanup's
        // committed-segment removal ever touches it — left in place, it permanently strands the
        // eventual Library-committed cleanup in `cleanupNotPermitted`. Must be durably cleared
        // HERE, before quarantine registers the fallback recovery.
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test("an EISDIR orphan directory is reclaimed when empty before quarantine registers the fallback recovery (Codex round-9 finding 4)")
    func emptyEISDIROrphanIsClearedBeforeQuarantineRegistersFallback() async throws {
        let fixture = try ReconciliationFixture()
        let id = UUID()
        let sessionDirectory = fixture.root.appendingPathComponent(id.uuidString, isDirectory: true)
        try fixture.fileSystem.createDirectory(sessionDirectory)
        _ = try await fixture.store.createCapture(.init(
            id: id, directory: sessionDirectory, capturedAt: Date(), sampleRate: 16_000,
            channelCount: 1, inputDeviceUID: nil, destination: "external"
        ))
        let orphan = sessionDirectory.appendingPathComponent("segment-00000000.wav")
        try fixture.fileSystem.createDirectory(orphan)
        let faultFileSystem = OrphanSegmentEISDIRFaultFileSystem(target: orphan)

        let report = await RecoveryReconciler(
            directory: fixture.root, store: fixture.store, ledger: fixture.store,
            fileSystem: faultFileSystem, libraryDictationID: { _ in nil }
        ).reconcile()

        #expect(report.failed == 0, Comment(rawValue: String(describing: report.failures)))
        #expect(try await fixture.store.session(id: id)?.state == .damaged)
        // Codex round-9 finding 4: an empty EISDIR orphan is safe to reclaim (a non-recursive
        // removal — there's nothing inside to lose) instead of permanently stranding the eventual
        // Library-committed cleanup in `cleanupNotPermitted`.
        #expect(!FileManager.default.fileExists(atPath: orphan.path))
    }

    @Test("a transient survivor-fetch failure after finding a malformed orphan must not leave the session `.capturing` with the corruption evidence already deleted (Codex round-10 blocker)")
    func malformedOrphanSurvivorFetchFailureDoesNotResurfaceTruncatedAudioAsHealthy() async throws {
        let fixture = try ReconciliationFixture()
        let id = UUID()
        let sessionDirectory = fixture.root.appendingPathComponent(id.uuidString, isDirectory: true)
        try fixture.fileSystem.createDirectory(sessionDirectory)
        _ = try await fixture.store.createCapture(.init(
            id: id, directory: sessionDirectory, capturedAt: Date(), sampleRate: 16_000,
            channelCount: 1, inputDeviceUID: nil, destination: "external"
        ))
        let codec = CaptureSegmentCodec(fileSystem: fixture.fileSystem)
        // A genuinely healthy, already ledger-committed first segment — this is the "clean
        // contiguous prefix" the round-10 blocker describes: a crash/corruption of the SECOND
        // segment must never let this first one alone be assembled and registered as though the
        // capture completed cleanly.
        let firstURL = sessionDirectory.appendingPathComponent("segment-00000000.wav")
        let firstData = codec.encode([0.5, 0.6])
        try firstData.write(to: firstURL)
        try await fixture.store.recordCommittedSegment(.init(
            captureID: id, ordinal: 0, url: firstURL, sampleCount: 2, contentHash: codec.hash(firstData)
        ))
        // A genuine, never-committed orphan (the round-5 finding-1 crash window) with a malformed
        // WAV header — the LAST segment on disk, so once it's cleared nothing distinguishes this
        // capture's directory from a genuinely complete one-segment recording.
        let orphanURL = sessionDirectory.appendingPathComponent("segment-00000001.wav")
        try Data("not a wav file".utf8).write(to: orphanURL)

        // Fails exactly the SECOND call to `committedSegments` across the pass: the first is
        // `reconcileSegmentInventory`'s own inventory read (must succeed so the malformed orphan is
        // actually discovered and the catch below is entered); the second is the quarantine catch's
        // survivor fetch — the exact injection point the blocker describes ("injected transient
        // ledger/validation failure after orphan removal point" in the pre-fix ordering, where the
        // orphan had already been deleted by the time this call failed).
        let faultyLedger = SurvivorsFetchFailingLedger(base: fixture.store)
        let reconciler = RecoveryReconciler(
            directory: fixture.root, store: fixture.store, ledger: faultyLedger,
            fileSystem: fixture.fileSystem, libraryDictationID: { _ in nil }
        )

        let first = await reconciler.reconcile()
        #expect(first.failed == 1, Comment(rawValue: String(describing: first.failures)))

        let second = await reconciler.reconcile()
        #expect(second.failed == 0, Comment(rawValue: String(describing: second.failures)))

        // The truncated one-segment audio must never be silently registered as a normal, healthy
        // recovery (`.staged`/`.processing`, `assetKind == .audio`) — it must be quarantined, with
        // the malformed second segment's corruption reflected in the job's failure message, not
        // discarded in favor of a plain "ready to retry" on the truncated prefix.
        let session = try await fixture.store.session(id: id)
        #expect(session?.state == .damaged)
        #expect(session?.assetKind == .quarantined)
        let job = try #require(try await fixture.store.job(id: id))
        #expect(job.state == .failed(
            JobFailure(stage: .preparing, message: "Damaged or unsupported recovery audio was quarantined")
        ))
    }

    @Test("a crash after the durable `.damaged` transition but before orphan removal is retried and cleared on the next pass, never wedging Library-committed cleanup (Codex round-11 blocker)")
    func damagedRetryClearsLeftoverOrphanBeforeLibraryCommittedCleanupSucceeds() async throws {
        let fixture = try ReconciliationFixture()
        let id = UUID()
        let sessionDirectory = fixture.root.appendingPathComponent(id.uuidString, isDirectory: true)
        try fixture.fileSystem.createDirectory(sessionDirectory)
        _ = try await fixture.store.createCapture(.init(
            id: id, directory: sessionDirectory, capturedAt: Date(), sampleRate: 16_000,
            channelCount: 1, inputDeviceUID: nil, destination: "external"
        ))
        let codec = CaptureSegmentCodec(fileSystem: fixture.fileSystem)
        // A genuinely healthy, already ledger-committed first segment — this becomes the
        // quarantine fallback, so the leftover orphan below is the SOLE thing keeping the
        // directory nonempty (a synthesized `capture-failure.marker` would confound the final
        // assertion with an unrelated, already-known residue shape).
        let firstURL = sessionDirectory.appendingPathComponent("segment-00000000.wav")
        let firstData = codec.encode([0.5, 0.6])
        try firstData.write(to: firstURL)
        try await fixture.store.recordCommittedSegment(.init(
            captureID: id, ordinal: 0, url: firstURL, sampleCount: 2, contentHash: codec.hash(firstData)
        ))
        // A genuine, never-committed orphan with a malformed WAV header triggers the
        // malformed-orphan quarantine catch.
        let orphanURL = sessionDirectory.appendingPathComponent("segment-00000001.wav")
        try Data("not a wav file".utf8).write(to: orphanURL)

        // Fails exactly the first `remove` of the orphan's own path — simulating a crash between
        // `transitionToDamaged`'s durable write (already landed) and the `clearOwnedOrphan` call
        // immediately after it, exactly the round-11 blocker's crash window. Every other removal
        // (including the orphan's own removal on the NEXT pass) succeeds normally.
        let faultFileSystem = OrphanRemovalCrashFileSystem(target: orphanURL)
        let reconciler = RecoveryReconciler(
            directory: fixture.root, store: fixture.store, ledger: fixture.store,
            fileSystem: faultFileSystem, libraryDictationID: { _ in nil }
        )

        let first = await reconciler.reconcile()
        // The durable `.damaged` transition landed before the injected failure, so this is a
        // reported/retried failure, not a session left `.capturing`.
        #expect(first.failed == 1, Comment(rawValue: String(describing: first.failures)))
        #expect(try await fixture.store.session(id: id)?.state == .damaged)
        #expect(FileManager.default.fileExists(atPath: orphanURL.path))

        let second = await reconciler.reconcile()
        #expect(second.failed == 0, Comment(rawValue: String(describing: second.failures)))
        // Codex round-11 blocker: the `.damaged` steady-state branch must retry orphan cleanup by
        // rescanning the session directory — the orphan was never durably recorded as pending, so
        // retry-by-rescan (not a new ledger column) is what recovers it here.
        #expect(!FileManager.default.fileExists(atPath: orphanURL.path))
        let session = try #require(try await fixture.store.session(id: id))
        #expect(session.state == .damaged)
        #expect(session.assetKind == .quarantined)

        // With the orphan cleared, Library-committed cleanup must succeed without ever hitting
        // `cleanupNotPermitted` — the leftover orphan (not a recognized residual-artifact shape)
        // was the one thing that would have wedged it forever.
        let libraryID: Int64 = 77
        try await fixture.store.transition(
            id: id, from: .damaged, to: .libraryCommitted,
            recoveryJobID: session.recoveryJobID, libraryDictationID: libraryID,
            assetKind: session.assetKind, failureMessage: session.failureMessage,
            contentHash: session.contentHash
        )
        let captureService = RecoveryCaptureService(
            directory: fixture.root, store: fixture.store, ledger: fixture.store,
            journalFileSystem: fixture.fileSystem, libraryDictationID: { _ in libraryID }
        )
        try await captureService.resumeLibraryCommittedCapture(captureID: id)

        #expect(try await fixture.store.session(id: id) == nil)
        #expect(!FileManager.default.fileExists(atPath: sessionDirectory.path))
    }

    @Test("a valid unledgered segment discovered while the session is already `.damaged` is adopted into the ledger instead of deleted, and its audio survives to the registered fallback recovery (Codex round-12 blocker)")
    func damagedStateAdoptsValidUnledgeredSegmentInsteadOfDeletingIt() async throws {
        let fixture = try ReconciliationFixture()
        let id = UUID()
        let sessionDirectory = fixture.root.appendingPathComponent(id.uuidString, isDirectory: true)
        try fixture.fileSystem.createDirectory(sessionDirectory)
        _ = try await fixture.store.createCapture(.init(
            id: id, directory: sessionDirectory, capturedAt: Date(), sampleRate: 16_000,
            channelCount: 1, inputDeviceUID: nil, destination: "external"
        ))
        let codec = CaptureSegmentCodec(fileSystem: fixture.fileSystem)
        // A durably-renamed, fully valid segment whose matching `ledger.recordCommittedSegment`
        // call never landed — exactly the race `CaptureJournalWriter.commit` can leave behind:
        // it renames the segment file into place BEFORE the ledger insert (`CaptureJournalWriter
        // .swift:371-378`), so a failure in that insert propagates and `CaptureJournalService
        // .preserveFailure` then transitions the session straight to `.damaged`, regardless of
        // the segment's validity.
        let segmentURL = sessionDirectory.appendingPathComponent("segment-00000000.wav")
        let segmentData = codec.encode([0.25, 0.5, 0.75])
        try segmentData.write(to: segmentURL)
        let segmentHash = codec.hash(segmentData)

        // Simulates `preserveFailure` landing mid-race: the session is durably `.damaged` with
        // the valid segment above never ledger-committed.
        try await fixture.store.transition(
            id: id, from: .capturing, to: .damaged,
            recoveryJobID: id, libraryDictationID: nil,
            assetKind: .quarantined, failureMessage: "simulated ledger-insert race", contentHash: nil
        )

        let report = await fixture.reconciler().reconcile()
        #expect(report.failed == 0, Comment(rawValue: String(describing: report.failures)))

        // The valid segment must survive on disk — never silently deleted as "abandoned".
        #expect(FileManager.default.fileExists(atPath: segmentURL.path))
        // It must become a ledger-committed segment (adopted), visible to survivor selection and
        // owned by normal cleanup, not permanently unrecognized disk residue.
        let committed = try await fixture.store.committedSegments(captureID: id)
        #expect(committed.count == 1)
        #expect(committed.first?.ordinal == 0)
        #expect(committed.first?.contentHash == segmentHash)

        // Its audio must have reached the registered fallback recovery, not a synthesized
        // "capture journal is damaged" failure marker.
        let job = try #require(try await fixture.store.job(id: id))
        let owned = sessionDirectory.appendingPathComponent("\(id.uuidString).wav")
        #expect(FileManager.default.fileExists(atPath: owned.path))
        #expect(try codec.hashFile(owned) == segmentHash)
        #expect(job.source.reference == owned.path)

        // Library-committed cleanup afterward must succeed without ever hitting
        // `cleanupNotPermitted` — the adopted segment is now in the ledger's committed-segment
        // set that `cleanupLibraryCommittedSession` removes as part of normal cleanup.
        let libraryID: Int64 = 91
        let session = try #require(try await fixture.store.session(id: id))
        try await fixture.store.transition(
            id: id, from: .damaged, to: .libraryCommitted,
            recoveryJobID: session.recoveryJobID, libraryDictationID: libraryID,
            assetKind: session.assetKind, failureMessage: session.failureMessage,
            contentHash: session.contentHash
        )
        let captureService = RecoveryCaptureService(
            directory: fixture.root, store: fixture.store, ledger: fixture.store,
            journalFileSystem: fixture.fileSystem, libraryDictationID: { _ in libraryID }
        )
        try await captureService.resumeLibraryCommittedCapture(captureID: id)

        #expect(try await fixture.store.session(id: id) == nil)
        #expect(!FileManager.default.fileExists(atPath: sessionDirectory.path))
    }

    @Test("a `.damaged` steady-state rescan never touches a segment-shaped name whose extension isn't `.wav` — `CaptureSegmentCodec.ordinal(from:)` matching alone is not proof it's an owned segment file (Codex round-12 blocker)")
    func damagedStateIgnoresNonWAVSegmentShapedName() async throws {
        let fixture = try ReconciliationFixture()
        let id = UUID()
        let sessionDirectory = fixture.root.appendingPathComponent(id.uuidString, isDirectory: true)
        try fixture.fileSystem.createDirectory(sessionDirectory)
        _ = try await fixture.store.createCapture(.init(
            id: id, directory: sessionDirectory, capturedAt: Date(), sampleRate: 16_000,
            channelCount: 1, inputDeviceUID: nil, destination: "external"
        ))
        // `CaptureSegmentCodec.ordinal(from:)` strips the path extension before checking the
        // "segment-" prefix, so a non-WAV file with this exact stem still parses as ordinal 0 —
        // it must not be treated as an owned segment artifact on that basis alone.
        let strayFile = sessionDirectory.appendingPathComponent("segment-00000000.txt")
        try Data("not owned segment content".utf8).write(to: strayFile)
        #expect(CaptureSegmentCodec.ordinal(from: strayFile) == 0)

        try await fixture.store.transition(
            id: id, from: .capturing, to: .damaged,
            recoveryJobID: id, libraryDictationID: nil,
            assetKind: .quarantined, failureMessage: "simulated damage", contentHash: nil
        )

        _ = await fixture.reconciler().reconcile()

        // Untouched by the rescan: neither deleted nor adopted into the ledger.
        #expect(FileManager.default.fileExists(atPath: strayFile.path))
        #expect(try await fixture.store.committedSegments(captureID: id).isEmpty)
    }

    @Test("a `.damaged` steady-state fallback selection skips a segment-shaped non-WAV stray file and never lets it stand in for the adopted WAV — `quarantineJournal` copies the selected fallback's raw bytes into `<captureID>.wav` with no WAV validation, so picking the wrong candidate silently persists the wrong audio (Codex round-13 blocker)")
    func damagedStateFallbackSkipsNonWAVStrayFileForAdoptedWAV() async throws {
        let fixture = try ReconciliationFixture()
        let id = UUID()
        let sessionDirectory = fixture.root.appendingPathComponent(id.uuidString, isDirectory: true)
        try fixture.fileSystem.createDirectory(sessionDirectory)
        _ = try await fixture.store.createCapture(.init(
            id: id, directory: sessionDirectory, capturedAt: Date(), sampleRate: 16_000,
            channelCount: 1, inputDeviceUID: nil, destination: "external"
        ))
        let codec = CaptureSegmentCodec(fileSystem: fixture.fileSystem)
        // The genuinely adopted, valid audio: never ledger-committed yet (mirrors the round-12
        // ledger-insert race), so `clearUnledgeredOrphanSegments` adopts it into the ledger on this
        // pass but leaves the file on disk exactly where the buggy fallback scan could still find it.
        let wavURL = sessionDirectory.appendingPathComponent("segment-00000000.wav")
        let wavData = codec.encode([0.11, 0.22, 0.33])
        try wavData.write(to: wavURL)
        let wavHash = codec.hash(wavData)

        // A stray segment-shaped name with a non-WAV extension. `CaptureSegmentCodec.ordinal(from:)`
        // strips the extension before matching the "segment-" prefix, so this parses as ordinal 0
        // too — indistinguishable from the real WAV by ordinal alone, and without the
        // `pathExtension == "wav"` guard on the fallback predicate it could win `first(where:)`.
        let strayFile = sessionDirectory.appendingPathComponent("segment-00000000.txt")
        try Data("not owned segment content".utf8).write(to: strayFile)
        #expect(CaptureSegmentCodec.ordinal(from: strayFile) == 0)

        try await fixture.store.transition(
            id: id, from: .capturing, to: .damaged,
            recoveryJobID: id, libraryDictationID: nil,
            assetKind: .quarantined, failureMessage: "simulated damage", contentHash: nil
        )

        // `FileManager.contentsOfDirectory` gives no directory-ordering guarantee, so this wrapper
        // forces the adversarial order deterministically: "segment-00000000.txt" is returned before
        // "segment-00000000.wav" (matching how the two names already sort alphabetically — `t` <
        // `w` — so directory ordering alone could reproduce this without the wrapper on most
        // filesystems; the wrapper just removes that dependency and makes the failure
        // deterministic). Manually confirmed this test fails (wrong bytes copied to `<id>.wav`)
        // against the unfixed predicate — see Codex round-13 disposition notes.
        let orderedFileSystem = SortedContentsFileSystem(base: fixture.fileSystem)
        let report = await RecoveryReconciler(
            directory: fixture.root, store: fixture.store, ledger: fixture.store,
            fileSystem: orderedFileSystem, libraryDictationID: { _ in nil }
        ).reconcile()

        #expect(report.failed == 0, Comment(rawValue: String(describing: report.failures)))

        // The registered recovery job's source bytes must be the real WAV's bytes (by hash), never
        // the stray text file's — a bare metadata/state check alone would not catch the wrong file
        // being copied.
        let job = try #require(try await fixture.store.job(id: id))
        let owned = sessionDirectory.appendingPathComponent("\(id.uuidString).wav")
        #expect(FileManager.default.fileExists(atPath: owned.path))
        #expect(try codec.hashFile(owned) == wavHash)
        #expect(job.source.reference == owned.path)

        // The real audio must survive on disk: never deleted while quarantining the wrong candidate.
        #expect(FileManager.default.fileExists(atPath: wavURL.path))
    }

    @Test("`.damaged` steady-state orphan adoption hashes and decodes a candidate segment from the SAME byte snapshot — a concurrent replacement between two separate reads must never persist a mismatched hash/sample-count pair (Codex round-13 minor)")
    func damagedStateOrphanAdoptionHashAndDecodeShareOneReadSnapshot() async throws {
        let fixture = try ReconciliationFixture()
        let id = UUID()
        let sessionDirectory = fixture.root.appendingPathComponent(id.uuidString, isDirectory: true)
        try fixture.fileSystem.createDirectory(sessionDirectory)
        _ = try await fixture.store.createCapture(.init(
            id: id, directory: sessionDirectory, capturedAt: Date(), sampleRate: 16_000,
            channelCount: 1, inputDeviceUID: nil, destination: "external"
        ))
        let codec = CaptureSegmentCodec(fileSystem: fixture.fileSystem)
        let segmentURL = sessionDirectory.appendingPathComponent("segment-00000000.wav")
        // The byte snapshot the FIRST read of this candidate must observe.
        let firstSnapshot = codec.encode([0.1, 0.2])
        try firstSnapshot.write(to: segmentURL)
        // A DIFFERENT, also-valid snapshot a SECOND, separate read of the same URL would observe
        // if the file were concurrently replaced between a hash read and a later decode re-read —
        // deliberately a different sample count (4 vs 2) so a mismatched pairing is unambiguous.
        let racingSnapshot = codec.encode([0.9, 0.8, 0.7, 0.6])

        try await fixture.store.transition(
            id: id, from: .capturing, to: .damaged,
            recoveryJobID: id, libraryDictationID: nil,
            assetKind: .quarantined, failureMessage: "simulated damage", contentHash: nil
        )

        // Returns `firstSnapshot` on the first read of `segmentURL` and `racingSnapshot` on every
        // read after that. If the orphan-adoption code under test still read the candidate twice
        // (once for hashing, once inside a separate decode call), the second of those two reads
        // would land on this wrapper's second call and observe `racingSnapshot` instead — exactly
        // reproducing the race. Later, unrelated reads of the same file elsewhere in the
        // reconciliation pipeline (e.g. `LegacyRecoveryImporter.importAudio`'s own single read of
        // the quarantine fallback) also observe `racingSnapshot`, which is expected and irrelevant
        // to this test — only the segment record `clearUnledgeredOrphanSegments` produces is
        // asserted below.
        let racingFileSystem = RaceOnReadFileSystem(
            base: fixture.fileSystem, target: segmentURL,
            firstRead: firstSnapshot, subsequentReads: racingSnapshot
        )
        let report = await RecoveryReconciler(
            directory: fixture.root, store: fixture.store, ledger: fixture.store,
            fileSystem: racingFileSystem, libraryDictationID: { _ in nil }
        ).reconcile()

        #expect(report.failed == 0, Comment(rawValue: String(describing: report.failures)))

        let committed = try await fixture.store.committedSegments(captureID: id)
        #expect(committed.count == 1)
        // Hash and sample count must both derive from the SAME (first) snapshot — never a hash
        // computed from one read paired with a sample count decoded from a different, later read.
        #expect(committed.first?.contentHash == codec.hash(firstSnapshot))
        #expect(committed.first?.sampleCount == 2)
    }

    @Test("`.damaged` steady-state orphan adoption re-verifies identity before deleting a decode-rejected candidate — a concurrent replacement between the failed read and the delete must leave the (possibly healthy) replacement on disk (Codex round-14)")
    func damagedStateOrphanAdoptionSkipsDeletionWhenCandidateChangesAfterFailedDecode() async throws {
        let fixture = try ReconciliationFixture()
        let id = UUID()
        let sessionDirectory = fixture.root.appendingPathComponent(id.uuidString, isDirectory: true)
        try fixture.fileSystem.createDirectory(sessionDirectory)
        _ = try await fixture.store.createCapture(.init(
            id: id, directory: sessionDirectory, capturedAt: Date(), sampleRate: 16_000,
            channelCount: 1, inputDeviceUID: nil, destination: "external"
        ))
        let codec = CaptureSegmentCodec(fileSystem: fixture.fileSystem)
        let segmentURL = sessionDirectory.appendingPathComponent("segment-00000000.wav")
        // The byte snapshot the FIRST read observes — malformed, so `codec.decode` throws and
        // the malformed-orphan catch runs.
        let malformedSnapshot = Data("not a wav file".utf8)
        try malformedSnapshot.write(to: segmentURL)
        // A DIFFERENT, valid snapshot every read AFTER the first observes — simulating the file
        // being atomically replaced with healthy bytes between the failed decode read and the
        // re-verification read the round-14 fix performs immediately before deleting.
        let replacementSnapshot = codec.encode([0.9, 0.8, 0.7, 0.6])

        try await fixture.store.transition(
            id: id, from: .capturing, to: .damaged,
            recoveryJobID: id, libraryDictationID: nil,
            assetKind: .quarantined, failureMessage: "simulated damage", contentHash: nil
        )

        let racingFileSystem = RaceOnReadFileSystem(
            base: fixture.fileSystem, target: segmentURL,
            firstRead: malformedSnapshot, subsequentReads: replacementSnapshot
        )
        let report = await RecoveryReconciler(
            directory: fixture.root, store: fixture.store, ledger: fixture.store,
            fileSystem: racingFileSystem, libraryDictationID: { _ in nil }
        ).reconcile()

        #expect(report.failed == 0, Comment(rawValue: String(describing: report.failures)))

        // Never adopted — the first (only) read was the malformed snapshot, so decode legitimately
        // failed and the candidate is not durably owned via the ledger.
        let committed = try await fixture.store.committedSegments(captureID: id)
        #expect(committed.isEmpty)
        // Never deleted — the re-verification read observed bytes that no longer match the
        // rejected snapshot's hash, so the (possibly healthy) replacement must survive on disk
        // for the next reconciliation pass to re-evaluate from scratch.
        #expect(FileManager.default.fileExists(atPath: segmentURL.path))
    }

    @Test("a malformed-orphan quarantine still hydrates the durable stop-time snapshot before registering the fallback recovery (Codex round-9 finding 1)")
    func malformedOrphanQuarantineHydratesVoiceCommandSnapshot() async throws {
        let fixture = try ReconciliationFixture()
        let id = UUID()
        let sessionDirectory = fixture.root.appendingPathComponent(id.uuidString, isDirectory: true)
        try fixture.fileSystem.createDirectory(sessionDirectory)
        _ = try await fixture.store.createCapture(.init(
            id: id, directory: sessionDirectory, capturedAt: Date(), sampleRate: 16_000,
            channelCount: 1, inputDeviceUID: nil, destination: "external"
        ))
        // Durable stop-time intent marker present (Stop wrote it) with the session's snapshot
        // columns still NULL (the ledger write itself failed), alongside a genuine malformed
        // orphan that forces the quarantine catch.
        try DurableArtifactWriter(fileSystem: fixture.fileSystem).commit(
            try JSONEncoder().encode(VoiceCommandFinalizationIntent(
                enabled: true, keywords: ["command", "comando"]
            )),
            temporary: sessionDirectory.appendingPathComponent(".intent.tmp"),
            destination: VoiceCommandFinalizationIntent.markerURL(in: sessionDirectory)
        )
        let orphan = sessionDirectory.appendingPathComponent("segment-00000000.wav")
        try Data("not a wav file".utf8).write(to: orphan)

        let report = await fixture.reconciler().reconcile()

        #expect(report.failed == 0, Comment(rawValue: String(describing: report.failures)))
        #expect(try await fixture.store.session(id: id)?.state == .damaged)
        // Codex round-9 finding 1: the malformed-orphan/EISDIR quarantine paths previously
        // returned before hydration ever ran, so the ledger snapshot columns stayed NULL and the
        // quarantine job below inherited nil/nil instead of the marker's exact stop-time policy.
        #expect(try await fixture.store.session(id: id)?.voiceCommandsEnabled == true)
        #expect(try await fixture.store.session(id: id)?.commandKeywords == ["command", "comando"])
        let job = try #require(try await fixture.store.job(id: id))
        #expect(job.voiceCommandsEnabled == true)
        #expect(job.commandKeywords == ["command", "comando"])
    }

    @Test("quarantine fallback skips a hash-mismatched surviving segment instead of trusting WAV syntax alone (Codex round-9 finding 2)")
    func quarantineFallbackSkipsHashMismatchedSurvivor() async throws {
        let fixture = try ReconciliationFixture()
        let id = UUID()
        let sessionDirectory = fixture.root.appendingPathComponent(id.uuidString, isDirectory: true)
        try fixture.fileSystem.createDirectory(sessionDirectory)
        _ = try await fixture.store.createCapture(.init(
            id: id, directory: sessionDirectory, capturedAt: Date(), sampleRate: 16_000,
            channelCount: 1, inputDeviceUID: nil, destination: "external"
        ))
        let codec = CaptureSegmentCodec(fileSystem: fixture.fileSystem)
        // Segment 0 is structurally a perfectly valid WAV file — a bare WAV-syntax decode alone
        // would happily accept it — but its persisted ledger hash doesn't match its actual bytes
        // (e.g. a partial overwrite that still parses as valid WAV). That mismatch is real,
        // deterministic corruption evidence a syntax-only check ignores.
        let firstURL = sessionDirectory.appendingPathComponent("segment-00000000.wav")
        let firstData = codec.encode([0.9, 0.9])
        try firstData.write(to: firstURL)
        try await fixture.store.recordCommittedSegment(.init(
            captureID: id, ordinal: 0, url: firstURL, sampleCount: 2, contentHash: "stale-hash"
        ))
        // Segment 1 is genuinely healthy and must be the one recovered instead.
        let secondURL = sessionDirectory.appendingPathComponent("segment-00000001.wav")
        let secondData = codec.encode([0.3, 0.4])
        try secondData.write(to: secondURL)
        try await fixture.store.recordCommittedSegment(.init(
            captureID: id, ordinal: 1, url: secondURL, sampleCount: 2, contentHash: codec.hash(secondData)
        ))
        // Ordinal 2 is a genuine orphan (never ledger-committed) with a malformed WAV header —
        // takes the malformed-orphan catch, whose fallback scan is exactly what's under test.
        let thirdURL = sessionDirectory.appendingPathComponent("segment-00000002.wav")
        try Data("not a wav file".utf8).write(to: thirdURL)

        let report = await fixture.reconciler().reconcile()

        #expect(report.failed == 0, Comment(rawValue: String(describing: report.failures)))
        #expect(try await fixture.store.session(id: id)?.state == .damaged)
        #expect(try await fixture.store.session(id: id)?.assetKind == .quarantined)
        let job = try #require(try await fixture.store.job(id: id))
        let recovered = try codec.decode(URL(fileURLWithPath: job.source.reference))
        #expect(recovered == [0.3, 0.4])
    }

    @Test("a transient read failure while validating a surviving segment reports and retries instead of discarding it permanently (Codex round-9 finding 2)")
    func survivorValidationTransientFailureReportsInsteadOfDiscarding() async throws {
        let fixture = try ReconciliationFixture()
        let id = UUID()
        let sessionDirectory = fixture.root.appendingPathComponent(id.uuidString, isDirectory: true)
        try fixture.fileSystem.createDirectory(sessionDirectory)
        _ = try await fixture.store.createCapture(.init(
            id: id, directory: sessionDirectory, capturedAt: Date(), sampleRate: 16_000,
            channelCount: 1, inputDeviceUID: nil, destination: "external"
        ))
        let codec = CaptureSegmentCodec(fileSystem: fixture.fileSystem)
        let firstURL = sessionDirectory.appendingPathComponent("segment-00000000.wav")
        let firstData = codec.encode([0.5, 0.6])
        try firstData.write(to: firstURL)
        try await fixture.store.recordCommittedSegment(.init(
            captureID: id, ordinal: 0, url: firstURL, sampleCount: 2, contentHash: codec.hash(firstData)
        ))
        // A genuine orphan (never ledger-committed) with a malformed WAV header takes the
        // malformed-orphan catch, whose fallback scan re-reads segment 0 to validate it.
        let secondURL = sessionDirectory.appendingPathComponent("segment-00000001.wav")
        try Data("not a wav file".utf8).write(to: secondURL)

        let faultFileSystem = SurvivorValidationReadFaultFileSystem(target: firstURL)
        let report = await RecoveryReconciler(
            directory: fixture.root, store: fixture.store, ledger: fixture.store,
            fileSystem: faultFileSystem, libraryDictationID: { _ in nil }
        ).reconcile()

        // A transient read failure while validating segment 0 (still sitting healthy on disk)
        // must be reported for retry — not silently read as "no surviving segment" and converted
        // into a bare, non-recoverable failure marker.
        #expect(report.failed == 1)
        #expect(try await fixture.store.session(id: id)?.state == .capturing)
        #expect(FileManager.default.fileExists(atPath: firstURL.path))
    }

    @Test("a crash between writing and renaming a nested-session import temporary is recognized as residue instead of wedging Library cleanup forever (Codex round-9 finding 3)")
    func nestedSessionImportTemporaryIsRecognizedResidue() async throws {
        let fixture = try ReconciliationFixture()
        let id = UUID()
        let sessionDirectory = fixture.root.appendingPathComponent(id.uuidString, isDirectory: true)
        try fixture.fileSystem.createDirectory(sessionDirectory)
        _ = try await fixture.store.createCapture(.init(
            id: id, directory: sessionDirectory, capturedAt: Date(), sampleRate: 16_000,
            channelCount: 1, inputDeviceUID: nil, destination: "external"
        ))
        let codec = CaptureSegmentCodec(fileSystem: fixture.fileSystem)
        // A genuinely healthy committed segment — the quarantine fallback that
        // `LegacyRecoveryImporter` copies into the owned `<captureID>.wav` path, INSIDE this same
        // nested session directory (Codex round-9 finding 3: contrary to the round-8 exclusion's
        // claim, the importer's `.<id>.<uuid>.import.tmp` temporary DOES land here whenever
        // `owned` differs from `source`).
        let segmentURL = sessionDirectory.appendingPathComponent("segment-00000000.wav")
        let segmentData = codec.encode([0.2, 0.3])
        try segmentData.write(to: segmentURL)
        try await fixture.store.recordCommittedSegment(.init(
            captureID: id, ordinal: 0, url: segmentURL, sampleCount: 2, contentHash: codec.hash(segmentData)
        ))
        // A genuine, never-committed malformed orphan triggers the malformed-orphan quarantine
        // catch.
        let orphanURL = sessionDirectory.appendingPathComponent("segment-00000001.wav")
        try Data("not a wav file".utf8).write(to: orphanURL)

        // Simulates a crash between the import temporary's durable write and its rename into the
        // owned `<captureID>.wav` path — the first attempt's temporary is abandoned; the retrier's
        // second attempt (a fresh UUID) succeeds.
        let faultFileSystem = ImportTemporaryRenameFaultFileSystem()
        let report = await RecoveryReconciler(
            directory: fixture.root, store: fixture.store, ledger: fixture.store,
            fileSystem: faultFileSystem, libraryDictationID: { _ in nil }, retrySleep: { _ in }
        ).reconcile()

        #expect(report.failed == 0, Comment(rawValue: String(describing: report.failures)))
        #expect(try await fixture.store.session(id: id)?.state == .damaged)
        let residue = try fixture.fileSystem.contents(sessionDirectory).filter {
            $0.lastPathComponent.hasSuffix(".import.tmp")
        }
        #expect(residue.count == 1)

        // The abandoned import temporary must not permanently block the eventual Library-
        // committed cleanup of this directory.
        try await fixture.store.transition(
            id: id, from: .damaged, to: .libraryCommitted,
            recoveryJobID: id, libraryDictationID: 55, assetKind: .quarantined,
            failureMessage: nil, contentHash: nil
        )
        let service = RecoveryCaptureService(
            directory: fixture.root, store: fixture.store, ledger: fixture.store,
            journalFileSystem: fixture.fileSystem, libraryDictationID: { _ in 55 }
        )
        try await service.resumeLibraryCommittedCapture(captureID: id)

        #expect(try await fixture.store.session(id: id) == nil)
        #expect(!FileManager.default.fileExists(atPath: sessionDirectory.path))
    }

    @Test("an EISDIR read failure on a newly discovered orphan segment quarantines instead of retrying forever (Codex round-7 finding 7)")
    func orphanSegmentEISDIRQuarantinesInsteadOfRetryingForever() async throws {
        let fixture = try ReconciliationFixture()
        let id = UUID()
        let sessionDirectory = fixture.root.appendingPathComponent(id.uuidString, isDirectory: true)
        try fixture.fileSystem.createDirectory(sessionDirectory)
        _ = try await fixture.store.createCapture(.init(
            id: id, directory: sessionDirectory, capturedAt: Date(), sampleRate: 16_000,
            channelCount: 1, inputDeviceUID: nil, destination: "external"
        ))
        // A genuine orphan on disk (never ledger-committed) whose entry is a directory sitting
        // where a `segment-*.wav` file should be — deterministic corruption evidence, exactly as
        // conclusive as a malformed WAV header, unlike the ENOENT enumeration/read race this must
        // stay distinct from.
        let orphan = sessionDirectory.appendingPathComponent("segment-00000000.wav")
        try fixture.fileSystem.createDirectory(orphan)
        let faultFileSystem = OrphanSegmentEISDIRFaultFileSystem(target: orphan)

        let report = await RecoveryReconciler(
            directory: fixture.root, store: fixture.store, ledger: fixture.store,
            fileSystem: faultFileSystem, libraryDictationID: { _ in nil }
        ).reconcile()

        #expect(report.failed == 0, Comment(rawValue: String(describing: report.failures)))
        #expect(try await fixture.store.session(id: id)?.state == .damaged)
        #expect(try await fixture.store.session(id: id)?.assetKind == .quarantined)
    }

    @Test("orphan canonical-audio reconstruction hydrates the durable intent marker instead of recreating the job with a NULL snapshot (Codex round-3 finding 2)")
    func orphanCanonicalReconstructionHydratesVoiceCommandIntent() async throws {
        let fixture = try ReconciliationFixture()
        let id = UUID()
        let sessionDirectory = fixture.root.appendingPathComponent(id.uuidString, isDirectory: true)
        try fixture.fileSystem.createDirectory(sessionDirectory)
        let canonical = sessionDirectory.appendingPathComponent("\(id.uuidString).wav")
        let codec = CaptureSegmentCodec(fileSystem: fixture.fileSystem)
        try codec.encode(Array(repeating: 0.2, count: 1_600)).write(to: canonical)
        // No ledger session exists at all — a genuine orphan directory (e.g. its ledger row is
        // long gone) with the exact stop-time intent still durable on disk.
        try DurableArtifactWriter(fileSystem: fixture.fileSystem).commit(
            try JSONEncoder().encode(VoiceCommandFinalizationIntent(
                enabled: true, keywords: ["command", "comando"]
            )),
            temporary: sessionDirectory.appendingPathComponent(".intent.tmp"),
            destination: VoiceCommandFinalizationIntent.markerURL(in: sessionDirectory)
        )

        let report = await fixture.reconciler().reconcile()

        #expect(report.failed == 0, Comment(rawValue: String(describing: report.failures)))
        #expect(report.imported == 1)
        let job = try #require(try await fixture.store.job(id: id))
        #expect(job.voiceCommandsEnabled == true)
        #expect(job.commandKeywords == ["command", "comando"])
    }

    @Test("orphan committed-segment reconstruction hydrates the durable intent marker instead of recreating the job with a NULL snapshot (Codex round-3 finding 2)")
    func orphanSegmentReconstructionHydratesVoiceCommandIntent() async throws {
        let fixture = try ReconciliationFixture()
        let id = UUID()
        let sessionDirectory = fixture.root.appendingPathComponent(id.uuidString, isDirectory: true)
        try fixture.fileSystem.createDirectory(sessionDirectory)
        let codec = CaptureSegmentCodec(fileSystem: fixture.fileSystem)
        for (ordinal, samples) in [[Float(0.2), 0.1], [0.3]].enumerated() {
            let url = sessionDirectory.appendingPathComponent(String(format: "segment-%08d.wav", ordinal))
            try codec.encode(samples).write(to: url)
        }
        // No ledger session and no committed-segment ledger rows either — segment files alone
        // survived (e.g. a restored recovery directory without its database), together with the
        // durable stop-time intent marker.
        try DurableArtifactWriter(fileSystem: fixture.fileSystem).commit(
            try JSONEncoder().encode(VoiceCommandFinalizationIntent(
                enabled: true, keywords: ["command", "comando"]
            )),
            temporary: sessionDirectory.appendingPathComponent(".intent.tmp"),
            destination: VoiceCommandFinalizationIntent.markerURL(in: sessionDirectory)
        )

        let report = await fixture.reconciler().reconcile()

        #expect(report.failed == 0, Comment(rawValue: String(describing: report.failures)))
        #expect(report.imported == 1)
        let job = try #require(try await fixture.store.job(id: id))
        #expect(job.voiceCommandsEnabled == true)
        #expect(job.commandKeywords == ["command", "comando"])
        #expect(FileManager.default.fileExists(
            atPath: sessionDirectory.appendingPathComponent("\(id.uuidString).wav").path
        ))
    }

    @Test("orphan committed-segment reconstruction recovers the full segment inventory after a one-time hydration failure (Codex round-4 finding 2)")
    func orphanSegmentReconstructionRecoversAfterOneTimeHydrationFailure() async throws {
        let fixture = try ReconciliationFixture()
        let id = UUID()
        let sessionDirectory = fixture.root.appendingPathComponent(id.uuidString, isDirectory: true)
        try fixture.fileSystem.createDirectory(sessionDirectory)
        let codec = CaptureSegmentCodec(fileSystem: fixture.fileSystem)
        var segmentURLs: [URL] = []
        for (ordinal, samples) in [[Float(0.2), 0.1], [0.3]].enumerated() {
            let url = sessionDirectory.appendingPathComponent(String(format: "segment-%08d.wav", ordinal))
            try codec.encode(samples).write(to: url)
            segmentURLs.append(url)
        }
        // No ledger session and no committed-segment ledger rows yet — a genuine orphan directory,
        // with the durable stop-time intent marker present so reconciliation attempts hydration.
        try DurableArtifactWriter(fileSystem: fixture.fileSystem).commit(
            try JSONEncoder().encode(VoiceCommandFinalizationIntent(
                enabled: true, keywords: ["command", "comando"]
            )),
            temporary: sessionDirectory.appendingPathComponent(".intent.tmp"),
            destination: VoiceCommandFinalizationIntent.markerURL(in: sessionDirectory)
        )

        // Hydration fails once, AFTER capture ownership is created — reconciliation must have
        // already recorded every segment's metadata in the ledger before attempting hydration
        // (Codex round-4 finding 2), so the still-present segment files are resumable on the next
        // pass instead of being seen as "an owned session with zero committed segments" and
        // quarantined as no-audio.
        let faultyLedger = SnapshotFailingLedger(base: fixture.store)
        let firstReport = await RecoveryReconciler(
            directory: fixture.root, store: fixture.store, ledger: faultyLedger,
            fileSystem: fixture.fileSystem, libraryDictationID: { _ in nil }
        ).reconcile()

        #expect(firstReport.failed == 1)
        #expect(firstReport.quarantined == 0)
        #expect(firstReport.imported == 0)
        #expect(try await fixture.store.session(id: id)?.state == .capturing)
        #expect(try await fixture.store.committedSegments(captureID: id).count == 2)
        for url in segmentURLs {
            #expect(FileManager.default.fileExists(atPath: url.path))
        }

        let reopened = try fixture.reopen()
        let secondReport = await reopened.reconciler().reconcile()

        #expect(secondReport.failed == 0, Comment(rawValue: String(describing: secondReport.failures)))
        #expect(try await reopened.store.session(id: id)?.state == .processing)
        let job = try #require(try await reopened.store.job(id: id))
        #expect(job.voiceCommandsEnabled == true)
        #expect(job.commandKeywords == ["command", "comando"])
        #expect(FileManager.default.fileExists(
            atPath: sessionDirectory.appendingPathComponent("\(id.uuidString).wav").path
        ))
    }

    @Test("a one-time metadata-transition failure after successful assembly preserves all segments and recovers fully on the next pass (Codex round-4 finding 3)")
    func transitionFailureAfterAssemblyDoesNotQuarantineHealthySegments() async throws {
        let fixture = try ReconciliationFixture()
        let id = UUID()
        let sessionDirectory = fixture.root.appendingPathComponent(id.uuidString, isDirectory: true)
        try fixture.fileSystem.createDirectory(sessionDirectory)
        _ = try await fixture.store.createCapture(.init(
            id: id, directory: sessionDirectory, capturedAt: Date(), sampleRate: 16_000,
            channelCount: 1, inputDeviceUID: nil, destination: "external"
        ))
        let codec = CaptureSegmentCodec(fileSystem: fixture.fileSystem)
        var segmentURLs: [URL] = []
        for (ordinal, samples) in [[Float(0.2), 0.1], [0.3, 0.4]].enumerated() {
            let url = sessionDirectory.appendingPathComponent(String(format: "segment-%08d.wav", ordinal))
            let data = codec.encode(samples)
            try data.write(to: url)
            try await fixture.store.recordCommittedSegment(.init(
                captureID: id, ordinal: ordinal, url: url, sampleCount: samples.count,
                contentHash: codec.hash(data)
            ))
            segmentURLs.append(url)
        }

        // The transition from `.capturing` to `.staged` fails once, AFTER assembly of the two
        // committed segments has already succeeded — proving the audio is healthy. This must be
        // reported for retry (Codex round-4 finding 3), not folded into "segments are damaged" and
        // quarantined down to a single, non-retryable fallback file.
        let faultyLedger = TransitionFailingLedger(base: fixture.store)
        let firstReport = await RecoveryReconciler(
            directory: fixture.root, store: fixture.store, ledger: faultyLedger,
            fileSystem: fixture.fileSystem, libraryDictationID: { _ in nil }
        ).reconcile()

        #expect(firstReport.failed == 1)
        #expect(firstReport.quarantined == 0)
        #expect(try await fixture.store.session(id: id)?.state == .capturing)
        #expect(try await fixture.store.committedSegments(captureID: id).count == 2)
        for url in segmentURLs {
            #expect(FileManager.default.fileExists(atPath: url.path))
        }

        let reopened = try fixture.reopen()
        let secondReport = await reopened.reconciler().reconcile()

        #expect(secondReport.failed == 0, Comment(rawValue: String(describing: secondReport.failures)))
        #expect(try await reopened.store.session(id: id)?.state == .processing)
        _ = try #require(try await reopened.store.job(id: id))
        #expect(FileManager.default.fileExists(
            atPath: sessionDirectory.appendingPathComponent("\(id.uuidString).wav").path
        ))
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

    @Test("capturing ledger segments are assembled and become visible after reopen")
    func interruptedSegmentsBecomeVisible() async throws {
        let fixture = try ReconciliationFixture()
        let id = UUID()
        let sessionDirectory = fixture.root.appendingPathComponent(id.uuidString, isDirectory: true)
        try fixture.fileSystem.createDirectory(sessionDirectory)
        _ = try await fixture.store.createCapture(.init(
            id: id, directory: sessionDirectory, capturedAt: Date(), sampleRate: 16_000,
            channelCount: 1, inputDeviceUID: nil, destination: "external"
        ))
        let codec = CaptureSegmentCodec(fileSystem: fixture.fileSystem)
        for (ordinal, samples) in [[Float(0.2), 0.1], [0.3]].enumerated() {
            let url = sessionDirectory.appendingPathComponent(String(format: "segment-%08d.wav", ordinal))
            let data = codec.encode(samples)
            try data.write(to: url)
            try await fixture.store.recordCommittedSegment(.init(
                captureID: id, ordinal: ordinal, url: url, sampleCount: samples.count,
                contentHash: codec.hash(data)
            ))
        }

        let reopened = try fixture.reopen()
        let report = await reopened.reconciler().reconcile()
        #expect(report.failed == 0)
        #expect(try await reopened.store.session(id: id)?.state == .processing)
        #expect(try await reopened.store.job(id: id) != nil)
        #expect(FileManager.default.fileExists(atPath: sessionDirectory.appendingPathComponent("\(id.uuidString).wav").path))
    }

    @Test("Library identity wins over loose UUID audio without creating Recovery")
    func looseUUIDLibraryIdentityWins() async throws {
        let fixture = try ReconciliationFixture()
        let id = UUID()
        let audio = fixture.root.appendingPathComponent("\(id.uuidString).wav")
        try WAVEncoder.encode(samples: Array(repeating: 0.2, count: 1_600), sampleRate: 16_000).write(to: audio)
        let report = await fixture.reconciler(libraryDictationID: { candidate in candidate == id ? 73 : nil }).reconcile()
        #expect(report.imported == 0)
        #expect(try await fixture.store.job(id: id) == nil)
        #expect(!FileManager.default.fileExists(atPath: audio.path))
    }

    @Test("pending temporary audio is retained until durable owned registration")
    func pendingTemporaryEvidenceIsRetained() async throws {
        let fixture = try ReconciliationFixture()
        let id = UUID()
        let temporary = fixture.root.appendingPathComponent(".\(id.uuidString).tmp")
        let marker = fixture.root.appendingPathComponent("\(id.uuidString).pending")
        try WAVEncoder.encode(samples: Array(repeating: 0.1, count: 1_600), sampleRate: 16_000).write(to: temporary)
        try Data("0".utf8).write(to: marker)
        let report = await fixture.reconciler().reconcile()
        #expect(report.imported == 1)
        #expect(FileManager.default.fileExists(atPath: temporary.path))
        #expect(!FileManager.default.fileExists(atPath: marker.path))
        let job = try #require(try await fixture.store.job(id: id))
        #expect(FileManager.default.fileExists(atPath: job.source.reference))
        #expect(job.source.reference != temporary.path)
    }

    @MainActor @Test("production launch gate coalesces concurrent launches")
    func launchGateCoalescesConcurrentCalls() async {
        let gate = RecoveryLaunchGate()
        let probe = LaunchGateProbe()
        async let first: Void = gate.run { await probe.enter() }
        async let second: Void = gate.run { await probe.enter() }
        _ = await (first, second)
        #expect(await probe.count == 1)
    }

    @Test("canonical registration uses exact same-session retry schedule")
    func canonicalRegistrationRetriesExactly() async throws {
        let fixture = try ReconciliationFixture()
        let id = UUID()
        let sessionDirectory = fixture.root.appendingPathComponent(id.uuidString, isDirectory: true)
        try fixture.fileSystem.createDirectory(sessionDirectory)
        let canonical = sessionDirectory.appendingPathComponent("\(id.uuidString).wav")
        let codec = CaptureSegmentCodec(fileSystem: fixture.fileSystem)
        try codec.encode(Array(repeating: 0.2, count: 1_600)).write(to: canonical)
        _ = try await fixture.store.createCapture(.init(
            id: id, directory: sessionDirectory, capturedAt: Date(), sampleRate: 16_000,
            channelCount: 1, inputDeviceUID: nil, destination: "external"
        ))
        let probe = ReconciliationRetryProbe(failures: 2)
        let report = await fixture.reconciler(
            retrySleep: { await probe.record($0) },
            beforeRegistrationAttempt: { try await probe.attempt() }
        ).reconcile()
        #expect(report.failed == 0)
        #expect(await probe.delays == [.zero, .milliseconds(250), .seconds(1)])
        #expect(try await fixture.store.job(id: id) != nil)
    }

    @Test("pending temporary survives exhausted registration then converges on reopen")
    func pendingTemporaryFailureConverges() async throws {
        let fixture = try ReconciliationFixture()
        let id = UUID()
        let temporary = fixture.root.appendingPathComponent(".\(id.uuidString).tmp")
        let marker = fixture.root.appendingPathComponent("\(id.uuidString).pending")
        try WAVEncoder.encode(samples: Array(repeating: 0.1, count: 1_600), sampleRate: 16_000).write(to: temporary)
        try Data("0".utf8).write(to: marker)
        let probe = ReconciliationRetryProbe(failures: 3)
        let failed = await fixture.reconciler(
            retrySleep: { _ in }, beforeRegistrationAttempt: { try await probe.attempt() }
        ).reconcile()
        #expect(failed.failed == 1)
        #expect(FileManager.default.fileExists(atPath: temporary.path))
        #expect(FileManager.default.fileExists(atPath: marker.path))

        let reopened = try fixture.reopen()
        let recovered = await reopened.reconciler().reconcile()
        #expect(recovered.failed == 0)
        #expect(try await reopened.store.job(id: id) != nil)
        #expect(FileManager.default.fileExists(atPath: temporary.path))
    }

    @Test("Library identity cleans capturing and staged canonical sessions before registration")
    func libraryWinsForPreRegistrationSessions() async throws {
        for staged in [false, true] {
            let fixture = try ReconciliationFixture()
            let id = UUID()
            let sessionDirectory = fixture.root.appendingPathComponent(id.uuidString, isDirectory: true)
            try fixture.fileSystem.createDirectory(sessionDirectory)
            let canonical = sessionDirectory.appendingPathComponent("\(id.uuidString).wav")
            let codec = CaptureSegmentCodec(fileSystem: fixture.fileSystem)
            try codec.encode(Array(repeating: 0.2, count: 1_600)).write(to: canonical)
            _ = try await fixture.store.createCapture(.init(
                id: id, directory: sessionDirectory, capturedAt: Date(), sampleRate: 16_000,
                channelCount: 1, inputDeviceUID: nil, destination: "external"
            ))
            if staged {
                try await fixture.store.transition(
                    id: id, from: .capturing, to: .staged, recoveryJobID: nil,
                    libraryDictationID: nil, assetKind: .audio, failureMessage: nil,
                    contentHash: try codec.hashFile(canonical)
                )
            }
            let report = await fixture.reconciler(
                libraryDictationID: { candidate in candidate == id ? 91 : nil }
            ).reconcile()
            #expect(report.failed == 0)
            #expect(try await fixture.store.session(id: id) == nil)
            #expect(try await fixture.store.job(id: id) == nil)
            #expect(!FileManager.default.fileExists(atPath: canonical.path))
        }
    }

    @Test("capturing failure marker becomes visible durable quarantine")
    func capturingFailureMarkerBecomesVisible() async throws {
        let fixture = try ReconciliationFixture()
        let id = UUID()
        let sessionDirectory = fixture.root.appendingPathComponent(id.uuidString, isDirectory: true)
        try fixture.fileSystem.createDirectory(sessionDirectory)
        let marker = sessionDirectory.appendingPathComponent("capture-failure.marker")
        try Data("writer failure".utf8).write(to: marker)
        _ = try await fixture.store.createCapture(.init(
            id: id, directory: sessionDirectory, capturedAt: Date(), sampleRate: 16_000,
            channelCount: 1, inputDeviceUID: nil, destination: "external"
        ))
        let reopened = try fixture.reopen()
        let report = await reopened.reconciler().reconcile()
        #expect(report.failed == 0)
        #expect(try await reopened.store.session(id: id)?.state == .damaged)
        #expect(try await reopened.store.session(id: id)?.assetKind == .quarantined)
        #expect(try await reopened.store.job(id: id) != nil)
    }

    @Test("exhausted registration I/O failure does not block a later valid item")
    func registrationFailureIsPerItem() async throws {
        let fixture = try ReconciliationFixture()
        try WAVEncoder.encode(
            samples: Array(repeating: 0.1, count: 1_600), sampleRate: 16_000
        ).write(to: fixture.root.appendingPathComponent("failed-000-io.wav"))
        try WAVEncoder.encode(
            samples: Array(repeating: 0.2, count: 1_600), sampleRate: 16_000
        ).write(to: fixture.root.appendingPathComponent("failed-999-valid.wav"))
        let probe = ReconciliationRetryProbe(failures: 3)
        let report = await fixture.reconciler(
            retrySleep: { _ in }, beforeRegistrationAttempt: { try await probe.attempt() }
        ).reconcile()
        #expect(report.failed == 1)
        #expect(report.imported == 1)
        #expect(try await fixture.store.jobs(kind: .recovery).count == 1)
    }

    @Test("Library cleanup discovers a capture job when ledger link was never persisted")
    func libraryCleanupRepairsMissingLedgerJobLink() async throws {
        let fixture = try ReconciliationFixture()
        let id = UUID()
        let sessionDirectory = fixture.root.appendingPathComponent(id.uuidString, isDirectory: true)
        try fixture.fileSystem.createDirectory(sessionDirectory)
        let canonical = sessionDirectory.appendingPathComponent("\(id.uuidString).wav")
        let codec = CaptureSegmentCodec(fileSystem: fixture.fileSystem)
        try codec.encode(Array(repeating: 0.2, count: 1_600)).write(to: canonical)
        _ = try await fixture.store.createCapture(.init(
            id: id, directory: sessionDirectory, capturedAt: Date(), sampleRate: 16_000,
            channelCount: 1, inputDeviceUID: nil, destination: "external"
        ))
        try await fixture.store.transition(
            id: id, from: .capturing, to: .staged, recoveryJobID: nil,
            libraryDictationID: nil, assetKind: .audio, failureMessage: nil,
            contentHash: try codec.hashFile(canonical)
        )
        _ = try await fixture.store.createProvisionalRecovery(
            id: id, source: JobSource(reference: canonical.path), capturedAt: Date()
        )

        let reopened = try fixture.reopen()
        let report = await reopened.reconciler(
            libraryDictationID: { candidate in candidate == id ? 501 : nil }
        ).reconcile()
        #expect(report.failed == 0)
        #expect(try await reopened.store.job(id: id) == nil)
        #expect(try await reopened.store.session(id: id) == nil)
        #expect(!FileManager.default.fileExists(atPath: canonical.path))
    }

    @Test("marker-backed normalized job converges when Library identity appears")
    func markerBackedLibraryCleanupConverges() async throws {
        let fixture = try ReconciliationFixture()
        let id = UUID()
        let marker = fixture.root.appendingPathComponent(
            ".capture-preparation-\(id.uuidString).marker"
        )
        try Data("interrupted prepare".utf8).write(to: marker)
        _ = await fixture.reconciler().reconcile()
        let job = try #require(try await fixture.store.job(id: id))
        #expect(try await fixture.store.session(id: id) != nil)

        let reopened = try fixture.reopen()
        let report = await reopened.reconciler(
            libraryDictationID: { candidate in candidate == id ? 777 : nil }
        ).reconcile()
        #expect(report.failed == 0)
        #expect(try await reopened.store.job(id: id) == nil)
        #expect(try await reopened.store.session(id: id) == nil)
        #expect(!FileManager.default.fileExists(atPath: job.source.reference))
    }

    @MainActor @Test("disposing one fixed-content marker never disposes another capture identity")
    func markerDispositionKeepsCaptureIdentity() async throws {
        let fixture = try ReconciliationFixture()
        let firstID = UUID()
        let secondID = UUID()
        for id in [firstID, secondID] {
            try Data("same interrupted preparation".utf8).write(to:
                fixture.root.appendingPathComponent(".capture-preparation-\(id.uuidString).marker")
            )
        }
        _ = await fixture.reconciler().reconcile()
        let library = JobLibraryStore(store: fixture.store, recoveryDirectory: fixture.root)
        try await library.refresh()
        try await library.delete(id: firstID)

        let reopened = try fixture.reopen()
        let report = await reopened.reconciler().reconcile()
        #expect(report.failed == 0, Comment(rawValue: String(describing: report.failures)))
        #expect(try await reopened.store.job(id: firstID) == nil)
        #expect(try await reopened.store.session(id: firstID) == nil)
        #expect(try await reopened.store.job(id: secondID) != nil)
        #expect(try await reopened.store.session(id: secondID) != nil)
    }
}

enum SilentCleanupBoundary: CaseIterable, Sendable {
    case removeSegment
    case synchronizeDirectory
    case removeMetadata
}

enum UnsafeSilentSegmentCase: CaseIterable, Sendable {
    case outsideRoot
    case pathTraversal
    case symlink
    case ordinalMismatch
    case sessionOutsideRoot
}

private final class SilentCleanupFaultFileSystem: JournalFileSystem, @unchecked Sendable {
    private let base = LocalJournalFileSystem()
    private let boundary: SilentCleanupBoundary
    private let lock = NSLock()
    private var didFail = false
    private var removedSegment = false

    init(boundary: SilentCleanupBoundary) { self.boundary = boundary }
    func createDirectory(_ url: URL) throws { try base.createDirectory(url) }
    func write(_ data: Data, to url: URL) throws { try base.write(data, to: url) }
    func append(_ data: Data, to url: URL) throws { try base.append(data, to: url) }
    func synchronizeFile(_ url: URL) throws { try base.synchronizeFile(url) }
    func rename(_ source: URL, to destination: URL) throws { try base.rename(source, to: destination) }
    func synchronizeDirectory(_ url: URL) throws {
        let fail = lock.withLock { () -> Bool in
            guard boundary == .synchronizeDirectory, removedSegment, !didFail else { return false }
            didFail = true
            return true
        }
        if fail { throw JournalPersistenceError.synchronizeDirectory(path: url.path, code: EIO) }
        try base.synchronizeDirectory(url)
    }
    func contents(_ url: URL) throws -> [URL] { try base.contents(url) }
    func read(_ url: URL) throws -> Data { try base.read(url) }
    func remove(_ url: URL) throws {
        let isSegment = CaptureSegmentCodec.ordinal(from: url) != nil
        let fail = lock.withLock { () -> Bool in
            if isSegment { removedSegment = true }
            guard boundary == .removeSegment, isSegment, !didFail else { return false }
            didFail = true
            return true
        }
        if fail { throw JournalPersistenceError.remove(path: url.path, code: EIO) }
        try base.remove(url)
    }
    func removeEmptyDirectory(_ url: URL) throws { try base.removeEmptyDirectory(url) }
    func removeRegularFile(_ url: URL) throws { try base.removeRegularFile(url) }
    func exists(_ url: URL) -> Bool { base.exists(url) }
}

private final class SilentCleanupFaultLedger: CaptureLedgerStoring, @unchecked Sendable {
    private let base: TranscriptionJobStore
    private let boundary: SilentCleanupBoundary
    private let lock = NSLock()
    private var didFail = false

    init(base: TranscriptionJobStore, boundary: SilentCleanupBoundary) {
        self.base = base
        self.boundary = boundary
    }
    func createCapture(_ request: CaptureStartRequest) async throws -> CaptureSession { try await base.createCapture(request) }
    func recordCommittedSegment(_ segment: CaptureSegment) async throws { try await base.recordCommittedSegment(segment) }
    func transition(id: UUID, from: CaptureSessionState, to: CaptureSessionState, recoveryJobID: UUID?, libraryDictationID: Int64?, assetKind: RecoveryAssetKind, failureMessage: String?, contentHash: String?) async throws {
        try await base.transition(id: id, from: from, to: to, recoveryJobID: recoveryJobID, libraryDictationID: libraryDictationID, assetKind: assetKind, failureMessage: failureMessage, contentHash: contentHash)
    }
    func session(id: UUID) async throws -> CaptureSession? { try await base.session(id: id) }
    func unfinishedSessions() async throws -> [CaptureSession] { try await base.unfinishedSessions() }
    func committedSegments(captureID: UUID) async throws -> [CaptureSegment] { try await base.committedSegments(captureID: captureID) }
    func removeCommittedSegments(captureID: UUID) async throws {
        let fail = lock.withLock { () -> Bool in
            guard boundary == .removeMetadata, !didFail else { return false }
            didFail = true
            return true
        }
        if fail { throw TestLedgerError.injected }
        try await base.removeCommittedSegments(captureID: captureID)
    }
    func removeCleanedSession(id: UUID) async throws { try await base.removeCleanedSession(id: id) }
}

/// Fails once on exactly the SECOND call to `committedSegments` — the first is
/// `reconcileSegmentInventory`'s own inventory read (must succeed so a malformed/EISDIR orphan is
/// actually discovered), the second is the malformed-orphan/EISDIR quarantine catch's survivor
/// fetch. Used to prove a transient failure at that exact point (Codex round-10 blocker) must not
/// leave the session `.capturing` with the orphan's corruption evidence already deleted.
private final class SurvivorsFetchFailingLedger: CaptureLedgerStoring, @unchecked Sendable {
    private let base: TranscriptionJobStore
    private let lock = NSLock()
    private var callCount = 0
    private var didFail = false

    init(base: TranscriptionJobStore) { self.base = base }
    func createCapture(_ request: CaptureStartRequest) async throws -> CaptureSession { try await base.createCapture(request) }
    func recordCommittedSegment(_ segment: CaptureSegment) async throws { try await base.recordCommittedSegment(segment) }
    func transition(id: UUID, from: CaptureSessionState, to: CaptureSessionState, recoveryJobID: UUID?, libraryDictationID: Int64?, assetKind: RecoveryAssetKind, failureMessage: String?, contentHash: String?) async throws {
        try await base.transition(id: id, from: from, to: to, recoveryJobID: recoveryJobID, libraryDictationID: libraryDictationID, assetKind: assetKind, failureMessage: failureMessage, contentHash: contentHash)
    }
    func session(id: UUID) async throws -> CaptureSession? { try await base.session(id: id) }
    func unfinishedSessions() async throws -> [CaptureSession] { try await base.unfinishedSessions() }
    func committedSegments(captureID: UUID) async throws -> [CaptureSegment] {
        let shouldFail = lock.withLock { () -> Bool in
            callCount += 1
            guard !didFail, callCount == 2 else { return false }
            didFail = true
            return true
        }
        if shouldFail { throw TestLedgerError.injected }
        return try await base.committedSegments(captureID: captureID)
    }
    func removeCommittedSegments(captureID: UUID) async throws { try await base.removeCommittedSegments(captureID: captureID) }
    func removeCleanedSession(id: UUID) async throws { try await base.removeCleanedSession(id: id) }
    func recordVoiceCommandSnapshot(id: UUID, enabled: Bool, keywords: [String]) async throws {
        try await base.recordVoiceCommandSnapshot(id: id, enabled: enabled, keywords: keywords)
    }
}

private final class SnapshotFailingLedger: CaptureLedgerStoring, @unchecked Sendable {
    private let base: TranscriptionJobStore
    private let lock = NSLock()
    private var didFail = false

    init(base: TranscriptionJobStore) { self.base = base }
    func createCapture(_ request: CaptureStartRequest) async throws -> CaptureSession { try await base.createCapture(request) }
    func recordCommittedSegment(_ segment: CaptureSegment) async throws { try await base.recordCommittedSegment(segment) }
    func transition(id: UUID, from: CaptureSessionState, to: CaptureSessionState, recoveryJobID: UUID?, libraryDictationID: Int64?, assetKind: RecoveryAssetKind, failureMessage: String?, contentHash: String?) async throws {
        try await base.transition(id: id, from: from, to: to, recoveryJobID: recoveryJobID, libraryDictationID: libraryDictationID, assetKind: assetKind, failureMessage: failureMessage, contentHash: contentHash)
    }
    func session(id: UUID) async throws -> CaptureSession? { try await base.session(id: id) }
    func unfinishedSessions() async throws -> [CaptureSession] { try await base.unfinishedSessions() }
    func committedSegments(captureID: UUID) async throws -> [CaptureSegment] { try await base.committedSegments(captureID: captureID) }
    func removeCommittedSegments(captureID: UUID) async throws { try await base.removeCommittedSegments(captureID: captureID) }
    func removeCleanedSession(id: UUID) async throws { try await base.removeCleanedSession(id: id) }
    func recordVoiceCommandSnapshot(id: UUID, enabled: Bool, keywords: [String]) async throws {
        let shouldFail = lock.withLock { () -> Bool in
            guard !didFail else { return false }
            didFail = true
            return true
        }
        if shouldFail { throw TestLedgerError.injected }
        try await base.recordVoiceCommandSnapshot(id: id, enabled: enabled, keywords: keywords)
    }
}

/// Fails once on the `.capturing -> .staged` transition — used to prove a transient metadata-
/// transition failure (Codex round-4 finding 3) propagates to `report.recordFailure` instead of
/// being folded into the segment-corruption quarantine path.
private final class TransitionFailingLedger: CaptureLedgerStoring, @unchecked Sendable {
    private let base: TranscriptionJobStore
    private let lock = NSLock()
    private var didFail = false

    init(base: TranscriptionJobStore) { self.base = base }
    func createCapture(_ request: CaptureStartRequest) async throws -> CaptureSession { try await base.createCapture(request) }
    func recordCommittedSegment(_ segment: CaptureSegment) async throws { try await base.recordCommittedSegment(segment) }
    func transition(id: UUID, from: CaptureSessionState, to: CaptureSessionState, recoveryJobID: UUID?, libraryDictationID: Int64?, assetKind: RecoveryAssetKind, failureMessage: String?, contentHash: String?) async throws {
        let shouldFail = lock.withLock { () -> Bool in
            guard !didFail, from == .capturing, to == .staged else { return false }
            didFail = true
            return true
        }
        if shouldFail { throw TestLedgerError.injected }
        try await base.transition(id: id, from: from, to: to, recoveryJobID: recoveryJobID, libraryDictationID: libraryDictationID, assetKind: assetKind, failureMessage: failureMessage, contentHash: contentHash)
    }
    func session(id: UUID) async throws -> CaptureSession? { try await base.session(id: id) }
    func unfinishedSessions() async throws -> [CaptureSession] { try await base.unfinishedSessions() }
    func committedSegments(captureID: UUID) async throws -> [CaptureSegment] { try await base.committedSegments(captureID: captureID) }
    func removeCommittedSegments(captureID: UUID) async throws { try await base.removeCommittedSegments(captureID: captureID) }
    func removeCleanedSession(id: UUID) async throws { try await base.removeCleanedSession(id: id) }
    func recordVoiceCommandSnapshot(id: UUID, enabled: Bool, keywords: [String]) async throws {
        try await base.recordVoiceCommandSnapshot(id: id, enabled: enabled, keywords: keywords)
    }
}

private actor LaunchGateProbe {
    private(set) var count = 0
    func enter() async { count += 1; await Task.yield() }
}

private actor ReconciliationRetryProbe {
    private let failures: Int
    private(set) var attempts = 0
    private(set) var delays: [Duration] = []
    init(failures: Int) { self.failures = failures }
    func record(_ delay: Duration) { delays.append(delay) }
    func attempt() throws {
        attempts += 1
        if attempts <= failures { throw CocoaError(.fileWriteUnknown) }
    }
}

/// Wraps a `LocalJournalFileSystem` and returns `contents(_:)` sorted lexicographically by path,
/// removing any dependency on `FileManager.contentsOfDirectory`'s unspecified ordering — used to
/// deterministically force an adversarial directory order in fallback-selection tests (Codex
/// round-13 blocker).
private struct SortedContentsFileSystem: JournalFileSystem {
    let base: LocalJournalFileSystem
    func createDirectory(_ url: URL) throws { try base.createDirectory(url) }
    func write(_ data: Data, to url: URL) throws { try base.write(data, to: url) }
    func append(_ data: Data, to url: URL) throws { try base.append(data, to: url) }
    func synchronizeFile(_ url: URL) throws { try base.synchronizeFile(url) }
    func rename(_ source: URL, to destination: URL) throws { try base.rename(source, to: destination) }
    func synchronizeDirectory(_ url: URL) throws { try base.synchronizeDirectory(url) }
    func contents(_ url: URL) throws -> [URL] { try base.contents(url).sorted { $0.path < $1.path } }
    func read(_ url: URL) throws -> Data { try base.read(url) }
    func remove(_ url: URL) throws { try base.remove(url) }
    func removeEmptyDirectory(_ url: URL) throws { try base.removeEmptyDirectory(url) }
    func removeRegularFile(_ url: URL) throws { try base.removeRegularFile(url) }
    func exists(_ url: URL) -> Bool { base.exists(url) }
}

/// Returns `firstRead` on the FIRST `read(_:)` call for `target` and `subsequentReads` on every
/// call after that, delegating every other URL and every other operation straight to `base` —
/// simulates a concurrent replacement of one specific candidate file between two separate reads
/// of it (Codex round-13 minor).
private final class RaceOnReadFileSystem: JournalFileSystem, @unchecked Sendable {
    private let base: LocalJournalFileSystem
    private let target: URL
    private let firstRead: Data
    private let subsequentReads: Data
    private let lock = NSLock()
    private var readCount = 0

    init(base: LocalJournalFileSystem, target: URL, firstRead: Data, subsequentReads: Data) {
        self.base = base
        self.target = target.standardizedFileURL
        self.firstRead = firstRead
        self.subsequentReads = subsequentReads
    }

    func createDirectory(_ url: URL) throws { try base.createDirectory(url) }
    func write(_ data: Data, to url: URL) throws { try base.write(data, to: url) }
    func append(_ data: Data, to url: URL) throws { try base.append(data, to: url) }
    func synchronizeFile(_ url: URL) throws { try base.synchronizeFile(url) }
    func rename(_ source: URL, to destination: URL) throws { try base.rename(source, to: destination) }
    func synchronizeDirectory(_ url: URL) throws { try base.synchronizeDirectory(url) }
    func contents(_ url: URL) throws -> [URL] { try base.contents(url) }
    func read(_ url: URL) throws -> Data {
        guard url.standardizedFileURL == target else { return try base.read(url) }
        let isFirst = lock.withLock { () -> Bool in
            readCount += 1
            return readCount == 1
        }
        return isFirst ? firstRead : subsequentReads
    }
    func remove(_ url: URL) throws { try base.remove(url) }
    func removeEmptyDirectory(_ url: URL) throws { try base.removeEmptyDirectory(url) }
    func removeRegularFile(_ url: URL) throws { try base.removeRegularFile(url) }
    func exists(_ url: URL) -> Bool { base.exists(url) }
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
    func removeEmptyDirectory(_ url: URL) throws { try base.removeEmptyDirectory(url) }
    func removeRegularFile(_ url: URL) throws { try base.removeRegularFile(url) }
    func exists(_ url: URL) -> Bool { base.exists(url) }
}

/// Fails once on `rename` (the final step of `CaptureSegmentCodec.assemble`, promoting the
/// temporary canonical WAV into place) — used to prove a transient I/O failure while assembling
/// otherwise-healthy segments must report/retry, never quarantine (Codex round-5 finding 2).
private final class AssembleRenameFaultFileSystem: JournalFileSystem, @unchecked Sendable {
    private let base = LocalJournalFileSystem()
    private let lock = NSLock()
    private var didFail = false
    func createDirectory(_ url: URL) throws { try base.createDirectory(url) }
    func write(_ data: Data, to url: URL) throws { try base.write(data, to: url) }
    func append(_ data: Data, to url: URL) throws { try base.append(data, to: url) }
    func synchronizeFile(_ url: URL) throws { try base.synchronizeFile(url) }
    func rename(_ source: URL, to destination: URL) throws {
        let shouldFail = lock.withLock { () -> Bool in
            guard !didFail else { return false }
            didFail = true
            return true
        }
        if shouldFail { throw JournalPersistenceError.rename(source: source.path, destination: destination.path, code: EIO) }
        try base.rename(source, to: destination)
    }
    func synchronizeDirectory(_ url: URL) throws { try base.synchronizeDirectory(url) }
    func contents(_ url: URL) throws -> [URL] { try base.contents(url) }
    func read(_ url: URL) throws -> Data { try base.read(url) }
    func remove(_ url: URL) throws { try base.remove(url) }
    func removeEmptyDirectory(_ url: URL) throws { try base.removeEmptyDirectory(url) }
    func removeRegularFile(_ url: URL) throws { try base.removeRegularFile(url) }
    func exists(_ url: URL) -> Bool { base.exists(url) }
}

/// Fails exactly the first `remove` of `target` — simulating a crash between the durable
/// `.damaged` transition in the malformed-orphan/EISDIR quarantine catches and the
/// `clearOwnedOrphan` call immediately after it (Codex round-11 blocker). Every later attempt at
/// removing `target` (the retry the fix must perform from the `.damaged` steady-state branch)
/// succeeds normally.
private final class OrphanRemovalCrashFileSystem: JournalFileSystem, @unchecked Sendable {
    private let base = LocalJournalFileSystem()
    private let target: URL
    private let lock = NSLock()
    private var didFail = false
    init(target: URL) { self.target = target }
    func createDirectory(_ url: URL) throws { try base.createDirectory(url) }
    func write(_ data: Data, to url: URL) throws { try base.write(data, to: url) }
    func append(_ data: Data, to url: URL) throws { try base.append(data, to: url) }
    func synchronizeFile(_ url: URL) throws { try base.synchronizeFile(url) }
    func rename(_ source: URL, to destination: URL) throws { try base.rename(source, to: destination) }
    func synchronizeDirectory(_ url: URL) throws { try base.synchronizeDirectory(url) }
    func contents(_ url: URL) throws -> [URL] { try base.contents(url) }
    func read(_ url: URL) throws -> Data { try base.read(url) }
    func remove(_ url: URL) throws {
        if url.standardizedFileURL == target.standardizedFileURL {
            let shouldFail = lock.withLock { () -> Bool in
                guard !didFail else { return false }
                didFail = true
                return true
            }
            if shouldFail { throw JournalPersistenceError.remove(path: url.path, code: EIO) }
        }
        try base.remove(url)
    }
    func removeEmptyDirectory(_ url: URL) throws { try base.removeEmptyDirectory(url) }
    func removeRegularFile(_ url: URL) throws { try base.removeRegularFile(url) }
    func exists(_ url: URL) -> Bool { base.exists(url) }
}

/// Simulates a directory sitting where a `segment-*.wav` orphan file should be — `read` throws
/// `EISDIR`, exactly as a real directory read would, without depending on platform-specific
/// NSError → POSIX-code translation for a case that's awkward to provoke for real inside a
/// sandboxed test run (Codex round-7 finding 7).
private final class OrphanSegmentEISDIRFaultFileSystem: JournalFileSystem, @unchecked Sendable {
    private let base = LocalJournalFileSystem()
    private let target: URL
    init(target: URL) { self.target = target }
    func createDirectory(_ url: URL) throws { try base.createDirectory(url) }
    func write(_ data: Data, to url: URL) throws { try base.write(data, to: url) }
    func append(_ data: Data, to url: URL) throws { try base.append(data, to: url) }
    func synchronizeFile(_ url: URL) throws { try base.synchronizeFile(url) }
    func rename(_ source: URL, to destination: URL) throws { try base.rename(source, to: destination) }
    func synchronizeDirectory(_ url: URL) throws { try base.synchronizeDirectory(url) }
    func contents(_ url: URL) throws -> [URL] { try base.contents(url) }
    func read(_ url: URL) throws -> Data {
        if url.standardizedFileURL == target.standardizedFileURL {
            throw JournalPersistenceError.read(path: url.path, code: EISDIR)
        }
        return try base.read(url)
    }
    func remove(_ url: URL) throws { try base.remove(url) }
    func removeEmptyDirectory(_ url: URL) throws { try base.removeEmptyDirectory(url) }
    func removeRegularFile(_ url: URL) throws { try base.removeRegularFile(url) }
    func exists(_ url: URL) -> Bool { base.exists(url) }
}

/// Fails `read` with a transient `EIO` for exactly one target URL — used to prove a read failure
/// while validating a quarantine fallback survivor (`firstValidatedSurvivingSegment`) must
/// propagate for retry, not be silently read as "this segment didn't survive" (Codex round-9
/// finding 2).
private final class SurvivorValidationReadFaultFileSystem: JournalFileSystem, @unchecked Sendable {
    private let base = LocalJournalFileSystem()
    private let target: URL
    init(target: URL) { self.target = target }
    func createDirectory(_ url: URL) throws { try base.createDirectory(url) }
    func write(_ data: Data, to url: URL) throws { try base.write(data, to: url) }
    func append(_ data: Data, to url: URL) throws { try base.append(data, to: url) }
    func synchronizeFile(_ url: URL) throws { try base.synchronizeFile(url) }
    func rename(_ source: URL, to destination: URL) throws { try base.rename(source, to: destination) }
    func synchronizeDirectory(_ url: URL) throws { try base.synchronizeDirectory(url) }
    func contents(_ url: URL) throws -> [URL] { try base.contents(url) }
    func read(_ url: URL) throws -> Data {
        if url.standardizedFileURL == target.standardizedFileURL {
            throw JournalPersistenceError.read(path: url.path, code: EIO)
        }
        return try base.read(url)
    }
    func remove(_ url: URL) throws { try base.remove(url) }
    func removeEmptyDirectory(_ url: URL) throws { try base.removeEmptyDirectory(url) }
    func removeRegularFile(_ url: URL) throws { try base.removeRegularFile(url) }
    func exists(_ url: URL) -> Bool { base.exists(url) }
}

/// Fails once on a `rename` whose source is a `LegacyRecoveryImporter` import temporary
/// (`.<id>.<uuid>.import.tmp`) — simulating a crash between that temporary's durable write and
/// its rename into the owned destination. The retrier's next attempt uses a fresh UUID and
/// succeeds, leaving the first temporary behind as legitimate abandoned residue (Codex round-9
/// finding 3).
private final class ImportTemporaryRenameFaultFileSystem: JournalFileSystem, @unchecked Sendable {
    private let base = LocalJournalFileSystem()
    private let lock = NSLock()
    private var didFail = false
    func createDirectory(_ url: URL) throws { try base.createDirectory(url) }
    func write(_ data: Data, to url: URL) throws { try base.write(data, to: url) }
    func append(_ data: Data, to url: URL) throws { try base.append(data, to: url) }
    func synchronizeFile(_ url: URL) throws { try base.synchronizeFile(url) }
    func rename(_ source: URL, to destination: URL) throws {
        let shouldFail = lock.withLock { () -> Bool in
            guard !didFail, source.lastPathComponent.hasSuffix(".import.tmp") else { return false }
            didFail = true
            return true
        }
        if shouldFail {
            throw JournalPersistenceError.rename(
                source: source.path, destination: destination.path, code: EIO
            )
        }
        try base.rename(source, to: destination)
    }
    func synchronizeDirectory(_ url: URL) throws { try base.synchronizeDirectory(url) }
    func contents(_ url: URL) throws -> [URL] { try base.contents(url) }
    func read(_ url: URL) throws -> Data { try base.read(url) }
    func remove(_ url: URL) throws { try base.remove(url) }
    func removeEmptyDirectory(_ url: URL) throws { try base.removeEmptyDirectory(url) }
    func removeRegularFile(_ url: URL) throws { try base.removeRegularFile(url) }
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
        libraryDictationID: @escaping @Sendable (UUID) async throws -> Int64? = { _ in nil },
        retrySleep: @escaping @Sendable (Duration) async -> Void = { _ in },
        beforeRegistrationAttempt: @escaping @Sendable () async throws -> Void = {}
    ) -> RecoveryReconciler {
        RecoveryReconciler(
            directory: root, store: store, ledger: store, fileSystem: fileSystem,
            libraryDictationID: libraryDictationID, retrySleep: retrySleep,
            beforeRegistrationAttempt: beforeRegistrationAttempt
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
