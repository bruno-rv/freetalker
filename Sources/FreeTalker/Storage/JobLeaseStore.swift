import CSQLite
import Foundation

extension TranscriptionJobStore: LeasedTranscriptionJobStoring {
    func claimQueuedJob(_ id: UUID, kind: JobKind?, owner: UUID, leaseDuration: TimeInterval) throws -> TranscriptionJob {
        let statement = try leasePrepare("""
        UPDATE transcription_jobs
        SET state = 'processing', failure_stage = 'preparing', failure_message = NULL,
            lease_owner = ?, lease_expires_at = ?, started_at = COALESCE(started_at, ?), updated_at = ?
        WHERE id = ? AND state = 'queued' AND deletion_claimed_at IS NULL
          AND (? IS NULL OR kind = ?);
        """)
        defer { sqlite3_finalize(statement) }
        let now = clock.now.timeIntervalSince1970
        leaseBind(owner.uuidString, 1, statement); sqlite3_bind_double(statement, 2, now + max(1, leaseDuration))
        sqlite3_bind_double(statement, 3, now); sqlite3_bind_double(statement, 4, now); leaseBind(id.uuidString, 5, statement)
        if let kind { leaseBind(kind.rawValue, 6, statement); leaseBind(kind.rawValue, 7, statement) } else { sqlite3_bind_null(statement, 6); sqlite3_bind_null(statement, 7) }
        try leaseStep(statement)
        guard sqlite3_changes(handle) == 1, let value = try job(id: id) else { throw JobStoreError.invalidTransition }
        return value
    }

    func renewLease(_ id: UUID, owner: UUID, leaseDuration: TimeInterval) throws {
        let statement = try leasePrepare("UPDATE transcription_jobs SET lease_expires_at = ?, updated_at = ? WHERE id = ? AND state = 'processing' AND lease_owner = ? AND lease_expires_at > ? AND deletion_claimed_at IS NULL;")
        defer { sqlite3_finalize(statement) }; let now = clock.now.timeIntervalSince1970
        sqlite3_bind_double(statement, 1, now + max(1, leaseDuration)); sqlite3_bind_double(statement, 2, now)
        leaseBind(id.uuidString, 3, statement); leaseBind(owner.uuidString, 4, statement); sqlite3_bind_double(statement, 5, now); try leaseStep(statement)
        guard sqlite3_changes(handle) == 1 else { throw JobStoreError.leaseLost }
    }

    func transitionOwned(_ id: UUID, owner: UUID, to state: JobState) throws {
        guard state.kind != .queued && state.kind != .processing else { throw JobStoreError.invalidTransition }
        let statement = try leasePrepare("""
        UPDATE transcription_jobs SET state = ?, failure_stage = ?, failure_message = ?,
            updated_at = ?, completed_at = ?, lease_owner = NULL, lease_expires_at = NULL
        WHERE id = ? AND state = 'processing' AND lease_owner = ? AND lease_expires_at > ?
          AND deletion_claimed_at IS NULL;
        """)
        defer { sqlite3_finalize(statement) }; let now = clock.now.timeIntervalSince1970
        leaseBind(state.kind.rawValue, 1, statement)
        if case .failed(let failure) = state { leaseBind(failure.stage.rawValue, 2, statement); leaseBind(failure.message, 3, statement) }
        else { sqlite3_bind_null(statement, 2); sqlite3_bind_null(statement, 3) }
        sqlite3_bind_double(statement, 4, now); sqlite3_bind_double(statement, 5, now)
        leaseBind(id.uuidString, 6, statement); leaseBind(owner.uuidString, 7, statement); sqlite3_bind_double(statement, 8, now); try leaseStep(statement)
        guard sqlite3_changes(handle) == 1 else { throw JobStoreError.leaseLost }
    }

    func recoverStaleJobs(kind: JobKind? = nil) throws -> Int {
        let statement = try leasePrepare("""
        UPDATE transcription_jobs SET state = 'queued', failure_stage = NULL, failure_message = NULL,
            lease_owner = NULL, lease_expires_at = NULL, updated_at = ?, completed_at = NULL
        WHERE state = 'processing' AND deletion_claimed_at IS NULL
          AND (lease_owner IS NULL OR lease_expires_at <= ?)
          AND (? IS NULL OR kind = ?);
        """)
        defer { sqlite3_finalize(statement) }; let now = clock.now.timeIntervalSince1970
        sqlite3_bind_double(statement, 1, now); sqlite3_bind_double(statement, 2, now)
        if let kind { leaseBind(kind.rawValue, 3, statement); leaseBind(kind.rawValue, 4, statement) } else { sqlite3_bind_null(statement, 3); sqlite3_bind_null(statement, 4) }
        try leaseStep(statement); return Int(sqlite3_changes(handle))
    }

    func assertLease(jobID: UUID, owner: UUID) throws {
        let statement = try leasePrepare("SELECT COUNT(*) FROM transcription_jobs WHERE id = ? AND state = 'processing' AND lease_owner = ? AND lease_expires_at > ? AND deletion_claimed_at IS NULL;")
        defer { sqlite3_finalize(statement) }; leaseBind(jobID.uuidString, 1, statement); leaseBind(owner.uuidString, 2, statement); sqlite3_bind_double(statement, 3, clock.now.timeIntervalSince1970)
        guard sqlite3_step(statement) == SQLITE_ROW, sqlite3_column_int(statement, 0) == 1 else { throw JobStoreError.leaseLost }
    }

    private func leasePrepare(_ sql: String) throws -> OpaquePointer { var statement: OpaquePointer?; guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw DatabaseError.sqlFailed(String(cString: sqlite3_errmsg(handle))) }; return statement }
    private func leaseStep(_ statement: OpaquePointer) throws { guard sqlite3_step(statement) == SQLITE_DONE else { throw DatabaseError.sqlFailed(String(cString: sqlite3_errmsg(handle))) } }
    private func leaseBind(_ value: String, _ index: Int32, _ statement: OpaquePointer) { sqlite3_bind_text(statement, index, value, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
}
