import Foundation

struct CaptureJournalService: Sendable {
    let fileSystem: any JournalFileSystem
    let ledger: any CaptureLedgerStoring
    let configuration: CaptureJournalWriter.Configuration
    let onFailure: @Sendable (String) -> Void

    init(
        fileSystem: any JournalFileSystem,
        ledger: any CaptureLedgerStoring,
        configuration: CaptureJournalWriter.Configuration = .default,
        onFailure: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.fileSystem = fileSystem
        self.ledger = ledger
        self.configuration = configuration
        self.onFailure = onFailure
    }

    func prepare(_ request: CaptureStartRequest) async throws -> ActiveCaptureJournal {
        guard request.sampleRate == Double(CaptureSegmentCodec.sampleRate),
              request.channelCount == CaptureSegmentCodec.channelCount else {
            throw CaptureJournalError.invalidAudioFormat(
                sampleRate: request.sampleRate, channelCount: request.channelCount
            )
        }
        try fileSystem.createDirectory(request.directory)
        try fileSystem.synchronizeDirectory(request.directory.deletingLastPathComponent())
        let session = try await ledger.createCapture(request)
        let codec = CaptureSegmentCodec(fileSystem: fileSystem)
        return ActiveCaptureJournal(
            session: session,
            writer: CaptureJournalWriter(
                session: session, fileSystem: fileSystem, ledger: ledger, codec: codec,
                configuration: configuration, onFailure: onFailure
            )
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
        try await ledger.transition(
            id: active.session.id, from: .capturing, to: .silent,
            recoveryJobID: nil, libraryDictationID: nil, assetKind: .silent,
            failureMessage: diagnostics.routeFailure, contentHash: nil
        )
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
        }
        if fileSystem.exists(session.directory) {
            try fileSystem.remove(session.directory)
        }
        try fileSystem.synchronizeDirectory(session.directory.deletingLastPathComponent())
        try await ledger.removeCleanedSession(id: session.id)
    }
}
