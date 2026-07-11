import CSQLite
import Foundation

actor TranscriptionJobStore {
    private let connection: SQLiteJobConnection
    private var handle: OpaquePointer { connection.handle }
    private let clock: any JobClock

    init(databaseURL: URL, clock: any JobClock) throws {
        var database: OpaquePointer?
        guard sqlite3_open(databaseURL.path, &database) == SQLITE_OK, let database else {
            let message = database.map { String(cString: sqlite3_errmsg($0)) } ?? "Could not open database"
            sqlite3_close(database)
            throw DatabaseError.openFailed(message)
        }
        do {
            try DatabaseMigrator.migrate(database)
        } catch {
            sqlite3_close(database)
            throw error
        }
        connection = SQLiteJobConnection(handle: database)
        self.clock = clock
    }

    func create(kind: JobKind, source: JobSource, now: Date) throws -> TranscriptionJob {
        let id = UUID()
        let statement = try prepare("""
        INSERT INTO transcription_jobs
            (id, kind, source_reference, source_bookmark, state, progress, created_at, updated_at)
        VALUES (?, ?, ?, ?, ?, 0, ?, ?);
        """)
        defer { sqlite3_finalize(statement) }
        bind(id.uuidString, to: 1, in: statement)
        bind(kind.rawValue, to: 2, in: statement)
        bind(source.reference, to: 3, in: statement)
        bind(source.bookmark, to: 4, in: statement)
        bind(JobState.Kind.queued.rawValue, to: 5, in: statement)
        sqlite3_bind_double(statement, 6, now.timeIntervalSince1970)
        sqlite3_bind_double(statement, 7, now.timeIntervalSince1970)
        try stepDone(statement)
        return TranscriptionJob(
            id: id, kind: kind, source: source, state: .queued, progress: 0,
            createdAt: now, updatedAt: now, startedAt: nil, completedAt: nil,
            expiresAt: nil, result: nil, needsSourceCleanup: false, sourceCleanupError: nil
        )
    }

    func createRecovery(source: JobSource, metadata: RecoveryMetadata) throws -> TranscriptionJob {
        let id = UUID()
        let statement = try prepare("""
        INSERT INTO transcription_jobs
            (id, kind, source_reference, source_bookmark, state, progress, created_at, updated_at,
             completed_at, failure_stage, failure_message)
        VALUES (?, ?, ?, ?, ?, 0, ?, ?, ?, ?, ?);
        """)
        defer { sqlite3_finalize(statement) }
        bind(id.uuidString, to: 1, in: statement)
        bind(JobKind.recovery.rawValue, to: 2, in: statement)
        bind(source.reference, to: 3, in: statement)
        bind(source.bookmark, to: 4, in: statement)
        bind(JobState.Kind.failed.rawValue, to: 5, in: statement)
        sqlite3_bind_double(statement, 6, metadata.capturedAt.timeIntervalSince1970)
        sqlite3_bind_double(statement, 7, metadata.capturedAt.timeIntervalSince1970)
        sqlite3_bind_double(statement, 8, metadata.capturedAt.timeIntervalSince1970)
        bind(metadata.failure.stage.rawValue, to: 9, in: statement)
        bind(metadata.failure.message, to: 10, in: statement)
        try stepDone(statement)
        return TranscriptionJob(
            id: id, kind: .recovery, source: source, state: .failed(metadata.failure), progress: 0,
            createdAt: metadata.capturedAt, updatedAt: metadata.capturedAt, startedAt: nil,
            completedAt: metadata.capturedAt, expiresAt: nil, result: nil,
            needsSourceCleanup: false, sourceCleanupError: nil
        )
    }

    func claimExpiredRecoveries(cutoff: Date, claimedAt: Date) throws -> [RecoveryPurgeClaim] {
        let statement = try prepare("""
        UPDATE transcription_jobs
        SET purge_claimed_at = ?, purge_error = NULL, updated_at = ?
        WHERE kind = 'recovery' AND state = 'failed' AND purge_claimed_at IS NULL
          AND created_at <= ?
          AND NOT EXISTS (
              SELECT 1 FROM job_attempts
              WHERE job_id = transcription_jobs.id AND completed_at IS NULL
          )
        RETURNING id, source_reference, purge_claimed_at, purge_error;
        """)
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_double(statement, 1, claimedAt.timeIntervalSince1970)
        sqlite3_bind_double(statement, 2, claimedAt.timeIntervalSince1970)
        sqlite3_bind_double(statement, 3, cutoff.timeIntervalSince1970)
        return try decodeClaims(statement)
    }

    func claimedRecoveries() throws -> [RecoveryPurgeClaim] {
        let statement = try prepare("""
        SELECT id, source_reference, purge_claimed_at, purge_error
        FROM transcription_jobs
        WHERE kind = 'recovery' AND state = 'failed' AND purge_claimed_at IS NOT NULL
        ORDER BY purge_claimed_at, id;
        """)
        defer { sqlite3_finalize(statement) }
        return try decodeClaims(statement)
    }

    func recordPurgeError(id: UUID, message: String) throws {
        let statement = try prepare("""
        UPDATE transcription_jobs SET purge_error = ?
        WHERE id = ? AND kind = 'recovery' AND state = 'failed' AND purge_claimed_at IS NOT NULL;
        """)
        defer { sqlite3_finalize(statement) }
        bind(message, to: 1, in: statement)
        bind(id.uuidString, to: 2, in: statement)
        try stepDone(statement)
        guard sqlite3_changes(handle) == 1 else { throw JobStoreError.invalidTransition }
    }

    func deleteClaimedRecovery(id: UUID, expectedSourceReference: String) throws -> Bool {
        let statement = try prepare("""
        DELETE FROM transcription_jobs
        WHERE id = ? AND kind = 'recovery' AND state = 'failed'
          AND purge_claimed_at IS NOT NULL AND source_reference = ?;
        """)
        defer { sqlite3_finalize(statement) }
        bind(id.uuidString, to: 1, in: statement)
        bind(expectedSourceReference, to: 2, in: statement)
        try stepDone(statement)
        return sqlite3_changes(handle) == 1
    }

    private func isPurgeClaimed(id: UUID) throws -> Bool {
        let statement = try prepare("SELECT purge_claimed_at IS NOT NULL FROM transcription_jobs WHERE id = ?;")
        defer { sqlite3_finalize(statement) }
        bind(id.uuidString, to: 1, in: statement)
        guard sqlite3_step(statement) == SQLITE_ROW else { throw JobStoreError.jobNotFound }
        return sqlite3_column_int(statement, 0) == 1
    }

    private func decodeClaims(_ statement: OpaquePointer) throws -> [RecoveryPurgeClaim] {
        var claims: [RecoveryPurgeClaim] = []
        var result = sqlite3_step(statement)
        while result == SQLITE_ROW {
            guard let id = UUID(uuidString: text(statement, 0)), let claimedAt = date(statement, 2) else {
                throw JobStoreError.corruptData("Invalid recovery purge claim")
            }
            claims.append(RecoveryPurgeClaim(
                id: id, sourceReference: text(statement, 1), claimedAt: claimedAt,
                cleanupError: optionalText(statement, 3)
            ))
            result = sqlite3_step(statement)
        }
        guard result == SQLITE_DONE else { throw sqlError() }
        return claims
    }

    func job(id: UUID) throws -> TranscriptionJob? {
        let statement = try prepare("""
        SELECT id, kind, source_reference, source_bookmark, state, progress,
               created_at, updated_at, started_at, completed_at, expires_at,
               failure_stage, failure_message, result, needs_source_cleanup, source_cleanup_error
        FROM transcription_jobs WHERE id = ?;
        """)
        defer { sqlite3_finalize(statement) }
        bind(id.uuidString, to: 1, in: statement)
        switch sqlite3_step(statement) {
        case SQLITE_ROW: return try decodeJob(statement)
        case SQLITE_DONE: return nil
        default: throw sqlError()
        }
    }

    func jobs(kind: JobKind? = nil) throws -> [TranscriptionJob] {
        let statement: OpaquePointer
        if let kind {
            statement = try prepare("""
            SELECT id, kind, source_reference, source_bookmark, state, progress,
                   created_at, updated_at, started_at, completed_at, expires_at,
                   failure_stage, failure_message, result, needs_source_cleanup, source_cleanup_error
            FROM transcription_jobs WHERE kind = ? ORDER BY created_at, id;
            """)
            bind(kind.rawValue, to: 1, in: statement)
        } else {
            statement = try prepare("""
            SELECT id, kind, source_reference, source_bookmark, state, progress,
                   created_at, updated_at, started_at, completed_at, expires_at,
                   failure_stage, failure_message, result, needs_source_cleanup, source_cleanup_error
            FROM transcription_jobs ORDER BY created_at, id;
            """)
        }
        defer { sqlite3_finalize(statement) }
        var values: [TranscriptionJob] = []
        var result = sqlite3_step(statement)
        while result == SQLITE_ROW {
            values.append(try decodeJob(statement))
            result = sqlite3_step(statement)
        }
        guard result == SQLITE_DONE else { throw sqlError() }
        return values
    }

    func transition(_ id: UUID, from: JobState.Kind, to state: JobState) throws {
        guard Self.isLegal(from: from, to: state.kind) else { throw JobStoreError.invalidTransition }
        let now = clock.now
        let statement = try prepare("""
        UPDATE transcription_jobs
        SET state = ?, failure_stage = ?, failure_message = ?, updated_at = ?,
            started_at = CASE WHEN ? = 'processing' THEN COALESCE(started_at, ?) ELSE started_at END,
            completed_at = CASE WHEN ? IN ('ready', 'failed', 'cancelled') THEN ? ELSE NULL END
        WHERE id = ? AND state = ? AND purge_claimed_at IS NULL;
        """)
        defer { sqlite3_finalize(statement) }
        let failure = state.failure
        bind(state.kind.rawValue, to: 1, in: statement)
        bind(state.stage?.rawValue, to: 2, in: statement)
        bind(failure?.message, to: 3, in: statement)
        sqlite3_bind_double(statement, 4, now.timeIntervalSince1970)
        bind(state.kind.rawValue, to: 5, in: statement)
        sqlite3_bind_double(statement, 6, now.timeIntervalSince1970)
        bind(state.kind.rawValue, to: 7, in: statement)
        sqlite3_bind_double(statement, 8, now.timeIntervalSince1970)
        bind(id.uuidString, to: 9, in: statement)
        bind(from.rawValue, to: 10, in: statement)
        try stepDone(statement)
        guard sqlite3_changes(handle) == 1 else {
            if try job(id: id) == nil { throw JobStoreError.jobNotFound }
            throw JobStoreError.invalidTransition
        }
    }

    func beginAttempt(jobID: UUID, configuration: AttemptConfiguration) throws -> JobAttempt {
        let startedAt = clock.now
        let statement = try prepare("""
        INSERT INTO job_attempts
            (job_id, attempt_number, started_at, language, speech_model, template)
        SELECT ?,
               COALESCE((SELECT MAX(attempt_number) FROM job_attempts WHERE job_id = ?), 0) + 1,
               ?, ?, ?, ?
        FROM transcription_jobs
        WHERE id = ? AND purge_claimed_at IS NULL;
        """)
        defer { sqlite3_finalize(statement) }
        bind(jobID.uuidString, to: 1, in: statement)
        bind(jobID.uuidString, to: 2, in: statement)
        sqlite3_bind_double(statement, 3, startedAt.timeIntervalSince1970)
        bind(configuration.language, to: 4, in: statement)
        bind(configuration.speechModel, to: 5, in: statement)
        bind(configuration.template, to: 6, in: statement)
        bind(jobID.uuidString, to: 7, in: statement)
        try stepDone(statement)
        guard sqlite3_changes(handle) == 1 else {
            guard try job(id: jobID) != nil else { throw JobStoreError.jobNotFound }
            if try isPurgeClaimed(id: jobID) { throw JobStoreError.purgeClaimed }
            throw JobStoreError.invalidTransition
        }
        let id = sqlite3_last_insert_rowid(handle)
        guard let attempt = try attempt(id: id) else { throw JobStoreError.attemptNotFound }
        return attempt
    }

    private func attempt(id: Int64) throws -> JobAttempt? {
        let statement = try prepare("""
        SELECT id, job_id, attempt_number, started_at, completed_at,
               language, speech_model, template, result, failure_stage, failure_message
        FROM job_attempts WHERE id = ?;
        """)
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, id)
        switch sqlite3_step(statement) {
        case SQLITE_ROW: return try decodeAttempt(statement)
        case SQLITE_DONE: return nil
        default: throw sqlError()
        }
    }

    func finishAttempt(_ id: Int64, result: AttemptResult) throws {
        let statement = try prepare("""
        UPDATE job_attempts
        SET completed_at = ?, result = ?, failure_stage = ?, failure_message = ?
        WHERE id = ? AND completed_at IS NULL;
        """)
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_double(statement, 1, clock.now.timeIntervalSince1970)
        bind(result.encoding, to: 2, in: statement)
        bind(result.failure?.stage.rawValue, to: 3, in: statement)
        bind(result.failure?.message, to: 4, in: statement)
        sqlite3_bind_int64(statement, 5, id)
        try stepDone(statement)
        guard sqlite3_changes(handle) == 1 else { throw JobStoreError.attemptNotFound }
    }

    func latestUnfinishedAttempt(jobID: UUID) throws -> JobAttempt? {
        let statement = try prepare("""
        SELECT id, job_id, attempt_number, started_at, completed_at,
               language, speech_model, template, result, failure_stage, failure_message
        FROM job_attempts
        WHERE job_id = ? AND completed_at IS NULL
        ORDER BY attempt_number DESC LIMIT 1;
        """)
        defer { sqlite3_finalize(statement) }
        bind(jobID.uuidString, to: 1, in: statement)
        switch sqlite3_step(statement) {
        case SQLITE_ROW: return try decodeAttempt(statement)
        case SQLITE_DONE: return nil
        default: throw sqlError()
        }
    }

    func completeAttemptAndMarkJobReady(jobID: UUID, attemptID: Int64) throws {
        try execute("BEGIN IMMEDIATE;")
        do {
            do {
                let attempt = try prepare("""
                UPDATE job_attempts
                SET completed_at = ?, result = 'succeeded', failure_stage = NULL, failure_message = NULL
                WHERE id = ? AND job_id = ? AND completed_at IS NULL;
                """)
                defer { sqlite3_finalize(attempt) }
                sqlite3_bind_double(attempt, 1, clock.now.timeIntervalSince1970)
                sqlite3_bind_int64(attempt, 2, attemptID)
                bind(jobID.uuidString, to: 3, in: attempt)
                try stepDone(attempt)
                guard sqlite3_changes(handle) == 1 else { throw JobStoreError.attemptNotFound }
            }
            do {
                let job = try prepare("""
                UPDATE transcription_jobs
                SET state = 'ready', failure_stage = NULL, failure_message = NULL,
                    updated_at = ?, completed_at = ?, needs_source_cleanup = 1,
                    source_cleanup_error = NULL
                WHERE id = ? AND kind = 'recovery' AND state = 'processing'
                  AND purge_claimed_at IS NULL;
                """)
                defer { sqlite3_finalize(job) }
                sqlite3_bind_double(job, 1, clock.now.timeIntervalSince1970)
                sqlite3_bind_double(job, 2, clock.now.timeIntervalSince1970)
                bind(jobID.uuidString, to: 3, in: job)
                try stepDone(job)
                guard sqlite3_changes(handle) == 1 else { throw JobStoreError.invalidTransition }
            }
            try execute("COMMIT;")
        } catch {
            try? execute("ROLLBACK;")
            throw error
        }
    }

    func failAttemptAndMarkJobFailed(jobID: UUID, attemptID: Int64, failure: JobFailure) throws {
        try execute("BEGIN IMMEDIATE;")
        do {
            do {
                let attempt = try prepare("""
                UPDATE job_attempts
                SET completed_at = ?, result = 'failed', failure_stage = ?, failure_message = ?
                WHERE id = ? AND job_id = ? AND completed_at IS NULL;
                """)
                defer { sqlite3_finalize(attempt) }
                sqlite3_bind_double(attempt, 1, clock.now.timeIntervalSince1970)
                bind(failure.stage.rawValue, to: 2, in: attempt)
                bind(failure.message, to: 3, in: attempt)
                sqlite3_bind_int64(attempt, 4, attemptID)
                bind(jobID.uuidString, to: 5, in: attempt)
                try stepDone(attempt)
                guard sqlite3_changes(handle) == 1 else { throw JobStoreError.attemptNotFound }
            }
            do {
                let job = try prepare("""
                UPDATE transcription_jobs
                SET state = 'failed', failure_stage = ?, failure_message = ?,
                    updated_at = ?, completed_at = ?
                WHERE id = ? AND kind = 'recovery' AND state = 'processing'
                  AND purge_claimed_at IS NULL;
                """)
                defer { sqlite3_finalize(job) }
                bind(failure.stage.rawValue, to: 1, in: job)
                bind(failure.message, to: 2, in: job)
                sqlite3_bind_double(job, 3, clock.now.timeIntervalSince1970)
                sqlite3_bind_double(job, 4, clock.now.timeIntervalSince1970)
                bind(jobID.uuidString, to: 5, in: job)
                try stepDone(job)
                guard sqlite3_changes(handle) == 1 else { throw JobStoreError.invalidTransition }
            }
            try execute("COMMIT;")
        } catch {
            try? execute("ROLLBACK;")
            throw error
        }
    }

    func recordSourceCleanupError(jobID: UUID, message: String) throws {
        let statement = try prepare("""
        UPDATE transcription_jobs SET needs_source_cleanup = 1, source_cleanup_error = ?
        WHERE id = ? AND kind = 'recovery' AND state = 'ready';
        """)
        defer { sqlite3_finalize(statement) }
        bind(message, to: 1, in: statement)
        bind(jobID.uuidString, to: 2, in: statement)
        try stepDone(statement)
        guard sqlite3_changes(handle) == 1 else { throw JobStoreError.invalidTransition }
    }

    func completeSourceCleanup(jobID: UUID) throws {
        let statement = try prepare("""
        UPDATE transcription_jobs SET needs_source_cleanup = 0, source_cleanup_error = NULL
        WHERE id = ? AND kind = 'recovery' AND state = 'ready' AND needs_source_cleanup = 1;
        """)
        defer { sqlite3_finalize(statement) }
        bind(jobID.uuidString, to: 1, in: statement)
        try stepDone(statement)
        guard sqlite3_changes(handle) == 1 else { throw JobStoreError.invalidTransition }
    }

    func jobsNeedingSourceCleanup() throws -> [TranscriptionJob] {
        let statement = try prepare("""
        SELECT id, kind, source_reference, source_bookmark, state, progress,
               created_at, updated_at, started_at, completed_at, expires_at,
               failure_stage, failure_message, result, needs_source_cleanup, source_cleanup_error
        FROM transcription_jobs
        WHERE kind = 'recovery' AND state = 'ready' AND needs_source_cleanup = 1
        ORDER BY updated_at, id;
        """)
        defer { sqlite3_finalize(statement) }
        var jobs: [TranscriptionJob] = []
        var result = sqlite3_step(statement)
        while result == SQLITE_ROW {
            jobs.append(try decodeJob(statement))
            result = sqlite3_step(statement)
        }
        guard result == SQLITE_DONE else { throw sqlError() }
        return jobs
    }

    func attempts(jobID: UUID) throws -> [JobAttempt] {
        let statement = try prepare("""
        SELECT id, job_id, attempt_number, started_at, completed_at,
               language, speech_model, template, result, failure_stage, failure_message
        FROM job_attempts WHERE job_id = ? ORDER BY attempt_number;
        """)
        defer { sqlite3_finalize(statement) }
        bind(jobID.uuidString, to: 1, in: statement)
        var values: [JobAttempt] = []
        var result = sqlite3_step(statement)
        while result == SQLITE_ROW {
            values.append(try decodeAttempt(statement))
            result = sqlite3_step(statement)
        }
        guard result == SQLITE_DONE else { throw sqlError() }
        return values
    }

    func recoverInterruptedJobs(kind: JobKind? = nil) throws -> Int {
        let statement: OpaquePointer
        if let kind {
            statement = try prepare("""
            UPDATE transcription_jobs
            SET state = 'queued', failure_stage = NULL, failure_message = NULL,
                updated_at = ?, completed_at = NULL
            WHERE state = 'processing' AND kind = ?;
            """)
            bind(kind.rawValue, to: 2, in: statement)
        } else {
            statement = try prepare("""
            UPDATE transcription_jobs
            SET state = 'queued', failure_stage = NULL, failure_message = NULL,
                updated_at = ?, completed_at = NULL
            WHERE state = 'processing';
            """)
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_double(statement, 1, clock.now.timeIntervalSince1970)
        try stepDone(statement)
        return Int(sqlite3_changes(handle))
    }

    func replaceSpeakerName(jobID: UUID, speakerID: String, name: String) throws {
        guard try job(id: jobID) != nil else { throw JobStoreError.jobNotFound }
        let statement = try prepare("""
        INSERT INTO speaker_names (job_id, speaker_id, name) VALUES (?, ?, ?)
        ON CONFLICT(job_id, speaker_id) DO UPDATE SET name = excluded.name;
        """)
        defer { sqlite3_finalize(statement) }
        bind(jobID.uuidString, to: 1, in: statement)
        bind(speakerID, to: 2, in: statement)
        bind(name, to: 3, in: statement)
        try stepDone(statement)
    }

    func speakerNames(jobID: UUID) throws -> [String: String] {
        let statement = try prepare("SELECT speaker_id, name FROM speaker_names WHERE job_id = ?;")
        defer { sqlite3_finalize(statement) }
        bind(jobID.uuidString, to: 1, in: statement)
        var names: [String: String] = [:]
        var result = sqlite3_step(statement)
        while result == SQLITE_ROW {
            names[text(statement, 0)] = text(statement, 1)
            result = sqlite3_step(statement)
        }
        guard result == SQLITE_DONE else { throw sqlError() }
        return names
    }

    private static func isLegal(from: JobState.Kind, to: JobState.Kind) -> Bool {
        switch (from, to) {
        case (.queued, .processing), (.queued, .cancelled),
             (.processing, .processing), (.processing, .ready),
             (.processing, .failed), (.processing, .cancelled),
             (.failed, .queued), (.cancelled, .queued): true
        default: false
        }
    }

    private func decodeJob(_ statement: OpaquePointer) throws -> TranscriptionJob {
        guard let id = UUID(uuidString: text(statement, 0)),
              let kind = JobKind(rawValue: text(statement, 1)),
              let stateKind = JobState.Kind(rawValue: text(statement, 4)) else {
            throw JobStoreError.corruptData("Invalid job identity or enum encoding")
        }
        let stage = optionalText(statement, 11).flatMap(JobStage.init(rawValue:))
        let message = optionalText(statement, 12)
        let state: JobState
        switch stateKind {
        case .queued: state = .queued
        case .processing:
            guard let stage else { throw JobStoreError.corruptData("Processing job has no stage") }
            state = .processing(stage: stage)
        case .ready: state = .ready
        case .failed:
            guard let stage, let message else { throw JobStoreError.corruptData("Failed job has no failure") }
            state = .failed(JobFailure(stage: stage, message: message))
        case .cancelled: state = .cancelled
        }
        return TranscriptionJob(
            id: id, kind: kind,
            source: JobSource(reference: text(statement, 2), bookmark: optionalData(statement, 3)),
            state: state, progress: sqlite3_column_double(statement, 5),
            createdAt: date(statement, 6)!, updatedAt: date(statement, 7)!,
            startedAt: date(statement, 8), completedAt: date(statement, 9),
            expiresAt: date(statement, 10), result: optionalText(statement, 13),
            needsSourceCleanup: sqlite3_column_int(statement, 14) == 1,
            sourceCleanupError: optionalText(statement, 15)
        )
    }

    private func decodeAttempt(_ statement: OpaquePointer) throws -> JobAttempt {
        guard let jobID = UUID(uuidString: text(statement, 1)) else {
            throw JobStoreError.corruptData("Invalid attempt job ID")
        }
        let result: AttemptResult?
        switch optionalText(statement, 8) {
        case nil: result = nil
        case "succeeded": result = .succeeded
        case "failed":
            guard let rawStage = optionalText(statement, 9), let stage = JobStage(rawValue: rawStage),
                  let message = optionalText(statement, 10) else {
                throw JobStoreError.corruptData("Invalid attempt failure")
            }
            result = .failed(JobFailure(stage: stage, message: message))
        default: throw JobStoreError.corruptData("Invalid attempt result encoding")
        }
        return JobAttempt(
            id: sqlite3_column_int64(statement, 0), jobID: jobID,
            number: Int(sqlite3_column_int(statement, 2)),
            configuration: AttemptConfiguration(
                language: optionalText(statement, 5), speechModel: optionalText(statement, 6),
                template: optionalText(statement, 7)
            ),
            startedAt: date(statement, 3)!, completedAt: date(statement, 4), result: result
        )
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw sqlError()
        }
        return statement
    }

    private func stepDone(_ statement: OpaquePointer) throws {
        guard sqlite3_step(statement) == SQLITE_DONE else { throw sqlError() }
    }

    private func execute(_ sql: String) throws {
        var message: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(handle, sql, nil, nil, &message) == SQLITE_OK else {
            let detail = message.map { String(cString: $0) } ?? String(cString: sqlite3_errmsg(handle))
            sqlite3_free(message)
            throw DatabaseError.sqlFailed(detail)
        }
    }

    private func sqlError() -> DatabaseError {
        .sqlFailed(String(cString: sqlite3_errmsg(handle)))
    }

    private func bind(_ value: String?, to index: Int32, in statement: OpaquePointer) {
        guard let value else { sqlite3_bind_null(statement, index); return }
        sqlite3_bind_text(statement, index, value, -1, Self.sqliteTransient)
    }

    private func bind(_ value: Data?, to index: Int32, in statement: OpaquePointer) {
        guard let value else { sqlite3_bind_null(statement, index); return }
        _ = value.withUnsafeBytes { bytes in
            sqlite3_bind_blob(statement, index, bytes.baseAddress, Int32(bytes.count), Self.sqliteTransient)
        }
    }

    private func text(_ statement: OpaquePointer, _ index: Int32) -> String {
        String(cString: sqlite3_column_text(statement, index))
    }

    private func optionalText(_ statement: OpaquePointer, _ index: Int32) -> String? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
        return text(statement, index)
    }

    private func optionalData(_ statement: OpaquePointer, _ index: Int32) -> Data? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL,
              let bytes = sqlite3_column_blob(statement, index) else { return nil }
        return Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, index)))
    }

    private func date(_ statement: OpaquePointer, _ index: Int32) -> Date? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
        return Date(timeIntervalSince1970: sqlite3_column_double(statement, index))
    }

    private static let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
}

private final class SQLiteJobConnection: @unchecked Sendable {
    let handle: OpaquePointer

    init(handle: OpaquePointer) {
        self.handle = handle
    }

    deinit {
        sqlite3_close(handle)
    }
}

private extension JobState {
    var stage: JobStage? {
        switch self {
        case .processing(let stage): stage
        case .failed(let failure): failure.stage
        default: nil
        }
    }

    var failure: JobFailure? {
        if case .failed(let failure) = self { failure } else { nil }
    }
}

private extension AttemptResult {
    var encoding: String {
        switch self {
        case .succeeded: "succeeded"
        case .failed: "failed"
        }
    }

    var failure: JobFailure? {
        if case .failed(let failure) = self { failure } else { nil }
    }
}
