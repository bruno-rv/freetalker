import CSQLite
import Foundation

enum MediaPipelineStage: String, CaseIterable, Sendable, Equatable {
    case decode
    case transcribe
    case diarize
    case finalize
}

extension TranscriptionJobStore {
    func completedMediaStages(jobID: UUID) throws -> Set<MediaPipelineStage> {
        let statement = try mediaPrepare("SELECT stage FROM media_job_stages WHERE job_id = ?;")
        defer { sqlite3_finalize(statement) }
        mediaBind(jobID.uuidString, 1, statement)
        var stages: Set<MediaPipelineStage> = []
        var result = sqlite3_step(statement)
        while result == SQLITE_ROW {
            if let value = sqlite3_column_text(statement, 0).map({ String(cString: $0) }),
               let stage = MediaPipelineStage(rawValue: value) { stages.insert(stage) }
            result = sqlite3_step(statement)
        }
        guard result == SQLITE_DONE else { throw mediaSQLError() }
        return stages
    }

    func isDerivedMediaRegistered(jobID: UUID, path: String) throws -> Bool {
        let statement = try mediaPrepare("SELECT COUNT(*) FROM media_derived_files WHERE job_id = ? AND path = ?;")
        defer { sqlite3_finalize(statement) }; mediaBind(jobID.uuidString, 1, statement); mediaBind(path, 2, statement)
        guard sqlite3_step(statement) == SQLITE_ROW else { throw mediaSQLError() }
        return sqlite3_column_int(statement, 0) == 1
    }

    func advanceMediaStage(jobID: UUID, owner: UUID, stage: JobStage) throws {
        let statement = try mediaPrepare("UPDATE transcription_jobs SET failure_stage = ?, updated_at = ? WHERE id = ? AND kind = 'media_import' AND state = 'processing' AND lease_owner = ? AND lease_expires_at > ? AND deletion_claimed_at IS NULL;")
        defer { sqlite3_finalize(statement) }; mediaBind(stage.rawValue, 1, statement); let now = clock.now.timeIntervalSince1970
        sqlite3_bind_double(statement, 2, now); mediaBind(jobID.uuidString, 3, statement); mediaBind(owner.uuidString, 4, statement); sqlite3_bind_double(statement, 5, now)
        try mediaStep(statement); guard sqlite3_changes(handle) == 1 else { throw JobStoreError.leaseLost }
    }

    func updateMediaProgress(jobID: UUID, owner: UUID, progress: Double) throws {
        let statement = try mediaPrepare("""
        UPDATE transcription_jobs SET progress = MAX(progress, ?), updated_at = ?
        WHERE id = ? AND kind = 'media_import' AND state = 'processing'
          AND lease_owner = ? AND lease_expires_at > ? AND deletion_claimed_at IS NULL;
        """)
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_double(statement, 1, min(1, max(0, progress.isFinite ? progress : 0)))
        sqlite3_bind_double(statement, 2, clock.now.timeIntervalSince1970)
        mediaBind(jobID.uuidString, 3, statement)
        mediaBind(owner.uuidString, 4, statement)
        sqlite3_bind_double(statement, 5, clock.now.timeIntervalSince1970)
        try mediaStep(statement)
        guard sqlite3_changes(handle) == 1 else { throw JobStoreError.leaseLost }
    }

    func persistDecodedMedia(jobID: UUID, owner: UUID, derivedAudioPath: String) throws {
        try mediaTransaction {
            try assertLease(jobID: jobID, owner: owner)
            let file = try mediaPrepare("INSERT OR IGNORE INTO media_derived_files (job_id, path) VALUES (?, ?);")
            defer { sqlite3_finalize(file) }
            mediaBind(jobID.uuidString, 1, file); mediaBind(derivedAudioPath, 2, file); try mediaStep(file)
            try assertLease(jobID: jobID, owner: owner)
            try insertMediaCheckpoint(jobID: jobID, stage: .decode)
            try assertLease(jobID: jobID, owner: owner)
        }
    }

    func persistTranscript(jobID: UUID, owner: UUID, segments: [TranscriptSegment]) throws {
        guard segments.allSatisfy({ $0.start.isFinite && $0.end.isFinite && $0.start >= 0 && $0.end > $0.start }) else {
            throw JobStoreError.corruptData("Invalid transcript segment interval")
        }
        try mediaTransaction {
            try assertLease(jobID: jobID, owner: owner)
            try deleteRows("transcript_segments", jobID: jobID)
            let statement = try mediaPrepare("INSERT INTO transcript_segments (job_id, ordinal, start_time, end_time, transcript) VALUES (?, ?, ?, ?, ?);")
            defer { sqlite3_finalize(statement) }
            for (ordinal, segment) in segments.enumerated() {
                mediaBind(jobID.uuidString, 1, statement); sqlite3_bind_int(statement, 2, Int32(ordinal))
                sqlite3_bind_double(statement, 3, segment.start); sqlite3_bind_double(statement, 4, segment.end)
                mediaBind(segment.text, 5, statement); try mediaStep(statement)
                sqlite3_reset(statement); sqlite3_clear_bindings(statement)
            }
            try assertLease(jobID: jobID, owner: owner)
            try insertMediaCheckpoint(jobID: jobID, stage: .transcribe)
            try assertLease(jobID: jobID, owner: owner)
        }
    }

    func persistSpeakerTurns(jobID: UUID, owner: UUID, turns: [SpeakerTurn]) throws {
        guard turns.allSatisfy({ !$0.speakerID.isEmpty && $0.start.isFinite && $0.end.isFinite && $0.start >= 0 && $0.end > $0.start }) else {
            throw JobStoreError.corruptData("Invalid speaker turn interval")
        }
        try mediaTransaction {
            try assertLease(jobID: jobID, owner: owner)
            try deleteRows("speaker_turns", jobID: jobID)
            let statement = try mediaPrepare("INSERT INTO speaker_turns (job_id, ordinal, speaker_id, start_time, end_time) VALUES (?, ?, ?, ?, ?);")
            defer { sqlite3_finalize(statement) }
            for (ordinal, turn) in turns.enumerated() {
                mediaBind(jobID.uuidString, 1, statement); sqlite3_bind_int(statement, 2, Int32(ordinal)); mediaBind(turn.speakerID, 3, statement)
                sqlite3_bind_double(statement, 4, turn.start); sqlite3_bind_double(statement, 5, turn.end); try mediaStep(statement)
                sqlite3_reset(statement); sqlite3_clear_bindings(statement)
            }
            try assertLease(jobID: jobID, owner: owner)
            try insertMediaCheckpoint(jobID: jobID, stage: .diarize)
            try assertLease(jobID: jobID, owner: owner)
        }
    }

    func transcriptSegments(jobID: UUID) throws -> [TranscriptSegment] {
        let statement = try mediaPrepare("SELECT start_time, end_time, transcript FROM transcript_segments WHERE job_id = ? ORDER BY ordinal;")
        defer { sqlite3_finalize(statement) }; mediaBind(jobID.uuidString, 1, statement)
        var values: [TranscriptSegment] = []; var result = sqlite3_step(statement)
        while result == SQLITE_ROW { values.append(.init(start: sqlite3_column_double(statement, 0), end: sqlite3_column_double(statement, 1), text: String(cString: sqlite3_column_text(statement, 2)))); result = sqlite3_step(statement) }
        guard result == SQLITE_DONE else { throw mediaSQLError() }; return values
    }

    func speakerTurns(jobID: UUID) throws -> [SpeakerTurn] {
        let statement = try mediaPrepare("SELECT speaker_id, start_time, end_time FROM speaker_turns WHERE job_id = ? ORDER BY ordinal;")
        defer { sqlite3_finalize(statement) }; mediaBind(jobID.uuidString, 1, statement)
        var values: [SpeakerTurn] = []; var result = sqlite3_step(statement)
        while result == SQLITE_ROW { values.append(.init(speakerID: String(cString: sqlite3_column_text(statement, 0)), start: sqlite3_column_double(statement, 1), end: sqlite3_column_double(statement, 2))); result = sqlite3_step(statement) }
        guard result == SQLITE_DONE else { throw mediaSQLError() }; return values
    }

    func finalizeMediaImport(jobID: UUID, owner: UUID) throws {
        try mediaTransaction {
            try assertLease(jobID: jobID, owner: owner)
            try insertMediaCheckpoint(jobID: jobID, stage: .finalize)
            let statement = try mediaPrepare("""
            UPDATE transcription_jobs SET state = 'ready', progress = 1, failure_stage = NULL,
                failure_message = NULL, updated_at = ?, completed_at = ?,
                lease_owner = NULL, lease_expires_at = NULL
            WHERE id = ? AND kind = 'media_import' AND state = 'processing' AND lease_owner = ?
              AND lease_expires_at > ? AND deletion_claimed_at IS NULL;
            """)
            defer { sqlite3_finalize(statement) }; let now = clock.now.timeIntervalSince1970
            sqlite3_bind_double(statement, 1, now); sqlite3_bind_double(statement, 2, now); mediaBind(jobID.uuidString, 3, statement); mediaBind(owner.uuidString, 4, statement); sqlite3_bind_double(statement, 5, now)
            try mediaStep(statement); guard sqlite3_changes(handle) == 1 else { throw JobStoreError.invalidTransition }
        }
    }

    func invalidateInvalidDecodedMedia(jobID: UUID, owner: UUID) throws {
        try mediaTransaction {
            try assertLease(jobID: jobID, owner: owner)
            for table in ["speaker_turns", "transcript_segments"] { try deleteRows(table, jobID: jobID) }
            let checkpoints = try mediaPrepare("DELETE FROM media_job_stages WHERE job_id = ? AND stage IN ('decode', 'transcribe', 'diarize', 'finalize');")
            defer { sqlite3_finalize(checkpoints) }; mediaBind(jobID.uuidString, 1, checkpoints); try mediaStep(checkpoints)
            let files = try mediaPrepare("DELETE FROM media_derived_files WHERE job_id = ?;")
            defer { sqlite3_finalize(files) }; mediaBind(jobID.uuidString, 1, files); try mediaStep(files)
            try assertLease(jobID: jobID, owner: owner)
        }
    }

    func queueMediaImportRetry(jobID: UUID) throws {
        let statement = try mediaPrepare("""
        UPDATE transcription_jobs SET state = 'queued', failure_stage = NULL, failure_message = NULL,
            updated_at = ?, completed_at = NULL
        WHERE id = ? AND kind = 'media_import' AND state IN ('failed', 'cancelled')
          AND lease_owner IS NULL AND deletion_claimed_at IS NULL;
        """)
        defer { sqlite3_finalize(statement) }; sqlite3_bind_double(statement, 1, clock.now.timeIntervalSince1970); mediaBind(jobID.uuidString, 2, statement)
        try mediaStep(statement); guard sqlite3_changes(handle) == 1 else { throw JobStoreError.invalidTransition }
    }

    func deleteMediaImport(jobID: UUID, jobsDirectory: URL, fileManager: FileManager = .default) throws {
        let deletionOwner = UUID()
        let claim = try mediaPrepare("""
        UPDATE transcription_jobs SET deletion_claimed_at = COALESCE(deletion_claimed_at, ?),
            deletion_owner = ?, deletion_expires_at = ?, deletion_error = NULL, updated_at = ?
        WHERE id = ? AND kind = 'media_import' AND state IN ('ready', 'failed', 'cancelled')
          AND lease_owner IS NULL AND (deletion_claimed_at IS NULL OR deletion_error IS NOT NULL OR deletion_expires_at <= ?);
        """)
        defer { sqlite3_finalize(claim) }; let now = clock.now.timeIntervalSince1970
        sqlite3_bind_double(claim, 1, now); mediaBind(deletionOwner.uuidString, 2, claim); sqlite3_bind_double(claim, 3, now + 30)
        sqlite3_bind_double(claim, 4, now); mediaBind(jobID.uuidString, 5, claim); sqlite3_bind_double(claim, 6, now)
        try mediaStep(claim); guard sqlite3_changes(handle) == 1 else { throw JobStoreError.invalidTransition }
        guard let current = try job(id: jobID), current.kind == .mediaImport else { throw JobStoreError.jobNotFound }
        let statement = try mediaPrepare("SELECT path FROM media_derived_files WHERE job_id = ?;")
        defer { sqlite3_finalize(statement) }; mediaBind(jobID.uuidString, 1, statement)
        var paths: [String] = []; var result = sqlite3_step(statement)
        while result == SQLITE_ROW { paths.append(String(cString: sqlite3_column_text(statement, 0))); result = sqlite3_step(statement) }
        guard result == SQLITE_DONE else { throw mediaSQLError() }
        do {
            let ownedDirectory = try OwnedJobDirectory(root: jobsDirectory, jobID: jobID, create: false)
            for path in paths {
                try ownedDirectory.unlinkRegistered(path: path, source: URL(fileURLWithPath: current.source.reference), fileManager: fileManager)
            }
        } catch {
            let failure = try? mediaPrepare("UPDATE transcription_jobs SET deletion_error = ? WHERE id = ? AND deletion_owner = ?;")
            if let failure { mediaBind(error.localizedDescription, 1, failure); mediaBind(jobID.uuidString, 2, failure); mediaBind(deletionOwner.uuidString, 3, failure); try? mediaStep(failure); sqlite3_finalize(failure) }
            throw error
        }
        do {
            try mediaTransaction {
                for table in ["speaker_names", "speaker_segments", "job_attempts"] { try deleteRows(table, jobID: jobID) }
                let delete = try mediaPrepare("DELETE FROM transcription_jobs WHERE id = ? AND kind = 'media_import' AND deletion_owner = ?;")
                defer { sqlite3_finalize(delete) }; mediaBind(jobID.uuidString, 1, delete); mediaBind(deletionOwner.uuidString, 2, delete); try mediaStep(delete)
                guard sqlite3_changes(handle) == 1 else { throw JobStoreError.jobNotFound }
            }
        } catch {
            let failure = try? mediaPrepare("UPDATE transcription_jobs SET deletion_error = ? WHERE id = ? AND deletion_owner = ?;")
            if let failure { mediaBind(error.localizedDescription, 1, failure); mediaBind(jobID.uuidString, 2, failure); mediaBind(deletionOwner.uuidString, 3, failure); try? mediaStep(failure); sqlite3_finalize(failure) }
            throw error
        }
    }

    func mediaDeletionError(jobID: UUID) throws -> String? {
        let statement = try mediaPrepare("SELECT deletion_error FROM transcription_jobs WHERE id = ? AND kind = 'media_import';")
        defer { sqlite3_finalize(statement) }; mediaBind(jobID.uuidString, 1, statement)
        guard sqlite3_step(statement) == SQLITE_ROW else { throw JobStoreError.jobNotFound }
        guard sqlite3_column_type(statement, 0) != SQLITE_NULL else { return nil }
        return String(cString: sqlite3_column_text(statement, 0))
    }

    private func insertMediaCheckpoint(jobID: UUID, stage: MediaPipelineStage) throws {
        let statement = try mediaPrepare("INSERT OR IGNORE INTO media_job_stages (job_id, stage, completed_at) VALUES (?, ?, ?);")
        defer { sqlite3_finalize(statement) }; mediaBind(jobID.uuidString, 1, statement); mediaBind(stage.rawValue, 2, statement)
        sqlite3_bind_double(statement, 3, clock.now.timeIntervalSince1970); try mediaStep(statement)
    }
    private func deleteRows(_ table: String, jobID: UUID) throws { let statement = try mediaPrepare("DELETE FROM \(table) WHERE job_id = ?;"); defer { sqlite3_finalize(statement) }; mediaBind(jobID.uuidString, 1, statement); try mediaStep(statement) }
    private func mediaTransaction(_ body: () throws -> Void) throws { try mediaExecute("BEGIN IMMEDIATE;"); do { try body(); try mediaExecute("COMMIT;") } catch { try? mediaExecute("ROLLBACK;"); throw error } }
    private func mediaPrepare(_ sql: String) throws -> OpaquePointer { var statement: OpaquePointer?; guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw mediaSQLError() }; return statement }
    private func mediaStep(_ statement: OpaquePointer) throws { guard sqlite3_step(statement) == SQLITE_DONE else { throw mediaSQLError() } }
    private func mediaExecute(_ sql: String) throws { guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else { throw mediaSQLError() } }
    private func mediaSQLError() -> DatabaseError { .sqlFailed(String(cString: sqlite3_errmsg(handle))) }
    private func mediaBind(_ value: String, _ index: Int32, _ statement: OpaquePointer) { sqlite3_bind_text(statement, index, value, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
}
