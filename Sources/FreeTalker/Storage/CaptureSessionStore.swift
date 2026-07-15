import CSQLite
import Foundation

protocol CaptureLedgerStoring: Sendable {
    func createCapture(_ request: CaptureStartRequest) async throws -> CaptureSession
    func recordCommittedSegment(_ segment: CaptureSegment) async throws
    func transition(
        id: UUID,
        from: CaptureSessionState,
        to: CaptureSessionState,
        recoveryJobID: UUID?,
        libraryDictationID: Int64?,
        assetKind: RecoveryAssetKind,
        failureMessage: String?,
        contentHash: String?
    ) async throws
    func session(id: UUID) async throws -> CaptureSession?
    func unfinishedSessions() async throws -> [CaptureSession]
    func committedSegments(captureID: UUID) async throws -> [CaptureSegment]
    func removeCleanedSession(id: UUID) async throws
}

extension TranscriptionJobStore: CaptureLedgerStoring {
    func createCapture(_ request: CaptureStartRequest) throws -> CaptureSession {
        let statement = try capturePrepare("""
        INSERT INTO capture_sessions
            (id, state, directory, captured_at, sample_rate, channel_count,
             input_device_uid, destination, asset_kind)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(id) DO NOTHING;
        """)
        defer { sqlite3_finalize(statement) }
        captureBind(request.id.uuidString, at: 1, in: statement)
        captureBind(CaptureSessionState.capturing.rawValue, at: 2, in: statement)
        captureBind(request.directory.path, at: 3, in: statement)
        sqlite3_bind_double(statement, 4, request.capturedAt.timeIntervalSince1970)
        sqlite3_bind_double(statement, 5, request.sampleRate)
        sqlite3_bind_int64(statement, 6, Int64(request.channelCount))
        captureBind(request.inputDeviceUID, at: 7, in: statement)
        captureBind(request.destination, at: 8, in: statement)
        captureBind(RecoveryAssetKind.audio.rawValue, at: 9, in: statement)
        try captureStepDone(statement)

        guard let stored = try session(id: request.id) else {
            throw JobStoreError.corruptData("Created capture session is missing")
        }
        let expected = CaptureSession(
            id: request.id, state: .capturing, directory: request.directory,
            capturedAt: request.capturedAt, sampleRate: request.sampleRate,
            channelCount: request.channelCount, inputDeviceUID: request.inputDeviceUID,
            destination: request.destination, recoveryJobID: nil, libraryDictationID: nil,
            assetKind: .audio, failureMessage: nil, contentHash: nil
        )
        guard stored.id == expected.id,
              stored.state == expected.state,
              stored.directory.standardizedFileURL.path == expected.directory.standardizedFileURL.path,
              abs(stored.capturedAt.timeIntervalSince1970 - expected.capturedAt.timeIntervalSince1970) < 0.000_001,
              stored.sampleRate == expected.sampleRate,
              stored.channelCount == expected.channelCount,
              stored.inputDeviceUID == expected.inputDeviceUID,
              stored.destination == expected.destination,
              stored.recoveryJobID == nil,
              stored.libraryDictationID == nil,
              stored.assetKind == .audio,
              stored.failureMessage == nil,
              stored.contentHash == nil else { throw JobStoreError.invalidTransition }
        return stored
    }

    func recordCommittedSegment(_ segment: CaptureSegment) throws {
        let statement = try capturePrepare("""
        INSERT INTO capture_segments (capture_id, ordinal, path, sample_count, content_hash)
        VALUES (?, ?, ?, ?, ?)
        ON CONFLICT(capture_id, ordinal) DO NOTHING;
        """)
        defer { sqlite3_finalize(statement) }
        captureBind(segment.captureID.uuidString, at: 1, in: statement)
        sqlite3_bind_int64(statement, 2, Int64(segment.ordinal))
        captureBind(segment.url.path, at: 3, in: statement)
        sqlite3_bind_int64(statement, 4, Int64(segment.sampleCount))
        captureBind(segment.contentHash, at: 5, in: statement)
        try captureStepDone(statement)

        guard try committedSegments(captureID: segment.captureID)
            .first(where: { $0.ordinal == segment.ordinal }) == segment else {
            throw JobStoreError.invalidTransition
        }
    }

    func transition(
        id: UUID,
        from: CaptureSessionState,
        to: CaptureSessionState,
        recoveryJobID: UUID?,
        libraryDictationID: Int64?,
        assetKind: RecoveryAssetKind,
        failureMessage: String?,
        contentHash: String?
    ) throws {
        guard Self.isLegalCaptureTransition(from: from, to: to) else {
            throw JobStoreError.invalidTransition
        }
        if from == to {
            guard try transitionMatchesPersistedSession(
                id: id, state: to, recoveryJobID: recoveryJobID,
                libraryDictationID: libraryDictationID, assetKind: assetKind,
                failureMessage: failureMessage, contentHash: contentHash
            ) else { throw JobStoreError.invalidTransition }
            return
        }
        let statement = try capturePrepare("""
        UPDATE capture_sessions
        SET state = ?, recovery_job_id = ?, library_dictation_id = ?, asset_kind = ?,
            failure_message = ?, content_hash = ?
        WHERE id = ? AND state = ?;
        """)
        defer { sqlite3_finalize(statement) }
        captureBind(to.rawValue, at: 1, in: statement)
        captureBind(recoveryJobID?.uuidString, at: 2, in: statement)
        if let libraryDictationID {
            sqlite3_bind_int64(statement, 3, libraryDictationID)
        } else {
            sqlite3_bind_null(statement, 3)
        }
        captureBind(assetKind.rawValue, at: 4, in: statement)
        captureBind(failureMessage, at: 5, in: statement)
        captureBind(contentHash, at: 6, in: statement)
        captureBind(id.uuidString, at: 7, in: statement)
        captureBind(from.rawValue, at: 8, in: statement)
        try captureStepDone(statement)
        if sqlite3_changes(handle) == 0 {
            guard try transitionMatchesPersistedSession(
                id: id, state: to, recoveryJobID: recoveryJobID,
                libraryDictationID: libraryDictationID, assetKind: assetKind,
                failureMessage: failureMessage, contentHash: contentHash
            ) else { throw JobStoreError.invalidTransition }
        }
    }

    private func transitionMatchesPersistedSession(
        id: UUID,
        state: CaptureSessionState,
        recoveryJobID: UUID?,
        libraryDictationID: Int64?,
        assetKind: RecoveryAssetKind,
        failureMessage: String?,
        contentHash: String?
    ) throws -> Bool {
        guard let persisted = try session(id: id) else { return false }
        return persisted.state == state
            && persisted.recoveryJobID == recoveryJobID
            && persisted.libraryDictationID == libraryDictationID
            && persisted.assetKind == assetKind
            && persisted.failureMessage == failureMessage
            && persisted.contentHash == contentHash
    }

    func session(id: UUID) throws -> CaptureSession? {
        let statement = try capturePrepare("""
        SELECT id, state, directory, captured_at, sample_rate, channel_count,
               input_device_uid, destination, recovery_job_id, library_dictation_id,
               asset_kind, failure_message, content_hash
        FROM capture_sessions WHERE id = ?;
        """)
        defer { sqlite3_finalize(statement) }
        captureBind(id.uuidString, at: 1, in: statement)
        switch sqlite3_step(statement) {
        case SQLITE_ROW: return try decodeCaptureSession(statement)
        case SQLITE_DONE: return nil
        default: throw captureSQLError()
        }
    }

    func unfinishedSessions() throws -> [CaptureSession] {
        let statement = try capturePrepare("""
        SELECT id, state, directory, captured_at, sample_rate, channel_count,
               input_device_uid, destination, recovery_job_id, library_dictation_id,
               asset_kind, failure_message, content_hash
        FROM capture_sessions ORDER BY captured_at, id;
        """)
        defer { sqlite3_finalize(statement) }
        var sessions: [CaptureSession] = []
        var result = sqlite3_step(statement)
        while result == SQLITE_ROW {
            sessions.append(try decodeCaptureSession(statement))
            result = sqlite3_step(statement)
        }
        guard result == SQLITE_DONE else { throw captureSQLError() }
        return sessions
    }

    func committedSegments(captureID: UUID) throws -> [CaptureSegment] {
        let statement = try capturePrepare("""
        SELECT capture_id, ordinal, path, sample_count, content_hash
        FROM capture_segments WHERE capture_id = ? ORDER BY ordinal;
        """)
        defer { sqlite3_finalize(statement) }
        captureBind(captureID.uuidString, at: 1, in: statement)
        var segments: [CaptureSegment] = []
        var result = sqlite3_step(statement)
        while result == SQLITE_ROW {
            guard let id = UUID(uuidString: captureText(statement, 0)) else {
                throw JobStoreError.corruptData("Invalid capture segment identity")
            }
            segments.append(CaptureSegment(
                captureID: id, ordinal: Int(sqlite3_column_int64(statement, 1)),
                url: URL(fileURLWithPath: captureText(statement, 2)),
                sampleCount: Int(sqlite3_column_int64(statement, 3)),
                contentHash: captureText(statement, 4)
            ))
            result = sqlite3_step(statement)
        }
        guard result == SQLITE_DONE else { throw captureSQLError() }
        return segments
    }

    func removeCleanedSession(id: UUID) throws {
        let statement = try capturePrepare("""
        DELETE FROM capture_sessions
        WHERE id = ? AND state IN ('library_committed', 'cancelling');
        """)
        defer { sqlite3_finalize(statement) }
        captureBind(id.uuidString, at: 1, in: statement)
        try captureStepDone(statement)
        guard sqlite3_changes(handle) == 0 else { return }
        guard try session(id: id) == nil else { throw JobStoreError.invalidTransition }
    }

    private static func isLegalCaptureTransition(
        from: CaptureSessionState, to: CaptureSessionState
    ) -> Bool {
        if from == to { return true }
        return switch (from, to) {
        case (.capturing, .staged), (.capturing, .silent),
             (.capturing, .damaged), (.capturing, .cancelling),
             (.capturing, .libraryCommitted),
             (.staged, .processing), (.staged, .damaged), (.staged, .cancelling),
             (.staged, .libraryCommitted),
             (.processing, .libraryCommitted), (.processing, .damaged),
             (.processing, .cancelling), (.damaged, .cancelling),
             (.damaged, .libraryCommitted), (.silent, .cancelling),
             (.silent, .libraryCommitted), (.libraryCommitted, .cancelling): true
        default: false
        }
    }

    private func decodeCaptureSession(_ statement: OpaquePointer) throws -> CaptureSession {
        guard let id = UUID(uuidString: captureText(statement, 0)),
              let state = CaptureSessionState(rawValue: captureText(statement, 1)),
              let assetKind = RecoveryAssetKind(rawValue: captureText(statement, 10)) else {
            throw JobStoreError.corruptData("Invalid capture session identity or enum encoding")
        }
        let recoveryJobID: UUID?
        if let rawRecoveryID = captureOptionalText(statement, 8) {
            guard let parsed = UUID(uuidString: rawRecoveryID) else {
                throw JobStoreError.corruptData("Invalid capture recovery job identity")
            }
            recoveryJobID = parsed
        } else {
            recoveryJobID = nil
        }
        return CaptureSession(
            id: id, state: state,
            directory: URL(fileURLWithPath: captureText(statement, 2)),
            capturedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 3)),
            sampleRate: sqlite3_column_double(statement, 4),
            channelCount: Int(sqlite3_column_int64(statement, 5)),
            inputDeviceUID: captureOptionalText(statement, 6),
            destination: captureText(statement, 7), recoveryJobID: recoveryJobID,
            libraryDictationID: sqlite3_column_type(statement, 9) == SQLITE_NULL
                ? nil : sqlite3_column_int64(statement, 9),
            assetKind: assetKind, failureMessage: captureOptionalText(statement, 11),
            contentHash: captureOptionalText(statement, 12)
        )
    }

    private func capturePrepare(_ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else { throw captureSQLError() }
        return statement
    }

    private func captureStepDone(_ statement: OpaquePointer) throws {
        guard sqlite3_step(statement) == SQLITE_DONE else { throw captureSQLError() }
    }

    private func captureBind(_ value: String?, at index: Int32, in statement: OpaquePointer) {
        guard let value else { sqlite3_bind_null(statement, index); return }
        sqlite3_bind_text(statement, index, value, -1, Self.captureSQLiteTransient)
    }

    private func captureText(_ statement: OpaquePointer, _ index: Int32) -> String {
        String(cString: sqlite3_column_text(statement, index))
    }

    private func captureOptionalText(_ statement: OpaquePointer, _ index: Int32) -> String? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
        return captureText(statement, index)
    }

    private func captureSQLError() -> DatabaseError {
        .sqlFailed(String(cString: sqlite3_errmsg(handle)))
    }

    private static let captureSQLiteTransient = unsafeBitCast(
        -1, to: sqlite3_destructor_type.self
    )
}
