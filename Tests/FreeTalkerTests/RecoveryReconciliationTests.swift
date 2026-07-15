import Foundation
import Testing
@testable import FreeTalker

@Suite struct RecoveryReconciliationTests {
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
