import CSQLite
import Foundation

extension TranscriptionJobStore: RecoveryLeaseStoring {
    func deleteCommittedRecovery(id: UUID, expectedSourceReference: String) throws -> Bool {
        let statement = try recoveryLeasePrepare("""
        DELETE FROM transcription_jobs
        WHERE id = ? AND kind = 'recovery' AND source_reference = ?;
        """)
        defer { sqlite3_finalize(statement) }
        recoveryLeaseBind(id.uuidString, 1, statement)
        recoveryLeaseBind(expectedSourceReference, 2, statement)
        try recoveryLeaseStep(statement)
        return sqlite3_changes(handle) == 1
    }

    /// `configuration.voiceCommandsEnabled`/`commandKeywords`, when the caller leaves them `nil`,
    /// COALESCE against the JOB's own durable snapshot columns in the same INSERT — mirrors
    /// `TranscriptionJobStore.beginAttempt`. Startup recovery (leased processing) must inherit the
    /// job's snapshot exactly like the manual/automatic retry paths do, or an interrupted-then-
    /// resumed attempt silently drops the stop-time policy. See PLAN.md PR A, item 1b.
    func beginOwnedAttempt(jobID: UUID, owner: UUID, configuration: AttemptConfiguration) throws -> JobAttempt {
        let statement = try recoveryLeasePrepare("""
        INSERT INTO job_attempts
            (job_id, attempt_number, started_at, language, speech_model, template,
             voice_commands_enabled, command_keywords)
        SELECT ?, COALESCE((SELECT MAX(attempt_number) FROM job_attempts WHERE job_id = ?), 0) + 1, ?, ?, ?, ?,
               COALESCE(?, voice_commands_enabled), COALESCE(?, command_keywords)
        FROM transcription_jobs WHERE id = ? AND state = 'processing' AND lease_owner = ?
          AND lease_expires_at > ? AND deletion_claimed_at IS NULL AND purge_claimed_at IS NULL;
        """)
        defer { sqlite3_finalize(statement) }; let now = clock.now.timeIntervalSince1970
        recoveryLeaseBind(jobID.uuidString, 1, statement); recoveryLeaseBind(jobID.uuidString, 2, statement); sqlite3_bind_double(statement, 3, now)
        recoveryLeaseBindOptional(configuration.language, 4, statement); recoveryLeaseBindOptional(configuration.speechModel, 5, statement); recoveryLeaseBindOptional(configuration.template, 6, statement)
        if let voiceCommandsEnabled = configuration.voiceCommandsEnabled {
            sqlite3_bind_int(statement, 7, voiceCommandsEnabled ? 1 : 0)
        } else {
            sqlite3_bind_null(statement, 7)
        }
        recoveryLeaseBindOptional(configuration.commandKeywords?.joined(separator: ","), 8, statement)
        recoveryLeaseBind(jobID.uuidString, 9, statement); recoveryLeaseBind(owner.uuidString, 10, statement); sqlite3_bind_double(statement, 11, now); try recoveryLeaseStep(statement)
        guard sqlite3_changes(handle) == 1, let attempt = try latestUnfinishedAttempt(jobID: jobID) else { throw JobStoreError.leaseLost }
        return attempt
    }

    func advanceOwnedStage(jobID: UUID, owner: UUID, stage: JobStage) throws {
        let statement = try recoveryLeasePrepare("UPDATE transcription_jobs SET failure_stage = ?, updated_at = ? WHERE id = ? AND kind = 'recovery' AND state = 'processing' AND lease_owner = ? AND lease_expires_at > ? AND deletion_claimed_at IS NULL;")
        defer { sqlite3_finalize(statement) }; let now = clock.now.timeIntervalSince1970
        recoveryLeaseBind(stage.rawValue, 1, statement); sqlite3_bind_double(statement, 2, now); recoveryLeaseBind(jobID.uuidString, 3, statement); recoveryLeaseBind(owner.uuidString, 4, statement); sqlite3_bind_double(statement, 5, now)
        try recoveryLeaseStep(statement); guard sqlite3_changes(handle) == 1 else { throw JobStoreError.leaseLost }
    }

    func finishOwnedAttempt(jobID: UUID, owner: UUID, attemptID: Int64, result: AttemptResult) throws {
        let statement = try recoveryLeasePrepare("UPDATE job_attempts SET completed_at = ?, result = ?, failure_stage = ?, failure_message = ? WHERE id = ? AND job_id = ? AND completed_at IS NULL AND EXISTS (SELECT 1 FROM transcription_jobs WHERE id = ? AND state = 'processing' AND lease_owner = ? AND lease_expires_at > ? AND deletion_claimed_at IS NULL);")
        defer { sqlite3_finalize(statement) }; let now = clock.now.timeIntervalSince1970
        sqlite3_bind_double(statement, 1, now)
        let failure: JobFailure? = { if case .failed(let value) = result { value } else { nil } }()
        recoveryLeaseBind(failure == nil ? "succeeded" : "failed", 2, statement)
        if let failure { recoveryLeaseBind(failure.stage.rawValue, 3, statement); recoveryLeaseBind(failure.message, 4, statement) } else { sqlite3_bind_null(statement, 3); sqlite3_bind_null(statement, 4) }
        sqlite3_bind_int64(statement, 5, attemptID); recoveryLeaseBind(jobID.uuidString, 6, statement); recoveryLeaseBind(jobID.uuidString, 7, statement); recoveryLeaseBind(owner.uuidString, 8, statement); sqlite3_bind_double(statement, 9, now)
        try recoveryLeaseStep(statement); guard sqlite3_changes(handle) == 1 else { throw JobStoreError.leaseLost }
    }

    func completeOwnedAttemptAndJob(jobID: UUID, owner: UUID, attemptID: Int64) throws {
        try ownedAttemptTransaction(jobID: jobID, owner: owner, attemptID: attemptID, failure: nil)
    }

    func failOwnedAttemptAndJob(jobID: UUID, owner: UUID, attemptID: Int64, failure: JobFailure) throws {
        try ownedAttemptTransaction(jobID: jobID, owner: owner, attemptID: attemptID, failure: failure)
    }

    private func ownedAttemptTransaction(jobID: UUID, owner: UUID, attemptID: Int64, failure: JobFailure?) throws {
        try recoveryLeaseExecute("BEGIN IMMEDIATE;")
        do {
            try assertLease(jobID: jobID, owner: owner)
            let attempt = try recoveryLeasePrepare("UPDATE job_attempts SET completed_at = ?, result = ?, failure_stage = ?, failure_message = ? WHERE id = ? AND job_id = ? AND completed_at IS NULL;")
            defer { sqlite3_finalize(attempt) }; let now = clock.now.timeIntervalSince1970
            sqlite3_bind_double(attempt, 1, now); recoveryLeaseBind(failure == nil ? "succeeded" : "failed", 2, attempt)
            if let failure { recoveryLeaseBind(failure.stage.rawValue, 3, attempt); recoveryLeaseBind(failure.message, 4, attempt) } else { sqlite3_bind_null(attempt, 3); sqlite3_bind_null(attempt, 4) }
            sqlite3_bind_int64(attempt, 5, attemptID); recoveryLeaseBind(jobID.uuidString, 6, attempt); try recoveryLeaseStep(attempt)
            guard sqlite3_changes(handle) == 1 else { throw JobStoreError.attemptNotFound }
            let job = try recoveryLeasePrepare("UPDATE transcription_jobs SET state = ?, failure_stage = ?, failure_message = ?, updated_at = ?, completed_at = ?, needs_source_cleanup = ?, source_cleanup_error = NULL, lease_owner = NULL, lease_expires_at = NULL WHERE id = ? AND kind = 'recovery' AND state = 'processing' AND lease_owner = ? AND lease_expires_at > ? AND purge_claimed_at IS NULL;")
            defer { sqlite3_finalize(job) }
            recoveryLeaseBind(failure == nil ? "ready" : "failed", 1, job)
            if let failure { recoveryLeaseBind(failure.stage.rawValue, 2, job); recoveryLeaseBind(failure.message, 3, job) } else { sqlite3_bind_null(job, 2); sqlite3_bind_null(job, 3) }
            sqlite3_bind_double(job, 4, now); sqlite3_bind_double(job, 5, now); sqlite3_bind_int(job, 6, failure == nil ? 1 : 0)
            recoveryLeaseBind(jobID.uuidString, 7, job); recoveryLeaseBind(owner.uuidString, 8, job); sqlite3_bind_double(job, 9, now); try recoveryLeaseStep(job)
            guard sqlite3_changes(handle) == 1 else { throw JobStoreError.leaseLost }
            try recoveryLeaseExecute("COMMIT;")
        } catch { try? recoveryLeaseExecute("ROLLBACK;"); throw error }
    }

    private func recoveryLeasePrepare(_ sql: String) throws -> OpaquePointer { var statement: OpaquePointer?; guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw DatabaseError.sqlFailed(String(cString: sqlite3_errmsg(handle))) }; return statement }
    private func recoveryLeaseStep(_ statement: OpaquePointer) throws { guard sqlite3_step(statement) == SQLITE_DONE else { throw DatabaseError.sqlFailed(String(cString: sqlite3_errmsg(handle))) } }
    private func recoveryLeaseExecute(_ sql: String) throws { guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else { throw DatabaseError.sqlFailed(String(cString: sqlite3_errmsg(handle))) } }
    private func recoveryLeaseBind(_ value: String, _ index: Int32, _ statement: OpaquePointer) { sqlite3_bind_text(statement, index, value, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
    private func recoveryLeaseBindOptional(_ value: String?, _ index: Int32, _ statement: OpaquePointer) { if let value { recoveryLeaseBind(value, index, statement) } else { sqlite3_bind_null(statement, index) } }
}
