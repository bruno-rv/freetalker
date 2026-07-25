import AVFoundation
import Combine
import Foundation

protocol RecoveryAudioPlaying: AnyObject {
    func play() -> Bool
}

extension AVAudioPlayer: RecoveryAudioPlaying {}

enum RecoveryPlaybackError: LocalizedError, Equatable {
    case couldNotStart

    var errorDescription: String? { "The recovery audio could not start playing." }
}

@MainActor
final class JobLibraryStore: ObservableObject {
    @Published private(set) var recoveryJobs: [TranscriptionJob] = []
    @Published private(set) var silentCaptures: [SilentCapturePresentation] = []
    @Published private(set) var recoveryItems: [RecoveryItem] = []
    @Published private(set) var importJobs: [TranscriptionJob] = []
    @Published private(set) var importStatusMessage: String?

    private let store: TranscriptionJobStore
    private let recoveryDirectory: URL
    private var enqueueRecovery: (@Sendable (UUID) async -> Void)?
    private var beginExternalRecording: (() -> Bool)?
    private var enqueueImport: (@Sendable (UUID) async -> Void)?
    private var cancelImport: (@Sendable (UUID) async -> LocalJobRunner.CancellationOutcome)?
    private var importService: MediaImportService?
    private var importsDirectory: URL?
    private let playbackFactory: (URL) throws -> any RecoveryAudioPlaying
    private let artifactExporter: any RecoveryArtifactExporting
    private var player: (any RecoveryAudioPlaying)?

    init(
        store: TranscriptionJobStore,
        recoveryDirectory: URL? = nil,
        playbackFactory: @escaping (URL) throws -> any RecoveryAudioPlaying = { try AVAudioPlayer(contentsOf: $0) },
        artifactExporter: any RecoveryArtifactExporting = RecoveryArtifactExporter()
    ) {
        self.store = store
        self.recoveryDirectory = recoveryDirectory ?? URL(fileURLWithPath: "/dev/null")
        self.playbackFactory = playbackFactory
        self.artifactExporter = artifactExporter
    }

    func configureRetry(_ enqueue: @escaping @Sendable (UUID) async -> Void) {
        enqueueRecovery = enqueue
    }

    func configureStartNewRecording(_ begin: @escaping () -> Bool) {
        beginExternalRecording = begin
    }

    func configureImports(
        service: MediaImportService,
        directory: URL,
        enqueue: @escaping @Sendable (UUID) async -> Void,
        cancel: @escaping @Sendable (UUID) async -> LocalJobRunner.CancellationOutcome
    ) {
        importService = service
        importsDirectory = directory
        enqueueImport = enqueue
        cancelImport = cancel
    }

    func importMedia(_ url: URL) async throws {
        guard let importService else { throw MediaImportError.invalidMedia }
        let id = try await importService.createJob(for: url)
        try await refresh()
        await enqueueImport?(id)
    }

    func retryImport(id: UUID) async throws {
        try await store.queueMediaImportRetry(jobID: id)
        try await refresh()
        await enqueueImport?(id)
    }

    @discardableResult
    func cancelImport(id: UUID) async throws -> LocalJobRunner.CancellationOutcome {
        guard let cancelImport else { throw JobStoreError.invalidTransition }
        var outcome = await cancelImport(id)
        if outcome == .notRunning, let job = try await store.job(id: id), job.state == .queued {
            try await store.transition(id, from: .queued, to: .cancelled)
            outcome = .accepted
        }
        importStatusMessage = MediaImportPresentation.cancellationMessage(outcome)
        try await refresh()
        return outcome
    }

    func deleteImport(id: UUID) async throws {
        guard let importsDirectory else { throw JobStoreError.invalidTransition }
        try await store.deleteMediaImport(jobID: id, jobsDirectory: importsDirectory)
        try await refresh()
    }

    func importDetail(id: UUID) async throws -> MediaImportDetail {
        guard let job = try await store.job(id: id), job.kind == .mediaImport else { throw JobStoreError.jobNotFound }
        let transcript = try await store.transcriptSegments(jobID: id)
        let turns = try await store.speakerTurns(jobID: id)
        return MediaImportDetail(
            job: job,
            transcript: transcript,
            turns: turns,
            names: try await store.speakerNames(jobID: id),
            completedStages: try await store.completedMediaStages(jobID: id)
        )
    }

    func renameSpeaker(jobID: UUID, speakerID: String, name: String) async throws {
        try await store.replaceSpeakerName(jobID: jobID, speakerID: speakerID, name: name)
        objectWillChange.send()
    }

    func refresh() async throws {
        async let recoveries = store.jobs(kind: .recovery)
        async let imports = store.jobs(kind: .mediaImport)
        async let captures = store.unfinishedSessions()
        let (recoveryRows, importRows, captureRows) = try await (recoveries, imports, captures)
        _ = RecoveryOwnershipMigrator(root: recoveryDirectory).migrate(
            jobs: recoveryRows + importRows, sessions: captureRows
        )
        recoveryJobs = recoveryRows
        importJobs = importRows
        silentCaptures = captureRows.compactMap(SilentCapturePresentation.init)
        let jobsByID = Dictionary(uniqueKeysWithValues: recoveryJobs.map { ($0.id, $0) })
        var projected = captureRows.compactMap { session in
            RecoveryItem(
                session: session,
                job: session.recoveryJobID.flatMap { jobsByID[$0] } ?? jobsByID[session.id],
                recoveryRoot: recoveryDirectory
            )
        }
        let represented = Set(captureRows.flatMap { session in
            [session.id, session.recoveryJobID].compactMap { $0 }
        })
        projected += recoveryJobs.compactMap { job in
            guard !represented.contains(job.id) else { return nil }
            return RecoveryItem(session: nil, job: job, recoveryRoot: recoveryDirectory)
        }
        recoveryItems = projected.sorted {
            ($0.session?.capturedAt ?? $0.job?.createdAt ?? .distantPast)
                > ($1.session?.capturedAt ?? $1.job?.createdAt ?? .distantPast)
        }
    }

    func retry(id: UUID, configuration: AttemptConfiguration) async throws {
        _ = try await store.queueRecoveryRetry(jobID: id, configuration: configuration)
        await enqueueRecovery?(id)
        try await refresh()
    }

    func preserve(samples: [Float], metadata: RecoveryMetadata) async throws -> UUID {
        let id = try await RecoveryCaptureService(directory: recoveryDirectory, store: store)
            .preserve(samples: samples, metadata: metadata)
        try await refresh()
        return id
    }

    func delete(id: UUID) async throws {
        if let item = recoveryItems.first(where: { $0.id == id }), item.job == nil {
            try await deleteLedgerOnly(item)
            try await refresh()
            return
        }
        let newlyClaimed = try await store.claimRecoveryForDeletion(id: id, claimedAt: Date())
        let alreadyClaimed = try await store.claimedRecoveries().contains { $0.id == id }
        guard newlyClaimed || alreadyClaimed else {
            throw JobStoreError.invalidTransition
        }
        SmokeCheckpoint.hit(.deleteClaim)
        let result = try await RecoveryRetentionService(
            directory: recoveryDirectory, store: store, ledger: store
        )
            .purgeClaim(id: id)
        guard result.deletedJobIDs.contains(id) else { throw JobStoreError.invalidTransition }
        try await refresh()
    }

    func export(id: UUID, to destination: URL) async throws {
        guard let item = recoveryItems.first(where: { $0.id == id }),
              let projectedSource = item.audioURL ?? item.artifactURL else {
            throw JobStoreError.jobNotFound
        }
        if let projectedJob = item.job {
            guard let currentJob = try await store.job(id: id),
                  currentJob.source.reference == projectedJob.source.reference else {
                throw RecoveryFinalizationError.captureIdentityMismatch
            }
        } else if item.session != nil {
            guard try await store.session(id: id) != nil else {
                throw JobStoreError.jobNotFound
            }
        }
        let validator = RecoveryOwnedArtifactValidator(
            root: recoveryDirectory, id: id, fileManager: .default
        )
        let source = if item.audioURL != nil {
            validator.validAudio(projectedSource)
        } else {
            validator.validArtifact(projectedSource)
        }
        guard let source else { throw RecoveryFinalizationError.captureIdentityMismatch }
        let target = destination.standardizedFileURL
        guard source.standardizedFileURL != target else {
            throw CocoaError(.fileWriteFileExists)
        }
        let codec = CaptureSegmentCodec(fileSystem: LocalJournalFileSystem())
        let dispositions = RecoveryImportDispositionStore(directory: recoveryDirectory)
        let durableHash = try dispositions.ownedSourceHash(id: id, source: source)
            ?? item.session?.contentHash
            ?? dispositions.descriptor(id: id)?.contentHash
        let expectedHash: String
        if let durableHash {
            expectedHash = durableHash
        } else {
            expectedHash = try codec.hashFile(source)
        }
        let stillValid = item.audioURL != nil
            ? validator.validAudio(source) != nil : validator.validArtifact(source) != nil
        guard stillValid, try codec.hashFile(source) == expectedHash else {
            throw CaptureJournalError.hashMismatch(source.path)
        }
        try artifactExporter.export(
            source: source, destination: target, expectedHash: expectedHash
        )
    }

    func startNewRecording(id: UUID) -> Bool {
        guard recoveryItems.first(where: { $0.id == id })?
            .availableActions.contains(.startNewRecording) == true else { return false }
        return beginExternalRecording?() ?? false
    }

    func play(id: UUID) throws {
        guard let source = recoveryItems.first(where: { $0.id == id })?.audioURL else {
            throw JobStoreError.jobNotFound
        }
        let nextPlayer = try playbackFactory(source)
        guard nextPlayer.play() else { throw RecoveryPlaybackError.couldNotStart }
        player = nextPlayer
    }

    private func deleteLedgerOnly(_ item: RecoveryItem) async throws {
        guard let session = item.session else { throw JobStoreError.invalidTransition }
        let expectedDirectory = recoveryDirectory.appendingPathComponent(
            session.id.uuidString, isDirectory: true
        ).standardizedFileURL
        guard session.directory.standardizedFileURL == expectedDirectory,
              session.directory.resolvingSymlinksInPath().standardizedFileURL
                == recoveryDirectory.resolvingSymlinksInPath().appendingPathComponent(
                    session.id.uuidString, isDirectory: true
                ).standardizedFileURL else {
            throw RecoveryFinalizationError.captureIdentityMismatch
        }
        let diagnostics = session.directory.appendingPathComponent("capture-diagnostics.json")
        let diagnosticValues = try? diagnostics.resourceValues(
            forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
        )
        let validDiagnostics = diagnostics.resolvingSymlinksInPath().standardizedFileURL
                == expectedDirectory.appendingPathComponent("capture-diagnostics.json")
                    .standardizedFileURL
            && diagnosticValues?.isRegularFile == true
            && diagnosticValues?.isSymbolicLink != true
        guard let retained = item.artifactURL ?? item.audioURL
                ?? (validDiagnostics ? diagnostics : nil) else {
            throw CaptureJournalError.failed("Recovery has no owned artifact to dispose")
        }
        let dispositions = RecoveryImportDispositionStore(directory: recoveryDirectory)
        let descriptor = try dispositions.descriptor(
            id: item.id, source: retained, defaultScope: .capture(item.id)
        )
        try dispositions.record(descriptor)
        try await store.transition(
            id: item.id, from: session.state, to: .cancelling,
            recoveryJobID: nil, libraryDictationID: session.libraryDictationID,
            assetKind: session.assetKind, failureMessage: session.failureMessage,
            contentHash: session.contentHash
        )
        SmokeCheckpoint.hit(.deleteClaim)
        try await CaptureJournalService(
            fileSystem: LocalJournalFileSystem(), ledger: store
        ).resumeCleanup(captureID: item.id)
    }
}
