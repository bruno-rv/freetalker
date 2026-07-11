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
            expiresAt: nil, result: nil
        )
    }

    func job(id: UUID) throws -> TranscriptionJob? {
        let statement = try prepare("""
        SELECT id, kind, source_reference, source_bookmark, state, progress,
               created_at, updated_at, started_at, completed_at, expires_at,
               failure_stage, failure_message, result
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
                   failure_stage, failure_message, result
            FROM transcription_jobs WHERE kind = ? ORDER BY created_at, id;
            """)
            bind(kind.rawValue, to: 1, in: statement)
        } else {
            statement = try prepare("""
            SELECT id, kind, source_reference, source_bookmark, state, progress,
                   created_at, updated_at, started_at, completed_at, expires_at,
                   failure_stage, failure_message, result
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
        WHERE id = ? AND state = ?;
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
        guard try job(id: jobID) != nil else { throw JobStoreError.jobNotFound }
        let number = try nextAttemptNumber(jobID: jobID)
        let startedAt = clock.now
        let statement = try prepare("""
        INSERT INTO job_attempts
            (job_id, attempt_number, started_at, language, speech_model, template)
        VALUES (?, ?, ?, ?, ?, ?);
        """)
        defer { sqlite3_finalize(statement) }
        bind(jobID.uuidString, to: 1, in: statement)
        sqlite3_bind_int(statement, 2, Int32(number))
        sqlite3_bind_double(statement, 3, startedAt.timeIntervalSince1970)
        bind(configuration.language, to: 4, in: statement)
        bind(configuration.speechModel, to: 5, in: statement)
        bind(configuration.template, to: 6, in: statement)
        try stepDone(statement)
        return JobAttempt(
            id: sqlite3_last_insert_rowid(handle), jobID: jobID, number: number,
            configuration: configuration, startedAt: startedAt, completedAt: nil, result: nil
        )
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

    func recoverInterruptedJobs() throws -> Int {
        let statement = try prepare("""
        UPDATE transcription_jobs
        SET state = 'queued', failure_stage = NULL, failure_message = NULL,
            updated_at = ?, completed_at = NULL
        WHERE state = 'processing';
        """)
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

    private func nextAttemptNumber(jobID: UUID) throws -> Int {
        let statement = try prepare("SELECT COALESCE(MAX(attempt_number), 0) + 1 FROM job_attempts WHERE job_id = ?;")
        defer { sqlite3_finalize(statement) }
        bind(jobID.uuidString, to: 1, in: statement)
        guard sqlite3_step(statement) == SQLITE_ROW else { throw sqlError() }
        return Int(sqlite3_column_int(statement, 0))
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
            expiresAt: date(statement, 10), result: optionalText(statement, 13)
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
