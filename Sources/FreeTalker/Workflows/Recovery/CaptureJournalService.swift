import Darwin
import Foundation

struct OwnedCapturePreparationFailure: Error, @unchecked Sendable {
    let active: ActiveCaptureJournal
    let message: String
}

struct UnresolvedCapturePreparationFailure: Error, Sendable {
    let request: CaptureStartRequest
    let message: String
}

private struct SilentSegmentOwnershipError: LocalizedError {
    let reason: String
    var errorDescription: String? { reason }
}

struct CaptureJournalService: Sendable {
    let fileSystem: any JournalFileSystem
    let ledger: any CaptureLedgerStoring
    let configuration: CaptureJournalWriter.Configuration
    let onFailure: @Sendable (String) -> Void
    let recoveryRoot: URL?

    init(
        fileSystem: any JournalFileSystem,
        ledger: any CaptureLedgerStoring,
        configuration: CaptureJournalWriter.Configuration = .default,
        recoveryRoot: URL? = nil,
        onFailure: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.fileSystem = fileSystem
        self.ledger = ledger
        self.configuration = configuration
        self.recoveryRoot = recoveryRoot?.standardizedFileURL
        self.onFailure = onFailure
    }

    func prepare(_ request: CaptureStartRequest) async throws -> ActiveCaptureJournal {
        guard request.sampleRate == Double(CaptureSegmentCodec.sampleRate),
              request.channelCount == CaptureSegmentCodec.channelCount else {
            throw CaptureJournalError.invalidAudioFormat(
                sampleRate: request.sampleRate, channelCount: request.channelCount
            )
        }
        do {
            try fileSystem.createDirectory(request.directory)
        } catch {
            // Directory creation can succeed durably and still lose its acknowledgement.
            // Compensate or persist ownership exactly like the later parent-sync boundary.
            try await compensateOrOwnFailedPrepare(request, original: error)
            throw error
        }
        do {
            try fileSystem.synchronizeDirectory(request.directory.deletingLastPathComponent())
        } catch {
            try await compensateOrOwnFailedPrepare(request, original: error)
            throw error
        }
        let session: CaptureSession
        do {
            session = try await ledger.createCapture(request)
        } catch {
            do {
                if let persisted = try await ledger.session(id: request.id) {
                    return makeActive(persisted)
                }
            } catch let readbackError {
                throw unresolvedPreparationFailure(
                    request,
                    message: "Capture commit state is unknown: \(error.localizedDescription); "
                        + readbackError.localizedDescription
                )
            }
            try await compensateOrOwnFailedPrepare(request, original: error)
            throw error
        }
        return makeActive(session)
    }

    private func makeActive(_ session: CaptureSession) -> ActiveCaptureJournal {
        let codec = CaptureSegmentCodec(fileSystem: fileSystem)
        return ActiveCaptureJournal(
            session: session,
            writer: CaptureJournalWriter(
                session: session, fileSystem: fileSystem, ledger: ledger, codec: codec,
                configuration: configuration, onFailure: onFailure
            )
        )
    }

    private func compensateFailedPrepare(_ request: CaptureStartRequest) throws {
        if fileSystem.exists(request.directory) {
            try fileSystem.remove(request.directory)
        }
        try fileSystem.synchronizeDirectory(request.directory.deletingLastPathComponent())
    }

    private func compensateOrOwnFailedPrepare(
        _ request: CaptureStartRequest,
        original: Error
    ) async throws {
        do {
            try compensateFailedPrepare(request)
            return
        } catch let cleanupError {
            let session: CaptureSession
            do {
                session = try await ledger.createCapture(request)
            } catch {
                do {
                    if let persisted = try await ledger.session(id: request.id) {
                        session = persisted
                    } else {
                        throw unresolvedPreparationFailure(
                            request,
                            message: "Capture preparation and cleanup require reconciliation: "
                                + "\(original.localizedDescription); \(cleanupError.localizedDescription)"
                        )
                    }
                } catch let unresolved as UnresolvedCapturePreparationFailure {
                    throw unresolved
                } catch let readbackError {
                    throw unresolvedPreparationFailure(
                        request,
                        message: "Capture preparation ownership is unknown: "
                            + "\(cleanupError.localizedDescription); \(readbackError.localizedDescription)"
                    )
                }
            }
            throw OwnedCapturePreparationFailure(
                active: makeActive(session),
                message: "Preparation failed and cleanup needs retry: "
                    + "\(original.localizedDescription); \(cleanupError.localizedDescription)"
            )
        }
    }

    func hasPreparationFailureEvidence(_ request: CaptureStartRequest) -> Bool {
        fileSystem.exists(preparationFailureEvidenceURL(request))
    }

    private func persistPreparationFailureEvidence(_ request: CaptureStartRequest) throws {
        let destination = preparationFailureEvidenceURL(request)
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(
            ".capture-preparation-\(request.id.uuidString).\(UUID().uuidString).tmp"
        )
        try DurableArtifactWriter(fileSystem: fileSystem).commit(
            Data("capture \(request.id.uuidString) requires reconciliation".utf8),
            temporary: temporary, destination: destination
        )
    }

    private func unresolvedPreparationFailure(
        _ request: CaptureStartRequest,
        message: String
    ) -> UnresolvedCapturePreparationFailure {
        do {
            try persistPreparationFailureEvidence(request)
            return UnresolvedCapturePreparationFailure(request: request, message: message)
        } catch {
            return UnresolvedCapturePreparationFailure(
                request: request,
                message: "\(message); recovery marker could not be persisted: "
                    + error.localizedDescription
            )
        }
    }

    private func preparationFailureEvidenceURL(_ request: CaptureStartRequest) -> URL {
        request.directory.deletingLastPathComponent().appendingPathComponent(
            ".capture-preparation-\(request.id.uuidString).marker"
        )
    }

    func finish(_ active: ActiveCaptureJournal) async throws -> StagedCapture {
        let staged = try await active.writer.finish()
        guard let contentHash = active.writer.finishedContentHash() else {
            throw CaptureJournalError.failed("canonical audio hash is unavailable")
        }
        try await ledger.transition(
            id: active.session.id, from: .capturing, to: .staged,
            recoveryJobID: nil, libraryDictationID: nil, assetKind: .audio,
            failureMessage: nil, contentHash: contentHash
        )
        return staged
    }

    func recordSilent(
        _ active: ActiveCaptureJournal,
        diagnostics: CaptureDiagnostics
    ) async throws {
        active.writer.updateDiagnostics(diagnostics)
        guard diagnostics.indicatesSilence else {
            throw CaptureJournalError.failed("capture diagnostics contain microphone signal")
        }
        await active.writer.stop()
        let diagnosticURL = silentDiagnosticsURL(active.session)
        try DurableArtifactWriter(fileSystem: fileSystem).commit(
            try JSONEncoder().encode(diagnostics),
            temporary: diagnosticURL.deletingLastPathComponent().appendingPathComponent(
                ".capture-diagnostics.\(UUID().uuidString).tmp"
            ),
            destination: diagnosticURL
        )
        try await ledger.transition(
            id: active.session.id, from: .capturing, to: .silent,
            recoveryJobID: nil, libraryDictationID: nil, assetKind: .silent,
            failureMessage: SilentCapturePresentation.message, contentHash: nil
        )
        try await removeSilentSegments(active.session)
    }

    func loadSilentDiagnostics(_ session: CaptureSession) throws -> CaptureDiagnostics {
        try JSONDecoder().decode(
            CaptureDiagnostics.self,
            from: fileSystem.read(silentDiagnosticsURL(session))
        )
    }

    private func silentDiagnosticsURL(_ session: CaptureSession) -> URL {
        session.directory.appendingPathComponent("capture-diagnostics.json")
    }

    func resumeSilentCleanup(captureID: UUID) async throws {
        guard let session = try await ledger.session(id: captureID) else { return }
        guard session.state == .silent else {
            throw CaptureJournalError.cleanupNotPermitted(session.state.rawValue)
        }
        try await removeSilentSegments(session)
    }

    private func removeSilentSegments(_ session: CaptureSession) async throws {
        let segments = try await ledger.committedSegments(captureID: session.id)
        try validateSilentSegmentOwnership(session: session, segments: segments)
        for segment in segments {
            if fileSystem.exists(segment.url) { try fileSystem.remove(segment.url) }
        }
        try fileSystem.synchronizeDirectory(session.directory)
        try await ledger.removeCommittedSegments(captureID: session.id)
    }

    private func validateSilentSegmentOwnership(
        session: CaptureSession,
        segments: [CaptureSegment]
    ) throws {
        guard let recoveryRoot else {
            throw SilentSegmentOwnershipError(
                reason: "Silent segment cleanup has no recovery root"
            )
        }
        let lexicalRoot = recoveryRoot.standardizedFileURL
        let resolvedRoot = lexicalRoot.resolvingSymlinksInPath().standardizedFileURL
        let expectedLexicalDirectory = lexicalRoot.appendingPathComponent(
            session.id.uuidString, isDirectory: true
        ).standardizedFileURL
        let expectedResolvedDirectory = resolvedRoot.appendingPathComponent(
            session.id.uuidString, isDirectory: true
        ).standardizedFileURL
        let lexicalDirectory = session.directory.standardizedFileURL
        guard lexicalDirectory == expectedLexicalDirectory,
              lexicalDirectory.resolvingSymlinksInPath().standardizedFileURL
                == expectedResolvedDirectory else {
            throw SilentSegmentOwnershipError(
                reason: "Silent capture directory is outside its owned recovery path"
            )
        }
        try requireDirectoryWithoutSymlink(lexicalDirectory)

        for segment in segments {
            let lexical = segment.url.standardizedFileURL
            let expectedName = String(format: "segment-%08d.wav", segment.ordinal)
            guard segment.captureID == session.id,
                  segment.ordinal >= 0,
                  lexical.deletingLastPathComponent() == expectedLexicalDirectory,
                  lexical.lastPathComponent == expectedName,
                  lexical.resolvingSymlinksInPath().standardizedFileURL
                    == expectedResolvedDirectory.appendingPathComponent(expectedName)
                        .standardizedFileURL else {
                throw SilentSegmentOwnershipError(
                    reason: "Silent capture segment is outside its owned recovery path"
                )
            }
            try requireRegularFileWithoutSymlinkIfPresent(lexical)
        }
    }

    private func requireDirectoryWithoutSymlink(_ url: URL) throws {
        var info = stat()
        guard lstat(url.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR else {
            throw SilentSegmentOwnershipError(
                reason: "Silent capture directory is not an owned directory"
            )
        }
    }

    private func requireRegularFileWithoutSymlinkIfPresent(_ url: URL) throws {
        var info = stat()
        if lstat(url.path, &info) != 0 {
            if errno == ENOENT { return }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        guard (info.st_mode & S_IFMT) == S_IFREG else {
            throw SilentSegmentOwnershipError(
                reason: "Silent capture segment is not a regular file"
            )
        }
    }

    func cancelAndClean(_ active: ActiveCaptureJournal) async throws {
        await active.writer.stop()
        guard let current = try await ledger.session(id: active.session.id) else { return }
        try await cancelAndClean(session: current)
    }

    func preserveFailure(_ active: ActiveCaptureJournal, message: String) async throws {
        await active.writer.stop()
        guard let current = try await ledger.session(id: active.session.id) else {
            throw CaptureJournalError.missingCapture(active.session.id)
        }
        guard current.state != .damaged else { return }
        try await ledger.transition(
            id: current.id, from: current.state, to: .damaged,
            recoveryJobID: current.recoveryJobID,
            libraryDictationID: current.libraryDictationID,
            assetKind: .damaged, failureMessage: message,
            contentHash: current.contentHash
        )
    }

    func markProcessing(captureID: UUID, recoveryJobID: UUID) async throws {
        guard let session = try await ledger.session(id: captureID) else {
            throw CaptureJournalError.missingCapture(captureID)
        }
        try await ledger.transition(
            id: captureID, from: .staged, to: .processing,
            recoveryJobID: recoveryJobID, libraryDictationID: session.libraryDictationID,
            assetKind: session.assetKind, failureMessage: session.failureMessage,
            contentHash: session.contentHash
        )
    }

    func markLibraryCommitted(captureID: UUID, dictationID: Int64) async throws {
        guard let session = try await ledger.session(id: captureID) else {
            throw CaptureJournalError.missingCapture(captureID)
        }
        try await ledger.transition(
            id: captureID, from: .processing, to: .libraryCommitted,
            recoveryJobID: session.recoveryJobID, libraryDictationID: dictationID,
            assetKind: session.assetKind, failureMessage: session.failureMessage,
            contentHash: session.contentHash
        )
        SmokeCheckpoint.hit(.postLibraryCommitted)
    }

    func resumeCleanup(captureID: UUID) async throws {
        guard let session = try await ledger.session(id: captureID) else { return }
        guard session.state == .cancelling || session.state == .libraryCommitted else {
            throw CaptureJournalError.cleanupNotPermitted(session.state.rawValue)
        }
        try await cancelAndClean(session: session)
    }

    private func cancelAndClean(session: CaptureSession) async throws {
        if session.state != .cancelling {
            try await ledger.transition(
                id: session.id, from: session.state, to: .cancelling,
                recoveryJobID: session.recoveryJobID,
                libraryDictationID: session.libraryDictationID,
                assetKind: session.assetKind, failureMessage: session.failureMessage,
                contentHash: session.contentHash
            )
            SmokeCheckpoint.hit(.cancelIntent)
        }
        if fileSystem.exists(session.directory) {
            try fileSystem.remove(session.directory)
        }
        try fileSystem.synchronizeDirectory(session.directory.deletingLastPathComponent())
        try await ledger.removeCleanedSession(id: session.id)
    }
}
